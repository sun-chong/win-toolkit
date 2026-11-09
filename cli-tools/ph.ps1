<#
.SYNOPSIS
    PowerShell 历史记录管理

.DESCRIPTION
    管理 PowerShell 命令历史记录。默认流程：去重 → fzf 选择命令加入白名单 → 按白名单过滤历史。
    白名单外的命令会被删除（删除前自动备份）。

    使用方式：
    - ph                    去重 → fzf 选择命令加入白名单 → 按白名单过滤历史
    - ph -e, ph --edit      清理历史（去重+按时间排序）→ VSCode 打开（不过滤）
    - ph -w, ph --whitelist 用 VSCode 编辑白名单配置
    - ph -p, ph --path      打开历史文件所在目录
    - ph -h, ph --help      显示帮助信息

    白名单匹配规则（与 Claude Code permissions 语法一致）：
    - 条目末尾为 ":*"（或 " *"）→ 前缀匹配，如 "git:*" 保留 git 与所有 git 开头的命令
    - 其他条目 → 精确匹配，如 "ph" 仅保留 ph 本身

.PARAMETER Edit
    清理历史（去重+按时间排序）→ VSCode 打开
    短参数：-e

.PARAMETER Whitelist
    用 VSCode 编辑白名单配置（文件不存在时自动创建模板）
    短参数：-w

.PARAMETER Path
    打开历史文件所在目录
    短参数：-p

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    ph
    去重 → fzf 选择命令加入白名单 → 按白名单过滤历史

.EXAMPLE
    ph -e
    清理历史并使用 VSCode 打开编辑（不做白名单过滤）

.EXAMPLE
    ph -w
    用 VSCode 编辑白名单配置

.EXAMPLE
    ph -p
    打开历史文件所在目录

.NOTES
    Author: SUNC
    Version: 1.2.0
#>

param(
    [Alias("e")]
    [switch]$Edit,

    [Alias("w")]
    [switch]$Whitelist,

    [Alias("p")]
    [switch]$Path,

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
        'ph                    去重 → fzf 选择命令加入白名单 → 按白名单过滤历史'
        'ph -e, ph --edit      清理历史（去重+按时间排序）→ VSCode 打开（不过滤）'
        'ph -w, ph --whitelist 用 VSCode 编辑白名单配置'
        'ph -p, ph --path      打开历史文件所在目录'
        'ph -h, ph --help      显示帮助信息'
    ) }
    @{ Title = '白名单匹配规则（与 Claude Code permissions 语法一致）'; Lines = @(
        '条目末尾 ":*"（或 " *"）→ 前缀匹配，如 git:* 保留 git 与所有 git 开头的命令'
        '其他条目               → 精确匹配，如 ph 仅保留 ph 本身'
    ) }
)

# 常量定义
#region Script Constants
$HistoryPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
$BackupPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ph.history.bak"
$ConfigPath = (Resolve-ToolkitConfigPath -BasePath (Join-Path -Path $PSScriptRoot -ChildPath "ph.config")).Path
#endregion

#region 核心函数

function Clear-PhHistory {
    <#
    .SYNOPSIS
        清理历史记录（去重+按时间排序）
    #>
    param(
        [switch]$Silent
    )

    if (-not (Test-Path -Path $HistoryPath)) {
        if (-not $Silent) {
            Write-ToolkitMessage -Kind Error -Text "历史记录文件不存在: $HistoryPath"
        }
        return $false
    }

    try {
        $history = Get-Content -Path $HistoryPath -Encoding UTF8
        if (-not $history) {
            if (-not $Silent) {
                Write-ToolkitMessage -Kind Warning -Text "历史记录为空"
            }
            return $true
        }

        # 单行历史无需反转去重
        if ($history.Count -gt 1) {
            # 反转数组（最新的在前）→ 去重（保留最新的）→ 反转回来（最旧的在前）
            [array]::Reverse($history)
            $uniqueHistory = $history | Select-Object -Unique
            [array]::Reverse($uniqueHistory)
        } else {
            $uniqueHistory = $history
        }

        # 保存回文件
        $uniqueHistory | Set-Content -Path $HistoryPath -Encoding UTF8

        if (-not $Silent) {
            Write-ToolkitMessage -Kind Success -Text "已清理历史记录（去重+按时间排序）"
        }
        return $true
    }
    catch {
        if (-not $Silent) {
            Write-ToolkitMessage -Kind Error -Text "清理历史记录失败: $_"
        }
        return $false
    }
}

function Get-PhWhitelist {
    <#
    .SYNOPSIS
        读取白名单条目列表
    #>

    if (-not (Test-Path -Path $ConfigPath)) {
        return @()
    }

    try {
        $config = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
        if ($null -ne $config.whitelist) {
            return @($config.whitelist)
        }
        return @()
    }
    catch {
        Write-ToolkitMessage -Kind Error -Text "读取白名单配置失败: $_"
        return @()
    }
}

function Save-PhWhitelist {
    <#
    .SYNOPSIS
        保存白名单条目列表（UTF-8 无 BOM）
    #>
    param(
        [string[]]$Entries
    )

    $config = [ordered]@{
        whitelist = @($Entries | Select-Object -Unique | Sort-Object)
    }
    $json = $config | ConvertTo-Json
    [System.IO.File]::WriteAllText($ConfigPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Test-PhWhitelistMatch {
    <#
    .SYNOPSIS
        判断单条命令是否命中白名单条目
    .DESCRIPTION
        条目末尾为 ":*"（或 " *"）→ 前缀匹配（含裸命令本身）；其他 → 精确匹配。不区分大小写。
    #>
    param(
        [string]$Command,
        [string]$Entry
    )

    $entry = $Entry.Trim()
    if ($entry -match '(:\*|\s\*)$') {
        # 前缀匹配：去掉尾部 ":*" 或 " *"
        $prefix = ($entry -replace '(:\*|\s\*)$', '').TrimEnd()
        if (-not $prefix) {
            return $false
        }
        return ($Command -ieq $prefix) -or $Command.StartsWith("$prefix ", [System.StringComparison]::OrdinalIgnoreCase)
    }
    return ($Command -ieq $entry)
}

function Add-PhWhitelistFromFzf {
    <#
    .SYNOPSIS
        fzf 交互选择命令，确认后整条写入白名单
    #>

    if (-not (Test-Path -Path $HistoryPath)) {
        Write-ToolkitMessage -Kind Error -Text "历史记录文件不存在: $HistoryPath"
        return
    }

    # 读取历史记录（最旧的在前）
    $history = Get-Content -Path $HistoryPath -Encoding UTF8
    if (-not $history) {
        Write-ToolkitMessage -Kind Warning -Text "历史记录为空"
        return
    }

    # 反转数组，最新的在最上面
    $reversedHistory = $history.Clone()
    if ($reversedHistory.Count -gt 1) {
        [array]::Reverse($reversedHistory)
    }

    try {
        $selected = $reversedHistory | fzf --multi --height 40% --prompt "选择要加入白名单的命令> "
    }
    catch {
        Write-ToolkitMessage -Kind Error -Text "fzf 调用失败（未安装？）: $_"
        return
    }

    if (-not $selected) {
        # 用户按 Esc 取消：跳过白名单添加，继续执行过滤
        Write-ToolkitMessage -Kind Warning -Text "已跳过白名单添加"
        return
    }

    # 获取选中的命令（可能多行）
    $selectedLines = $selected -split "`n" | Where-Object { $_ }

    Write-ToolkitMessage -Kind Success -Text "`n将整条写入白名单（精确匹配）："
    $selectedLines | ForEach-Object { Write-Host "  $_" }

    $confirm = Read-Host "确认加入？(y/N)"
    if ($confirm -ne 'y') {
        Write-ToolkitMessage -Kind Warning -Text "已取消，未修改白名单"
        return
    }

    $existing = Get-PhWhitelist
    Save-PhWhitelist -Entries (@($existing) + $selectedLines)
    Write-ToolkitMessage -Kind Success -Text "已加入 $($selectedLines.Count) 条白名单（当前共 $(@($existing).Count + $selectedLines.Count) 条）"
}

function Invoke-PhWhitelistFilter {
    <#
    .SYNOPSIS
        按白名单过滤历史记录（过滤前自动备份）
    #>

    $whitelist = Get-PhWhitelist
    if ($whitelist.Count -eq 0) {
        Write-ToolkitMessage -Kind Warning -Text "白名单为空，跳过过滤"
        return
    }

    $history = @(Get-Content -Path $HistoryPath -Encoding UTF8)
    if ($history.Count -eq 0) {
        Write-ToolkitMessage -Kind Warning -Text "历史记录为空，跳过过滤"
        return
    }

    # 单次遍历分为保留 / 过滤两组
    $kept = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($cmd in $history) {
        $matched = $false
        foreach ($entry in $whitelist) {
            if (Test-PhWhitelistMatch -Command $cmd -Entry $entry) {
                $matched = $true
                break
            }
        }
        if ($matched) {
            $kept.Add($cmd)
        } else {
            $removed.Add($cmd)
        }
    }

    if ($removed.Count -eq 0) {
        Write-ToolkitMessage -Kind Success -Text "白名单之外无历史命令，历史未变动"
        return
    }

    # 过滤前备份原历史（覆盖上一份备份）
    try {
        Copy-Item -Force -Path $HistoryPath -Destination $BackupPath

        if ($kept.Count -gt 0) {
            $kept | Set-Content -Path $HistoryPath -Encoding UTF8
        } else {
            Set-Content -Path $HistoryPath -Value "" -Encoding UTF8
        }

        Write-ToolkitMessage -Kind Success -Text "已按白名单过滤：保留 $($kept.Count) 条 / 过滤 $($removed.Count) 条（备份: $BackupPath）"

        # 列出被过滤的命令（最多 20 条）
        $showCount = [Math]::Min($removed.Count, 20)
        Write-ToolkitMessage -Kind Warning -Text "被过滤的命令："
        for ($i = 0; $i -lt $showCount; $i++) {
            Write-Host "  $($removed[$i])"
        }
        if ($removed.Count -gt $showCount) {
            Write-Host "  ……另有 $($removed.Count - $showCount) 条省略"
        }
    }
    catch {
        Write-ToolkitMessage -Kind Error -Text "按白名单过滤历史失败: $_"
    }
}

#endregion

#region 参数处理

# 互斥参数校验
$paramCount = @($Edit, $Path, $Whitelist, $Help).Where({ $_ }).Count
if ($paramCount -gt 1) {
    Write-ToolkitMessage -Kind Error -Text "错误：-e、-w、-p、-h 参数不能同时使用"
    return
}

# 帮助信息
if ($Help) {
    Show-ToolkitHelp -Command 'ph' -Title 'PowerShell 历史记录管理' -Sections $helpSections
    return
}

# 打开目录
if ($Path) {
    $dir = Split-Path -Path $HistoryPath -Parent
    if (Test-Path -Path $dir) {
        explorer $dir
    } else {
        Write-ToolkitMessage -Kind Error -Text "目录不存在: $dir"
    }
    return
}

# -w/--whitelist 参数：VSCode 编辑白名单配置
if ($Whitelist) {
    if (-not (Test-Path -Path $ConfigPath)) {
        Save-PhWhitelist -Entries @()
    }
    code $ConfigPath
    return
}

# -e/--edit 参数：清理 + VSCode 打开
if ($Edit) {
    $result = Clear-PhHistory
    if ($result) {
        code $HistoryPath
    }
    return
}

# 默认行为：去重 → fzf 选择加入白名单 → 按白名单过滤
$null = Clear-PhHistory -Silent
Add-PhWhitelistFromFzf
Invoke-PhWhitelistFilter

#endregion
