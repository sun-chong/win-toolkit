function Get-ToolkitPath {
    <#
    .SYNOPSIS
        把逻辑目录名解析为绝对路径
    .DESCRIPTION
        逻辑名来自 config/toolkit.config.jsonc 的 ProjectPaths，或内置的
        Root / UserHome（用户主目录）。ef 的检索目录由 EfSearchRoots 单独配置，
        不经过本函数。ProjectPaths 的值支持 %USERPROFILE% 等环境变量。
        未定义的名称会抛错并列出可用键。
    .PARAMETER Name
        逻辑目录名
    .PARAMETER Child
        追加到解析结果之后的子路径
    .EXAMPLE
        Get-ToolkitPath -Name UserHome -Child '.claude\agents'
    .EXAMPLE
        Get-ToolkitPath -Name MyProject
        需先在 ProjectPaths 中定义 MyProject
    .NOTES
        Author: SUNC
        Version: 1.0.1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [string]$Child
    )

    $config = Get-ToolkitConfig
    $userHome = [Environment]::GetFolderPath('UserProfile')

    $projectPaths = if ($config.ContainsKey('ProjectPaths')) { $config.ProjectPaths } else { @{} }

    if ($Name -eq 'Root' -or $Name -eq 'UserHome') {
        $base = $userHome
    }
    elseif ($projectPaths.ContainsKey($Name)) {
        # 与工具配置一致：允许 ProjectPaths 值写 %USERPROFILE% 等环境变量
        $base = Resolve-ToolkitPathValue -Path ([string]$projectPaths[$Name])
    }
    else {
        $available = @($projectPaths.Keys) + @('Root', 'UserHome')
        throw "未知的路径逻辑名 '$Name'。可用：$($available -join ', ')"
    }

    if ($Child) {
        return (Join-Path $base $Child)
    }
    return $base
}

function Get-RelativePath {
    <#
    .SYNOPSIS
        把绝对路径转换为相对根目录的路径
    .DESCRIPTION
        不在根目录下时返回完整路径；仅用于日志与展示。
    .PARAMETER Full
        完整路径
    .PARAMETER Root
        根目录
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Full,
        [Parameter(Mandatory = $true, Position = 1)][string]$Root
    )

    $root = $Root.TrimEnd('\')
    if ($Full -and $Full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $Full.Substring($root.Length + 1)
        if ($relative) { return $relative }
    }
    return $Full
}

function Resolve-ToolkitPathValue {
    <#
    .SYNOPSIS
        展开环境变量并按基准目录解析相对路径
    .DESCRIPTION
        配置文件中路径值的统一解析入口：
          1. 展开 %VAR% 形式的环境变量
          2. 已是绝对路径时直接返回
          3. 相对路径按 -Base 拼接；省略 -Base 时原样返回展开结果
    .PARAMETER Path
        待解析的路径值，可含 %VAR% 环境变量
    .PARAMETER Base
        相对路径的基准目录；省略时相对路径不拼接
    .EXAMPLE
        Resolve-ToolkitPathValue -Path '%USERPROFILE%\.claude\agents'
    .EXAMPLE
        Resolve-ToolkitPathValue -Path '%USERPROFILE%\path\to\subagents'
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Base
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded) -or [string]::IsNullOrWhiteSpace($Base)) {
        return $expanded
    }
    return (Join-Path $Base $expanded)
}

function Update-ToolkitProcessPath {
    <#
    .SYNOPSIS
        从注册表重建当前进程的 PATH
    .DESCRIPTION
        winget 与安装器写入的新目录不会自动进入当前进程。本函数按
        Machine 在前、User 在后的顺序重建 $env:Path，供安装完成后立即调用。
        注册表读取结果为空时保留当前值，不做破坏性覆盖。
    .EXAMPLE
        Update-ToolkitProcessPath
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()

    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')

    $entries = @($machine, $user) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $rebuilt = $entries -join ';'

    if ([string]::IsNullOrWhiteSpace($rebuilt)) { return }

    $env:Path = $rebuilt
}
