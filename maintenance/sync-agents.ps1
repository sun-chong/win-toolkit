<#
.SYNOPSIS
    按配置分发 Subagents 到各 Agent 目录

.DESCRIPTION
    读取 sync-agents.config.jsonc，把每个 Subagent 定义文件复制到配置中列出的目标目录。

    配置由每台机器自己维护：
      subagentsRoot —— Subagent 定义文件所在目录；相对路径按用户主目录解析
      distributions —— 分发清单，每项含 name、source、destinations
                        source 相对 subagentsRoot 解析；destinations 支持 %USERPROFILE% 等环境变量
                        destinations 中的相对路径按用户主目录解析

    脚本同时支持 .jsonc 与 .json 配置，优先使用 .jsonc；真实配置不入库，
    模板见同目录 sync-agents.config.jsonc.example。

.PARAMETER ConfigPath
    配置文件基础路径（可省略扩展名），默认为脚本同目录的 sync-agents.config。
    短参数：-c

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    .\sync-agents.ps1
    按同目录配置执行全部分发

.EXAMPLE
    .\sync-agents.ps1 -c .\my-agents.config.jsonc
    使用指定的配置文件

.NOTES
    Author: SUNC
    Version: 2.0.0
#>

param(
    [Alias("c")]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "sync-agents.config"),

    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

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

function Test-AgentsConfig {
    <#
    .SYNOPSIS
        校验配置结构，返回错误列表
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $errors = [System.Collections.Generic.List[string]]::new()

    $distributions = @($Config.distributions | Where-Object { $null -ne $_ })
    if ($distributions.Count -eq 0) {
        $errors.Add('配置缺少 distributions，或 distributions 为空')
        return $errors
    }

    $knownFields = @('name', 'source', 'destinations')

    for ($i = 0; $i -lt $distributions.Count; $i++) {
        $item = $distributions[$i]
        $label = "distributions[$($i + 1)]"

        if ([string]::IsNullOrWhiteSpace([string]$item.source)) {
            $errors.Add("$label 缺少 source")
        }

        $destinations = @($item.destinations | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($destinations.Count -eq 0) {
            $errors.Add("$label 缺少 destinations，或 destinations 为空")
        }

        Write-ToolkitConfigWarnings -Object $item -KnownKeys $knownFields -Label $label
    }

    return $errors
}

# ==========================================================================
# 主流程
# ==========================================================================

# 同时支持 .jsonc / .json，优先 .jsonc；调用方传入的扩展名会被规范化
$configInfo = Resolve-ToolkitConfigPath -BasePath $ConfigPath
$ConfigPath = $configInfo.Path

if (-not $configInfo.Exists) {
    Write-ToolkitMessage -Kind Error -Text "错误：配置文件不存在：$ConfigPath"
    Write-ToolkitMessage -Kind Error -Text '请复制同目录的 sync-agents.config.jsonc.example 为 sync-agents.config.jsonc，再按本机需求修改。'
    exit 1
}

try {
    $config = Read-ToolkitJson -Path $ConfigPath -ThrowOnError
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误：$($_.Exception.Message)"
    exit 1
}

$configErrors = Test-AgentsConfig -Config $config
if ($configErrors.Count -gt 0) {
    Write-ToolkitMessage -Kind Error -Text '配置校验失败：'
    foreach ($configError in $configErrors) {
        Write-ToolkitMessage -Kind Error -Text "  - $configError"
    }
    exit 1
}

Write-ToolkitConfigWarnings -Object $config -KnownKeys @('subagentsRoot', 'distributions') -Label '配置'

# 默认从公共配置 SubagentsRoot 读取；脚本配置 subagentsRoot 优先
$userHome = Get-ToolkitPath -Name UserHome
$defaultSubagentsRoot = [string](Get-ToolkitConfig).SubagentsRoot
$subagentRoot = if ([string]::IsNullOrWhiteSpace([string]$config.subagentsRoot)) {
    if ([string]::IsNullOrWhiteSpace($defaultSubagentsRoot)) {
        Write-ToolkitMessage -Kind Error -Text '错误：未配置 SubagentsRoot（config/toolkit.config.jsonc），脚本配置也未指定 subagentsRoot'
        exit 1
    }
    Resolve-ToolkitPathValue -Path $defaultSubagentsRoot -Base $userHome
}
else {
    Resolve-ToolkitPathValue -Path ([string]$config.subagentsRoot) -Base $userHome
}

$successCount = 0
$failCount = 0

foreach ($item in @($config.distributions)) {
    $name = if ([string]::IsNullOrWhiteSpace([string]$item.name)) { [string]$item.source } else { [string]$item.name }
    Write-Host ""
    Write-ToolkitMessage -Kind Info -Text "「Subagents」开始分发 $name"

    $source = Resolve-ToolkitPathValue -Path ([string]$item.source) -Base $subagentRoot
    if (-not (Test-Path -LiteralPath $source)) {
        Write-ToolkitMessage -Kind Error -Text "  ✗ 源文件不存在：$source"
        $failCount++
        continue
    }

    foreach ($destinationConfig in @($item.destinations)) {
        if ([string]::IsNullOrWhiteSpace([string]$destinationConfig)) { continue }

        $destination = Resolve-ToolkitPathValue -Path ([string]$destinationConfig) -Base $userHome
        try {
            if (-not (Test-Path -LiteralPath $destination)) {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
            }
            Copy-Item -Path $source -Destination $destination -Force
            Write-ToolkitMessage -Kind Success -Text "  ✓ $destination"
            $successCount++
        }
        catch {
            Write-ToolkitMessage -Kind Error -Text "  ✗ $destination：$($_.Exception.Message)"
            $failCount++
        }
    }
}

Write-Host ""
$resultKind = if ($failCount -gt 0) { 'Error' } else { 'Success' }
Write-ToolkitMessage -Kind $resultKind -Text "Subagents 分发完成：成功 $successCount 项，失败 $failCount 项"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
