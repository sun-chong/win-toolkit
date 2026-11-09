<#
.SYNOPSIS
    微博热搜终端速览

.DESCRIPTION
    免登录拉取微博实时热搜榜，在终端显示排名、标签（热/爆/沸/新）、标题与热度值。
    标题渲染为终端超链接（OSC 8，需 Windows Terminal 等现代终端支持），
    点击即用浏览器打开该热搜的详情页。默认显示 20 条，可用 -c 调整。
    使用 -op 可直接在默认浏览器中打开微博热搜页面。

.PARAMETER Count
    显示条数，取值 1-50，默认 20。
    短参数：-c
    示例：-c 40

.PARAMETER Open
    直接在默认浏览器打开微博热搜页面，不输出终端列表。
    短参数：-op

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    wb
    显示前 20 条热搜

.EXAMPLE
    wb -c 50
    显示前 50 条热搜

.EXAMPLE
    wb -op
    在默认浏览器中打开微博热搜页面

.NOTES
    Author: SUNC
    Version: 1.1.2
#>

param(
    [Alias("c")]
    [ValidateRange(1, 50)]
    [int]$Count = 20,

    [Alias("op")]
    [switch]$Open,

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
$HotSearchApi = "https://weibo.com/ajax/side/hotSearch"
$HotPageUrl = "https://s.weibo.com/top/summary?Refer=top_hot"
$DetailUrlTemplate = "https://s.weibo.com/weibo?q={0}"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# -op：浏览器打开热搜页，无需请求接口
if ($Open) {
    Start-Process $HotPageUrl
    Write-ToolkitMessage -Kind Success -Text "已在默认浏览器打开微博热搜页面"
    exit 0
}

# OSC 8 超链接转义字符（终止符用标准 ST=ESC \，兼容性优于 BEL）
$Esc = [char]27
$St = "$Esc\"

# 按显示宽度右补空格到指定列数
function Format-PadDisplay {
    param([string]$Text, [int]$TotalWidth)
    $padding = $TotalWidth - (Get-DisplayWidth $Text)
    if ($padding -gt 0) { return $Text + (" " * $padding) }
    return $Text
}

# 热度值格式化为「万」单位
function Format-Heat {
    param([long]$Num)
    if ($Num -ge 1000000) { return "{0:N0}万" -f ($Num / 10000) }
    if ($Num -ge 10000) { return "{0:N1}万" -f ($Num / 10000) }
    return "$Num"
}

# 标签颜色映射：爆/沸/热/新/荐
function Get-LabelColor {
    param([string]$Label)
    switch ($Label) {
        "爆" { return "Red" }
        "沸" { return "DarkRed" }
        "热" { return "Yellow" }
        "新" { return "Green" }
        "荐" { return "Magenta" }
        default { return "DarkGray" }
    }
}

try {
    $resp = Invoke-RestMethod -Uri $HotSearchApi -Headers @{
        Referer     = "https://weibo.com/"
        "User-Agent" = $UserAgent
    } -TimeoutSec 15
} catch {
    Write-ToolkitMessage -Kind Error -Text "热搜接口请求失败：$($_.Exception.Message)"
    Write-ToolkitMessage -Color DarkGray -Text "请检查网络连接或稍后重试"
    exit 1
}

if (-not $resp.ok -or -not $resp.data.realtime) {
    Write-ToolkitMessage -Kind Error -Text "接口返回数据异常，未能获取热搜列表"
    exit 1
}

# 过滤广告条目后取前 N 条
$items = @($resp.data.realtime | Where-Object { -not $_.is_ad } | Select-Object -First $Count)

if ($items.Count -eq 0) {
    Write-ToolkitMessage -Kind Error -Text "未获取到有效热搜条目"
    exit 1
}

# 标题列宽：最长条目宽度与 44 列取小，保证列表不失控
$titleWidth = ($items | ForEach-Object { Get-DisplayWidth $_.word } | Measure-Object -Maximum).Maximum
if ($titleWidth -gt 44) { $titleWidth = 44 }
$rankWidth = ("$($items.Count)").Length + 1

Write-Host ""
Write-ToolkitMessage -Kind Info -Text "微博热搜 · $(Get-Date -Format 'HH:mm')"
Write-Host ""

foreach ($item in $items) {
    $rank = [string]($item.rank + 1)
    $label = [string]$item.label_name

    # 详情页链接（带 # 的话题词直接编码）
    $query = if ($item.word_scheme) { $item.word_scheme } else { $item.word }
    $url = $DetailUrlTemplate -f [uri]::EscapeDataString($query)

    # 超长标题截断（按显示宽度）
    $title = $item.word
    if ((Get-DisplayWidth $title) -gt $titleWidth) {
        $trimmed = ""
        $w = 0
        foreach ($ch in $title.ToCharArray()) {
            $cw = if ((Get-DisplayWidth "$ch") -eq 2) { 2 } else { 1 }
            if ($w + $cw -gt $titleWidth - 2) { break }
            $trimmed += $ch
            $w += $cw
        }
        $title = $trimmed + "…"
    }

    $linkedTitle = "$Esc]8;;$url$St$title$Esc]8;;$St"

    Write-ToolkitMessage -Color DarkYellow -Text (Format-PadDisplay $rank $rankWidth) -NoNewline
    if ($label) {
        Write-ToolkitMessage -Text " [$label]" -NoNewline -Color ([System.ConsoleColor](Get-LabelColor $label))
    } else {
        Write-Host "     " -NoNewline
    }
    # 超链接转义序列不计入列宽，按可见标题宽度手动补齐
    Write-Host " $linkedTitle" -NoNewline
    $pad = $titleWidth - (Get-DisplayWidth $title)
    if ($pad -gt 0) { Write-Host (" " * $pad) -NoNewline }
    Write-ToolkitMessage -Color DarkGray -Text "  $(Format-Heat $item.num)"
}
