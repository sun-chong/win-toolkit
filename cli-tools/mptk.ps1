<#
.SYNOPSIS
    magpie 当天 Token 消耗趋势

.DESCRIPTION
    从 magpie 的 usage.jsonl 读取当天请求日志，统计 Token 总量、按小时趋势曲线与
    各供应商用量，以彩色面积图直接打印到当前终端。
    Token 口径为 in + out + cache_read + cache_write，与 magpie 用量口径一致。
    统计完成后可选择打开 magpie 桌面应用。

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    mptk
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
        '从 magpie 的 usage.jsonl 读取当天请求日志，统计 Token 总量、按小时趋势曲线'
        '与各供应商用量，以彩色面积图直接打印到当前终端。'
        'Token 口径为 in + out + cache_read + cache_write。'
    ) }
    @{ Title = '使用方式'; Lines = @(
        '直接运行脚本查看今日消耗；统计完成后可选择打开 magpie'
    ) }
    @{ Title = '参数'; Lines = @(
        '-Help, -h'
        '    显示帮助信息'
    ) }
    @{ Title = '示例'; Lines = @(
        'mptk                显示今日 Token 消耗趋势与供应商分布'
    ) }
)

if ($Help) {
    Show-ToolkitHelp -Command 'mptk' -Title 'Token 消耗趋势' -Sections $helpSections
    return
}

$TokenColor = '#B380DA'
$ChartColor = '#3577D9'
$ChartFillColor = '#25508F'
$MutedColor = '#8A8A92'
$ValueColor = '#FFFFFF'
$AxisColor = '#33333A'
$ChartRows = 8

# Token 数量换算：亿以上用「亿」，千万级用「千万」，不足千万用「百万」。
function Format-TokenAmount {
    param([double]$Value)
    if ($Value -le 0) { return '0' }
    if ($Value -ge 1e8) { return ('{0:F2}亿' -f ($Value / 1e8)) }
    if ($Value -ge 1e7) { return ('{0:F2}千万' -f ($Value / 1e7)) }
    return ('{0:F2}百万' -f ($Value / 1e6))
}

# 用 Braille 2×4 点阵渲染按小时数值的静态面积图，每个值横向占 ColumnsPerValue 个字符列。
function Get-MptkChartLines {
    param(
        [double[]]$Values,
        [int]$Rows,
        [int]$ColumnsPerValue = 1,
        [string]$HexColor,
        [string]$FillHexColor = '',
        [double]$Max = 0
    )
    if ($Max -le 0) {
        foreach ($v in $Values) {
            if ($v -gt $Max) { $Max = $v }
        }
    }
    if ($Max -le 0) {
        return @(for ($i = 0; $i -lt $Rows; $i++) { '' })
    }

    $columns = $Values.Count * $ColumnsPerValue
    $dotRows = $Rows * 4
    $mixed = if ($FillHexColor) { $FillHexColor } else { Get-ToolkitMixedHex -HexColor $HexColor -Percent 62 }
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
                [void]$sb.Append((Format-ToolkitAnsi -Text ([string]$ch) -HexColor $color))
            }
        }
        $lines.Add($sb.ToString())
    }
    return @($lines)
}

# 读取 providers.json，建立 provider id（含 was 别名）到可读名称的映射。
function Get-MptkProviderNames {
    param([string]$ProvidersPath)

    $map = @{}
    $providers = Read-ToolkitJson -Path $ProvidersPath -Default $null
    if ($null -eq $providers) { return $map }

    foreach ($provider in @($providers.providers)) {
        if ($null -eq $provider) { continue }
        $id = [string]$provider.id
        $name = [string]$provider.name
        if (-not $name) { $name = $id }
        if ($id) { $map[$id] = $name }
        foreach ($alias in @($provider.was)) {
            if ($alias) { $map[[string]$alias] = $name }
        }
    }
    return $map
}

# 安全读取一行 JSON 中的数值字段，缺失、为空或非数值时按 0。
function Get-MptkRowToken {
    param($Row, [string]$Name)
    $prop = $Row.PSObject.Properties[$Name]
    if ($null -eq $prop -or -not $prop.Value) { return 0.0 }
    try {
        return [double]$prop.Value
    }
    catch {
        return 0.0
    }
}

# 读取 magpie 用量日志并输出当天统计。
function Get-MptkUsage {
    param(
        [string]$UsagePath,
        [string]$ProvidersPath
    )

    $hourly = [double[]]::new(24)
    $providerTotals = @{}
    $today = [datetime]::Today
    $total = 0.0
    $requests = 0
    $cacheRead = 0.0
    $cacheBasis = 0.0

    if (Test-Path -LiteralPath $UsagePath) {
        $providerNames = Get-MptkProviderNames -ProvidersPath $ProvidersPath

        # 共享读取：magpie 可能正在追加写入，不能独占打开
        $stream = $null
        $reader = $null
        try {
            $stream = [System.IO.FileStream]::new(
                $UsagePath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            while ($null -ne ($line = $reader.ReadLine())) {
                if (-not $line.Trim()) { continue }
                $row = try { $line | ConvertFrom-Json } catch { $null }
                if ($null -eq $row) { continue }
                # 健康探测与模型列表请求不计入用量与请求数
                if ([string]$row.source -eq 'probe' -or [string]$row.kind -eq 'model_list') { continue }

                $local = try {
                    [datetimeoffset]::Parse(
                        [string]$row.t,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None).LocalDateTime
                }
                catch { $null }
                if ($null -eq $local -or $local.Date -ne $today) { continue }

                $inTokens = Get-MptkRowToken -Row $row -Name 'in'
                $outTokens = Get-MptkRowToken -Row $row -Name 'out'
                $readTokens = Get-MptkRowToken -Row $row -Name 'cache_read'
                $writeTokens = Get-MptkRowToken -Row $row -Name 'cache_write'

                $rowTotal = $inTokens + $outTokens + $readTokens + $writeTokens
                $total += $rowTotal
                $requests++
                $cacheRead += $readTokens
                $cacheBasis += $inTokens + $readTokens + $writeTokens
                $hourly[$local.Hour] += $rowTotal

                $providerId = [string]$row.provider
                if (-not $providerId) { $providerId = [string]$row.host }
                $name = if ($providerNames.ContainsKey($providerId)) { $providerNames[$providerId] } else { $providerId }
                if (-not $name) { $name = '未知供应商' }
                $providerTotals[$name] += $rowTotal
            }
        }
        catch [System.IO.IOException] {
            throw "无法读取 magpie 用量文件：$UsagePath — $($_.Exception.Message)"
        }
        catch [System.UnauthorizedAccessException] {
            throw "无权读取 magpie 用量文件：$UsagePath — $($_.Exception.Message)"
        }
        finally {
            if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
        }
    }

    $providers = @($providerTotals.GetEnumerator() |
        Sort-Object -Property Value -Descending |
        ForEach-Object { [pscustomobject]@{ name = [string]$_.Key; tokens = [long]$_.Value } })

    return [pscustomobject]@{
        total      = [long]$total
        requests   = [int]$requests
        cacheRead  = [long]$cacheRead
        cacheBasis = [long]$cacheBasis
        hourly     = $hourly
        providers  = $providers
    }
}

try {
    $usagePath = Get-ToolkitPath -Name UserHome -Child '.config\magpie\usage.jsonl'
    if (-not (Test-Path -LiteralPath $usagePath)) {
        Write-ToolkitMessage -Kind Error -Text "magpie 用量文件不存在: $usagePath"
        return
    }
    $providersPath = Join-Path (Split-Path -Parent $usagePath) 'providers.json'

    # magpie 可执行文件路径：读跨脚本配置，支持 %LOCALAPPDATA% 等环境变量
    $config = Get-ToolkitConfig
    $magpieExe = if ($config.ContainsKey('MagpieExePath') -and $config.MagpieExePath) {
        [string]$config.MagpieExePath
    }
    else {
        '%LOCALAPPDATA%\Programs\magpie\magpie.exe'
    }
    $magpieExe = Resolve-ToolkitPathValue -Path $magpieExe
    $exeAvailable = Test-Path -LiteralPath $magpieExe

    $data = Get-MptkUsage -UsagePath $usagePath -ProvidersPath $providersPath

    Write-Host ''
    $nowText = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host (' ' + (Format-ToolkitAnsi -Text '今日 Token 消耗' -HexColor $ValueColor) + (Format-ToolkitAnsi -Text " · $nowText" -HexColor $MutedColor))

    if ($data.total -le 0) {
        Write-ToolkitMessage -Kind Warning -Text '今日暂无 Token 消耗记录'
        Write-Host ''
        return
    }

    # 头部汇总
    $hitRate = if ($data.cacheBasis -gt 0) { $data.cacheRead / $data.cacheBasis * 100 } else { 0 }
    $summary = ' 总消耗  ' + (Format-ToolkitAnsi -Text (Format-TokenAmount -Value $data.total) -HexColor $TokenColor) +
        '    请求数  ' + (Format-ToolkitAnsi -Text ([string]$data.requests) -HexColor $ValueColor) +
        '    缓存命中率  ' + (Format-ToolkitAnsi -Text ('{0:F1}%' -f $hitRate) -HexColor $ValueColor)
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

    # 每小时列数：终端足够宽时 3 列，放不下时按宽度收缩
    $windowWidth = Get-ToolkitConsoleWidth
    $hourColumns = [math]::Max(1, [math]::Min(3, [int][math]::Floor(($windowWidth - $yWidth - 2) / 24)))

    $chart = @(Get-MptkChartLines -Values $hourly -Rows $ChartRows -ColumnsPerValue $hourColumns -HexColor $ChartColor -FillHexColor $ChartFillColor -Max $max)

    for ($r = 0; $r -lt $ChartRows; $r++) {
        $label = if ($yLabels.ContainsKey($r)) { $yLabels[$r] } else { '' }
        $prefix = (Format-ToolkitDisplayText -Text $label -Width $yWidth -Align Right) + ' '
        $suffix = if ($yLabels.ContainsKey($r)) { Format-ToolkitAnsi -Text '┤' -HexColor $AxisColor } else { Format-ToolkitAnsi -Text '│' -HexColor $AxisColor }
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
    Write-Host ($blankPrefix + (Format-ToolkitAnsi -Text ([string]::new($axisChars)) -HexColor $AxisColor))
    Write-Host ($blankPrefix + (Format-ToolkitAnsi -Text ([string]::new($labelChars)) -HexColor $MutedColor))
    Write-Host ''

    # 供应商分布
    $nameWidth = 20
    $amountWidth = 12
    $percentWidth = 8
    $header = ' ' + (Format-ToolkitDisplayText -Text '供应商' -Width $nameWidth) +
        (Format-ToolkitDisplayText -Text 'Tokens' -Width $amountWidth -Align Right) +
        (Format-ToolkitDisplayText -Text '占比' -Width $percentWidth -Align Right)
    Write-Host (Format-ToolkitAnsi -Text $header -HexColor $MutedColor)

    foreach ($provider in $data.providers) {
        if ($provider.tokens -le 0) { continue }
        $name = Format-ToolkitDisplayText -Text ([string]$provider.name) -Width $nameWidth -Truncate -NoPad
        $percent = $provider.tokens / $data.total * 100
        $line = ' ' + (Format-ToolkitDisplayText -Text $name -Width $nameWidth) +
            (Format-ToolkitAnsi -Text (Format-ToolkitDisplayText -Text (Format-TokenAmount -Value $provider.tokens) -Width $amountWidth -Align Right) -HexColor $TokenColor) +
            (Format-ToolkitAnsi -Text (Format-ToolkitDisplayText -Text ('{0:F1}%' -f $percent) -Width $percentWidth -Align Right) -HexColor $MutedColor)
        Write-Host $line
    }
    Write-Host ''

    # 交互：打开 magpie
    if ($exeAvailable -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $answer = Read-Host '打开 magpie？（y/N）'
        if ($answer -match '^\s*[yY]\s*$') {
            Start-Process -FilePath $magpieExe
        }
    }
    elseif (-not $exeAvailable) {
        Write-ToolkitMessage -Kind Muted -Text "未找到 magpie 可执行文件: $magpieExe"
    }
}
catch {
    # Ctrl+C 中断视为取消，静默退出
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { return }
    Write-ToolkitMessage -Kind Error -Text $_.Exception.Message
    exit 1
}
