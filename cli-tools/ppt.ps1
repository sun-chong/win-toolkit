<#
.SYNOPSIS
    ppt-master 项目管理快捷脚本

.DESCRIPTION
    以交互方式创建 ppt-master 项目、导入源资料、校验项目结构及查看项目信息。
    按提示逐步输入参数即可，无需记忆脚本路径和命令格式。

.PARAMETER Command
    操作类型：init / import / validate / info
    可作为位置参数直接使用（无需 -Command）
    示例：ppt init, ppt import

.PARAMETER Help
    查看帮助信息
    短参数：-h

.EXAMPLE
    ppt init
    交互式创建新项目

.EXAMPLE
    ppt import
    交互式导入源文件/URL 到项目

.EXAMPLE
    ppt validate
    交互式校验项目结构

.EXAMPLE
    ppt info
    交互式查看项目信息

.EXAMPLE
    ppt -h
    查看帮助信息

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "import", "validate", "info", "help", IgnoreCase = $true)]
    [string]$Command,

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
    @{ Title = '使用方式'; Lines = @(
        'ppt init              创建新项目（交互式）'
        'ppt import            导入源文件/URL 到项目（交互式）'
        'ppt validate          校验项目结构（交互式）'
        'ppt info              查看项目信息（交互式）'
        'ppt help, ppt -h      查看帮助信息'
    ) }
    @{ Title = '说明'; Lines = @(
        '各命令按提示逐步输入参数即可。'
        'init 的画布格式可跳过，留待创作时确定。'
    ) }
)
# PPT 仓库定位：由公共配置 PptMasterRoot 指定
$pptRepoConfig = [string](Get-ToolkitConfig).PptMasterRoot
$script:PPTRepo = $null
if (-not [string]::IsNullOrWhiteSpace($pptRepoConfig)) {
    $script:PPTRepo = Resolve-ToolkitPathValue -Path $pptRepoConfig -Base ([Environment]::GetFolderPath('UserProfile'))
    $script:PmScript = Join-Path $script:PPTRepo "skills\ppt-master\scripts\project_manager.py"
    $script:ProjectsDir = Join-Path $script:PPTRepo "projects"
}

function Invoke-Ppt {
    param([string[]]$Arguments)

    $env:PYTHONUTF8 = "1"
    & python $script:PmScript @Arguments
}

function Split-ArgTokens {
    param([string]$Text)

    # 按空白拆分，支持双引号包裹的空格（如拖入的带空格路径）
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Text, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) {
            $tokens.Add($m.Groups[1].Value)
        } else {
            $tokens.Add($m.Groups[2].Value)
        }
    }
    return $tokens
}

function Get-ProjectNames {
    return @(Get-ChildItem -Directory $script:ProjectsDir -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name | Sort-Object)
}

function Select-Project {
    $names = @(Get-ProjectNames)
    if ($names.Count -eq 0) {
        Write-ToolkitMessage -Kind Warning -Text "projects/ 下暂无项目，请先运行: ppt init"
        exit 1
    }
    Write-ToolkitMessage -Kind Info -Text "选择项目（输入编号，或直接输入路径）："
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $names[$i])
    }
    $choice = Read-Host "项目"
    if ([string]::IsNullOrWhiteSpace($choice)) { exit 1 }
    $choice = $choice.Trim()
    if ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
        if ($idx -ge 0 -and $idx -lt $names.Count) {
            return Join-Path $script:ProjectsDir $names[$idx]
        }
        Write-ToolkitMessage -Kind Error -Text "编号无效"
        exit 1
    }
    if (-not [System.IO.Path]::IsPathRooted($choice)) {
        if ($choice -match '[/\\]') {
            # 相对路径（如 projects\demo），相对仓库根解析
            $choice = Join-Path $script:PPTRepo $choice
        } else {
            # 纯项目名称（如 demo_20260101），自动拼到 projects/
            $choice = Join-Path $script:ProjectsDir $choice
        }
    }
    if (-not (Test-Path $choice)) {
        Write-ToolkitMessage -Kind Error -Text "路径不存在: $choice"
        exit 1
    }
    return $choice
}

function New-PptProject {
    $name = Read-Host "项目名称"
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-ToolkitMessage -Kind Error -Text "项目名称不能为空"
        exit 1
    }
    Write-ToolkitMessage -Kind Info -Text "画布格式（直接回车跳过；可选：ppt169/ppt43/xiaohongshu/moments/story/banner/wechat）"
    $format = Read-Host "格式"
    $pyArgs = @("init", $name.Trim())
    if (-not [string]::IsNullOrWhiteSpace($format)) {
        $pyArgs += "--format"
        $pyArgs += $format.Trim()
    }
    Invoke-Ppt -Arguments $pyArgs
}

function Import-PptSources {
    $project = Select-Project
    $sources = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Read-Host "源文件/URL（空格分隔多个，可拖入文件；直接回车结束）"
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        foreach ($token in Split-ArgTokens -Text $line) {
            $sources.Add($token)
        }
    }
    if ($sources.Count -eq 0) {
        Write-ToolkitMessage -Kind Error -Text "未输入任何源文件"
        exit 1
    }
    $pyArgs = @("import-sources", $project)
    foreach ($source in $sources) {
        $pyArgs += $source
    }
    Invoke-Ppt -Arguments $pyArgs
}

function Invoke-PptValidate {
    $project = Select-Project
    Invoke-Ppt -Arguments @("validate", $project)
}

function Invoke-PptInfo {
    $project = Select-Project
    Invoke-Ppt -Arguments @("info", $project)
}

# 入口逻辑
if ($Help -or [string]::IsNullOrWhiteSpace($Command) -or $Command -eq "help") {
    Show-ToolkitHelp -Command 'ppt' -Title 'PPT 项目管理' -Sections $helpSections
    exit 0
}

if ([string]::IsNullOrWhiteSpace($script:PPTRepo)) {
    Write-ToolkitMessage -Kind Error -Text '错误：未配置 PptMasterRoot（config/toolkit.config.jsonc）'
    exit 1
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-ToolkitMessage -Kind Error -Text "未找到 python，请先安装并加入 PATH"
    exit 1
}

switch ($Command.ToLower()) {
    "init"     { New-PptProject }
    "import"   { Import-PptSources }
    "validate" { Invoke-PptValidate }
    "info"     { Invoke-PptInfo }
}
exit $LASTEXITCODE
