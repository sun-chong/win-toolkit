function Get-DisplayWidth {
    <#
    .SYNOPSIS
        计算字符串的终端显示宽度
    .DESCRIPTION
        CJK 与全角字符按 2 列计，其余按 1 列计。
    .PARAMETER Text
        要计算的文本
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Text
    )

    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -ge 0x2E80 -and [int]$ch -le 0x9FFF) { $width += 2 }
        elseif ([int]$ch -ge 0xFF00 -and [int]$ch -le 0xFFEF) { $width += 2 }
        else { $width += 1 }
    }
    return $width
}

function Get-ToolkitColor {
    <#
    .SYNOPSIS
        按语义类别读取配置中的终端颜色
    .PARAMETER Kind
        语义类别：Success / Info / Warning / Error / Muted
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Info', 'Warning', 'Error', 'Muted')]
        [string]$Kind
    )

    $colors = (Get-ToolkitConfig).Colors
    if (-not $colors.ContainsKey($Kind)) {
        throw "配置 Colors 缺少键 '$Kind'"
    }
    return [System.ConsoleColor]$colors[$Kind]
}

function Format-ToolkitAnsi {
    <#
    .SYNOPSIS
        用 ANSI 24-bit 前景色包裹文本
    .DESCRIPTION
        返回带 `e[38;2;r;g;bm 前缀与 `e[0m 后缀的字符串；
        HexColor 为空时原样返回。适合日志、图表等需要精确配色的输出。
    .PARAMETER Text
        要着色的文本
    .PARAMETER HexColor
        十六进制颜色，如 #4CC2FF
    .EXAMPLE
        Format-ToolkitAnsi -Text '完成' -HexColor '#4ECB71'
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
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

function Get-ToolkitMixedHex {
    <#
    .SYNOPSIS
        把前景色与深色背景混合，得到面积填充色
    .PARAMETER HexColor
        前景十六进制颜色
    .PARAMETER Percent
        前景色占比（0-100）
    .PARAMETER BackgroundRgb
        背景亮度，默认 12（接近终端深色背景）
    .EXAMPLE
        Get-ToolkitMixedHex -HexColor '#4CC2FF' -Percent 62
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [string]$HexColor,
        [int]$Percent,
        [int]$BackgroundRgb = 12
    )
    $hex = $HexColor.TrimStart('#')
    $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    $t = [math]::Max(0, [math]::Min(100, $Percent)) / 100.0
    $bg = [math]::Max(0, [math]::Min(255, $BackgroundRgb))
    $mr = [int][math]::Round($r * $t + $bg * (1 - $t))
    $mg = [int][math]::Round($g * $t + $bg * (1 - $t))
    $mb = [int][math]::Round($b * $t + $bg * (1 - $t))
    return ('#{0:X2}{1:X2}{2:X2}' -f $mr, $mg, $mb)
}

function Format-ToolkitDisplayText {
    <#
    .SYNOPSIS
        按终端显示宽度补齐、截断或居中文本
    .DESCRIPTION
        以 Get-DisplayWidth 计算宽度（CJK 与全角字符按 2 列）。
        超宽时：默认原样返回；-Truncate 时按显示宽度截断。
        不超宽时：默认左对齐补齐；-Align Right / Center 改变对齐；-NoPad 不补齐。
    .PARAMETER Text
        要处理的文本
    .PARAMETER Width
        目标显示宽度
    .PARAMETER Align
        对齐方式：Left（默认）/ Right / Center
    .PARAMETER Truncate
        超宽时截断而不是原样返回
    .PARAMETER NoPad
        不补齐（仅截断或原样返回）
    .EXAMPLE
        Format-ToolkitDisplayText -Text 'CPU' -Width 6 -Right
    .EXAMPLE
        Format-ToolkitDisplayText -Text $name -Width 20 -Truncate
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [string]$Text,
        [int]$Width,
        [ValidateSet('Left', 'Right', 'Center')]
        [string]$Align = 'Left',
        [switch]$Truncate,
        [switch]$NoPad
    )

    if (-not $Text) { return $(if ($NoPad) { '' } else { ' ' * $Width }) }
    $displayWidth = Get-DisplayWidth -Text $Text

    if ($displayWidth -gt $Width) {
        if (-not $Truncate) { return $Text }
        $sb = [System.Text.StringBuilder]::new()
        $used = 0
        foreach ($ch in $Text.ToCharArray()) {
            $w = Get-DisplayWidth -Text ([string]$ch)
            if ($used + $w -gt $Width) { break }
            [void]$sb.Append($ch)
            $used += $w
        }
        return $sb.ToString()
    }

    if ($NoPad) { return $Text }
    $padding = ' ' * ($Width - $displayWidth)
    switch ($Align) {
        'Right' { return $padding + $Text }
        'Center' {
            $left = [int][math]::Floor($padding.Length / 2)
            return (' ' * $left) + $Text + (' ' * ($padding.Length - $left))
        }
        default { return $Text + $padding }
    }
}

function Get-ToolkitConsoleWidth {
    <#
    .SYNOPSIS
        读取当前终端宽度，读取失败时返回默认值
    .PARAMETER Default
        无法读取或宽度无效时使用的值，默认 120
    .EXAMPLE
        Get-ToolkitConsoleWidth -Default 100
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param([int]$Default = 120)

    try {
        $width = [Console]::WindowWidth
        if ($width -gt 0) { return $width }
    }
    catch {
        return $Default
    }
    return $Default
}

function Write-ToolkitMessage {
    <#
    .SYNOPSIS
        按语义类别输出一行彩色消息
    .PARAMETER Text
        要输出的文本
    .PARAMETER Kind
        语义类别，默认 Info
    .PARAMETER Color
        直接指定颜色，优先于 Kind
    .PARAMETER NoNewline
        不追加换行
    .EXAMPLE
        Write-ToolkitMessage -Kind Success -Text '完成'
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Text,
        [ValidateSet('Success', 'Info', 'Warning', 'Error', 'Muted')]
        [string]$Kind = 'Info',
        [System.ConsoleColor]$Color,
        [switch]$NoNewline
    )

    $consoleColor = if ($PSBoundParameters.ContainsKey('Color')) {
        $Color
    }
    else {
        Get-ToolkitColor -Kind $Kind
    }

    if ($NoNewline) {
        Write-Host -Object $Text -ForegroundColor $consoleColor -NoNewline
    }
    else {
        Write-Host -Object $Text -ForegroundColor $consoleColor
    }
}
