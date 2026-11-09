function Get-UniqueFileName {
    <#
    .SYNOPSIS
        在目录中生成不冲突的文件名
    .DESCRIPTION
        目标文件不存在时直接返回；否则按 name(1).ext、name(2).ext 递增。
    .PARAMETER Directory
        目标目录
    .PARAMETER BaseName
        期望的文件名（含扩展名）
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $extension = [System.IO.Path]::GetExtension($BaseName)
    $nameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($BaseName)

    $fullPath = Join-Path $Directory "$nameWithoutExt$extension"
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return $fullPath
    }

    $counter = 1
    while ($true) {
        $newPath = Join-Path $Directory "$nameWithoutExt($counter)$extension"
        if (-not (Test-Path -LiteralPath $newPath)) {
            return $newPath
        }
        $counter++
    }
}

function Read-ToolkitJson {
    <#
    .SYNOPSIS
        读取 UTF-8 JSON 文件
    .DESCRIPTION
        默认在文件不存在或解析失败时返回 -Default 并给出警告，不抛异常。
        -ThrowOnError 时改为抛出带路径的异常，供配置文件等必须有结果的场景使用。
    .PARAMETER Path
        JSON 文件路径
    .PARAMETER Default
        读取失败时返回的默认值
    .PARAMETER AsHashtable
        解析结果转换为哈希表（嵌套对象同样转换），默认返回 PSCustomObject
    .PARAMETER ThrowOnError
        文件不存在、为空或解析失败时抛异常，而不是返回 -Default
    .NOTES
        Author: SUNC
        Version: 1.1.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Default = @{},
        [switch]$AsHashtable,
        [switch]$ThrowOnError
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($ThrowOnError) { throw "JSON 文件不存在：$Path" }
        return $Default
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }
    catch {
        if ($ThrowOnError) { throw "读取 JSON 文件失败：$Path — $($_.Exception.Message)" }
        Write-Warning "读取 JSON 失败：$Path — $($_.Exception.Message)"
        return $Default
    }

    if ([string]::IsNullOrWhiteSpace($json)) {
        if ($ThrowOnError) { throw "JSON 文件为空：$Path" }
        return $Default
    }

    try {
        return ($json | ConvertFrom-Json -AsHashtable:$AsHashtable -ErrorAction Stop)
    }
    catch {
        if ($ThrowOnError) { throw "JSON 解析失败：$Path — $($_.Exception.Message)" }
        Write-Warning "读取 JSON 失败：$Path — $($_.Exception.Message)"
        return $Default
    }
}

function Write-ToolkitJson {
    <#
    .SYNOPSIS
        写入 UTF-8 无 BOM 的 JSON 文件
    .PARAMETER Path
        JSON 文件路径
    .PARAMETER Data
        要序列化的对象
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}
