<#
.SYNOPSIS
    登录启动清单执行器

.DESCRIPTION
    按一份有序启动清单依次执行启动项。默认读取 cli-tools\as.config.jsonc
    （兼容 .json），用 -c 可指定命名配置（如 as-shopee）或按路径指定配置，
    一次运行只使用一份启动配置。

    本版本实现 folder（用资源管理器打开目录）与 sleep（显式等待）两类启动项；
    app、url、command、vscode 完成解析与校验后标记为失败，并提示该类型将在后续工单实现。
    单个启动项失败不会中断清单，结束时给出成功/失败汇总并按结果设置退出码。

.PARAMETER Config
    启动配置的短名或路径
    短参数：-c
    短名与相对路径都相对 cli-tools 目录解析；.config 与 .jsonc/.json 后缀可省略。
    示例：-c as-shopee、-c as-shopee.config、-c as-shopee.config.jsonc、
          -c .\as-shopee.config.jsonc、-c C:\configs\as-shopee.config.json

.PARAMETER DryRun
    只打印解析计划与每项间隔规则，不启动任何程序、不写日志

.PARAMETER SkipTopMost
    跳过置顶阶段；置顶由后续工单实现，本版本无实际效果

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    as
    执行默认启动配置 as.config

.EXAMPLE
    as -c as-shopee
    执行命名启动配置 as-shopee.config.jsonc（或 .json）

.EXAMPLE
    as -DryRun
    预演默认启动配置，只打印解析计划与间隔规则

.EXAMPLE
    as -c .\as-shopee.config.jsonc -DryRun -SkipTopMost
    按相对路径预演命名启动配置

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
    [Alias("c")]
    [string]$Config,

    [switch]$DryRun,

    [switch]$SkipTopMost,

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
        'as                              执行默认启动配置 as.config'
        'as -c as-shopee                 执行命名启动配置（短名/带 .config/完整文件名均可）'
        'as -c .\as-shopee.config.jsonc  按路径指定启动配置（相对路径相对 cli-tools 目录）'
        'as -DryRun                      只打印解析计划，不启动程序、不写日志'
        'as -SkipTopMost                 跳过置顶阶段（置顶由后续工单实现）'
        'as -h                           显示帮助信息'
    ) }
    @{ Title = '启动配置'; Lines = @(
        '默认读取 cli-tools\as.config.jsonc（兼容 .json）；命名配置以 as- 开头。'
        '-c 的短名与相对路径都在 cli-tools 目录下解析，.config 与 .jsonc/.json 后缀可省略。'
        '顶层字段：delayMs（默认间隔，默认 1000 毫秒）、items（启动清单）。'
        '未知顶层字段只警告；配置缺失或 JSON/顶层结构错误时直接退出 1。'
    ) }
    @{ Title = '启动项'; Lines = @(
        'app      name 或 path（二者互斥）              名称启动/路径启动（后续工单实现）'
        'url      urls（字符串或字符串数组）            默认浏览器多标签（后续工单实现）'
        'folder   path                                  资源管理器打开目录（本版本已实现）'
        'command  command，可选 cwd/newTab/keepOpen     默认终端执行（后续工单实现）'
        'vscode   path 或 name（二者互斥）              VS Code 打开项目（后续工单实现）'
        'sleep    ms（正整数）                          显式等待（本版本已实现）'
        '公共可选字段：delayMs（覆盖本项之后的间隔）、topMost（仅 app/vscode，置顶由后续工单实现）。'
        '休眠项不接受 delayMs/topMost，出现时警告并忽略。'
        '路径会先展开 %VAR% 环境变量；相对路径相对当前工作目录解析。'
    ) }
    @{ Title = '示例'; Lines = @(
        'as -DryRun                      预演默认配置，检查解析结果与间隔'
        'as -c as-shopee                 执行 as-shopee.config.jsonc（或 .json）'
        'as -c C:\configs\as-work.config.json -DryRun   按绝对路径预演'
    ) }
    @{ Title = '退出码'; Lines = @(
        '0  全部启动项成功（DryRun 时表示没有校验失败的启动项）'
        '1  配置缺失、JSON 解析失败、顶层结构非法，或存在失败的启动项'
    ) }
)

if ($Help) {
    Show-ToolkitHelp -Command 'as' -Title '登录启动清单执行器' -Sections $helpSections
    exit 0
}

$script:ScriptDir = $PSScriptRoot
$script:DefaultConfigName = 'as.config'
$script:DefaultDelayMs = 1000

# ============================================================
# 配置解析
# ============================================================

function Resolve-AsConfigInfo {
    <#
    .SYNOPSIS
        解析 -c 指定的启动配置路径
    .DESCRIPTION
        无 -c 时使用默认配置 as.config。先把 -c 的 .jsonc/.json 与 .config 后缀去掉，
        统一补回 .config，再交给 Resolve-ToolkitConfigPath 探测扩展名（优先 .jsonc）。
        含路径分隔符或以盘符开头时按路径处理，相对路径相对 cli-tools 目录解析；
        其余短名也在 cli-tools 目录下解析。
    .PARAMETER Name
        -c 的原始值；为空时使用默认配置
    .OUTPUTS
        Resolve-ToolkitConfigPath 的返回值：Path / Exists / Extension
    #>
    param([string]$Name)

    $value = if ([string]::IsNullOrWhiteSpace($Name)) { $script:DefaultConfigName } else { $Name.Trim() }

    # 三种 -c 写法（as-shopee / as-shopee.config / as-shopee.config.jsonc）都归一到 as-shopee.config
    $base = $value -replace '\.jsonc$', '' -replace '\.json$', ''
    $base = $base -replace '\.config$', ''
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'as' }

    $isPath = $base -match '[\\/]' -or $base -match '^[A-Za-z]:'
    if ($isPath) {
        $expanded = Resolve-ToolkitPathValue -Path $base
        $basePath = if ([System.IO.Path]::IsPathRooted($expanded)) {
            $expanded
        } else {
            Join-Path $script:ScriptDir $expanded
        }
    } else {
        $basePath = Join-Path $script:ScriptDir $base
    }

    # 归一化后拼接 .config，报错与列目录时都是干净路径
    try { $basePath = [System.IO.Path]::GetFullPath($basePath) } catch { $null = $_ }
    $basePath += '.config'

    return (Resolve-ToolkitConfigPath -BasePath $basePath)
}

function Test-AsIntegerValue {
    <#
    .SYNOPSIS
        判断 JSON 数值是否是指定范围内的整数
    .DESCRIPTION
        只接受 JSON 数字（整数或整值浮点），字符串与布尔值一律视为无效。
    .PARAMETER Value
        待校验的值
    .PARAMETER Minimum
        允许的最小值（含）
    .PARAMETER Maximum
        允许的最大值（含）
    .PARAMETER Result
        校验通过时回填的整数值
    #>
    param(
        [object]$Value,
        [long]$Minimum = 0,
        [long]$Maximum = [int]::MaxValue,
        [ref]$Result
    )

    $Result.Value = 0
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]) {
        if ($Value -lt $Minimum -or $Value -gt $Maximum) { return $false }
        $Result.Value = [int]$Value
        return $true
    }

    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        if ($Value -lt $Minimum -or $Value -gt $Maximum) { return $false }
        if ($Value -ne [math]::Floor($Value)) { return $false }
        $Result.Value = [int]$Value
        return $true
    }

    return $false
}

function Show-AsAvailableConfigs {
    <#
    .SYNOPSIS
        列出一个目录下现有的 as*.config.json(c) 启动配置
    .PARAMETER Directory
        要扫描的目录
    #>
    param([string]$Directory)

    $files = @()
    if ($Directory -and (Test-Path -LiteralPath $Directory -PathType Container)) {
        $files = @(
            Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^as.*\.config\.jsonc?$' } |
                Sort-Object Name
        )
    }

    if ($files.Count -gt 0) {
        Write-ToolkitMessage -Kind Warning -Text '现有启动配置：'
        foreach ($file in $files) {
            Write-ToolkitMessage -Kind Muted -Text "  $($file.Name)"
        }
    } else {
        Write-ToolkitMessage -Kind Muted -Text "该目录下没有 as*.config.json(c) 启动配置：$Directory"
    }
}

# ============================================================
# 启动项校验
# ============================================================

function Get-AsItemModel {
    <#
    .SYNOPSIS
        把原始启动项校验并转换为统一模型
    .DESCRIPTION
        六类启动项都校验必填字段与公共可选字段。未知字段只警告；
        未知类型、缺少必填字段或字段值非法时该项标记 Failed，由调用方警告并跳过。
    .PARAMETER Raw
        配置中的原始启动项
    .PARAMETER Index
        启动项序号，从 1 开始
    .OUTPUTS
        PSCustomObject：Index / Type / DelayMs / TopMost / Status / Reason / Data
    #>
    param(
        [object]$Raw,
        [int]$Index
    )

    $model = [PSCustomObject]@{
        Index   = $Index
        Type    = '?'
        DelayMs = $null
        TopMost = $false
        Status  = 'Valid'
        Reason  = ''
        Data    = @{}
    }

    if (-not ($Raw -is [hashtable])) {
        $model.Status = 'Failed'
        $model.Reason = '启动项必须是 JSON 对象'
        return $model
    }

    $typeValue = if ($Raw.ContainsKey('type')) { $Raw['type'] } else { $null }
    if ($typeValue -isnot [string] -or [string]::IsNullOrWhiteSpace($typeValue)) {
        Write-ToolkitConfigWarnings -Object $Raw -KnownKeys @('type', 'delayMs', 'topMost') -Label "启动项 [$Index]"
        $model.Status = 'Failed'
        $model.Reason = '缺少 type 字段或 type 不是字符串'
        return $model
    }

    $type = $typeValue.Trim().ToLowerInvariant()
    $model.Type = $type

    # 公共字段 + 当前类型的专属字段；未知字段逐项警告
    $knownKeys = @('type', 'delayMs', 'topMost')
    switch ($type) {
        'app' { $knownKeys += @('name', 'path') }
        'url' { $knownKeys += 'urls' }
        'folder' { $knownKeys += 'path' }
        'command' { $knownKeys += @('command', 'cwd', 'newTab', 'keepOpen') }
        'vscode' { $knownKeys += @('name', 'path') }
        'sleep' { $knownKeys += 'ms' }
    }
    Write-ToolkitConfigWarnings -Object $Raw -KnownKeys $knownKeys -Label "启动项 [$Index]"

    if ($type -notin @('app', 'url', 'folder', 'command', 'vscode', 'sleep')) {
        $model.Status = 'Failed'
        $model.Reason = "未知类型 '$typeValue'"
        return $model
    }

    $reasons = @()

    if ($type -eq 'sleep') {
        # 休眠项以自身 ms 替代相邻默认间隔，不接受 delayMs/topMost
        if ($Raw.ContainsKey('delayMs')) {
            Write-ToolkitMessage -Kind Warning -Text "警告：启动项 [$Index] 的类型 sleep 不支持 delayMs，已忽略"
        }
        if ($Raw.ContainsKey('topMost')) {
            Write-ToolkitMessage -Kind Warning -Text "警告：启动项 [$Index] 的类型 sleep 不支持 topMost，已忽略"
        }
    } else {
        if ($Raw.ContainsKey('delayMs')) {
            $delay = 0
            if (Test-AsIntegerValue -Value $Raw['delayMs'] -Minimum 0 -Result ([ref]$delay)) {
                $model.DelayMs = $delay
            } else {
                $reasons += 'delayMs 必须是非负整数'
            }
        }

        if ($Raw.ContainsKey('topMost')) {
            if ($type -notin @('app', 'vscode')) {
                Write-ToolkitMessage -Kind Warning -Text "警告：启动项 [$Index] 的类型 '$type' 不支持 topMost，已忽略"
            } elseif ($Raw['topMost'] -is [bool]) {
                $model.TopMost = [bool]$Raw['topMost']
            } else {
                Write-ToolkitMessage -Kind Warning -Text "警告：启动项 [$Index] 的 topMost 必须是布尔值，已忽略"
            }
        }
    }

    switch ($type) {
        'app' {
            $hasName = $Raw.ContainsKey('name')
            $hasPath = $Raw.ContainsKey('path')
            if ($hasName -and $hasPath) {
                $reasons += 'name 与 path 只能二选一'
            } elseif (-not $hasName -and -not $hasPath) {
                $reasons += '缺少 name 或 path'
            } elseif ($hasName) {
                if ($Raw['name'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Raw['name'])) {
                    $model.Data.Name = $Raw['name'].Trim()
                } else {
                    $reasons += 'name 必须是非空字符串'
                }
            } else {
                if ($Raw['path'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Raw['path'])) {
                    $model.Data.Path = $Raw['path'].Trim()
                } else {
                    $reasons += 'path 必须是非空字符串'
                }
            }
        }
        'url' {
            if (-not $Raw.ContainsKey('urls')) {
                $reasons += '缺少 urls 字段'
            } else {
                $urlValue = $Raw['urls']
                if ($urlValue -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($urlValue)) {
                        $reasons += 'urls 不能为空'
                    } else {
                        $model.Data.Urls = @($urlValue.Trim())
                    }
                } elseif ($urlValue -is [array]) {
                    $list = @($urlValue)
                    if ($list.Count -eq 0) {
                        $reasons += 'urls 至少包含一个网址'
                    } else {
                        $allValid = $true
                        foreach ($entry in $list) {
                            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                                $allValid = $false
                                break
                            }
                        }
                        if ($allValid) {
                            $model.Data.Urls = @($list | ForEach-Object { $_.Trim() })
                        } else {
                            $reasons += 'urls 中的每一项都必须是非空字符串'
                        }
                    }
                } else {
                    $reasons += 'urls 必须是字符串或字符串数组'
                }
            }
        }
        'folder' {
            if (-not $Raw.ContainsKey('path')) {
                $reasons += '缺少 path 字段'
            } elseif ($Raw['path'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Raw['path'])) {
                $reasons += 'path 必须是非空字符串'
            } else {
                # 相对路径沿用 Resolve-ToolkitPathValue 的约定：不传 -Base，相对当前工作目录
                $model.Data.Path = [string](Resolve-ToolkitPathValue -Path $Raw['path'].Trim())
            }
        }
        'command' {
            if (-not $Raw.ContainsKey('command') -or $Raw['command'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Raw['command'])) {
                $reasons += 'command 必须是非空字符串'
            } else {
                $model.Data.Command = $Raw['command'].Trim()
            }

            if ($Raw.ContainsKey('cwd')) {
                if ($Raw['cwd'] -is [string]) {
                    if (-not [string]::IsNullOrWhiteSpace($Raw['cwd'])) {
                        $model.Data.Cwd = $Raw['cwd'].Trim()
                    }
                } else {
                    $reasons += 'cwd 必须是字符串'
                }
            }

            $model.Data.NewTab = $false
            if ($Raw.ContainsKey('newTab')) {
                if ($Raw['newTab'] -is [bool]) {
                    $model.Data.NewTab = [bool]$Raw['newTab']
                } else {
                    $reasons += 'newTab 必须是布尔值'
                }
            }

            $model.Data.KeepOpen = $true
            if ($Raw.ContainsKey('keepOpen')) {
                if ($Raw['keepOpen'] -is [bool]) {
                    $model.Data.KeepOpen = [bool]$Raw['keepOpen']
                } else {
                    $reasons += 'keepOpen 必须是布尔值'
                }
            }
        }
        'vscode' {
            $hasName = $Raw.ContainsKey('name')
            $hasPath = $Raw.ContainsKey('path')
            if ($hasName -and $hasPath) {
                $reasons += 'name 与 path 只能二选一'
            } elseif (-not $hasName -and -not $hasPath) {
                $reasons += '缺少 name 或 path'
            } elseif ($hasName) {
                if ($Raw['name'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Raw['name'])) {
                    $model.Data.Name = $Raw['name'].Trim()
                } else {
                    $reasons += 'name 必须是非空字符串'
                }
            } else {
                if ($Raw['path'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Raw['path'])) {
                    $model.Data.Path = $Raw['path'].Trim()
                } else {
                    $reasons += 'path 必须是非空字符串'
                }
            }
        }
        'sleep' {
            $ms = 0
            if (-not $Raw.ContainsKey('ms')) {
                $reasons += '缺少 ms 字段'
            } elseif (-not (Test-AsIntegerValue -Value $Raw['ms'] -Minimum 1 -Result ([ref]$ms))) {
                $reasons += 'ms 必须是正整数'
            } else {
                $model.Data.Ms = $ms
            }
        }
    }

    if ($reasons.Count -gt 0) {
        $model.Status = 'Failed'
        $model.Reason = ($reasons -join '；')
    }
    return $model
}

function Get-AsItemDetail {
    <#
    .SYNOPSIS
        生成启动项的 DryRun 配置摘要
    .PARAMETER Item
        已校验的启动项模型
    #>
    param([object]$Item)

    switch ($Item.Type) {
        'folder' { return "打开目录：$($Item.Data.Path)" }
        'sleep' { return "等待 $($Item.Data.Ms) 毫秒" }
        'app' {
            $text = if ($Item.Data.ContainsKey('Name')) { "名称：$($Item.Data.Name)" } else { "路径：$($Item.Data.Path)" }
            if ($Item.TopMost) { $text += '；置顶：是' }
            return $text
        }
        'url' { return "网址：$($Item.Data.Urls -join '、')" }
        'command' {
            $text = "命令：$($Item.Data.Command)"
            if ($Item.Data.ContainsKey('Cwd')) { $text += "；工作目录：$($Item.Data.Cwd)" }
            if ($Item.Data.NewTab) { $text += '；新标签：是' }
            if (-not $Item.Data.KeepOpen) { $text += '；保留终端：否' }
            return $text
        }
        'vscode' {
            $text = if ($Item.Data.ContainsKey('Name')) { "名称：$($Item.Data.Name)" } else { "路径：$($Item.Data.Path)" }
            if ($Item.TopMost) { $text += '；置顶：是' }
            return $text
        }
        default { return '' }
    }
}

# ============================================================
# 节奏引擎
# ============================================================

function Get-AsIntervalMs {
    <#
    .SYNOPSIS
        计算相邻启动项之间的等待毫秒数
    .DESCRIPTION
        任一端为休眠项时为 0（休眠项替代默认间隔，不叠加）；
        否则取前一项的 delayMs（若有），再退回全局默认间隔。
    .PARAMETER Previous
        前一个启动项模型
    .PARAMETER Next
        后一个启动项模型
    .PARAMETER DefaultDelayMs
        全局默认间隔
    #>
    param(
        [object]$Previous,
        [object]$Next,
        [int]$DefaultDelayMs
    )

    if ($Previous.Type -eq 'sleep' -or $Next.Type -eq 'sleep') { return 0 }
    if ($null -ne $Previous.DelayMs) { return [int]$Previous.DelayMs }
    return $DefaultDelayMs
}

function Get-AsIntervalDescription {
    <#
    .SYNOPSIS
        生成 DryRun 用的间隔规则说明
    #>
    param(
        [object]$Previous,
        [object]$Next,
        [int]$DefaultDelayMs
    )

    if ($Previous.Type -eq 'sleep' -and $Next.Type -eq 'sleep') {
        return '0 毫秒（两个休眠项相邻，无额外间隔）'
    }
    if ($Previous.Type -eq 'sleep') {
        return '0 毫秒（休眠项替代相邻默认间隔）'
    }
    if ($Next.Type -eq 'sleep') {
        return '0 毫秒（下一项为休眠项，替代默认间隔）'
    }
    if ($null -ne $Previous.DelayMs) {
        return "$($Previous.DelayMs) 毫秒（本项 delayMs 覆盖默认间隔）"
    }
    return "$DefaultDelayMs 毫秒（默认间隔）"
}

# ============================================================
# 执行与预演
# ============================================================

function Invoke-AsItem {
    <#
    .SYNOPSIS
        执行单个启动项
    .DESCRIPTION
        本版本只执行 folder 与 sleep；其余四类返回失败并提示后续工单实现。
        返回 PSCustomObject：Success / Message。
    .PARAMETER Item
        已校验的启动项模型
    #>
    param([object]$Item)

    switch ($Item.Type) {
        'sleep' {
            Start-Sleep -Milliseconds ([int]$Item.Data.Ms)
            return [PSCustomObject]@{ Success = $true; Message = "等待 $($Item.Data.Ms) 毫秒" }
        }
        'folder' {
            $path = [string]$Item.Data.Path
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                return [PSCustomObject]@{ Success = $false; Message = "目录不存在：$path" }
            }
            try {
                $explorer = Join-Path $env:SystemRoot 'explorer.exe'
                Start-Process -FilePath $explorer -ArgumentList ('"{0}"' -f $path) -ErrorAction Stop
                return [PSCustomObject]@{ Success = $true; Message = "打开目录：$path" }
            } catch {
                return [PSCustomObject]@{ Success = $false; Message = "打开目录失败：$($_.Exception.Message)" }
            }
        }
        default {
            return [PSCustomObject]@{ Success = $false; Message = '该类型将在后续工单实现' }
        }
    }
}

function Show-AsDryRun {
    <#
    .SYNOPSIS
        打印启动清单的解析计划与间隔规则，不启动任何程序、不写日志
    .DESCRIPTION
        逐项打印序号、类型与解析结果；folder 显示展开后的路径，
        sleep 显示毫秒数，app/url/command/vscode 显示配置摘要并标注尚未实现。
        返回校验失败（含目录不存在）的项数，供调用方决定退出码。
    .PARAMETER Items
        启动项模型数组
    .PARAMETER DefaultDelayMs
        全局默认间隔
    .PARAMETER ConfigPath
        当前使用的启动配置路径
    .PARAMETER SkipTopMostStage
        是否由 -SkipTopMost 跳过置顶阶段
    #>
    param(
        [object[]]$Items,
        [int]$DefaultDelayMs,
        [string]$ConfigPath,
        [bool]$SkipTopMostStage
    )

    Write-ToolkitMessage -Kind Info -Text "启动配置：$ConfigPath"
    Write-ToolkitMessage -Kind Info -Text "启动项：$($Items.Count) 个；默认间隔：$DefaultDelayMs 毫秒"
    Write-ToolkitMessage -Kind Muted -Text '模式：DryRun（不启动任何程序、不写日志）'
    if ($SkipTopMostStage) {
        Write-ToolkitMessage -Kind Muted -Text '置顶阶段：已跳过（-SkipTopMost；置顶由后续工单实现）'
    } else {
        Write-ToolkitMessage -Kind Muted -Text '置顶阶段：由后续工单实现，本次预演不激活窗口'
    }

    $readyCount = 0
    $pendingCount = 0
    $failedCount = 0

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $prefix = "[$($item.Index)/$($Items.Count)]"

        if ($item.Status -eq 'Failed') {
            Write-ToolkitMessage -Kind Warning -Text "$prefix $($item.Type) 校验失败：$($item.Reason)"
            $failedCount++
        } elseif ($item.Type -eq 'folder') {
            $exists = Test-Path -LiteralPath $item.Data.Path -PathType Container
            if ($exists) {
                Write-ToolkitMessage -Kind Info -Text "$prefix folder 打开目录：$($item.Data.Path)"
                $readyCount++
            } else {
                Write-ToolkitMessage -Kind Warning -Text "$prefix folder 打开目录：$($item.Data.Path)（目录不存在，执行时将失败）"
                $failedCount++
            }
        } elseif ($item.Type -eq 'sleep') {
            $label = if ($i -eq 0) { '启动前等待' } else { '等待' }
            Write-ToolkitMessage -Kind Info -Text "$prefix sleep $label $($item.Data.Ms) 毫秒"
            $readyCount++
        } else {
            $detail = Get-AsItemDetail -Item $item
            Write-ToolkitMessage -Kind Info -Text "$prefix $($item.Type) $detail（尚未实现）"
            $pendingCount++
        }

        if ($i -lt $Items.Count - 1) {
            $description = Get-AsIntervalDescription -Previous $item -Next $Items[$i + 1] -DefaultDelayMs $DefaultDelayMs
            Write-ToolkitMessage -Kind Muted -Text "    后续间隔：$description"
        } else {
            Write-ToolkitMessage -Kind Muted -Text '    后续间隔：无（清单结束）'
        }
    }

    Write-ToolkitMessage -Kind Info -Text "DryRun 汇总：可执行 $readyCount 项，待后续工单实现 $pendingCount 项，校验失败 $failedCount 项"
    Write-ToolkitMessage -Kind Muted -Text '未启动任何程序，未写日志。'
    return $failedCount
}

# ============================================================
# 主流程
# ============================================================

$configInfo = Resolve-AsConfigInfo -Name $Config
if (-not $configInfo.Exists) {
    Write-ToolkitMessage -Kind Error -Text "未找到启动配置：$($configInfo.Path)"
    Show-AsAvailableConfigs -Directory (Split-Path -Parent $configInfo.Path)
    exit 1
}

$globalDelayMs = $script:DefaultDelayMs
$rawItems = @()
try {
    $configData = Read-ToolkitJson -Path $configInfo.Path -AsHashtable -ThrowOnError
    if (-not ($configData -is [hashtable])) {
        throw '顶层必须是 JSON 对象'
    }

    Write-ToolkitConfigWarnings -Object $configData -KnownKeys @('delayMs', 'items') -Label '启动配置'

    if ($configData.ContainsKey('delayMs')) {
        $parsedDelay = 0
        if (-not (Test-AsIntegerValue -Value $configData['delayMs'] -Minimum 0 -Result ([ref]$parsedDelay))) {
            throw '顶层 delayMs 必须是非负整数'
        }
        $globalDelayMs = $parsedDelay
    }

    if (-not $configData.ContainsKey('items') -or $null -eq $configData['items'] -or $configData['items'] -isnot [array]) {
        throw '顶层 items 必须是数组'
    }
    $rawItems = $configData['items']
} catch {
    Write-ToolkitMessage -Kind Error -Text "启动配置无效：$($_.Exception.Message)"
    exit 1
}

$items = @(
    for ($i = 0; $i -lt $rawItems.Count; $i++) {
        Get-AsItemModel -Raw $rawItems[$i] -Index ($i + 1)
    }
)

if ($DryRun) {
    $failedCount = Show-AsDryRun -Items $items -DefaultDelayMs $globalDelayMs -ConfigPath $configInfo.Path -SkipTopMostStage ([bool]$SkipTopMost)
    if ($failedCount -gt 0) { exit 1 }
    exit 0
}

Write-ToolkitMessage -Kind Info -Text "启动配置：$($configInfo.Path)"
Write-ToolkitMessage -Kind Info -Text "启动项：$($items.Count) 个；默认间隔：$globalDelayMs 毫秒"
if ($SkipTopMost) {
    Write-ToolkitMessage -Kind Muted -Text '置顶阶段：本版本尚未实现，-SkipTopMost 无实际影响'
}

$successCount = 0
$failureCount = 0

for ($i = 0; $i -lt $items.Count; $i++) {
    $item = $items[$i]
    $prefix = "[$($item.Index)/$($items.Count)]"

    $result = if ($item.Status -eq 'Failed') {
        [PSCustomObject]@{ Success = $false; Message = $item.Reason }
    } else {
        Invoke-AsItem -Item $item
    }

    $line = if ($result.Success) {
        "$prefix $($item.Type) 成功：$($result.Message)"
    } else {
        "$prefix $($item.Type) 失败：$($result.Message)"
    }

    if ($result.Success) {
        $successCount++
        Write-ToolkitMessage -Kind Success -Text $line
    } else {
        $failureCount++
        Write-ToolkitMessage -Kind Warning -Text $line
    }
    Write-ToolkitLogLine -Tool 'as' -Text $line

    # 相邻项间隔：休眠项自身已在执行阶段等待，任一端为休眠项时不再额外等待
    if ($i -lt $items.Count - 1) {
        $intervalMs = Get-AsIntervalMs -Previous $item -Next $items[$i + 1] -DefaultDelayMs $globalDelayMs
        if ($intervalMs -gt 0) {
            Start-Sleep -Milliseconds $intervalMs
        }
    }
}

$summary = "汇总：成功 $successCount，失败 $failureCount"
if ($failureCount -gt 0) {
    Write-ToolkitMessage -Kind Warning -Text $summary
} else {
    Write-ToolkitMessage -Kind Success -Text $summary
}
Write-ToolkitLogLine -Tool 'as' -Text "$summary（启动配置：$($configInfo.Path)）"

if ($failureCount -gt 0) { exit 1 }
exit 0
</content>
</file_path>
