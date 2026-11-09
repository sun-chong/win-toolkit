function Resolve-ToolkitConfigPath {
    <#
    .SYNOPSIS
        解析工具配置文件路径，同时支持 .json 与 .jsonc
    .DESCRIPTION
        传入不含扩展名的基础路径，按优先顺序探测 .jsonc 与 .json：
        - 两者都存在时使用优先扩展名，并警告配置重复
        - 都不存在时返回基础路径 + 优先扩展名，供调用方创建
        调用方应在启动时解析一次，读写都使用返回的 Path，避免配置分裂。
    .PARAMETER BasePath
        不含扩展名的配置路径，如 <工具目录>\ghup.config；传入带扩展名的路径会自动去掉
    .PARAMETER PreferredExtension
        两种文件都存在时优先使用的扩展名，默认 .jsonc
    .OUTPUTS
        PSCustomObject：Path（实际使用或待创建的路径）、Exists（文件是否存在）、Extension
    .EXAMPLE
        $info = Resolve-ToolkitConfigPath -BasePath (Join-Path $PSScriptRoot 'ghup.config')
        $info.Path
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [ValidateSet('.jsonc', '.json')][string]$PreferredExtension = '.jsonc'
    )

    # 去掉调用方可能带上的扩展名（-replace 默认不区分大小写）
    $base = $BasePath -replace '\.jsonc?$', ''

    $candidates = if ($PreferredExtension -eq '.jsonc') { @('.jsonc', '.json') } else { @('.json', '.jsonc') }
    $found = @(
        foreach ($ext in $candidates) {
            $path = $base + $ext
            if (Test-Path -LiteralPath $path) { $path }
        }
    )

    if ($found.Count -gt 1) {
        Write-Warning "配置文件重复：$($found -join ' 与 ')，使用 $($found[0])"
    }

    if ($found.Count -gt 0) {
        return [PSCustomObject]@{
            Path      = $found[0]
            Exists    = $true
            Extension = [System.IO.Path]::GetExtension($found[0])
        }
    }

    return [PSCustomObject]@{
        Path      = $base + $PreferredExtension
        Exists    = $false
        Extension = $PreferredExtension
    }
}

function Get-ToolkitConfig {
    <#
    .SYNOPSIS
        读取公共配置
    .DESCRIPTION
        读取 config/toolkit.config.jsonc（或 .json，优先 .jsonc），解析结果统一转换为
        哈希表并缓存在模块内；-Refresh 强制重新读取。不再支持 config/local.psd1 覆盖。
    .PARAMETER Refresh
        忽略缓存，重新读取配置文件
    .EXAMPLE
        (Get-ToolkitConfig).ClashProxyPort
    .NOTES
        Author: SUNC
        Version: 2.0.0
    #>
    [CmdletBinding()]
    param(
        [switch]$Refresh
    )

    if ($null -ne $script:ConfigCache -and -not $Refresh) {
        return $script:ConfigCache
    }

    $configDir = if ($env:TOOLKIT_CONFIG_DIR) {
        $env:TOOLKIT_CONFIG_DIR
    }
    else {
        Join-Path $script:ToolkitRoot 'config'
    }

    # 公共配置与工具配置统一走同一套扩展名探测，优先 .jsonc
    $configInfo = Resolve-ToolkitConfigPath -BasePath (Join-Path $configDir 'toolkit.config')
    if (-not $configInfo.Exists) {
        throw "缺少公共配置文件：$($configInfo.Path)。请从同目录的 toolkit.config.jsonc.example 复制一份"
    }

    try {
        $json = Get-Content -LiteralPath $configInfo.Path -Raw -Encoding UTF8
        $config = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "公共配置文件格式错误：$($configInfo.Path) — $($_.Exception.Message)"
    }

    $script:ConfigCache = $config
    return $config
}

function Get-ToolkitStateDirectory {
    <#
    .SYNOPSIS
        返回运行时状态目录，不存在时创建
    #>
    $dir = if ($env:TOOLKIT_STATE_DIR) {
        $env:TOOLKIT_STATE_DIR
    }
    else {
        Join-Path $env:LOCALAPPDATA 'toolkit\state'
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Read-ToolkitState {
    <#
    .SYNOPSIS
        读取一个工具的运行时状态
    .DESCRIPTION
        状态文件位于 TOOLKIT_STATE_DIR 或 %LOCALAPPDATA%\toolkit\state\<Name>.json。
        读取失败时返回 -Default 并给出警告，不抛异常。
    .PARAMETER Name
        状态名，对应文件名（不含扩展名）
    .PARAMETER Default
        文件不存在或读取失败时返回的默认值
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Default = @{}
    )

    try {
        $path = Join-Path (Get-ToolkitStateDirectory) "$Name.json"
    }
    catch {
        Write-Warning "读取状态目录失败：$($_.Exception.Message)"
        return $Default
    }

    if (-not (Test-Path -LiteralPath $path)) {
        return $Default
    }

    try {
        $data = Read-ToolkitJson -Path $path -Default $null
        if ($null -eq $data) {
            return $Default
        }
        if ($data -is [System.Array]) {
            Write-Warning "状态文件格式无效（根节点为数组）：$path"
            return $Default
        }
        if ($data -is [hashtable]) {
            return $data
        }

        $result = @{}
        foreach ($prop in $data.PSObject.Properties) {
            $result[$prop.Name] = $prop.Value
        }
        return $result
    }
    catch {
        Write-Warning "读取状态文件失败：$path — $($_.Exception.Message)"
        return $Default
    }
}

function Write-ToolkitState {
    <#
    .SYNOPSIS
        写入一个工具的运行时状态
    .DESCRIPTION
        写入 TOOLKIT_STATE_DIR 或 %LOCALAPPDATA%\toolkit\state\<Name>.json，
        使用 UTF-8 无 BOM。返回是否写入成功；失败时给出警告，不抛异常。
    .PARAMETER Name
        状态名，对应文件名（不含扩展名）
    .PARAMETER Data
        要写入的哈希表
    .OUTPUTS
        System.Boolean
    .NOTES
        Author: SUNC
        Version: 1.1.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Data
    )

    try {
        $dir = Get-ToolkitStateDirectory
        $path = Join-Path $dir "$Name.json"
        Write-ToolkitJson -Path $path -Data $Data
        return $true
    }
    catch {
        Write-Warning "写入状态文件失败：$Name — $($_.Exception.Message)"
        return $false
    }
}

function Write-ToolkitConfigWarnings {
    <#
    .SYNOPSIS
        对配置对象中未登记的字段输出警告
    .DESCRIPTION
        供各配置校验器共用：接受 PSCustomObject 或哈希表，逐个比较已知字段名，
        未知字段输出一条 Warning 级消息。只提示、不修改配置，
        由调用方决定未知字段是否算错误。
    .PARAMETER Object
        配置对象、阶段或分发条目
    .PARAMETER KnownKeys
        该层允许的字段名
    .PARAMETER Label
        提示中的位置标签，如 stages[1] 或配置
    .EXAMPLE
        Write-ToolkitConfigWarnings -Object $config -KnownKeys 'timeoutSeconds', 'stages' -Label '配置'
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$KnownKeys,
        [string]$Label = '配置'
    )

    $names = if ($Object -is [hashtable]) { @($Object.Keys) } else { @($Object.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ($name -notin $KnownKeys) {
            Write-ToolkitMessage -Kind Warning -Text "警告：$Label 中的未知字段 '$name' 已忽略"
        }
    }
}

function Read-ToolkitEnvFile {
    <#
    .SYNOPSIS
        读取 .env 格式的键值文件
    .DESCRIPTION
        按行解析 KEY=VALUE，忽略空行与 # 开头的注释，去掉值两侧的单/双引号。
        文件按 UTF-8 读取；键名区分大小写。无效行抛出异常。
    .PARAMETER Path
        .env 文件路径
    .OUTPUTS
        System.Collections.Hashtable
    .EXAMPLE
        $values = Read-ToolkitEnvFile -Path 'config/dgs.env'
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $result = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) {
            throw "无效的 .env 行（缺少 KEY=VALUE）：$line"
        }

        $key = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim()
        if ($value.Length -ge 2 -and (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return $result
}
