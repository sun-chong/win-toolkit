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
