<#
.SYNOPSIS
    CLI 工具入口

.DESCRIPTION
    查询工具清单和查看工具详细信息

.PARAMETER Fzf
    使用 fzf 交互式选择工具
    短参数：-f
    选中后自动输入命令名称

.PARAMETER List
    显示工具清单
    短参数：-l

.PARAMETER Info
    查看指定工具的详细信息
    短参数：-i
    示例：-i ghup

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    util
    显示所有可用工具列表

.EXAMPLE
    util -f
    使用 fzf 交互式选择工具

.EXAMPLE
    util list
    显示所有可用工具列表（与默认行为相同）

.EXAMPLE
    util info ghup
    查看 ghup 工具的详细信息

.EXAMPLE
    util -h
    显示帮助信息

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
    [Parameter(Position = 0)]
    [Alias("l")]
    [ValidateSet('list', 'info', 'lib')]
    [string]$List,

    [Parameter(Position = 1)]
    [Alias("i")]
    [string]$Info,

    [Parameter(Position = 2)]
    [Alias("f")]
    [switch]$Fzf,

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

# Module scope constants
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ExcludedScripts = @('util.ps1')

# 扫描目录下的工具脚本
function Get-Tools {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptDir,

        [Parameter(Mandatory = $true)]
        [string[]]$ExcludedScripts
    )

    $toolsList = @()

    $allScripts = Get-ChildItem -Path $ScriptDir -Filter "*.ps1" -Recurse -File |
        Where-Object {
            $relative = [System.IO.Path]::GetRelativePath($ScriptDir, $_.FullName)
            $relative -notmatch '^(\.archive|lib|bin)[\\/]'
        }

    foreach ($file in $allScripts) {
        $relative = [System.IO.Path]::GetRelativePath($ScriptDir, $file.FullName)
        $scriptName = [System.IO.Path]::GetFileName($relative)

        # 排除入口脚本自身
        if ($ExcludedScripts -contains $scriptName) {
            continue
        }

        # 子目录显示为「分类/工具名」
        $toolName = [System.IO.Path]::GetFileNameWithoutExtension($relative) -replace '\\', '/'

        # 复用公共解析器提取简介
        $synopsis = (Get-ToolkitHelp -Path $file.FullName).Synopsis

        $toolObj = [PSCustomObject]@{
            Name     = $toolName
            Synopsis = $synopsis
            FilePath = $file.FullName
        }
        $toolsList += $toolObj
    }

    # 按名称排序
    return $toolsList | Sort-Object { $_.Name }
}

# 获取工具完整信息
function Get-ToolInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    return Get-ToolkitHelp -Path $ScriptPath
}

# Main logic
if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path
    exit 0
}

# 公共函数清单与详情
if ($List -eq 'lib') {
    $functions = Get-Command -Module Toolkit | Sort-Object Name

    if ($Info) {
        if ($functions.Name -notcontains $Info) {
            Write-ToolkitMessage -Kind Error -Text "未找到公共函数: $Info"
            exit 1
        }
        Get-Help $Info -Full
        exit 0
    }

    Write-Host ""
    Write-ToolkitMessage -Kind Info -Text "===================================="
    Write-ToolkitMessage -Kind Info -Text "     Toolkit 公共函数"
    Write-ToolkitMessage -Kind Info -Text "===================================="
    Write-Host ""

    foreach ($function in $functions) {
        $synopsis = (Get-Help $function.Name).Synopsis
        if (-not $synopsis) { $synopsis = "" }
        $synopsis = ($synopsis -replace '\s+', ' ').Trim()
        Write-ToolkitMessage -Color White -Text ("{0,-30} {1}" -f $function.Name, $synopsis)
    }

    Write-Host ""
    Write-ToolkitMessage -Kind Muted -Text "共 $($functions.Count) 个公共函数，输入 util lib <函数名> 查看详情"
    exit 0
}

if ($Fzf) {
    # fzf 交互模式逻辑
    if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        Write-Error "未找到 fzf.exe，请先安装 fzf"
        exit 1
    }

    $tools = Get-Tools -ScriptDir $script:ScriptDir -ExcludedScripts $script:ExcludedScripts

    # 构造 fzf 输入格式：名称 + 简介
    $fzfInput = $tools | ForEach-Object { "$($_.Name)`t$($_.Synopsis)" }

    # 调用 fzf 捕获选择结果
    $selected = $fzfInput | fzf --reverse --header="提示: 选择后自动输入命令名称 " --exit-0

    # 处理用户取消（Escape 或无选择）
    if (-not $selected) {
        exit 0
    }

    # 提取选中命令名称（去掉简介部分）
    $selectedCmd = ($selected -split "`t")[0]

    # 使用剪贴板 + Ctrl+V 输入，绕过中文 IME 拦截 SendKeys 的问题
    Set-Clipboard -Value $selectedCmd
    Start-Sleep -Milliseconds 50
    $wshell = New-Object -ComObject Wscript.Shell
    $wshell.SendKeys("^v")

    exit 0
}

if ($Info -or $List -eq "info") {
    if (-not $Info) {
        Write-ToolkitMessage -Kind Error -Text "错误: util info 需要指定工具名称"
        exit 1
    }

    # 查找指定工具
    $tools = Get-Tools -ScriptDir $script:ScriptDir -ExcludedScripts $script:ExcludedScripts
    $targetTool = $tools | Where-Object {
        $_.Name -eq $Info -or ($_.Name -split '/')[-1] -eq $Info
    } | Select-Object -First 1

    if (-not $targetTool) {
        Write-ToolkitMessage -Kind Error -Text "未找到工具: $Info"
        Write-Host ""
        Write-ToolkitMessage -Kind Warning -Text "可用工具:"
        foreach ($t in $tools) {
            Write-ToolkitMessage -Color White -Text "  $($t.Name)"
        }
        exit 1
    }

    # 获取完整信息
    $toolInfo = Get-ToolInfo -ScriptPath $targetTool.FilePath

    Write-Host ""
    Write-ToolkitMessage -Kind Info -Text "===================================="
    Write-ToolkitMessage -Kind Info -Text "     $($targetTool.Name) - 工具信息"
    Write-ToolkitMessage -Kind Info -Text "===================================="
    Write-Host ""

    # 简介
    if ($toolInfo.Synopsis) {
        Write-ToolkitMessage -Kind Success -Text $toolInfo.Synopsis
        Write-Host ""
    }

    # 详细描述
    if ($toolInfo.Description) {
        Write-ToolkitMessage -Color White -Text $toolInfo.Description
        Write-Host ""
    }

    # 参数说明
    if ($toolInfo.Parameters.Count -gt 0) {
        Write-ToolkitMessage -Kind Warning -Text "参数:"
        foreach ($param in $toolInfo.Parameters) {
            Write-ToolkitMessage -Kind Info -Text "  -$($param.Name)"
            Write-ToolkitMessage -Kind Muted -Text "    $($param.Description)"
        }
        Write-Host ""
    }

    # 使用示例
    if ($toolInfo.Examples.Count -gt 0) {
        Write-ToolkitMessage -Kind Warning -Text "使用示例:"
        foreach ($example in $toolInfo.Examples) {
            Write-ToolkitMessage -Kind Muted -Text "  $example"
        }
        Write-Host ""
    }

    # 备注
    if ($toolInfo.Notes) {
        Write-ToolkitMessage -Kind Warning -Text "备注:"
        Write-ToolkitMessage -Kind Muted -Text "  $($toolInfo.Notes)"
        Write-Host ""
    }

    # 相关链接
    if ($toolInfo.Links.Count -gt 0) {
        Write-ToolkitMessage -Kind Warning -Text "相关链接:"
        foreach ($link in $toolInfo.Links) {
            Write-ToolkitMessage -Kind Muted -Text "  $link"
        }
    }

    exit 0
}

# 默认显示列表
$tools = Get-Tools -ScriptDir $script:ScriptDir -ExcludedScripts $script:ExcludedScripts

Write-Host ""
Write-ToolkitMessage -Kind Info -Text "===================================="
Write-ToolkitMessage -Kind Info -Text "     CLI Tools - 工具清单"
Write-ToolkitMessage -Kind Info -Text "===================================="
Write-Host ""

$maxNameLen = ($tools | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
$padWidth = $maxNameLen + 2
foreach ($tool in $tools) {
    $formatted = [string]::Format("{0,-$padWidth} {1}", $tool.Name, $tool.Synopsis)
    Write-ToolkitMessage -Color White -Text $formatted
}

Write-Host ""
Write-ToolkitMessage -Kind Muted -Text "共 $($tools.Count) 个工具，输入 util info <tool> 查看详情"
