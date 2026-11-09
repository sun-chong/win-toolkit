<#
.SYNOPSIS
    按配置文件更新系统工具、包管理器及 AI 工具

.DESCRIPTION
    读取 update-all.config（自动探测 .jsonc 与 .json，优先 .jsonc），
    按其中定义的阶段顺序执行更新任务。
    每个阶段可包含三类任务，执行顺序固定为 commands → winget → repos：
      commands —— 一条命令字符串，交由 cmd.exe 执行，可用 %USERPROFILE% 等环境变量
      winget   —— 只写包 ID，脚本统一拼成
                  winget upgrade --id <id> -e --source winget -i
      repos    —— 开源仓库根目录，按其下两层 <owner>/<repo> 自动发现 git 仓库并 pull

    commands 排在 winget 之前，因此可以把 winget source update 放在同阶段的
    commands 里，确保包源先刷新再执行升级。

    所有阶段执行完毕后，脚本固定追加一个 Temp 清理阶段（删除超过 7 天的临时文件）。

    需要超时保护的命令通过 Invoke-Update 执行，失败后继续后续任务，末尾汇总失败项。
    联网操作前自动探测可用代理并写入 http_proxy / https_proxy——git、node、npm
    都不读 Windows 系统代理设置，缺失这两个变量时会绕过代理直连。

    本文件是通用引擎，具体更新清单由每台机器自己的 update-all.config.jsonc（或 .json）提供；
    该文件不入库，模板见同目录 update-all.config.jsonc.example。

.PARAMETER ConfigPath
    配置文件基础路径（可省略扩展名），默认为脚本同目录的 update-all.config。
    自动探测 .jsonc 与 .json，优先 .jsonc。
    短参数：-c

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    .\update-all.ps1
    按同目录的 update-all.config.jsonc 执行全部更新任务

.EXAMPLE
    .\update-all.ps1 -c .\my-update.config.jsonc
    使用指定的配置文件

.NOTES
    Author: SUNC
    Version: 2.0.0
#>

param(
    [Alias('c')]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'update-all.config'),

    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

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

if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path -Full
    return
}

$DefaultTimeoutSeconds = [int](Get-ToolkitConfig).DefaultTimeoutSeconds
# 配置缺失或为 0 时 Invoke-WithTimeout 的 ValidateRange 会拒绝；给一个安全保底
if ($DefaultTimeoutSeconds -lt 1) { $DefaultTimeoutSeconds = 300 }
$FailedUpdates = [Collections.Generic.List[string]]::new()

# ==========================================================================
# 通用执行函数
# ==========================================================================

function Invoke-Update {
    <#
    .SYNOPSIS
        执行单个任务：带超时、失败记录、空白分隔
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [object]$Command,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if ($Command -isnot [string] -and $Command -isnot [scriptblock]) {
        throw 'Invoke-Update 只接受命令字符串或 ScriptBlock'
    }

    $commandText = if ($Command -is [scriptblock]) { $Command.ToString() } else { $Command }
    $description = ($commandText -replace '\s+', ' ').Trim()
    if ($description.Length -gt 300) { $description = $description.Substring(0, 297) + '...' }

    # 空行放在任务开始之前：分隔上一个任务的结果与本次任务，而不是坠在本次结果之后
    Write-Host ''
    Write-ToolkitMessage -Kind Info -Text "$description （超时 $TimeoutSeconds 秒）..."

    $result = if ($Command -is [scriptblock]) {
        Invoke-WithTimeout -ScriptBlock $Command -TimeoutSeconds $TimeoutSeconds
    }
    else {
        Invoke-WithTimeout -Command $Command -TimeoutSeconds $TimeoutSeconds
    }

    if ($result.TimedOut) {
        Write-ToolkitMessage -Kind Error -Text "$description 超时（超过 $TimeoutSeconds 秒），强制结束进程树..."
        Write-ToolkitMessage -Kind Error -Text "$description 失败（超时终止）"
        $FailedUpdates.Add($description)
        return
    }

    if ($result.ExitCode -eq 0) {
        Write-ToolkitMessage -Kind Success -Text "$description 成功"
        return
    }

    Write-ToolkitMessage -Kind Error -Text "$description 失败（退出码：$($result.ExitCode)）"
    $FailedUpdates.Add($description)
    return
}

# 同名 winget 函数只负责解析并调用 winget.exe，空行由任务入口统一输出
function winget {
    if (-not $script:WingetExe) {
        $resolved = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-ToolkitMessage -Kind Warning -Text '警告：未找到 winget.exe，跳过这条命令'
            return
        }
        $script:WingetExe = $resolved.Source
    }
    & $script:WingetExe @args
}

# 阶段标题：橙黄色，前面留两个空行分隔模块
function Write-Stage {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Title
    )

    Write-Host ''
    Write-Host ''
    Write-ToolkitMessage -Color DarkYellow -Text "=== $Title ==="
    Write-Host ''
}

function Invoke-WingetUpgrade {
    <#
    .SYNOPSIS
        按包 ID 执行 winget 升级
    .DESCRIPTION
        WinGet 安装器可能等待交互确认，因此保持直接运行而不走超时包装。
    #>
    param([Parameter(Mandatory = $true)][string]$Id)

    Write-Host ''
    Write-ToolkitMessage -Kind Info -Text "winget upgrade --id $Id -e --source winget -i"
    winget upgrade --id $Id -e --source winget -i
}

function Invoke-RepoPull {
    <#
    .SYNOPSIS
        发现根目录下的开源仓库并逐个 pull
    .DESCRIPTION
        根目录按 <owner>/<repo> 排列，发现两层目录下的所有 git 仓库。
        根目录不存在时只警告并跳过，便于同一份配置在多台机器间复用。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $resolvedRoot = Resolve-ToolkitPathValue -Path $Root
    if (-not (Test-Path -LiteralPath $resolvedRoot)) {
        Write-ToolkitMessage -Kind Warning -Text "警告：开源仓库根目录不存在，跳过：$resolvedRoot"
        return
    }

    $repos = @(
        Get-ChildItem -Path $resolvedRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue } |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') }
    )

    if ($repos.Count -eq 0) {
        Write-ToolkitMessage -Kind Info -Text "未在 $resolvedRoot 下发现需要同步的开源仓库"
        return
    }

    foreach ($repo in $repos) {
        Invoke-Update -Command ('git -C "' + $repo.FullName + '" pull') -TimeoutSeconds $TimeoutSeconds
    }
}

function Invoke-UpdateStage {
    <#
    .SYNOPSIS
        执行配置中的一个阶段：commands → winget → repos
    #>
    param(
        [Parameter(Mandatory = $true)]$Stage,
        [Parameter(Mandatory = $true)][int]$StageTimeoutSeconds
    )

    $stageTimeout = if ($null -ne $Stage.timeoutSeconds) {
        [int]$Stage.timeoutSeconds
    }
    else {
        $StageTimeoutSeconds
    }

    Write-Stage $Stage.title

    # commands 先于 winget：允许 winget source update 在升级前刷新包源
    foreach ($command in @($Stage.commands)) {
        if ([string]::IsNullOrWhiteSpace([string]$command)) { continue }
        Invoke-Update -Command ([string]$command) -TimeoutSeconds $stageTimeout
    }

    foreach ($id in @($Stage.winget)) {
        if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
        Invoke-WingetUpgrade -Id ([string]$id)
    }

    foreach ($root in @($Stage.repos)) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) { continue }
        Invoke-RepoPull -Root ([string]$root) -TimeoutSeconds $stageTimeout
    }
}

function Test-UpdateConfig {
    <#
    .SYNOPSIS
        校验配置结构，返回错误列表
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $errors = [Collections.Generic.List[string]]::new()
    $stages = @($Config.stages | Where-Object { $null -ne $_ })

    if ($stages.Count -eq 0) {
        $errors.Add('配置缺少 stages，或 stages 为空')
        return $errors
    }

    $knownFields = @('title', 'timeoutSeconds', 'winget', 'commands', 'repos')

    for ($i = 0; $i -lt $stages.Count; $i++) {
        $stage = $stages[$i]
        $label = "stages[$($i + 1)]"

        if ([string]::IsNullOrWhiteSpace([string]$stage.title)) {
            $errors.Add("$label 缺少 title")
        }

        # 注意：@($null).Count 在 PowerShell 7 中为 1，必须逐个判断空值后再计数
        $taskCount = 0
        foreach ($field in 'winget', 'commands', 'repos') {
            foreach ($item in @($stage.$field)) {
                if ($null -eq $item) { continue }
                if ([string]::IsNullOrWhiteSpace([string]$item)) {
                    $errors.Add("$label 的 $field 含空白项")
                }
                else {
                    $taskCount++
                }
            }
        }
        if ($taskCount -eq 0) {
            $errors.Add("$label 没有任何 winget / commands / repos 任务")
        }

        Write-ToolkitConfigWarnings -Object $stage -KnownKeys $knownFields -Label $label
    }

    return $errors
}

# ==========================================================================
# 主流程
# ==========================================================================

# 读取并校验配置；同时支持 .jsonc 与 .json，优先 .jsonc
$configInfo = Resolve-ToolkitConfigPath -BasePath $ConfigPath
$ConfigPath = $configInfo.Path

if (-not $configInfo.Exists) {
    Write-ToolkitMessage -Kind Error -Text "错误：配置文件不存在：$ConfigPath"
    Write-ToolkitMessage -Kind Error -Text '请复制同目录的 update-all.config.jsonc.example 为 update-all.config.jsonc（或 .json），再按本机需求修改。'
    exit 1
}

try {
    $config = Read-ToolkitJson -Path $ConfigPath -ThrowOnError
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误：$($_.Exception.Message)"
    exit 1
}

$configErrors = Test-UpdateConfig -Config $config
if ($configErrors.Count -gt 0) {
    Write-ToolkitMessage -Kind Error -Text '配置校验失败：'
    foreach ($configError in $configErrors) {
        Write-ToolkitMessage -Kind Error -Text "  - $configError"
    }
    exit 1
}

$configTimeout = if ($null -ne $config.timeoutSeconds) {
    [int]$config.timeoutSeconds
}
else {
    $DefaultTimeoutSeconds
}

# Invoke-WithTimeout 只接受 1..86400，配置写 0 或负数时回退到默认值而不是中断整个更新
if ($configTimeout -lt 1 -or $configTimeout -gt 86400) {
    Write-ToolkitMessage -Kind Warning -Text "警告：timeoutSeconds=$configTimeout 超出 1..86400，改用 $DefaultTimeoutSeconds 秒"
    $configTimeout = $DefaultTimeoutSeconds
}

Write-ToolkitConfigWarnings -Object $config -KnownKeys @('timeoutSeconds', 'stages') -Label '配置'

# 代理探测：git / node / npm 都不读 Windows 系统代理，必须显式注入环境变量，
# 子命令经 cmd.exe 启动时会继承；探测不到则保持直连
$proxyUrl = Set-ProxyEnvironment
if ($proxyUrl) {
    Write-ToolkitMessage -Color DarkGray -Text "代理：$proxyUrl"
}
else {
    Write-ToolkitMessage -Color DarkGray -Text '提示：未检测到可用代理，联网操作将直连（TUN 模式下属正常）'
}

$env:npm_config_fetch_timeout = '30000'
$env:npm_config_fetch_retries = '1'

Write-ToolkitMessage -Color DarkGray -Text "配置：$ConfigPath（默认超时 $configTimeout 秒，阶段可单独覆盖）"

foreach ($stage in @($config.stages)) {
    Invoke-UpdateStage -Stage $stage -StageTimeoutSeconds $configTimeout
}

# Temp 清理固化在脚本中，固定排在所有配置阶段之后
Write-Stage '开始清理 Temp 目录下超过 7 天的临时文件'
Invoke-Update {
    $options = @{
        Path        = $env:TEMP
        Recurse     = $true
        Force       = $true
        ErrorAction = 'SilentlyContinue'
    }
    $cutoff = (Get-Date).AddDays(-7)
    $stale = @(Get-ChildItem @options | Where-Object { $_.LastWriteTime -lt $cutoff })
    $stale | Where-Object { -not $_.PSIsContainer } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $stale | Where-Object { $_.PSIsContainer } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} -TimeoutSeconds $configTimeout

Write-Stage '所有系统及资产更新任务已全部执行完毕！'
if ($FailedUpdates.Count -gt 0) {
    Write-ToolkitMessage -Kind Error -Text '以下任务失败或超时，请单独重跑：'
    foreach ($failedCommand in $FailedUpdates) {
        Write-ToolkitMessage -Kind Error -Text "  - $failedCommand"
    }
    exit 1
}
exit 0
