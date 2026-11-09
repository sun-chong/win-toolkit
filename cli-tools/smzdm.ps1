<#
.SYNOPSIS
    什么值得买好价排行终端速览

.DESCRIPTION
    抓取什么值得买（smzdm.com）首页「好价排行榜」轮播区块（服务端直出的静态
    HTML，固定 30 条），在终端显示排名、商品名与价格说明。
    商品名渲染为终端超链接（OSC 8，需 Windows Terminal 等现代终端支持），
    点击即用浏览器打开该好价的详情页。默认显示 20 条，可用 -c 调整（最多 30）。

.PARAMETER Count
    显示条数，取值 1-30，默认 20。
    短参数：-c
    示例：-c 30

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    smzdm
    显示前 20 条好价排行

.EXAMPLE
    smzdm -c 30
    显示全部 30 条好价排行

.NOTES
    Author: SUNC
    Version: 1.0.1
#>

param(
    [Alias("c")]
    [ValidateRange(1, 30)]
    [int]$Count = 20,

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

if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path
    exit 0
}

# ============================================
# 配置区域 — 按需修改
# ============================================
$HomePageUrl = "https://www.smzdm.com/"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# 好价轮播区块的起止标记（区块固定位于「好价」tab 下，其后是「社区」tab）
$BlockStartMark = "feed-hot-item feed-hot-item-haojia"
$BlockEndMark = "feed-hot-item feed-hot-item-shequ"
$CardSplitMark = '<div class="feed-hot-card">'

# OSC 8 超链接转义字符（终止符用标准 ST=ESC \，兼容性优于 BEL）
$Esc = [char]27
$St = "$Esc\"

# 排名数字右补空格到指定列数
function Format-RankPad {
    param([int]$Num, [int]$TotalWidth)
    $text = "$Num"
    $padding = $TotalWidth - $text.Length
    if ($padding -gt 0) { return $text + (" " * $padding) }
    return $text
}

# 超长文本按显示宽度截断，超出部分以 … 结尾
function Trim-ToDisplayWidth {
    param([string]$Text, [int]$MaxWidth)
    if ((Get-DisplayWidth $Text) -le $MaxWidth) { return $Text }
    $trimmed = ""
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cw = if ((Get-DisplayWidth "$ch") -eq 2) { 2 } else { 1 }
        if ($w + $cw -gt $MaxWidth - 2) { break }
        $trimmed += $ch
        $w += $cw
    }
    return $trimmed + "…"
}

try {
    # 经临时文件中转读取，确保按 UTF-8 解码，不依赖响应头 charset 探测
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) "smzdm-homepage.html"
    Invoke-WebRequest -Uri $HomePageUrl -Headers @{
        "User-Agent" = $UserAgent
        "Referer"    = "https://www.smzdm.com/"
    } -TimeoutSec 20 -OutFile $tempFile
    $html = [IO.File]::ReadAllText($tempFile, [Text.Encoding]::UTF8)
} catch {
    Write-ToolkitMessage -Kind Error -Text "首页请求失败：$($_.Exception.Message)"
    Write-ToolkitMessage -Color DarkGray -Text "请检查网络连接或稍后重试"
    exit 1
}

# 定位好价排行榜区块并按卡片切块
$start = $html.IndexOf($BlockStartMark)
$end = $html.IndexOf($BlockEndMark, [Math]::Max($start, 0))
if ($start -lt 0 -or $end -lt 0) {
    Write-ToolkitMessage -Kind Error -Text "未在首页中定位到好价排行榜区块，页面结构可能已变更"
    exit 1
}
$blocks = $html.Substring($start, $end - $start) -split $CardSplitMark | Select-Object -Skip 1

# 每张卡片提取：详情链接 / 商品名 / 价格说明
$items = @()
foreach ($block in $blocks) {
    $href = [regex]::Match($block, 'href="(https://www\.smzdm\.com/p/\d+/)"').Groups[1].Value
    $title = [regex]::Match($block, 'feed-hot-title">([^<]+)</div>').Groups[1].Value
    $price = [regex]::Match($block, 'z-highlight">([^<]+)</span>').Groups[1].Value
    if ($href -and $title) {
        $items += [pscustomobject]@{
            Url   = $href
            Title = [Net.WebUtility]::HtmlDecode($title).Trim()
            Price = [Net.WebUtility]::HtmlDecode($price).Trim()
        }
    }
}

if ($items.Count -eq 0) {
    Write-ToolkitMessage -Kind Error -Text "未能从好价排行榜区块解析出条目，页面结构可能已变更"
    exit 1
}

$items = @($items | Select-Object -First $Count)

# 商品名列宽：最长条目宽度与 52 列取小，保证列表不失控
$titleWidth = ($items | ForEach-Object { Get-DisplayWidth $_.Title } | Measure-Object -Maximum).Maximum
if ($titleWidth -gt 52) { $titleWidth = 52 }
$rankWidth = ("$($items.Count)").Length + 1

Write-Host ""
Write-ToolkitMessage -Kind Info -Text "什么值得买 · 好价排行 · $(Get-Date -Format 'HH:mm')"
Write-Host ""

$rank = 0
foreach ($item in $items) {
    $rank++
    $title = Trim-ToDisplayWidth $item.Title $titleWidth
    $linkedTitle = "$Esc]8;;$($item.Url)$St$title$Esc]8;;$St"

    Write-ToolkitMessage -Color DarkYellow -Text (Format-RankPad $rank $rankWidth) -NoNewline
    # 超链接转义序列不计入列宽，按可见标题宽度手动补齐
    Write-Host " $linkedTitle" -NoNewline
    $pad = $titleWidth - (Get-DisplayWidth $title)
    if ($pad -gt 0) { Write-Host (" " * $pad) -NoNewline }
    Write-ToolkitMessage -Color DarkGray -Text "  $($item.Price)"
}
