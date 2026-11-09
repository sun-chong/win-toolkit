<#
.SYNOPSIS
    VS Code 项目快速打开

.DESCRIPTION
    快速打开 VS Code 最近访问的目录，支持交互式菜单和命令行参数。支持按名称模糊匹配，唯一匹配直接打开。

.PARAMETER Query
    目录名称的部分字符串，用于匹配。
    匹配模式：优先精确匹配目录名称，无精确匹配时进行模糊匹配。
    - 无参数：显示交互式菜单
    - 唯一匹配：直接打开该目录
    - 多个匹配：显示交互式菜单供选择
    示例：my-project, Assets

.EXAMPLE
    vsc
    打开交互式菜单，输入编号打开对应目录

.EXAMPLE
    vsc my-project
    模糊匹配包含 "my-project" 的目录，唯一匹配则直接打开

.NOTES
    Author: SUNC
    Version: 1.3.0
    新窗口最大化依赖 VS Code 自身的 window.maximized 配置，脚本不再用 Win32 API 强制最大化。
#>

param(
    [Parameter(Position = 0)]
    [string]$Query,

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

# 设置输出编码
$OutputEncoding = [System.Text.Encoding]::UTF8

# 存储路径
$storagePath = Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json'

# 检查 storage.json 是否存在
if (-not (Test-Path $storagePath)) {
    Write-Error "未找到 VS Code 存储文件: $storagePath"
    exit 1
}

# 读取并解析 storage.json
try {
    $storageContent = Get-Content $storagePath -Raw -Encoding UTF8
    $storageData = $storageContent | ConvertFrom-Json
}
catch {
    Write-Error "读取 storage.json 失败: $_"
    exit 1
}

# 提取所有目录
$directories = @()
$seenPaths = @{}

# 1. 从 windowsState.openedWindows 读取
if ($storageData.windowsState -and $storageData.windowsState.openedWindows) {
    foreach ($window in $storageData.windowsState.openedWindows) {
        if ($window.folder) {
            $path = [System.Uri]::UnescapeDataString($window.folder.Replace('file:///', ''))
            if (-not $seenPaths.ContainsKey($path.ToLower())) {
                $name = Split-Path $path -Leaf
                $seenPaths[$path.ToLower()] = $true
                $directories += [PSCustomObject]@{
                    Name = $name
                    Path = $path
                }
            }
        }
    }
}

# 2. 从 backupWorkspaces.folders 读取
if ($storageData.backupWorkspaces -and $storageData.backupWorkspaces.folders) {
    foreach ($folder in $storageData.backupWorkspaces.folders) {
        if ($folder.folderUri) {
            $path = [System.Uri]::UnescapeDataString($folder.folderUri.Replace('file:///', ''))
            if (-not $seenPaths.ContainsKey($path.ToLower())) {
                $name = Split-Path $path -Leaf
                $seenPaths[$path.ToLower()] = $true
                $directories += [PSCustomObject]@{
                    Name = $name
                    Path = $path
                }
            }
        }
    }
}

# 3. 从 profileAssociations.workspaces 读取
if ($storageData.profileAssociations -and $storageData.profileAssociations.workspaces) {
    $workspaces = $storageData.profileAssociations.workspaces | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    foreach ($workspaceUri in $workspaces) {
        $path = [System.Uri]::UnescapeDataString($workspaceUri.Replace('file:///', ''))
        if (-not $seenPaths.ContainsKey($path.ToLower())) {
            $name = Split-Path $path -Leaf
            $seenPaths[$path.ToLower()] = $true
            $directories += [PSCustomObject]@{
                Name = $name
                Path = $path
            }
        }
    }
}

# 检查是否有目录
if ($directories.Count -eq 0) {
    Write-ToolkitMessage -Kind Warning -Text "未找到最近打开的目录。"
    exit 0
}

# 按名称排序
$directories = $directories | Sort-Object Name

# 函数：打开目录
function Open-Directory {
    param([string]$Path)
    Write-ToolkitMessage -Kind Success -Text "正在打开: $Path"
    & code -n $Path
}

# 函数：显示菜单并获取选择
function Show-Menu {
    param([array]$Items)

    Write-ToolkitMessage -Kind Info -Text "`n========================================"
    Write-ToolkitMessage -Kind Info -Text "      VS Code 项目快速打开"
    Write-ToolkitMessage -Kind Info -Text "========================================`n"

    Write-ToolkitMessage -Color White -Text "最近打开的目录：`n"

    # 计算名称列的最大宽度
    $maxNameLength = ($Items | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $nameColumnWidth = [Math]::Max($maxNameLength + 4, 12)

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $num = $i + 1
        $name = $Items[$i].Name
        $path = $Items[$i].Path
        $paddedName = $name.PadRight($nameColumnWidth)
        Write-ToolkitMessage -Kind Muted -Text "  $num. $paddedName $path"
    }

    Write-Host ""

    while ($true) {
        $userInput = Read-Host "请输入编号 (1-$($Items.Count))，或输入 q 退出"

        if ($userInput -eq 'q') {
            exit 0
        }

        $num = 0
        if ([int]::TryParse($userInput, [ref]$num) -and ($num -ge 1 -and $num -le $Items.Count)) {
            return $Items[$num - 1]
        }

        Write-ToolkitMessage -Kind Error -Text "无效输入，请重新输入。"
    }
}

# 主逻辑
if ([string]::IsNullOrWhiteSpace($Query)) {
    $selected = Show-Menu -Items $directories
    Open-Directory -Path $selected.Path
}
else {
    $queryLower = $Query.ToLower()

    # 优先精确匹配目录名称
    $exactMatch = $directories | Where-Object { $_.Name.ToLower() -eq $queryLower }

    if ($exactMatch) {
        Open-Directory -Path $exactMatch.Path
    }
    else {
        # 模糊匹配：只匹配目录名称
        $matchedDirs = @($directories | Where-Object { $_.Name.ToLower().Contains($queryLower) })

        if ($matchedDirs.Count -eq 0) {
            Write-ToolkitMessage -Kind Warning -Text "未找到匹配的目录。"
            exit 0
        }
        elseif ($matchedDirs.Count -eq 1) {
            Open-Directory -Path $matchedDirs[0].Path
        }
        else {
            Write-ToolkitMessage -Kind Info -Text "`n找到 $($matchedDirs.Count) 个匹配的目录：`n"
            $selected = Show-Menu -Items $matchedDirs
            Open-Directory -Path $selected.Path
        }
    }
}
