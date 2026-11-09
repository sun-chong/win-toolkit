<#
.SYNOPSIS
    Claude Code 服务商状态查询

.DESCRIPTION
    查询当前 Claude Code 的服务商及模型配置。格式化显示服务商名称、模型列表等运行状态。

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    ccstat
    显示当前服务商和模型配置状态

.NOTES
    Author: SUNC
    Version: 1.1.2
#>

param(
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
    @{ Title = ''; Lines = @(
        '查询当前 Claude Code 的服务商及模型配置。格式化显示服务商名称、模型列表等运行状态。'
    ) }
    @{ Title = '使用方式'; Lines = @(
        '直接运行脚本查看当前配置状态'
    ) }
    @{ Title = '参数'; Lines = @(
        '-Help, -h'
        '    显示帮助信息'
    ) }
    @{ Title = '示例'; Lines = @(
        'ccstat              显示当前服务商和模型配置状态'
    ) }
)

$CcSwitchDir = Get-ToolkitPath -Name UserHome -Child '.cc-switch'
$SettingsPath = Join-Path $CcSwitchDir "settings.json"
$DbPath = Join-Path $CcSwitchDir "cc-switch.db"

# 显示帮助信息
if ($Help) {
    Show-ToolkitHelp -Command 'ccstat' -Title '服务商状态查询' -Sections $helpSections
    return
}

# 格式化输出表头
function Write-StatusHeader {
    Write-Host ""
    Write-ToolkitMessage -Kind Info -Text "当前 Claude Code 服务商状态"
    Write-ToolkitMessage -Kind Info -Text "─────────────────────────────"
}

# 代理接管时，实时路由与直接模式的当前服务商可能不同。
function Get-ProviderUuid {
    $liveStatePath = Join-Path $CcSwitchDir "live-state.json"
    if (Test-Path $liveStatePath) {
        $liveState = Get-Content $liveStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $claudeState = $liveState.apps.claude
        if ($claudeState.mode -eq "proxy" -and $claudeState.attached) {
            if (-not $claudeState.proxy_route) {
                throw "cc-switch 已接管 Claude Code，但未配置代理供应商路由"
            }
            return $claudeState.proxy_route
        }
    }

    if (-not (Test-Path $SettingsPath)) {
        throw "cc-switch 配置文件不存在: $SettingsPath"
    }
    try {
        $settings = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $settings.currentProviderClaude
    }
    catch {
        throw "读取 cc-switch 配置文件失败: $_"
    }
}

# 通过 Python 查询 SQLite 数据库获取服务商详情
function Get-ProviderInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uuid
    )

    if (-not (Test-Path $DbPath)) {
        throw "cc-switch 数据库不存在: $DbPath"
    }

    $pythonScript = @"
import sqlite3, json, sys
db_path = sys.argv[1]
provider_uuid = sys.argv[2]
try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT name, settings_config, website_url FROM providers WHERE id = ? AND app_type = 'claude'",
        (provider_uuid,)
    )
    row = cursor.fetchone()
    conn.close()
    if row:
        result = {
            'name': row[0],
            'settingsConfig': json.loads(row[1]),
            'websiteUrl': row[2]
        }
        print(json.dumps(result, ensure_ascii=True))
    else:
        print('null')
except Exception as e:
    print(json.dumps({'error': str(e)}, ensure_ascii=False))
    sys.exit(1)
"@

    $result = & python -c $pythonScript $DbPath $Uuid
    if ($LASTEXITCODE -ne 0) {
        throw "数据库查询失败，python 退出码: $LASTEXITCODE"
    }
    if (-not $result) {
        throw "数据库查询未返回数据，请检查 python 环境和数据库文件"
    }

    $info = $result | ConvertFrom-Json
    if ($null -eq $info) {
        throw "数据库中未找到服务商 UUID: $Uuid"
    }
    return $info
}

# 格式化输出
function Write-ProviderStatus {
    param(
        [Parameter(Mandatory = $true)]
        $ProviderInfo
    )

    $configEnv = $ProviderInfo.settingsConfig.env
    $name = $ProviderInfo.name
    $haiku = $configEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL ?? $configEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME ?? "-"
    $sonnet = $configEnv.ANTHROPIC_DEFAULT_SONNET_MODEL ?? $configEnv.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME ?? "-"
    $opus = $configEnv.ANTHROPIC_DEFAULT_OPUS_MODEL ?? $configEnv.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME ?? "-"
    $fable = $configEnv.ANTHROPIC_DEFAULT_FABLE_MODEL ?? $configEnv.ANTHROPIC_DEFAULT_FABLE_MODEL_NAME
    $baseUrl = if ($configEnv.ANTHROPIC_BASE_URL) { $configEnv.ANTHROPIC_BASE_URL } else { "-" }

    Write-StatusHeader
    Write-ToolkitMessage -Color White -Text ("服务商:   " + $name)
    Write-ToolkitMessage -Color White -Text ("Haiku:    " + $haiku)
    Write-ToolkitMessage -Color White -Text ("Sonnet:   " + $sonnet)
    Write-ToolkitMessage -Color White -Text ("Opus:     " + $opus)
    if ($fable) {
        Write-ToolkitMessage -Color White -Text ("Fable:    " + $fable)
    }
    Write-ToolkitMessage -Color White -Text ("端点:     " + $baseUrl)
    Write-Host ""
}

# 主逻辑
try {
    $uuid = Get-ProviderUuid
    if (-not $uuid) {
        Write-StatusHeader
        Write-ToolkitMessage -Kind Warning -Text "状态:     未配置服务商"
        Write-Host ""
        return
    }
    $info = Get-ProviderInfo -Uuid $uuid
    Write-ProviderStatus -ProviderInfo $info
}
catch {
    Write-ToolkitMessage -Kind Error -Text $_.Exception.Message
    return
}
