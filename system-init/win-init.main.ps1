#Requires -Version 7.0

<#
.SYNOPSIS
    Windows 新机一键初始化（主流程）

.DESCRIPTION
    由 win-init.ps1 在管理员 + PowerShell 7 下调用，按配置文件中的清单执行安装与配置。
    直接运行不会提权，仅供调试与 -DryRun 预览。

.PARAMETER OriginalUserProfile
    提权前用户的 USERPROFILE；由入口脚本传入。

.PARAMETER DryRun
    只打印将要执行的步骤，不安装、不写环境变量。

.PARAMETER Help
    显示帮助。

.PARAMETER List
    打印当前安装清单后退出，不做任何安装。

.NOTES
    Author: SUNC
    Version: 2.1.0
#>
[CmdletBinding()]
param(
    [string]$OriginalUserProfile,
    [switch]$DryRun,
    [switch]$List,
    [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'

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
    Show-ToolkitHelp -Command 'win-init.main' -Title 'Windows 新机一键初始化（主流程）' -Sections @(
        @{ Title = '用法'; Lines = @(
                '入口是 win-init.ps1 或 win-init.cmd，不要直接运行本脚本',
                '.\win-init.cmd -List      打印当前安装清单',
                '.\win-init.cmd -DryRun    只预览将执行的步骤',
                '安装清单：system-init\win-init.config.jsonc（模板见 .example）'
            )
        }
        @{ Title = '流程'; Lines = @(
                '基础环境 → 按清单逐段安装（第一阶段后暂停配置代理）',
                '→ 本机自定义脚本 win-init.local.ps1（存在则执行）',
                '阶段内容与顺序由 win-init.config.jsonc 的 stages 决定',
                'winget 写包 ID；其他安装步骤写 PowerShell 代码'
            )
        }
        @{ Title = '退出码'; Lines = @(
                '0 全部成功',
                '1 存在失败或关键前置中止'
            )
        }
    )
    exit 0
}

# 入口脚本已校验一次；直接运行本脚本时再防御一次，避免环境变量写到错误用户
if ($OriginalUserProfile -and $OriginalUserProfile -ne $env:USERPROFILE) {
    Write-ToolkitMessage -Kind Error -Text "当前用户目录与提权前不一致（提权前：$OriginalUserProfile，当前：$env:USERPROFILE）"
    exit 1
}

# 新机上真实配置不入库，缺失时从模板创建，避免 Get-ToolkitConfig 直接抛错。
# 配置目录与扩展名探测和 Get-ToolkitConfig 保持一致（含 TOOLKIT_CONFIG_DIR 覆盖）
$configDir = if ($env:TOOLKIT_CONFIG_DIR) { $env:TOOLKIT_CONFIG_DIR } else { Join-Path $toolkitRoot 'config' }
$configInfo = Resolve-ToolkitConfigPath -BasePath (Join-Path $configDir 'toolkit.config')
if (-not $configInfo.Exists) {
    Copy-Item -LiteralPath "$($configInfo.Path).example" -Destination $configInfo.Path
    Write-ToolkitMessage -Kind Warning -Text "已从模板创建 $($configInfo.Path)"
}

$script:Failures = [System.Collections.Generic.List[object]]::new()
$script:SuccessCount = 0
$script:ProxyUrl = $null
$script:DryRun = [bool]$DryRun
# winget 的「已安装 / 无可用更新」退出码（0x8A15002B），install 与 upgrade 语义不同但码相同
$script:WingetNoOpExitCode = -1978335189

function Add-Success {
    param([Parameter(Mandatory)][string]$Name)
    $script:SuccessCount++
    Write-ToolkitMessage -Kind Success -Text "  ✓ $Name"
    Write-Host ''
}

function Add-Failure {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Detail
    )
    $script:Failures.Add([pscustomobject]@{ Name = $Name; Detail = $Detail })
    Write-ToolkitMessage -Kind Error -Text "  ✗ $Name — $Detail"
    Write-Host ''
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Critical
    )
    try {
        & $Action
        Add-Success -Name $Name
    }
    catch {
        Add-Failure -Name $Name -Detail $_.Exception.Message
        if ($Critical) { throw "关键前置失败：$Name" }
    }
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-ToolkitMessage -Kind Info -Text "========== $Title =========="
}

function Write-Summary {
    Write-Host ''
    Write-ToolkitMessage -Kind Info -Text '========== 结果汇总 =========='
    Write-ToolkitMessage -Kind Success -Text "成功：$script:SuccessCount 项"
    Write-ToolkitMessage -Kind Error -Text "失败：$($script:Failures.Count) 项"
    foreach ($failure in $script:Failures) {
        Write-Host "  - $($failure.Name)：$($failure.Detail)"
    }
    if ($script:Failures.Count -gt 0) {
        Write-Host ''
        Write-Host '失败项请手动重试；安装向导相关的失败通常可直接重跑对应命令。'
    }
    Write-Host ''
}

function Test-WingetAvailable {
    return Test-ExternalCommand -Name 'winget.exe'
}

function Install-WingetApp {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Critical,
        [switch]$Silent
    )

    $wingetArgs = @(
        'install', '--id', $Id, '-e', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements', '--wait'
    )
    $wingetArgs += if ($Silent) { '--silent' } else { '--interactive' }

    if ($script:DryRun) {
        Write-ToolkitMessage -Kind Info -Text "  [DryRun] winget $($wingetArgs -join ' ')"
        Add-Success -Name "$Name（预览）"
        return
    }

    Write-ToolkitMessage -Kind Info -Text "→ 安装 $Name（$Id）"
    & winget @wingetArgs
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Add-Success -Name $Name
        return
    }
    # 包已安装或已是最新，不算失败
    if ($code -eq $script:WingetNoOpExitCode) {
        Add-Success -Name "$Name（已安装，跳过）"
        return
    }

    Add-Failure -Name $Name -Detail "winget 退出码 $code"
    if ($Critical) { throw "安装失败：$Name" }
}

function Invoke-ConfiguredCommand {
    param([Parameter(Mandatory)][string]$Code)

    $label = if ($Code.Length -gt 70) { $Code.Substring(0, 67) + '...' } else { $Code }

    if ($script:DryRun) {
        Write-ToolkitMessage -Kind Info -Text "  [DryRun] $Code"
        Add-Success -Name "$label（预览）"
        return
    }

    # 代码里可能调用 exit；交给公共库在独立 pwsh 子进程中执行，退出码可被观察
    try {
        $scriptBlock = [scriptblock]::Create($Code)
    }
    catch {
        Add-Failure -Name $label -Detail "代码语法错误：$($_.Exception.Message)"
        return
    }

    Write-ToolkitMessage -Kind Info -Text "→ $label"
    $result = Invoke-ChildProcess -ScriptBlock $scriptBlock -PassThruConsole
    if ($result.ExitCode -ne 0) {
        Add-Failure -Name $label -Detail "退出码 $($result.ExitCode)"
    }
    else {
        Add-Success -Name $label
    }

    Update-ToolkitProcessPath
}

function Get-WinInitConfig {
    $configInfo = Resolve-ToolkitConfigPath -BasePath (Join-Path $PSScriptRoot 'win-init.config')
    $script:ConfigPath = $configInfo.Path
    $readPath = $configInfo.Path

    if (-not $configInfo.Exists) {
        $example = "$($configInfo.Path).example"
        if (-not (Test-Path -LiteralPath $example)) {
            throw "安装清单与模板都不存在：$($configInfo.Path)"
        }
        if ($script:DryRun -or $List) {
            # 预览与列清单不写盘：直接读模板
            $readPath = $example
            Write-ToolkitMessage -Kind Warning -Text "未找到 $($configInfo.Path)，预览使用模板 $example"
        }
        else {
            Copy-Item -LiteralPath $example -Destination $configInfo.Path
            Write-ToolkitMessage -Kind Warning -Text "已从模板创建 $($configInfo.Path)"
        }
    }

    try {
        return Read-ToolkitJson -Path $readPath -AsHashtable -ThrowOnError
    }
    catch {
        throw "安装清单读取失败：$readPath — $($_.Exception.Message)"
    }
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)]$Table,
        [Parameter(Mandatory)][string]$Key,
        $Default = $null
    )
    if ($Table -is [hashtable] -and $Table.ContainsKey($Key) -and $null -ne $Table[$Key]) {
        return $Table[$Key]
    }
    return $Default
}

function Get-ConfigList {
    param(
        [Parameter(Mandatory)]$Table,
        [Parameter(Mandatory)][string]$Key
    )
    return @(Get-ConfigValue -Table $Table -Key $Key -Default @())
}

function Invoke-ConfiguredStage {
    param(
        [Parameter(Mandatory)]$Stage,
        [switch]$Critical
    )

    $title = [string](Get-ConfigValue -Table $Stage -Key 'title' -Default '未命名阶段')

    Write-Section $title
    $failuresBefore = $script:Failures.Count

    foreach ($id in (Get-ConfigList -Table $Stage -Key 'winget')) {
        Install-WingetApp -Id $id -Name $id
    }
    foreach ($code in (Get-ConfigList -Table $Stage -Key 'commands')) {
        Invoke-ConfiguredCommand -Code $code
    }

    Update-ToolkitProcessPath

    if ($Critical -and $script:Failures.Count -gt $failuresBefore) {
        throw "关键阶段失败：$title"
    }
}

function Invoke-ProxyGate {
    Write-Section '代理'
    Write-ToolkitMessage -Kind Warning -Text '请在 Clash Verge 中完成订阅/节点配置，并开启「系统代理」。'
    if (-not $script:DryRun) {
        Read-Host '完成后按回车继续'

        try {
            $clashExe = (Get-ToolkitConfig).ClashExePath
            if ($clashExe -and (Test-Path -LiteralPath $clashExe) -and
                -not (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $clashExe
                Start-Sleep -Seconds 3
            }
        }
        catch {
            Write-ToolkitMessage -Kind Warning -Text "启动 Clash Verge 失败：$($_.Exception.Message)"
        }
    }

    # 只读探测；DryRun 下同样执行，便于验证降级路径
    try {
        $script:ProxyUrl = Set-ProxyEnvironment
    }
    catch {
        $script:ProxyUrl = $null
        Write-ToolkitMessage -Kind Warning -Text "代理探测失败：$($_.Exception.Message)"
    }
    if ($script:ProxyUrl) {
        Write-ToolkitMessage -Kind Success -Text "代理已启用：$($script:ProxyUrl)"
    }
    else {
        Write-ToolkitMessage -Kind Warning -Text '未探测到可用代理，联网步骤可能失败'
    }
}

function Show-InstallList {
    Write-Host ''
    Write-ToolkitMessage -Kind Info -Text '========== 安装清单 =========='

    foreach ($stage in (Get-ConfigList -Table $script:Config -Key 'stages')) {
        $title = [string](Get-ConfigValue -Table $stage -Key 'title' -Default '未命名阶段')
        $label = if ([bool](Get-ConfigValue -Table $stage -Key 'critical' -Default $false)) { '（关键）' } else { '' }
        Write-ToolkitMessage -Kind Info -Text "$title$label："

        foreach ($id in (Get-ConfigList -Table $stage -Key 'winget')) { Write-Host "  - $id" }
        foreach ($code in (Get-ConfigList -Table $stage -Key 'commands')) { Write-Host "  - [命令] $code" }

        Write-Host ''
    }

    Write-Host 'Windows Terminal 由脚本自动检测并安装/升级。'
    Write-ToolkitMessage -Kind Muted -Text "配置文件：$script:ConfigPath"
}

$script:Config = Get-WinInitConfig

if ($List) {
    Show-InstallList
    exit 0
}

try {
    # ---------- 基础环境 ----------
    Write-Section '基础环境'

    if (-not (Test-WingetAvailable)) {
        Write-ToolkitMessage -Kind Error -Text '未找到 winget。请先从 Microsoft Store 安装「应用安装程序」，或安装 Microsoft.DesktopAppInstaller 后重新运行。'
        throw '关键前置失败：winget 不可用'
    }

    $wingetVersion = ((& winget --version) -join '').Trim() -replace '^v', ''
    # winget 输出异常时不要中止初始化：版本检查只是提示，后续安装会给出真实退出码
    try {
        if ($wingetVersion -and [version]$wingetVersion -lt [version]'1.6') {
            Write-ToolkitMessage -Kind Warning -Text "winget 版本 $wingetVersion 低于 1.6，--wait / --interactive 行为可能不可靠，建议先升级"
        }
    }
    catch {
        Write-ToolkitMessage -Kind Warning -Text "无法解析 winget 版本（$wingetVersion），跳过版本检查"
    }

    if ($script:DryRun) {
        Write-ToolkitMessage -Kind Info -Text '  [DryRun] winget source update'
    }
    else {
        & winget source update | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-ToolkitMessage -Kind Warning -Text "winget 源更新失败（退出码 $LASTEXITCODE），继续执行"
        }
    }

    if ($script:DryRun) {
        Write-ToolkitMessage -Kind Info -Text '  [DryRun] 检测 Windows Terminal：已安装则升级，否则安装'
    }
    else {
        & winget list --id Microsoft.WindowsTerminal -e --accept-source-agreements | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Invoke-Step -Name 'Windows Terminal 升级' -Action {
                & winget upgrade --id Microsoft.WindowsTerminal -e --source winget --interactive `
                    --accept-package-agreements --accept-source-agreements --wait
                $code = $LASTEXITCODE
                # 在 upgrade 语义下表示没有可用更新
                if ($code -eq $script:WingetNoOpExitCode) { return }
                if ($code -ne 0) { throw "winget 退出码 $code" }
            }
        }
        else {
            Install-WingetApp -Id 'Microsoft.WindowsTerminal' -Name 'Windows Terminal'
        }
    }

    $stages = Get-ConfigList -Table $script:Config -Key 'stages'
    $stageIndex = 0
    foreach ($stage in $stages) {
        $stageIndex++
        $critical = [bool](Get-ConfigValue -Table $stage -Key 'critical' -Default $false)
        Invoke-ConfiguredStage -Stage $stage -Critical:$critical

        # 第一阶段（代理工具）结束后暂停，等用户配好代理再继续
        if ($stageIndex -eq 1) {
            Invoke-ProxyGate
        }
    }

    # Starship 主题放在所有阶段之后；未安装 Starship 时自动跳过
    Invoke-Step -Name 'Starship 主题' -Action {
        if ($script:DryRun) {
            Write-ToolkitMessage -Kind Info -Text '  [DryRun] starship preset gruvbox-rainbow'
            return
        }
        if (-not (Get-Command starship -ErrorAction SilentlyContinue)) {
            Write-ToolkitMessage -Kind Warning -Text '  未安装 Starship，跳过主题'
            return
        }
        $configDir = Join-Path $env:USERPROFILE '.config'
        if (-not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        & starship preset gruvbox-rainbow -o (Join-Path $configDir 'starship.toml')
        if ($LASTEXITCODE -ne 0) { throw "starship 退出码 $LASTEXITCODE" }
    }

    # profile 已由清单中的脚本创建；这里只提示可选内容
    Write-ToolkitMessage -Kind Info -Text "profile 路径：$PROFILE（内容请自行填写）"
    Write-ToolkitMessage -Kind Info -Text '如需 Starship 提示符，请在 profile 中加入：Invoke-Expression (& starship init powershell)'
    Write-ToolkitMessage -Kind Info -Text '如需预测补全，请在 profile 中加入：Set-PSReadLineOption -PredictionSource History'

    # ---------- 本机自定义 ----------
    # 环境变量、PATH 等难以写进清单的本机设置放在 win-init.local.ps1（不入库）
    $localScript = Join-Path $PSScriptRoot 'win-init.local.ps1'
    if (Test-Path -LiteralPath $localScript) {
        Write-Section '本机自定义'
        if ($script:DryRun) {
            Write-ToolkitMessage -Kind Info -Text "  [DryRun] 执行 $localScript"
            Add-Success -Name '本机自定义脚本（预览）'
        }
        else {
            Write-ToolkitMessage -Kind Info -Text "→ 执行 $localScript"
            & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -ExecutionPolicy Bypass -File $localScript
            if ($LASTEXITCODE -ne 0) {
                Add-Failure -Name '本机自定义脚本' -Detail "退出码 $LASTEXITCODE"
            }
            else {
                Add-Success -Name '本机自定义脚本'
            }
        }
    }
}
catch {
    Write-ToolkitMessage -Kind Error -Text $_.Exception.Message
    # 未被 Invoke-Step 记录的中止也要计入失败，避免异常中止却返回 0
    if ($script:Failures.Count -eq 0) {
        $script:Failures.Add([pscustomobject]@{ Name = '主流程'; Detail = $_.Exception.Message })
    }
}
finally {
    Write-Summary
    if (-not $script:DryRun) { Read-Host '按回车关闭窗口' }
}

exit ($(if ($script:Failures.Count -gt 0) { 1 } else { 0 }))
