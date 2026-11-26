function Add-ToolkitVsCodeRecentPath {
    <#
    .SYNOPSIS
        把一条 VS Code file URI 转换、去重后加入最近目录列表
    .DESCRIPTION
        内部辅助函数，不导出。URI 去掉 file:/// 前缀后做 URL 解码，
        以小写路径作为去重键；首次出现的路径以 PSCustomObject 追加到列表。
    .PARAMETER Uri
        storage.json 中的 file URI，如 file:///c%3A/Users/me/project
    .PARAMETER Seen
        已出现路径的小写键集合（会被就地修改）
    .PARAMETER Directories
        结果列表，元素为 Name / Path（会被就地修改）
    #>
    param(
        [string]$Uri,
        [hashtable]$Seen,
        [System.Collections.Generic.List[object]]$Directories
    )

    if ([string]::IsNullOrWhiteSpace($Uri)) { return }

    $path = [System.Uri]::UnescapeDataString($Uri.Replace('file:///', ''))
    if ([string]::IsNullOrWhiteSpace($path)) { return }

    $key = $path.ToLowerInvariant()
    if ($Seen.ContainsKey($key)) { return }

    $Seen[$key] = $true
    $Directories.Add([PSCustomObject]@{
        Name = Split-Path $path -Leaf
        Path = $path
    })
}

function Get-ToolkitVsCodeRecentFolder {
    <#
    .SYNOPSIS
        获取 VS Code 最近打开的目录列表
    .DESCRIPTION
        从 %APPDATA%\Code\User\globalStorage\storage.json 提取最近目录：
        windowsState.openedWindows 的 folder、backupWorkspaces.folders 的 folderUri
        以及 profileAssociations.workspaces 的属性名。路径经 URL 解码，按小写路径
        去重，按提取顺序返回。

        storage.json 不存在时抛出 System.IO.FileNotFoundException（FileName 为
        存储文件路径）；读取或解析失败时抛出原始异常。函数不打印提示，
        由调用方决定文案与退出行为。
    .OUTPUTS
        PSCustomObject：Name（目录叶子名）/ Path（完整路径）
    .EXAMPLE
        $directories = @(Get-ToolkitVsCodeRecentFolder)
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()

    $storagePath = Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json'
    if (-not (Test-Path -LiteralPath $storagePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("未找到 VS Code 存储文件：$storagePath", $storagePath)
    }

    $storageContent = Get-Content -LiteralPath $storagePath -Raw -Encoding UTF8
    $storageData = $storageContent | ConvertFrom-Json

    $directories = [System.Collections.Generic.List[object]]::new()
    $seenPaths = @{}

    if ($storageData.windowsState -and $storageData.windowsState.openedWindows) {
        foreach ($window in $storageData.windowsState.openedWindows) {
            if ($window.folder) {
                Add-ToolkitVsCodeRecentPath -Uri ([string]$window.folder) -Seen $seenPaths -Directories $directories
            }
        }
    }

    if ($storageData.backupWorkspaces -and $storageData.backupWorkspaces.folders) {
        foreach ($folder in $storageData.backupWorkspaces.folders) {
            if ($folder.folderUri) {
                Add-ToolkitVsCodeRecentPath -Uri ([string]$folder.folderUri) -Seen $seenPaths -Directories $directories
            }
        }
    }

    if ($storageData.profileAssociations -and $storageData.profileAssociations.workspaces) {
        $workspaces = @($storageData.profileAssociations.workspaces.PSObject.Properties |
            Where-Object { $_.MemberType -eq 'NoteProperty' })
        foreach ($workspace in $workspaces) {
            Add-ToolkitVsCodeRecentPath -Uri ([string]$workspace.Name) -Seen $seenPaths -Directories $directories
        }
    }

    return $directories
}
