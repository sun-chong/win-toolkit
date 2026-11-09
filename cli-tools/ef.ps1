<#
.SYNOPSIS
    Everything 文件实时检索

.DESCRIPTION
    通过 Everything CLI + fzf 实现交互式文件检索。支持按扩展名过滤、自定义搜索路径和排序。

.PARAMETER Keyword
    搜索关键词，预填到 fzf 搜索框，可实时修改。
    示例：接口, 报告, config

.PARAMETER Ext
    按文件扩展名过滤，逗号分隔多个（不含前导点）。
    短参数：-e
    示例：-e ps1,md, -e docx,xlsx

.PARAMETER Path
    覆盖默认搜索路径，逗号分隔多个。
    短参数：-p
    示例：-p D:\Docs, -p E:\Projects

.PARAMETER Sort
    覆盖默认排序方式。
    短参数：-s
    dm：按修改日期排序
    da：按访问日期排序
    留空：按相关度排序

.EXAMPLE
    ef
    打开实时搜索界面，显示最近修改文件，输入关键词即时检索

.EXAMPLE
    ef 接口清单
    打开搜索界面，预填"接口清单"，显示对应结果，可继续修改关键词

.EXAMPLE
    ef 报告 -e ps1,md
    预填"报告"，按扩展名过滤 .ps1 和 .md 文件

.EXAMPLE
    ef 笔记 -p D:\Documents
    在指定目录搜索

.EXAMPLE
    ef config -s da
    预填"config"，按访问日期排序

.NOTES
    Author: SUNC
    Version: 2.2.0
#>

param(
    [Parameter(Position = 0)]
    [string]$Keyword,

    [Alias("e")]
    [string]$Ext,

    [Alias("p")]
    [string]$Path,

    [Alias("s")]
    [string]$Sort,

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

# ============================================
# 配置区域 — 按需修改
# ============================================
$SearchPaths = @((Get-ToolkitConfig).EfSearchRoots |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
    ForEach-Object { Resolve-ToolkitPathValue -Path ([string]$_) })
if ($SearchPaths.Count -eq 0) {
    $SearchPaths = @([Environment]::GetFolderPath('UserProfile'))
}
$ExcludeExt = @("lnk")
$SortBy     = "dm"

if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path
    exit 0
}

# 检查外部依赖
if (-not (Get-Command es -ErrorAction SilentlyContinue)) {
    Write-Error "未找到 es.exe，请先安装 Everything CLI"
    exit 1
}
if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Write-Error "未找到 fzf.exe，请先安装 fzf"
    exit 1
}

# 构建 es 参数
$esParams = @()

# 扩展名过滤（-Ext 参数）
if ($Ext) {
    $Ext.Split(',') | ForEach-Object {
        $esParams += "*.$($_.Trim())"
    }
}

# 排除扩展名（配置文件）
foreach ($ext in $ExcludeExt) {
    $esParams += "!ext:$ext"
}

# 路径过滤（-Path 参数或配置路径），用 | 分隔多个路径
if ($Path) {
    $pathFilters = ($Path.Split(',') | ForEach-Object { "path:$($_.Trim())" }) -join '|'
    $esParams += $pathFilters
} else {
    $pathFilters = ($SearchPaths | ForEach-Object { "path:$_" }) -join '|'
    $esParams += $pathFilters
}

# 排序方式（-Sort 参数或配置排序）
$SortMode = if ($Sort) { $Sort } else { $SortBy }
if ($SortMode) {
    $esParams += "-sort-$SortMode"
}

# 输出格式：仅全路径（不加 -highlight，避免 ANSI 转义码干扰 fzf）
$esParams += "-full-path-and-name"

# fzf 参数
$fzfArgs = @("--reverse", "--header", "输入关键词模糊搜索文件 | Enter 打开 | Esc 退出")
if (-not [string]::IsNullOrWhiteSpace($Keyword)) {
    $fzfArgs += "--query"
    $fzfArgs += $Keyword
}

try {
    # es.exe 输出 GBK 编码，用 StreamReader + Encoding(936) 解码为正确的 .NET 字符串，
    # 否则 PowerShell 默认 UTF-8 解码会导致中文变为替换字符（U+FFFD）。
    $esProc = [System.Diagnostics.Process]::new()
    try {
        $esProc.StartInfo.FileName = "es.exe"
        $esProc.StartInfo.Arguments = ($esParams | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '
        $esProc.StartInfo.RedirectStandardOutput = $true
        $esProc.StartInfo.UseShellExecute = $false
        $esProc.StartInfo.CreateNoWindow = $true
        [void]$esProc.Start()

        $reader = [System.IO.StreamReader]::new($esProc.StandardOutput.BaseStream, [System.Text.Encoding]::GetEncoding(936))
        try {
            $selectedFile = $reader.ReadToEnd() | fzf @fzfArgs
        } finally {
            $reader.Dispose()
        }
        $null = $esProc.WaitForExit()
    } finally {
        $esProc.Dispose()
    }

    if ($selectedFile) {
        $selectedFile = $selectedFile.Trim()
        Write-ToolkitMessage -Kind Success -Text "正在打开: $selectedFile"
        Invoke-Item -Path $selectedFile
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C 取消时静默退出
}
