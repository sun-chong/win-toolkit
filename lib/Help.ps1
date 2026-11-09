function Get-ToolkitHelp {
    <#
    .SYNOPSIS
        解析脚本的 Comment-Based Help
    .DESCRIPTION
        从脚本文件中提取注释帮助的各个段落（简介、描述、参数、示例、备注、链接），
        返回结构化对象，供 util 与帮助渲染复用。
    .PARAMETER Path
        脚本路径
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $result = [pscustomobject]@{
        Synopsis    = ''
        Description = ''
        Parameters  = @()
        Examples    = @()
        Notes       = ''
        Links       = @()
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $helpBlock = $null
    foreach ($block in [regex]::Matches($content, '(?s)<#(.*?)#>')) {
        if ($block.Groups[1].Value -match '\.SYNOPSIS') {
            $helpBlock = $block.Groups[1].Value
            break
        }
    }
    if (-not $helpBlock) {
        return $result
    }

    $parts = [regex]::Split(
        $helpBlock,
        '(?m)^\s*(?=\.(?:SYNOPSIS|DESCRIPTION|PARAMETER|EXAMPLE|NOTES|LINK)\b)'
    )

    foreach ($part in $parts) {
        $section = $part.Trim()
        if (-not $section) { continue }

        if ($section -match '^\.SYNOPSIS\s+([\s\S]*)$') {
            $result.Synopsis = $matches[1].Trim() -replace '\s+', ' '
        }
        elseif ($section -match '^\.DESCRIPTION\s+([\s\S]*)$') {
            $result.Description = $matches[1].Trim()
        }
        elseif ($section -match '^\.PARAMETER\s+(\S+)\s+([\s\S]*)$') {
            $result.Parameters += [pscustomobject]@{
                Name        = $matches[1]
                Description = $matches[2].Trim()
            }
        }
        elseif ($section -match '^\.EXAMPLE\s+([\s\S]*)$') {
            $result.Examples += $matches[1].Trim()
        }
        elseif ($section -match '^\.NOTES\s+([\s\S]*)$') {
            $result.Notes = $matches[1].Trim()
        }
        elseif ($section -match '^\.LINK\s+([\s\S]*)$') {
            $result.Links += $matches[1].Trim()
        }
    }

    return $result
}

function Show-ToolkitScriptHelp {
    <#
    .SYNOPSIS
        以紧凑版式输出脚本的 Comment-Based Help
    .DESCRIPTION
        Get-Help -Full 在示例、备注之间会插入 5 个以上空行，终端阅读松散。
        本函数取原始帮助文本后把连续空行压缩为一个空行，内容与缩进保持不变。
        用于仍以 Comment-Based Help 描述自己的脚本；新工具优先用 Show-ToolkitHelp。

    .PARAMETER Path
        脚本路径
    .PARAMETER Full
        显示完整帮助（参数与示例）；省略时只显示摘要
    .EXAMPLE
        Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path -Full
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Full
    )

    $help = if ($Full) { Get-Help -Name $Path -Full } else { Get-Help -Name $Path }
    $width = try { [Math]::Max(80, $Host.UI.RawUI.WindowSize.Width) } catch { 100 }
    $text = ($help | Out-String -Width $width)

    # 连续空行压缩为一个空行；模式只吃行尾与空白行，不会吞掉下一行的缩进
    $text = $text -replace '(?:[ \t]*\r?\n){3,}', "`r`n`r`n"
    Write-Host $text.TrimEnd()
}

function Show-ToolkitHelp {
    <#
    .SYNOPSIS
        按统一版式输出命令行工具的速查帮助
    .DESCRIPTION
        输出「命令 命令 - 标题」、分隔线，以及若干「章节 + 缩进行」。
        各脚本只维护内容，不再自己渲染版式。
    .PARAMETER Command
        命令名，如 tsd
    .PARAMETER Title
        一句话标题
    .PARAMETER Sections
        有序分节数组，每项包含 Title 与 Lines
    .PARAMETER Color
        标题颜色；省略时使用终端默认色
    .PARAMETER Compact
        节与节之间不输出空行，仅在末尾补一个空行；用于保持 tsd 等脚本的原有版式
    .EXAMPLE
        Show-ToolkitHelp -Command demo -Title 演示 -Sections @(
            @{ Title = '使用方式'; Lines = @('demo -h    帮助') }
        )
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][object[]]$Sections,
        [System.ConsoleColor]$Color,
        [switch]$Compact
    )

    $useColor = $PSBoundParameters.ContainsKey('Color')
    $heading = "$Command 命令 - $Title"

    Write-Host ''
    if ($useColor) {
        Write-Host $heading -ForegroundColor $Color
    }
    else {
        Write-Host $heading
    }
    Write-Host ('=' * 40)

    foreach ($section in $Sections) {
        $sectionTitle = $section.Title
        $lines = @($section.Lines)

        if ($sectionTitle) {
            Write-Host "$sectionTitle："
        }
        foreach ($line in $lines) {
            Write-Host "  $line"
        }
        if (-not $Compact) {
            Write-Host ''
        }
    }
    if ($Compact) {
        Write-Host ''
    }
}
