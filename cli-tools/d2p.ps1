<#
.SYNOPSIS
    draw.io 转 PDF / PNG

.DESCRIPTION
    将当前终端目录下的 .drawio 文件批量转换为 PDF（默认）或 PNG。

    底层调用本机已安装的 draw.io Desktop 命令行导出，不走 COM。

    多页文件逐页导出，文件名追加页码后缀（如 图-1.pdf、图-2.pdf）；
    单页文件不加后缀。

    运行前会提示保存并关闭 draw.io。确认后脚本将强制终止全部 draw.io 进程，
    再逐页导出；每页导出等待默认最多 60 秒，进程清理与退出确认另计最多 5 秒。
    导出完成但进程未退出时，会清理本次导出进程；首次失败且清理成功时仅重试一次。
    若进程无法确认退出，立即停止转换，避免残留进程累积。

    使用方式：
    - d2p：转换当前目录下的所有 .drawio 文件为 PDF
    - d2p -p：转换为 PNG
    - d2p -o <子目录>：转换并输出到指定子目录
    - d2p -h：显示帮助信息

.PARAMETER ToPng
    输出 PNG 而非默认的 PDF
    短参数：-p

.PARAMETER OutputSubdir
    指定输出子目录名，默认当前目录
    短参数：-o
    示例：-o pdfs

.PARAMETER TimeoutSeconds
    每页导出等待的秒数，默认 60 秒；进程清理与退出确认另计最多 5 秒
    短参数：-t

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    d2p
    转换当前目录下的所有 .drawio 文件为 PDF

.EXAMPLE
    d2p -p
    转换当前目录下的所有 .drawio 文件为 PNG

.EXAMPLE
    d2p -o pdfs
    转换为 PDF 并输出到当前目录下的 pdfs 子目录

.NOTES
    Author: SUNC
    Version: 1.1.1
#>

param(
    [Alias("p")]
    [switch]$ToPng,

    [Alias("o")]
    [string]$OutputSubdir,

    [Alias("t")]
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 60,

    [Alias("h")]
    [switch]$Help
)

# 公共库引导：从脚本目录向上查找仓库根
$toolkitRoot = $PSScriptRoot
while ($toolkitRoot -and -not (Test-Path -LiteralPath (Join-Path $toolkitRoot 'lib\Toolkit.psd1'))) {
    $toolkitRoot = Split-Path -Parent $toolkitRoot
}
if (-not $toolkitRoot) {
    Write-Host '错误：未找到公共库 lib/Toolkit.psd1；请确认脚本位于仓库内' -ForegroundColor Red
    exit 1
}
Import-Module (Join-Path $toolkitRoot 'lib\Toolkit.psd1') -Force

# 帮助信息
if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path -Full
    exit
}


# ============================================
# Win32 原生进程控制
# ============================================
# 卡死进程可能已显示退出码但进程句柄仍未变为有信号；HasExited/Stop-Process 会误判。
# 这里以句柄等待确有信号作为完整退出依据，并直接用 TerminateProcess 强制回收。
$script:DrawioNativeReady = $false

function Initialize-DrawioNative {
    if ($script:DrawioNativeReady) { return }
    if (-not ('D2pNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class D2pNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr handle, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool QueryFullProcessImageName(IntPtr handle, uint flags, System.Text.StringBuilder name, ref uint size);
}
'@
    }
    $script:DrawioNativeReady = $true
}

# 打开句柄：SYNCHRONIZE 用于等待，PROCESS_TERMINATE 用于强杀
function Open-DrawioProcess {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$ProcessName
    )

    $Handle = [D2pNative]::OpenProcess(0x00100000 -bor 0x0001 -bor 0x1000, $false, $ProcessId)
    if ($Handle -eq [IntPtr]::Zero) {
        $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        # 87 / 1168：枚举之后进程已结束，属正常竞态
        if ($ErrorCode -eq 87 -or $ErrorCode -eq 1168) { return $null }
        throw "无法打开进程 PID $ProcessId（Win32 错误码 $ErrorCode）"
    }

    # PID 可能在枚举后已被复用；终止前用映像名确认仍是目标程序
    if ($ProcessName) {
        $Name = [Text.StringBuilder]::new(32768)
        [uint32]$Size = $Name.Capacity
        if (-not [D2pNative]::QueryFullProcessImageName($Handle, 0, $Name, [ref]$Size) -or
            [IO.Path]::GetFileName($Name.ToString()) -ine "$ProcessName.exe") {
            [void][D2pNative]::CloseHandle($Handle)
            throw "PID $ProcessId 已被其他进程复用，拒绝终止。"
        }
    }
    return [pscustomobject]@{ Id = $ProcessId; Handle = $Handle; OwnHandle = $true }
}

function Close-DrawioProcess {
    param([Parameter(Position = 0)][object[]]$Targets)

    foreach ($Target in $Targets) {
        # 只关闭本函数打开的句柄；Start-Process 返回的句柄归 .NET Process 所有，重复关闭会误伤内核句柄
        if ($Target -and $Target.OwnHandle -and $Target.Handle -and $Target.Handle -ne [IntPtr]::Zero) {
            [void][D2pNative]::CloseHandle($Target.Handle)
            $Target.Handle = [IntPtr]::Zero
        }
    }
}

# 只有进程句柄出现有信号状态，才代表内核层面的退出完成
function Test-DrawioProcessExited {
    param([Parameter(Mandatory = $true)]$Target)

    if (-not $Target.Handle -or $Target.Handle -eq [IntPtr]::Zero) { return $false }
    return ([D2pNative]::WaitForSingleObject($Target.Handle, 0) -eq 0)
}

function Invoke-DrawioTermination {
    param([Parameter(Mandatory = $true)]$Target)

    if (-not [D2pNative]::TerminateProcess($Target.Handle, 1)) {
        $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "TerminateProcess 失败（Win32 错误码 $ErrorCode）"
    }
}

# 强杀给定进程并在时限内确认句柄有信号；无法确认则抛错，调用方必须停止批次
function Stop-DrawioProcess {
    param(
        [Parameter(Position = 0)][object[]]$Targets,
        [int]$CleanupMilliseconds = 5000
    )

    Initialize-DrawioNative
    $Pending = @($Targets | Where-Object { -not (Test-DrawioProcessExited $_) })

    foreach ($Target in $Pending) {
        try {
            Invoke-DrawioTermination $Target
        }
        catch {
            throw "清理失败：PID $($Target.Id) 无法终止（$($_.Exception.Message)）。为避免继续累积残留，已停止转换。"
        }
    }

    $Watch = [Diagnostics.Stopwatch]::StartNew()
    while ($Watch.ElapsedMilliseconds -lt $CleanupMilliseconds) {
        $Remaining = @($Targets | Where-Object { -not (Test-DrawioProcessExited $_) })
        if ($Remaining.Count -eq 0) { return }
        Start-Sleep -Milliseconds 50
    }

    $Pids = ($Targets | Where-Object { -not (Test-DrawioProcessExited $_) } | ForEach-Object { $_.Id }) -join ', '
    throw "清理失败：PID $Pids 在 $CleanupMilliseconds 毫秒内仍未退出。为避免继续累积残留，已停止转换。"
}

# 启动确认：只有明确输入 y / yes 才继续
function Confirm-DrawioCleanup {
    Write-Host ""
    Write-ToolkitMessage -Kind Warning -Text "注意：draw.io 可能存在冻结或假死进程。"
    Write-ToolkitMessage -Kind Warning -Text "继续后将强制终止全部 draw.io 进程（包括已打开的编辑器窗口）。"
    Write-ToolkitMessage -Kind Warning -Text "请先保存所有未保存的工作并关闭 draw.io；转换期间也不要手动打开 draw.io。"
    try {
        $Answer = Read-Host "已保存并关闭 draw.io，继续？（y/N）"
    }
    catch {
        # 无交互终端（EOF）按取消处理，绝不未经确认就杀进程
        return $false
    }
    return ($Answer -match '^(y|yes)$')
}

# 会话级互斥：避免两个 d2p 同时清理并启动导出
function Enter-DrawioExportLock {
    $Mutex = [Threading.Mutex]::new($false, 'Local\SUNC-d2p-export')
    try {
        if (-not $Mutex.WaitOne(0)) {
            $Mutex.Dispose()
            throw '另一个 d2p 正在运行，请等待其结束后再试。'
        }
    }
    catch [Threading.AbandonedMutexException] {
        # 上次异常退出遗留的互斥体已自动归本进程所有，可安全继续
        $null = $_
    }
    return $Mutex
}

# DGS 密文检测参数从本地 .env 读取；缺失时跳过检测，不阻塞 draw.io 转换
$DgsEnvPath = Join-Path $toolkitRoot 'config\dgs.env'
$DgsMagic = $null
if (Test-Path -LiteralPath $DgsEnvPath) {
    try {
        $dgsEnv = Read-ToolkitEnvFile -Path $DgsEnvPath
        $magicHex = [string]$dgsEnv['DGS_MAGIC']
        if ($magicHex -match '^[0-9A-Fa-f]{8}$') {
            $DgsMagic = [byte[]]::new(4)
            for ($i = 0; $i -lt 4; $i++) {
                $DgsMagic[$i] = [Convert]::ToByte($magicHex.Substring($i * 2, 2), 16)
            }
        }
    }
    catch {
        Write-ToolkitMessage -Kind Warning -Text "读取 DGS 参数失败，跳过密文检测：$($_.Exception.Message)"
    }
}
if ($null -eq $DgsMagic) {
    Write-ToolkitMessage -Kind Warning -Text "未配置有效的 DGS_MAGIC（config/dgs.env），跳过密文检测。"
}

# 统计变量
$SuccessCount = 0
$PageCount = 0     # 累计成功导出的页数
$FailCount = 0
$FailedFiles = @()  # 记录失败的文件名及原因

# 获取当前终端所在目录（非脚本所在目录）
$WorkDir = (Get-Location).Path

# 扫描 drawio 文件
$DrawioFiles = Get-ChildItem -Path $WorkDir -Filter "*.drawio" -File

if ($DrawioFiles.Count -eq 0) {
    Write-ToolkitMessage -Kind Error -Text "错误：当前目录下未找到 .drawio 文件。"
    exit 1
}

# 定位 draw.io Desktop（draw.io.exe）
$DrawioExeCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\draw.io\draw.io.exe"),
    "C:\Program Files\draw.io\draw.io.exe"
)
$DrawioExe = $DrawioExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $DrawioExe) {
    Write-ToolkitMessage -Kind Error -Text "错误：未找到 draw.io Desktop（draw.io.exe），请先安装。"
    exit 1
}

# 互斥必须在确认和清理之前取得，防止两个 d2p 同时清理、互相干扰
try {
    $ExportLock = Enter-DrawioExportLock
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误：$($_.Exception.Message)"
    exit 1
}

# 确认前不创建输出目录；取消时不得留下任何副作用
if (-not (Confirm-DrawioCleanup)) {
    Write-ToolkitMessage -Color DarkGray -Text "已取消，未终止任何进程，也未执行转换。"
    $ExportLock.ReleaseMutex()
    $ExportLock.Dispose()
    exit 0
}

# 确认后重新枚举，清理全部 draw.io（包括冻结、假死和半退出残留）
try {
    Initialize-DrawioNative
    $DrawioProcesses = @(Get-Process -Name 'draw.io' -ErrorAction SilentlyContinue)
    if ($DrawioProcesses.Count -gt 0) {
        Write-Host "正在清理 $($DrawioProcesses.Count) 个 draw.io 进程……"
        $CleanupTargets = @()
        try {
            foreach ($DrawioProcess in $DrawioProcesses) {
                try {
                    $Opened = Open-DrawioProcess -ProcessId $DrawioProcess.Id -ProcessName 'draw.io'
                    if ($Opened) { $CleanupTargets += $Opened }
                }
                catch {
                    throw "清理失败：无法打开 PID $($DrawioProcess.Id)（$($_.Exception.Message)）。请手动关闭 draw.io 后重试。"
                }
            }
            Stop-DrawioProcess @($CleanupTargets)
        }
        finally {
            Close-DrawioProcess @($CleanupTargets)
            $DrawioProcesses | ForEach-Object { $_.Dispose() }
        }
        Write-ToolkitMessage -Kind Success -Text "draw.io 进程已清理完毕。"
    }
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误：$($_.Exception.Message)"
    $ExportLock.ReleaseMutex()
    $ExportLock.Dispose()
    exit 1
}

# 处理输出目录
if ($OutputSubdir) {
    $OutputDir = Join-Path $WorkDir $OutputSubdir

    # 处理子目录重名：递增括号法
    $Counter = 1
    while (Test-Path $OutputDir -PathType Container) {
        $OutputDir = Join-Path $WorkDir "$OutputSubdir($Counter)"
        $Counter++
    }

    # 创建输出目录
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
} else {
    $OutputDir = $WorkDir
}

# 测试输出目录写入权限
try {
    $TestFile = Join-Path $OutputDir ".write_test_$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($TestFile, "test")
    Remove-Item $TestFile -Force
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误：输出目录无写入权限: $OutputDir"
    $ExportLock.ReleaseMutex()
    $ExportLock.Dispose()
    exit 1
}

$FormatName = if ($ToPng) { "PNG" } else { "PDF" }
Write-Host "输出目录: $OutputDir（格式：$FormatName）"

# 统计 .drawio 文件的页数（解析 XML 中 <diagram> 节点数量）
function Get-DrawioPageCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Xml = [xml][System.IO.File]::ReadAllText($Path)
    return @($Xml.mxfile.diagram).Count
}

# 检测文件是否为 DGS 密文（参数见 config/dgs.env）
function Test-DgsEncrypted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($null -eq $DgsMagic) { return $false }
    $Header = [System.IO.File]::ReadAllBytes($Path)[0..3]
    for ($i = 0; $i -lt 4; $i++) {
        if ($Header[$i] -ne $DgsMagic[$i]) {
            return $false
        }
    }
    return $true
}
# 校验 draw.io 产物是否完整：仅非空或仅看退出码都不够；读取异常视为尚未就绪
function Test-DrawioOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Format
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        $File = Get-Item -LiteralPath $Path
        if ($File.Length -le 0) { return $false }

        $Stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($Format -eq 'png') {
                if ($File.Length -lt 57) { return $false }
                $Head = [byte[]]::new(16)
                [void]$Stream.Read($Head, 0, 16)
                $Signature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
                for ($i = 0; $i -lt $Signature.Count; $i++) {
                    if ($Head[$i] -ne $Signature[$i]) { return $false }
                }
                if ([Text.Encoding]::ASCII.GetString($Head, 12, 4) -ne 'IHDR') { return $false }
                [void]$Stream.Seek(-8, 'End')
                $TailBytes = [byte[]]::new(4)
                [void]$Stream.Read($TailBytes, 0, 4)
                return ([Text.Encoding]::ASCII.GetString($TailBytes) -eq 'IEND')
            }

            if ($Format -eq 'pdf') {
                if ($File.Length -lt 16) { return $false }
                $Head = [byte[]]::new(5)
                [void]$Stream.Read($Head, 0, 5)
                if ([Text.Encoding]::ASCII.GetString($Head) -ne '%PDF-') { return $false }
                $TailLength = [math]::Min(1024, $File.Length)
                [void]$Stream.Seek(-$TailLength, 'End')
                $TailBytes = [byte[]]::new($TailLength)
                [void]$Stream.Read($TailBytes, 0, $TailLength)
                $Tail = [Text.Encoding]::ASCII.GetString($TailBytes)
                # 末尾必须是 EOF 标记，且结构里有 cross-reference 定位，避免只写了个头尾的半成品
                return ($Tail -match 'startxref' -and $Tail -match '%%EOF\s*$')
            }
        }
        finally {
            $Stream.Dispose()
        }
    }
    catch {
        return $false
    }

    return $false
}

# 识别本次导出派生出的同名子进程，避免只清理主进程而留下一批 Electron 子进程
function Get-DrawioExportTargets {
    param(
        [Parameter(Mandatory = $true)][int]$RootId,
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [Parameter(Position = 2)][object[]]$Targets
    )

    $Candidates = @(Get-CimInstance Win32_Process -Filter "Name = '$ProcessName.exe'" -ErrorAction SilentlyContinue)
    $Tree = [Collections.Generic.HashSet[int]]::new()
    [void]$Tree.Add($RootId)
    do {
        $Added = $false
        foreach ($Candidate in $Candidates) {
            if ($Tree.Contains([int]$Candidate.ParentProcessId) -and -not $Tree.Contains([int]$Candidate.ProcessId)) {
                [void]$Tree.Add([int]$Candidate.ProcessId)
                $Added = $true
            }
        }
    } while ($Added)

    $Known = @($Targets | ForEach-Object { $_.Id })
    foreach ($IdValue in $Tree) {
        if ($IdValue -eq $RootId -or $IdValue -in $Known) { continue }
        try {
            $Opened = Open-DrawioProcess -ProcessId $IdValue -ProcessName $ProcessName
            if ($Opened) { $Targets += $Opened }
        }
        catch {
            $ChildError = [Exception]::new("无法确认导出子进程 PID $IdValue：$($_.Exception.Message)")
            $ChildError.Data['StopBatch'] = $true
            throw $ChildError
        }
    }
    return $Targets
}

# 独立执行一次导出：日志和半成品均独立，进程必须确认退出才算完成
function Invoke-DrawioExport {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][int]$Page,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    Initialize-DrawioNative
    $LogDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("d2p-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $LogDirectory -ErrorAction Stop
    $StdoutPath = Join-Path $LogDirectory 'stdout.txt'
    $StderrPath = Join-Path $LogDirectory 'stderr.txt'
    # 半成品与最终文件同目录，确保 Move-Item 是同盘重命名，避免跨盘复制与 DLP 转码
    $PartialPath = Join-Path (Split-Path -Parent $OutputPath) (".d2p-partial-" + [guid]::NewGuid().ToString('N') + "." + $Format)
    $Process = $null
    $Targets = @()

    try {
        # --page-index 是 1-based；手动加引号，Start-Process 不会自动为空格路径加引号
        $Arguments = "-x -f $Format --page-index $Page -o `"$PartialPath`" `"$Source`""
        $Process = Start-Process -FilePath $Executable -ArgumentList $Arguments `
            -NoNewWindow -PassThru -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath -ErrorAction Stop
        $ProcessName = $Process.ProcessName

        try {
            $Targets += [pscustomobject]@{ Id = $Process.Id; Handle = $Process.Handle }
        }
        catch {
            throw "无法取得导出进程 PID $($Process.Id) 的句柄，无法确认其是否已退出。为避免残留，已停止转换。"
        }

        $Watch = [Diagnostics.Stopwatch]::StartNew()
        $ProductReadyAt = $null
        $Exited = $false
        $LastChildScan = -1000
        $LastValidate = -1000
        while ($true) {
            $Now = $Watch.ElapsedMilliseconds
            $Exited = Test-DrawioProcessExited $Targets[0]

            if (-not $Exited -and ($Now - $LastChildScan) -ge 250) {
                $Targets = Get-DrawioExportTargets -RootId $Process.Id -ProcessName $ProcessName -Targets $Targets
                $LastChildScan = $Now
            }

            $Valid = $false
            if (($Now - $LastValidate) -ge 250) {
                $Valid = Test-DrawioOutput -Path $PartialPath -Format $Format
                $LastValidate = $Now
                if ($Valid -and -not $ProductReadyAt) { $ProductReadyAt = $Now }
            }

            if ($Exited) { break }
            if ($Valid -and $ProductReadyAt -and ($Now - $ProductReadyAt) -ge 5000) { break }
            if ($Now -ge ($TimeoutSeconds * 1000)) { break }
            Start-Sleep -Milliseconds 100
        }

        # 主进程退出后给子进程一个短暂的自然退出窗口，仍存活的一律清理
        $Targets = Get-DrawioExportTargets -RootId $Process.Id -ProcessName $ProcessName -Targets $Targets
        if ($Exited) {
            $ChildWait = [Diagnostics.Stopwatch]::StartNew()
            while ($ChildWait.ElapsedMilliseconds -lt 1000 -and
                @($Targets | Where-Object { -not (Test-DrawioProcessExited $_) }).Count -gt 0) {
                Start-Sleep -Milliseconds 100
            }
            $Targets = Get-DrawioExportTargets -RootId $Process.Id -ProcessName $ProcessName -Targets $Targets
        }
        if (@($Targets | Where-Object { -not (Test-DrawioProcessExited $_) }).Count -gt 0) {
            try {
                Stop-DrawioProcess @($Targets)
            }
            catch {
                $_.Exception.Data['StopBatch'] = $true
                throw
            }
        }

        $Valid = Test-DrawioOutput -Path $PartialPath -Format $Format
        if (-not $Valid) {
            $Detail = [System.IO.File]::ReadAllText($StderrPath).Trim()
            if (-not $Detail) { $Detail = [System.IO.File]::ReadAllText($StdoutPath).Trim() }
            if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) }
            if (-not $Detail) { $Detail = '没有可用的错误输出' }
            throw "第 $Page 页导出失败：产物缺失或无效（$Detail）"
        }

        # 进程全部确认退出后才发布产物，避免半成品占用最终文件名
        Move-Item -LiteralPath $PartialPath -Destination $OutputPath -ErrorAction Stop
    }
    catch {
        $OriginalError = $_
        try {
            $Pending = @($Targets | Where-Object { -not (Test-DrawioProcessExited $_) })
            if ($Pending.Count -gt 0) {
                Stop-DrawioProcess @($Targets)
            }
        }
        catch {
            $Combined = [Exception]::new("$($OriginalError.Exception.Message)；清理失败：$($_.Exception.Message)")
            $Combined.Data['StopBatch'] = $true
            throw $Combined
        }
        throw $OriginalError
    }
    finally {
        Close-DrawioProcess @($Targets)
        if ($Process) { $Process.Dispose() }
        Remove-Item -LiteralPath $PartialPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $LogDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}


function Write-ProgressBar {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Current,

        [Parameter(Mandatory = $true)]
        [int]$Total,

        [Parameter(Mandatory = $true)]
        [string]$CurrentFile
    )

    $Percent = [math]::Round(($Current / $Total) * 100)
    $FilledCount = [math]::Floor($Percent / 2)
    $EmptyCount = 50 - $FilledCount

    # 使用█表示已填充，使用░表示未填充
    $FilledBar = "█" * $FilledCount
    $EmptyBar = "░" * $EmptyCount

    $ProgressBar = "$FilledBar$EmptyBar"

    # 首次调用时输出占位行
    if (-not $script:ProgressBarInitialized) {
        Write-Host ""
        Write-Host ""
        $script:ProgressBarInitialized = $true
    }

    # 尝试使用 VT 序列实现原地刷新
    # 如果终端不支持，回退到逐行输出
    try {
        $ESC = [char]27
        $up2 = "${ESC}[2A"
        $clearLine = "${ESC}[2K"

        [Console]::Write($up2)
        [Console]::Write($clearLine)
        [Console]::Write("${ProgressBar} ${Percent}%`n")
        [Console]::Write($clearLine)
        [Console]::Write("[$Current/$Total] 正在转换: $CurrentFile`n")
    }
    catch {
        # 回退方案：逐行输出
        Write-Host "${ProgressBar} ${Percent}%"
        Write-Host "[$Current/$Total] 正在转换: $CurrentFile"
    }
}

# 单页最多尝试两次：只在首次失败后重试；清理失败（StopBatch）不得重试
function Invoke-DrawioPageWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][int]$Page,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    for ($Attempt = 1; $Attempt -le 2; $Attempt++) {
        try {
            Invoke-DrawioExport -Executable $Executable -Source $Source -Format $Format `
                -Page $Page -OutputPath $OutputPath -TimeoutSeconds $TimeoutSeconds
            return
        }
        catch {
            if ($_.Exception.Data['StopBatch']) { throw }
            if ($Attempt -ge 2) { throw }
            Write-ToolkitMessage -Kind Warning -Text "    警告: 第 $Page 页首次导出失败，重试一次（2/2）"
        }
    }
}

# 批量转换循环
$TotalCount = $DrawioFiles.Count
$CurrentIndex = 0
$script:BatchStopped = $false
$Fmt = $FormatName.ToLower()

foreach ($File in $DrawioFiles) {
    if ($script:BatchStopped) { break }

    $CurrentIndex++

    # 显示进度
    Write-ProgressBar -Current $CurrentIndex -Total $TotalCount -CurrentFile $File.Name

    try {
        # 检测 DGS 密文：密文无法解析也无法被 draw.io 读取
        if (Test-DgsEncrypted -Path $File.FullName) {
            Write-ToolkitMessage -Kind Error -Text "    错误: DGS 透明加密文件，请先解密（可使用 dgs-decrypt）"
            $FailedFiles += "$($File.Name) - DGS 透明加密文件"
            $FailCount++
            continue
        }

        # 解析页数
        $Pages = Get-DrawioPageCount -Path $File.FullName
        if ($Pages -lt 1) {
            $Pages = 1
        }

        $FilePageFailCount = 0

        # 逐页导出：单页不加后缀，多页追加 -页码 后缀
        for ($Page = 1; $Page -le $Pages; $Page++) {
            if ($script:BatchStopped) { break }

            if ($Pages -gt 1) {
                $OutBaseName = "$($File.BaseName)-$Page.$Fmt"
            } else {
                $OutBaseName = "$($File.BaseName).$Fmt"
            }
            $OutputPath = Get-UniqueFileName -Directory $OutputDir -BaseName $OutBaseName

            try {
                Invoke-DrawioPageWithRetry -Executable $DrawioExe -Source $File.FullName `
                    -Format $Fmt -Page $Page -OutputPath $OutputPath `
                    -TimeoutSeconds $TimeoutSeconds
                $PageCount++
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-ToolkitMessage -Kind Error -Text "    错误: 第 $Page 页导出失败 - $ErrorMessage"
                $FailedFiles += "$($File.Name) 第 $Page 页 - $ErrorMessage"
                $FailCount++
                $FilePageFailCount++
                if ($_.Exception.Data['StopBatch']) { $script:BatchStopped = $true }
            }
        }

        # 该文件至少成功导出一页才计入成功；批次中止时不能把未完成的文件算作成功
        if ($FilePageFailCount -lt $Pages -and -not $script:BatchStopped) {
            $SuccessCount++
        }
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        Write-ToolkitMessage -Kind Error -Text "    错误: $ErrorMessage"
        $FailedFiles += "$($File.Name) - $ErrorMessage"
        $FailCount++
    }
}

# 统计报告
$UnprocessedFiles = if ($script:BatchStopped) { $TotalCount - $CurrentIndex } else { 0 }
Write-Host ""
Write-ToolkitMessage -Kind Info -Text "================ 结果统计 ================"
Write-Host "输出目录: $OutputDir"
Write-Host "文件总数: $TotalCount"
Write-ToolkitMessage -Kind Success -Text "成功数量: $SuccessCount（共导出 $PageCount 页）"
if ($script:BatchStopped) {
    Write-ToolkitMessage -Kind Error -Text "批次已停止：进程无法确认清理，避免继续累积残留。"
    if ($UnprocessedFiles -gt 0) {
        Write-ToolkitMessage -Kind Warning -Text "未处理文件: $UnprocessedFiles（其余 $UnprocessedFiles 个文件未执行）"
    }
}
if ($FailCount -gt 0) {
    Write-ToolkitMessage -Kind Error -Text "失败数量: $FailCount"

    # 显示失败文件列表
    Write-Host ""
    Write-ToolkitMessage -Kind Warning -Text "失败文件列表:"
    foreach ($FailedFile in $FailedFiles) {
        Write-ToolkitMessage -Color DarkGray -Text "  - $FailedFile"
    }
} else {
    Write-ToolkitMessage -Kind Success -Text "失败数量: 0"
}
Write-ToolkitMessage -Kind Info -Text "=========================================="

$ExportLock.ReleaseMutex()
$ExportLock.Dispose()
if ($FailCount -gt 0) { exit 1 }
