<#
.SYNOPSIS
    自动更新工具

.DESCRIPTION
    自动分发 AI 组件并更新软件。在线操作前自动检测并启动 Clash Verge 代理，
    并把可用代理写入 http_proxy / https_proxy——git、node、npm 都不读 Windows
    系统代理设置，缺失这两个变量时会绕过代理直连，表现为难以定位的网络报错。
    （自动关闭 Clash Verge 的功能已临时停用：由用户自行通过界面退出，
    GUI 正常退出时会一并结束 mihomo 内核并清理系统代理。）

    使用方式：
    - au                    全部执行（更新 + 分发）
    - au -s local           只分发 Subagents 与本地 Skills（不联网）
    - au -s online          只分发在线 Skills
    - au -s all             分发全部（Subagents + 本地 Skills + 在线 Skills）
    - au -u, au --update    只更新软件
    - au -h, au --help      显示帮助信息

.PARAMETER Sync
    分发组件。必须带子参数：local（本地）、online（在线）、all（全部）。
    短参数：-s

.PARAMETER Update
    只更新软件（运行 update-all.ps1）
    短参数：-u

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    au
    全部执行（更新 + 分发）

.EXAMPLE
    au -s local
    只分发 Subagents 与本地 Skills（不启动代理，不联网）

.EXAMPLE
    au -s online
    只分发在线 Skills（需要代理）

.EXAMPLE
    au -s all
    分发全部（先本地，后在线）

.EXAMPLE
    au -u
    只更新软件

.NOTES
    Author: SUNC
    Version: 2.6.1
#>

param(
    [Alias("s")]
    [switch]$Sync,

    [Alias("m")]
    [string]$Mode = "",

    [Alias("u")]
    [switch]$Update,

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

# 常量定义
#region Script Constants
$ScriptDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\maintenance"))
$SyncAgentsScript = Join-Path $ScriptDir "sync-agents.ps1"
$SyncSkillsScript = Join-Path $ScriptDir "sync-skills.ps1"
$UpdateScript = Join-Path $ScriptDir "update-all.ps1"

$ClashProcessName = "clash-verge"
$ClashExePath = (Get-ToolkitConfig).ClashExePath
$ProxyPort = (Get-ToolkitConfig).ClashProxyPort
#endregion

#region 核心函数

function Start-ClashProxy {
    <#
    .SYNOPSIS
        确保 Clash Verge 运行且代理端口就绪（Mutex 保护，防止并发重复启动）
    .DESCRIPTION
        先探测端口；不通时进程未运行则启动，随后统一等待端口就绪。
        端口始终不通时返回 $false，由调用方提示后继续——TUN 模式不依赖该端口。
    #>
    # 使用命名 Mutex 防止多个 au 进程同时启动 clash-verge
    $mutex = [System.Threading.Mutex]::new($false, "Global\AuStartClashProxy")
    $lockTaken = $false
    try {
        # 等待最多 60 秒获取锁（覆盖 clash-verge 最长启动等待时间）
        $lockTaken = $mutex.WaitOne(60000)
        if (-not $lockTaken) {
            Write-ToolkitMessage -Kind Warning -Text "等待启动锁超时，跳过 Clash Verge 检查"
            return $false
        }

        # 端口已就绪说明代理可用，无需区分进程是否由本脚本启动
        if (Test-TcpEndpoint -HostName "127.0.0.1" -Port $ProxyPort) {
            Write-ToolkitMessage -Kind Success -Text "Clash Verge 代理已就绪 (端口 $ProxyPort)"
            return $true
        }

        if (Get-Process $ClashProcessName -ErrorAction SilentlyContinue) {
            # 进程在但端口没起来：内核可能仍在初始化，也可能是 TUN 模式或端口被改
            Write-ToolkitMessage -Kind Info -Text "Clash Verge 已在运行，等待端口 $ProxyPort 就绪..."
        } elseif (Test-Path $ClashExePath) {
            Write-ToolkitMessage -Kind Info -Text "检测到 Clash Verge 未启动，正在启动..."
            Start-Process $ClashExePath
            # 给外壳与内核留出启动时间
            Start-Sleep -Seconds 3
        } else {
            Write-ToolkitMessage -Kind Warning -Text "Clash Verge 未安装: $ClashExePath"
            return $false
        }

        # 统一等待端口就绪，最多再等 5 秒
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            if (Test-TcpEndpoint -HostName "127.0.0.1" -Port $ProxyPort) {
                Write-ToolkitMessage -Kind Success -Text "Clash Verge 代理已就绪 (端口 $ProxyPort)"
                return $true
            }
            Start-Sleep -Seconds 1
        }

        Write-ToolkitMessage -Kind Warning -Text "警告：端口 $ProxyPort 未就绪（TUN 模式下可忽略），联网操作将按直连处理"
        return $false
    } finally {
        # 只有真正拿到锁才释放；未持有时调用 ReleaseMutex 会抛异常
        if ($lockTaken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-PsScript {
    <#
    .SYNOPSIS
        调用 PowerShell 脚本并输出结果
    .DESCRIPTION
        子进程启动、无超时等待与控制台模式恢复由 Toolkit 公共库的
        Invoke-ChildProcess 负责；本函数只做路径校验与结果展示。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [string[]]$Arguments = @()
    )

    if (-not (Test-Path $ScriptPath)) {
        Write-ToolkitMessage -Kind Error -Text "$Description 失败：脚本不存在 ($ScriptPath)"
        return $false
    }

    $pwshPath = (Get-Process -Id $PID).Path
    $quotedArguments = foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            '"' + ($argument -replace '"', '\"') + '"'
        }
        else {
            $argument
        }
    }
    $parts = @("`"$pwshPath`"", '-NoProfile', '-File', "`"$ScriptPath`"") + $quotedArguments
    $commandLine = $parts -join ' '

    Write-ToolkitMessage -Kind Info -Text "$Description ..."
    $result = Invoke-ChildProcess -Command $commandLine -TimeoutSeconds 0 -PassThruConsole

    if ($result.ExitCode -eq 0) {
        Write-ToolkitMessage -Kind Success -Text "$Description 成功"
        return $true
    }
    Write-ToolkitMessage -Kind Error -Text "$Description 失败 (退出码: $($result.ExitCode))"
    return $false
}

#endregion


#region 参数解析

# 参数校验：-s 必须带子参数
if ($Sync -and -not $Mode) {
    Write-ToolkitMessage -Kind Error -Text "错误：-s 必须带子参数。用法：-s local、-s online、-s all"
    return
}

if ($Mode -and $Mode -notin @("local", "online", "all")) {
    Write-ToolkitMessage -Kind Error -Text "错误：-s 只接受 local、online 或 all 子参数"
    return
}

$paramCount = @($Sync, $Update, $Help).Where({ $_ }).Count
if ($paramCount -gt 1) {
    Write-ToolkitMessage -Kind Error -Text "错误：-s、-u、-h 参数不能同时使用"
    return
}

# 显示帮助
if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path -Full
    return
}

#endregion

#region 业务逻辑

# 1. 启动代理（仅 local 模式跳过）
if ($Mode -ne "local") {
    $null = Start-ClashProxy
    # git / node / npm 都不读 Windows 系统代理，必须显式写入环境变量；
    # 后续子脚本与它们启动的进程通过继承获得，无需各自重复探测
    $proxyUrl = Set-ProxyEnvironment -ClashPort $ProxyPort
    if ($proxyUrl) {
        Write-ToolkitMessage -Kind Muted -Text "代理环境变量：$proxyUrl"
    } else {
        Write-ToolkitMessage -Kind Muted -Text "提示：未检测到可用代理，联网操作将直连（TUN 模式下属正常）"
    }
}

try {
    # 2. 按模式组装要执行的阶段
    $steps = if ($Update) {
        @{ Update = $true; Agents = $false; Local = $false; Online = $false }
    } else {
        switch ($Mode) {
            "local" { @{ Update = $false; Agents = $true; Local = $true; Online = $false } }
            "online" { @{ Update = $false; Agents = $false; Local = $false; Online = $true } }
            "all" { @{ Update = $false; Agents = $true; Local = $true; Online = $true } }
            default { @{ Update = $true; Agents = $true; Local = $true; Online = $true } }
        }
    }

    $title = if ($Update) { "软件更新" }
    elseif ($Mode -eq "local") { "本地分发" }
    elseif ($Mode -eq "online") { "在线分发" }
    elseif ($Mode -eq "all") { "全部分发" }
    else { "全部执行" }

    if ($Mode -eq "all" -or (-not $Update -and -not $Mode)) {
        Write-Host ""
        Write-ToolkitMessage -Kind Info -Text "=== 开始$title ==="
        if (-not $Mode) {
            Write-ToolkitMessage -Kind Muted -Text "提示：任一步骤失败后仍会继续执行后续步骤"
        }
        Write-Host ""
    }

    # 3. 顺序执行启用的阶段并收集结果
    $results = [ordered]@{}
    if ($steps.Update) {
        $results["更新软件"] = Invoke-PsScript -ScriptPath $UpdateScript -Description "更新软件"
        Write-Host ""
    }
    if ($steps.Agents) {
        $results["分发 Subagents"] = Invoke-PsScript -ScriptPath $SyncAgentsScript -Description "分发 Subagents"
        Write-Host ""
    }
    if ($steps.Local) {
        $results["分发本地 Skills"] = Invoke-PsScript -ScriptPath $SyncSkillsScript -Description "分发本地 Skills" -Arguments @("-Scope", "local")
        Write-Host ""
    }
    if ($steps.Online) {
        $results["分发在线 Skills"] = Invoke-PsScript -ScriptPath $SyncSkillsScript -Description "分发在线 Skills" -Arguments @("-Scope", "online")
        Write-Host ""
    }

    # 4. 汇总
    $success = -not ($results.Values -contains $false)
    if ($success) {
        Write-ToolkitMessage -Kind Success -Text "=== ${title}完成 ==="
    } else {
        Write-ToolkitMessage -Kind Error -Text "=== 部分任务执行失败 ==="
        foreach ($name in $results.Keys) {
            if (-not $results[$name]) {
                Write-ToolkitMessage -Kind Error -Text "  - $name 失败"
            }
        }
    }
}

finally {
    # 确保终端状态恢复正常
    try { [Console]::ResetColor() } catch { $null = $_ }
    try { [Console]::CursorVisible = $true } catch { $null = $_ }
}

#endregion
