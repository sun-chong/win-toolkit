<#
.SYNOPSIS
    屏幕演示模式控制

.DESCRIPTION
    开启演示模式后，系统保持屏幕常亮并屏蔽通知。支持 `on`/`off` 切换及状态查看。
    开启/关闭后都会校验进程实际状态；残留的卡死进程不再误判为已开启，
    /stop 失效时自动兜底强制结束。

.PARAMETER Action
    操作类型：on 或 off
    可作为位置参数直接使用（无需 -Action）
    示例：aw on, aw off

.PARAMETER Status
    查看当前状态
    短参数：-s

.PARAMETER Help
    查看帮助信息
    短参数：-h

.EXAMPLE
    aw on
    开启屏幕常亮模式

.EXAMPLE
    aw off
    关闭屏幕常亮模式

.EXAMPLE
    aw -s
    查看当前状态

.EXAMPLE
    aw -h
    查看帮助信息

.EXAMPLE
    aw
    切换当前状态

.NOTES
    Author: SUNC
    Version: 2.2.1
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("on", "off", IgnoreCase = $true)]
    [string]$Action,

    [Alias("s")]
    [switch]$Status,

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

$helpSections = @(
    @{ Title = '使用方式'; Lines = @(
        'aw on              开启屏幕常亮模式'
        'aw off             关闭屏幕常亮模式'
        'aw -s, aw -Status  查看当前状态'
        'aw -h, aw -Help    查看帮助信息'
        'aw                 切换当前状态'
    ) }
)
$script:PSExe = Join-Path $env:SystemRoot "System32\PresentationSettings.exe"
$script:WaitSeconds = 3
# /stop 的优雅退出窗口：正常 1 秒内生效，超时说明进程不响应，立即强杀
$script:StopGraceSeconds = 1.5
# 强制结束后等待进程消失的时间，通常 200 毫秒内完成
$script:ForceWaitSeconds = 1

function Get-AwState {
    <#
    .SYNOPSIS
        检测演示模式当前状态
    .DESCRIPTION
        进程条目残留（已退出或卡死，无法按 PID 打开）时不视为已开启
    #>
    $procs = Get-Process -Name PresentationSettings -ErrorAction SilentlyContinue
    if (-not $procs) { return $false }
    foreach ($item in $procs) {
        if (Get-Process -Id $item.Id -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Wait-AwState {
    <#
    .SYNOPSIS
        轮询等待演示模式达到期望状态，超时返回 $false
    #>
    param(
        [bool]$Expected,
        [double]$TimeoutSeconds = $script:WaitSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ((Get-AwState) -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Stop-AwProcess {
    <#
    .SYNOPSIS
        强制结束残留的 PresentationSettings 进程
    .DESCRIPTION
        进程卡死时 /stop 无效，依次用 Stop-Process、WMI Terminate 兜底
    #>
    Get-Process -Name PresentationSettings -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Wait-AwState -Expected $false -TimeoutSeconds $script:ForceWaitSeconds) { return $true }

    Get-CimInstance Win32_Process -Filter "Name='PresentationSettings.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object { $null = Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue }
    return (Wait-AwState -Expected $false -TimeoutSeconds $script:ForceWaitSeconds)
}

function Start-AwKeepAwake {
    <#
    .SYNOPSIS
        开启屏幕常亮（演示模式），并校验进程确实已启动
    .DESCRIPTION
        不用 -NoNewWindow：它会让新进程继承调用方的管道句柄，
        用 execFileSync 等同步调用时父进程退出后管道仍不关闭，调用方会一直等到超时。
    #>
    Start-Process -FilePath $script:PSExe -ArgumentList "/start"
    if (Wait-AwState -Expected $true) {
        Write-ToolkitMessage -Kind Success -Text "屏幕常亮已开启"
        return
    }
    Write-ToolkitMessage -Kind Error -Text "开启失败：PresentationSettings 进程未能启动"
    exit 1
}

function Stop-AwKeepAwake {
    <#
    .SYNOPSIS
        关闭屏幕常亮（演示模式），/stop 短时未生效时立即兜底强制结束
    .DESCRIPTION
        /stop 对刚启动或卡死的进程可能完全无效，不能长时间空等：
        只给 1.5 秒优雅退出窗口，超时立即强制结束。
        也不要等 /stop 进程自身退出——它立即返回，与演示模式进程是否退出无关，
        加 -Wait 只会等错对象并掩盖真实状态。
    #>
    $null = Start-Process -FilePath $script:PSExe -ArgumentList "/stop" -PassThru
    if (Wait-AwState -Expected $false -TimeoutSeconds $script:StopGraceSeconds) {
        Write-ToolkitMessage -Kind Success -Text "屏幕常亮已关闭"
        return
    }
    if (Stop-AwProcess) {
        Write-ToolkitMessage -Kind Warning -Text "屏幕常亮已关闭（/stop 未生效，已强制结束进程）"
        return
    }
    Write-ToolkitMessage -Kind Error -Text "关闭失败：PresentationSettings 进程仍在运行"
    exit 1
}

# 入口逻辑
if ($Help) {
    Show-ToolkitHelp -Command 'aw' -Title '屏幕演示模式控制' -Sections $helpSections
    return
}

if ($Status) {
    if (Get-AwState) {
        Write-ToolkitMessage -Kind Info -Text "当前状态：屏幕常亮已开启"
    } else {
        Write-ToolkitMessage -Kind Info -Text "当前状态：屏幕常亮已关闭"
    }
    return
}

if ($Action -eq "on") {
    if (Get-AwState) {
        Write-ToolkitMessage -Kind Warning -Text "屏幕常亮已处于开启状态"
        return
    }
    Start-AwKeepAwake
    return
}
if ($Action -eq "off") {
    if (-not (Get-AwState)) {
        Write-ToolkitMessage -Kind Warning -Text "屏幕常亮已处于关闭状态"
        return
    }
    Stop-AwKeepAwake
    return
}

# 无参数：切换
if (Get-AwState) { Stop-AwKeepAwake } else { Start-AwKeepAwake }
