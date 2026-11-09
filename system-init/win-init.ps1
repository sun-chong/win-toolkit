# 不使用 #Requires -Version 7.0：本脚本负责安装 PowerShell 7

<#
.SYNOPSIS
    Windows 新机一键初始化（入口脚本）

.DESCRIPTION
    自动完成管理员提权与 PowerShell 7 自举，然后执行主流程。
    可在 Windows PowerShell 5.1 或 PowerShell 7 下运行。

.PARAMETER OriginalUserProfile
    提权前用户的 USERPROFILE，用于校验提权账户是否一致；由脚本自动传入。

.PARAMETER DryRun
    只打印将要执行的步骤，不安装、不写环境变量。

.PARAMETER List
    打印当前安装清单后退出，不做任何安装。

.PARAMETER Help
    显示帮助。

.EXAMPLE
    .\win-init.cmd
    双击运行，全自动完成。

.EXAMPLE
    .\win-init.cmd -DryRun
    只预览将执行的步骤。

.EXAMPLE
    .\win-init.cmd -List
    查看当前安装清单。

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

# 管理员判断与提权封装在公共库；入口脚本在 5.1 下不能加载 PS7 模块，单独点源 Admin.ps1
$adminModule = Join-Path $PSScriptRoot '..\lib\Admin.ps1'
if (-not (Test-Path -LiteralPath $adminModule)) {
    Write-Host "错误：未找到公共库 $adminModule" -ForegroundColor Red
    exit 1
}
. $adminModule

function Stop-EntryError {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint
    )
    Write-Host "错误：$Message" -ForegroundColor Red
    if ($Hint) { Write-Host $Hint -ForegroundColor Red }
    # 双击运行时窗口不能一闪而过，否则用户看不到指引
    if (-not $DryRun) { Read-Host '按回车关闭窗口' }
    exit 1
}

function Show-EntryHelp {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $toolkitRoot = $PSScriptRoot
        while ($toolkitRoot -and -not (Test-Path -LiteralPath (Join-Path $toolkitRoot 'lib\Toolkit.psd1'))) {
            $toolkitRoot = Split-Path -Parent $toolkitRoot
        }
        if ($toolkitRoot) {
            Import-Module (Join-Path $toolkitRoot 'lib\Toolkit.psd1') -Force
            Show-ToolkitHelp -Command 'win-init' -Title 'Windows 新机一键初始化' -Sections @(
                @{ Title = '入口'; Lines = @(
                        '.\win-init.cmd              双击运行，或不带参数执行本脚本',
                        '.\win-init.cmd -List       打印当前安装清单',
                        '.\win-init.cmd -DryRun     只打印步骤，不安装、不写系统',
                        '.\win-init.cmd -h          显示本帮助'
                    )
                }
                @{ Title = '流程'; Lines = @(
                        '1. 回车确认，自动弹 UAC 提权',
                        '2. 未安装 PowerShell 7 时静默安装，并用 pwsh 重新启动',
                        '3. 逐个安装工具，保留安装向导并等待用户点完',
                        '4. 结束时汇总成功与失败项'
                    )
                }
                @{ Title = '注意'; Lines = @(
                        'Clash Verge 安装后需在界面中配置订阅并开启系统代理'
                        '安装失败项会进入汇总清单，不会中断其余安装'
                    )
                }
            )
            return
        }
    }

    Get-Help $PSCommandPath -Full | Out-String | Write-Host
}

if ($Help) {
    Show-EntryHelp
    exit 0
}

# 只在首次启动时确认；提权重启会带上 OriginalUserProfile，不再重复询问
$isFirstRun = -not $OriginalUserProfile

# 提权前记录原用户目录，提权后用于校验账户是否一致
if (-not $OriginalUserProfile) {
    $OriginalUserProfile = $env:USERPROFILE
}

if ($isFirstRun -and -not $DryRun -and -not $List) {
    Write-Host ''
    Write-Host '即将初始化本机：安装软件、修改系统与用户环境变量。' -ForegroundColor Yellow
    Write-Host '按回车开始；输入 N 取消。' -ForegroundColor Yellow
    $answer = Read-Host '继续吗'
    if ($answer -match '^[Nn]') {
        Write-Host '已取消，未做任何修改。' -ForegroundColor Gray
        exit 0
    }
}

if (-not (Test-ToolkitAdministrator) -and -not $DryRun -and -not $List) {
    try {
        $process = Invoke-ToolkitElevation -ScriptPath $PSCommandPath `
            -ArgumentList @('-OriginalUserProfile', $OriginalUserProfile) `
            -WorkingDirectory $PSScriptRoot
    }
    catch {
        Stop-EntryError -Message '未获得管理员权限，已取消。' -Hint '请重新运行并在 UAC 对话框中选择「是」。'
    }
    # 传递主流程退出码，让 cmd 调用方看到真实结果
    exit $process.ExitCode
}

# 提权后校验账户：用其他管理员账户提权会把环境变量写到错误用户下
if ($OriginalUserProfile -and $OriginalUserProfile -ne $env:USERPROFILE) {
    Stop-EntryError -Message "当前会话的用户目录与提权前不一致（提权前：$OriginalUserProfile，当前：$env:USERPROFILE）。" `
        -Hint '请用当前登录账户提权，否则环境变量会写到错误的用户下。'
}

# 定位 PowerShell 7；未安装时静默安装后重新进入主流程
$pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshPath)) {
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwshCommand) { $pwshPath = $pwshCommand.Source }
}

if (-not (Test-Path -LiteralPath $pwshPath)) {
    # 预览与列清单承诺不安装任何东西；缺 PowerShell 7 时明确报错，不在后台静默安装
    if ($DryRun -or $List) {
        Stop-EntryError -Message '未安装 PowerShell 7，-DryRun / -List 需要 PowerShell 7 才能执行。' `
            -Hint '请先运行 winget install Microsoft.Powershell 安装 PowerShell 7，或去掉 -DryRun / -List 执行完整初始化。'
    }

    $wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCommand) {
        Stop-EntryError -Message '未找到 winget，无法安装 PowerShell 7。' `
            -Hint '请先从 Microsoft Store 安装「应用安装程序」，或安装 Microsoft.DesktopAppInstaller 后重新运行。'
    }

    Write-Host '正在安装 PowerShell 7（静默安装，请稍候）...' -ForegroundColor Cyan
    & winget install --id Microsoft.Powershell -e --source winget --silent `
        --accept-package-agreements --accept-source-agreements --wait
    # -1978335189 表示已安装；继续检查 pwsh 实际路径
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Stop-EntryError -Message "PowerShell 7 安装失败（winget 退出码 $LASTEXITCODE）。"
    }

    $pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshPath)) {
        Stop-EntryError -Message 'PowerShell 7 安装后仍未找到 pwsh.exe。'
    }
}

$mainScript = Join-Path $PSScriptRoot 'win-init.main.ps1'
if (-not (Test-Path -LiteralPath $mainScript)) {
    Stop-EntryError -Message "未找到主流程脚本 $mainScript"
}

$mainArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mainScript,
    '-OriginalUserProfile', $env:USERPROFILE
)
if ($DryRun) { $mainArgs += '-DryRun' }
if ($List) { $mainArgs += '-List' }

& $pwshPath @mainArgs
exit $LASTEXITCODE
