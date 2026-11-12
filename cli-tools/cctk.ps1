<#
.SYNOPSIS
    cc-switch 当天 Token 消耗趋势

.DESCRIPTION
    从 cc-switch 数据库读取当天请求日志，统计 Token 总量、按小时趋势曲线与
    各供应商用量，以彩色面积图直接打印到当前终端。
    Token 口径为 input + output + cache_read + cache_creation，与 cc-switch 界面一致。
    统计完成后可选择打开 cc-switch 桌面应用。

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    cctk
    显示今日 Token 消耗趋势与供应商分布

.NOTES
    Author: SUNC
    Version: 1.0.0
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
        '从 cc-switch 数据库读取当天请求日志，统计 Token 总量、按小时趋势曲线'
        '与各供应商用量，以彩色面积图直接打印到当前终端。'
        'Token 口径为 input + output + cache_read + cache_creation。'
    ) }
    @{ Title = '使用方式'; Lines = @(
        '直接运行脚本查看今日消耗；统计完成后可选择打开 cc-switch'
    ) }
    @{ Title = '参数'; Lines = @(
        '-Help, -h'
        '    显示帮助信息'
    ) }
    @{ Title = '示例'; Lines = @(
        'cctk                显示今日 Token 消耗趋势与供应商分布'
    ) }
)

if ($Help) {
    Show-ToolkitHelp -Command 'cctk' -Title 'Token 消耗趋势' -Sections $helpSections
    return
}

$TokenColor = '#FFB020'
$MutedColor = '#8A8A92'
$ValueColor = '#FFFFFF'
$AxisColor = '#33333A'
$ChartRows = 8

# 用 ANSI 24-bit 前景色包裹文本。
function Format-CctkAnsi {
    param(
        [string]$Text,
        [string]$HexColor
    )
    if (-not $HexColor) { return $Text }
    $hex = $HexColor.TrimStart('#')
    $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    return ("`e[38;2;$r;$g;${b}m$Text`e[0m")
}

# 把指标色与深色背景混合，得到面积填充色。
function Get-CctkMixedHex {
    param(
        [string]$HexColor,
        [int]$Percent
    )
    $hex = $HexColor.TrimStart('#')
    $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    $t = [math]::Max(0, [math]::Min(100, $Percent)) / 100.0
    $bg = 12
    $mr = [int][math]::Round($r * $t + $bg * (1 - $t))
    $mg = [int][math]::Round($g * $t + $bg * (1 - $t))
    $mb = [int][math]::Round($b * $t + $bg * (1 - $t))
    return ('#{0:X2}{1:X2}{2:X2}' -f $mr, $mg, $mb)
}

# Token 数量换算：亿以上用「亿」，不足一亿用「千万」。
function Format-TokenAmount {
    param([double]$Value)
    if ($Value -le 0) { return '0' }
    if ($Value -ge 1e8) { return ('{0:F2}亿' -f ($Value / 1e8)) }
    return ('{0:F2}千万' -f ($Value / 1e7))
}

# 用 Braille 2×4 点阵渲染按小时数值的静态面积图，每个值横向占 ColumnsPerValue 个字符列。
function Get-CctkChartLines {
    param(
        [double[]]$Values,
        [int]$Rows,
        [int]$ColumnsPerValue = 1,
        [string]$HexColor
    )
    $max = 0.0
    foreach ($v in $Values) {
        if ($v -gt $max) { $max = $v }
    }
    if ($max -le 0) {
        return @(for ($i = 0; $i -lt $Rows; $i++) { '' })
    }

    $columns = $Values.Count * $ColumnsPerValue
    $dotRows = $Rows * 4
    $mixed = Get-CctkMixedHex -HexColor $HexColor -Percent 62
    $bitLookup = @(0x01, 0x08, 0x02, 0x10, 0x04, 0x20, 0x40, 0x80)
    $lines = [System.Collections.Generic.List[string]]::new()

    for ($row = 0; $row -lt $Rows; $row++) {
        $sb = [System.Text.StringBuilder]::new()
        for ($x = 0; $x -lt $columns; $x++) {
            $index = [math]::Min($Values.Count - 1, [int][math]::Floor($x / $ColumnsPerValue))
            $value = [double]$Values[$index]
            $bits = 0
            $edge = $false
            $fill = [int][math]::Round(($value / $max) * $dotRows)
            if ($fill -gt 0) {
                $topPixel = $dotRows - $fill
                for ($subCol = 0; $subCol -lt 2; $subCol++) {
                    for ($subRow = 0; $subRow -lt 4; $subRow++) {
                        $pixel = $row * 4 + $subRow
                        if ($pixel -ge $topPixel) {
                            $bits = $bits -bor $bitLookup[$subRow * 2 + $subCol]
                            if ($pixel -eq $topPixel) { $edge = $true }
                        }
                    }
                }
            }
            if ($bits -eq 0) {
                [void]$sb.Append(' ')
            }
            else {
                $ch = [char](0x2800 + $bits)
                $color = if ($edge) { $HexColor } else { $mixed }
                [void]$sb.Append((Format-CctkAnsi -Text ([string]$ch) -HexColor $color))
            }
        }
        $lines.Add($sb.ToString())
    }
    return @($lines)
}

# 读取 cc-switch 数据库并输出当天统计 JSON。
function Get-CctkUsage {
    param([string]$DatabasePath)

    $pyScript = @'
import sqlite3, json, sys, datetime

db_path = sys.argv[1]
conn = sqlite3.connect('file:' + db_path + '?mode=ro', uri=True)
cur = conn.cursor()
today = datetime.date.today()
start = int(datetime.datetime.combine(today, datetime.time()).timestamp())
end = start + 86400
total_expr = 'COALESCE(input_tokens,0)+COALESCE(output_tokens,0)+COALESCE(cache_read_tokens,0)+COALESCE(cache_creation_tokens,0)'
join_expr = 'COALESCE(l.input_tokens,0)+COALESCE(l.output_tokens,0)+COALESCE(l.cache_read_tokens,0)+COALESCE(l.cache_creation_tokens,0)'

cur.execute(
    'SELECT COALESCE(SUM(' + total_expr + '),0), COUNT(*), '
    'COALESCE(SUM(cache_read_tokens),0), '
    'COALESCE(SUM(COALESCE(input_tokens,0)+COALESCE(cache_read_tokens,0)+COALESCE(cache_creation_tokens,0)),0) '
    'FROM proxy_request_logs WHERE created_at >= ? AND created_at < ?',
    (start, end))
total, requests, cache_read, cache_basis = cur.fetchone()

hourly = [0] * 24
cur.execute(
    "SELECT CAST(strftime('%H', created_at, 'unixepoch', 'localtime') AS INTEGER) AS h, "
    'COALESCE(SUM(' + total_expr + '),0) '
    'FROM proxy_request_logs WHERE created_at >= ? AND created_at < ? GROUP BY h',
    (start, end))
for h, value in cur.fetchall():
    if h is not None and 0 <= h < 24:
        hourly[h] = int(value)

providers = []
cur.execute(
    "SELECT COALESCE(p.name, l.provider_id, '未知供应商') AS provider, COUNT(*), "
    'COALESCE(SUM(' + join_expr + '),0) '
    'FROM proxy_request_logs l LEFT JOIN providers p ON l.provider_id = p.id '
    'WHERE l.created_at >= ? AND l.created_at < ? '
    'GROUP BY provider ORDER BY 3 DESC',
    (start, end))
for name, count, tokens in cur.fetchall():
    providers.append({'name': name, 'requests': int(count), 'tokens': int(tokens)})

result = {
    'date': today.isoformat(),
    'total': int(total),
    'requests': int(requests),
    'cacheRead': int(cache_read),
    'cacheBasis': int(cache_basis),
    'hourly': hourly,
    'providers': providers,
}
conn.close()
print(json.dumps(result, ensure_ascii=True))
'@

    $json = & python -c $pyScript $DatabasePath
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "查询 cc-switch 数据库失败，python 退出码: $LASTEXITCODE"
    }
    return ($json | ConvertFrom-Json)
}

# 按终端显示宽度右对齐/左对齐，避免中文错位。
function Format-CctkPad {
    param(
        [string]$Text,
        [int]$Width,
        [switch]$Right
    )
    if (-not $Text) { return (' ' * $Width) }
    $displayWidth = Get-DisplayWidth -Text $Text
    if ($displayWidth -ge $Width) {
        return $Text
    }
    $padding = ' ' * ($Width - $displayWidth)
    if ($Right) { return $padding + $Text }
    return $Text + $padding
}

# 截断超宽文本，保留显示宽度预算。
function Format-CctkTruncate {
    param(
        [string]$Text,
        [int]$Width
    )
    $result = ''
    $used = 0
    foreach ($ch in $Text.ToCharArray()) {
        $w = Get-DisplayWidth -Text ([string]$ch)
        if ($used + $w -gt $Width) { break }
        $result += $ch
        $used += $w
    }
    return $result
}

try {
    if (-not (Test-ExternalCommand -Name 'python')) {
        Write-ToolkitMessage -Kind Error -Text '缺少依赖 python；无法读取 cc-switch 数据库'
        exit 1
    }

    $ccSwitchDir = Get-ToolkitPath -Name UserHome -Child '.cc-switch'
    $dbPath = Join-Path $ccSwitchDir 'cc-switch.db'
    if (-not (Test-Path -LiteralPath $dbPath)) {
        Write-ToolkitMessage -Kind Error -Text "cc-switch 数据库不存在: $dbPath"
        return
    }

    # cc-switch 可执行文件路径：读跨脚本配置，支持 %LOCALAPPDATA% 等环境变量
    $config = Get-ToolkitConfig
    $ccSwitchExe = if ($config.ContainsKey('CcSwitchExePath') -and $config.CcSwitchExePath) {
        [string]$config.CcSwitchExePath
    }
    else {
        '%LOCALAPPDATA%\Programs\CC Switch\cc-switch.exe'
    }
    $ccSwitchExe = Resolve-ToolkitPathValue -Path $ccSwitchExe
    $exeAvailable = Test-Path -LiteralPath $ccSwitchExe

    $data = Get-CctkUsage -DatabasePath $dbPath

    Write-Host ''
    Write-Host (' ' + (Format-CctkAnsi -Text '今日 Token 消耗' -HexColor $ValueColor) + (Format-CctkAnsi -Text " · $($data.date)" -HexColor $MutedColor))
    Write-Host ''

    if ($data.total -le 0) {
        Write-ToolkitMessage -Kind Warning -Text '今日暂无 Token 消耗记录'
        Write-Host ''
        return
    }

    # 头部汇总
    $hitRate = if ($data.cacheBasis -gt 0) { $data.cacheRead / $data.cacheBasis * 100 } else { 0 }
    $summary = ' 总消耗  ' + (Format-CctkAnsi -Text (Format-TokenAmount -Value $data.total) -HexColor $TokenColor) +
        '    请求数  ' + (Format-CctkAnsi -Text ([string]$data.requests) -HexColor $ValueColor) +
        '    缓存命中率  ' + (Format-CctkAnsi -Text ('{0:F1}%' -f $hitRate) -HexColor $ValueColor)
    Write-Host $summary
    Write-Host ''

    # 面积图
    $hourly = @($data.hourly | ForEach-Object { [double]$_ })
    $max = ($hourly | Measure-Object -Maximum).Maximum
    $yValues = @($max, ($max * 0.75), ($max * 0.5), ($max * 0.25), 0.0)
    $yRows = @(0, [int][math]::Round($ChartRows * 0.25), [int][math]::Round($ChartRows * 0.5), [int][math]::Round($ChartRows * 0.75), ($ChartRows - 1))
    $yLabels = @{}
    for ($i = 0; $i -lt $yRows.Count; $i++) {
        $yLabels[$yRows[$i]] = Format-TokenAmount -Value $yValues[$i]
    }
    $yWidth = 1
    foreach ($label in $yLabels.Values) {
        $w = Get-DisplayWidth -Text $label
        if ($w -gt $yWidth) { $yWidth = $w }
    }

    # 每小时列数：终端足够宽时 3 列，放不下时降到 2 列
    $windowWidth = 120
    try {
        $consoleWidth = [Console]::WindowWidth
        if ($consoleWidth -gt 0) { $windowWidth = $consoleWidth }
    }
    catch {
        $windowWidth = 120
    }
    $hourColumns = 3
    while ($hourColumns -gt 1 -and ($yWidth + 2 + 24 * $hourColumns) -gt $windowWidth) {
        $hourColumns--
    }

    $chart = @(Get-CctkChartLines -Values $hourly -Rows $ChartRows -ColumnsPerValue $hourColumns -HexColor $TokenColor)

    for ($r = 0; $r -lt $ChartRows; $r++) {
        $label = if ($yLabels.ContainsKey($r)) { $yLabels[$r] } else { '' }
        $prefix = (Format-CctkPad -Text $label -Width $yWidth -Right) + ' '
        $suffix = if ($yLabels.ContainsKey($r)) { Format-CctkAnsi -Text '┤' -HexColor $AxisColor } else { Format-CctkAnsi -Text '│' -HexColor $AxisColor }
        Write-Host ($prefix + $suffix + $chart[$r])
    }

    # X 轴：每 3 小时一个刻度
    $chartWidth = $hourly.Count * $hourColumns
    $tickStep = 3 * $hourColumns
    $axisChars = [char[]]::new($chartWidth + 1)
    $axisChars[0] = [char]'└'
    for ($i = 1; $i -le $chartWidth; $i++) {
        $axisChars[$i] = if (($i - 1) % $tickStep -eq 0) { [char]'┬' } else { [char]'─' }
    }
    $labelChars = [char[]]::new($chartWidth + 1)
    for ($i = 0; $i -le $chartWidth; $i++) { $labelChars[$i] = [char]' ' }
    for ($h = 0; $h -lt 24; $h += 3) {
        $pos = $h * $hourColumns
        $text = '{0:D2}' -f $h
        $labelChars[$pos] = $text[0]
        if ($pos + 1 -le $chartWidth) { $labelChars[$pos + 1] = $text[1] }
    }
    $blankPrefix = ' ' * ($yWidth + 1)
    Write-Host ($blankPrefix + (Format-CctkAnsi -Text ([string]::new($axisChars)) -HexColor $AxisColor))
    Write-Host ($blankPrefix + (Format-CctkAnsi -Text ([string]::new($labelChars)) -HexColor $MutedColor))
    Write-Host ''

    # 供应商分布
    $nameWidth = 20
    $amountWidth = 12
    $percentWidth = 8
    $header = ' ' + (Format-CctkPad -Text '供应商' -Width $nameWidth) +
        (Format-CctkPad -Text 'Tokens' -Width $amountWidth -Right) +
        (Format-CctkPad -Text '占比' -Width $percentWidth -Right)
    Write-Host (Format-CctkAnsi -Text $header -HexColor $MutedColor)

    foreach ($provider in $data.providers) {
        if ($provider.tokens -le 0) { continue }
        $name = Format-CctkTruncate -Text ([string]$provider.name) -Width $nameWidth
        $percent = if ($data.total -gt 0) { $provider.tokens / $data.total * 100 } else { 0 }
        $line = ' ' + (Format-CctkPad -Text $name -Width $nameWidth) +
            (Format-CctkAnsi -Text (Format-CctkPad -Text (Format-TokenAmount -Value $provider.tokens) -Width $amountWidth -Right) -HexColor $TokenColor) +
            (Format-CctkAnsi -Text (Format-CctkPad -Text ('{0:F1}%' -f $percent) -Width $percentWidth -Right) -HexColor $MutedColor)
        Write-Host $line
    }
    Write-Host ''

    # 交互：打开 cc-switch
    if ($exeAvailable -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-ToolkitMessage -Kind Muted -Text '输入 y 回车打开 cc-switch，直接回车或输入 n 取消'
        $answer = Read-Host '>'
        if ($answer -match '^\s*[yY]\s*$') {
            Start-Process -FilePath $ccSwitchExe
        }
    }
    elseif (-not $exeAvailable) {
        Write-ToolkitMessage -Kind Muted -Text "未找到 cc-switch 可执行文件: $ccSwitchExe"
    }
}
catch {
    # Ctrl+C 中断视为取消，静默退出
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { return }
    Write-ToolkitMessage -Kind Error -Text $_.Exception.Message
    exit 1
}
