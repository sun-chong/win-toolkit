<#
.SYNOPSIS
    定时关机工具

.DESCRIPTION
    设定 Windows 定时强制关机，支持指定当天或未来 1-3 天内的关机时间。
    支持标准时间格式（HH:MM）、紧凑格式（HHMM）和中文冒号自动转换。

.PARAMETER Time
    关机时间，格式为 HH:MM 或 HHMM。
    支持中文冒号（：）自动转换为英文冒号（:）。
    示例：18:00, 1800, 18：00

.PARAMETER Offset
    天数偏移量，格式为 +N（N 为 1-3）。
    +1 表示明天，+2 表示后天，+3 表示大后天。
    示例：+1, +2, +3

.PARAMETER Cancel
    取消已设定的定时关机
    短参数：-c

.PARAMETER Help
    查看帮助信息
    短参数：-h

.EXAMPLE
    tsd 18:00
    今天 18:00 强制关机

.EXAMPLE
    tsd 18:00 +1
    明天 18:00 强制关机

.EXAMPLE
    tsd 1800
    紧凑格式，等同于 tsd 18:00

.EXAMPLE
    tsd cancel
    取消定时关机

.EXAMPLE
    tsd -h
    查看帮助信息

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
    [Parameter(Position = 0)]
    [string]$Time,

    [Parameter(Position = 1)]
    [string]$Offset,

    [Alias("c")]
    [switch]$Cancel,

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
        'tsd <时间> [+N]     设定关机时间'
        'tsd cancel, tsd -c  取消定时关机'
        'tsd -h              查看帮助信息'
    ) }
    @{ Title = '时间格式'; Lines = @(
        'HH:MM               标准格式（如 18:00）'
        'HHMM                紧凑格式（如 1800）'
        '中文冒号（：）       自动转为英文冒号（:）'
    ) }
    @{ Title = '天数偏移'; Lines = @(
        '+1                  明天'
        '+2                  后天'
        '+3                  大后天'
    ) }
    @{ Title = '示例'; Lines = @(
        'tsd 18:00           今天 18:00 关机'
        'tsd 18:00 +1        明天 18:00 关机'
        'tsd 1800            等同于 tsd 18:00'
        'tsd cancel          取消定时关机'
    ) }
)
function Stop-TimedShutdown {
    & shutdown /a 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 1116) {
        Write-ToolkitMessage -Kind Warning -Text "当前没有待执行的关机计划"
    } else {
        Write-ToolkitMessage -Kind Success -Text "定时关机已取消"
    }
}

function Convert-ToTimeFormat {
    param([string]$InputTime)

    # 中文冒号转英文冒号
    $InputTime = $InputTime -replace '：', ':'

    # 紧凑格式：4 位纯数字，自动插入冒号
    if ($InputTime -match '^\d{4}$') {
        $InputTime = "$($InputTime.Substring(0, 2)):$($InputTime.Substring(2, 2))"
    }

    return $InputTime
}

function Test-ValidTime {
    param([string]$TimeStr)

    # 验证格式 HH:MM
    if ($TimeStr -notmatch '^\d{1,2}:\d{2}$') {
        return $false
    }

    $parts = $TimeStr -split ':'
    $hour = [int]$parts[0]
    $minute = [int]$parts[1]

    if ($hour -lt 0 -or $hour -gt 23) { return $false }
    if ($minute -lt 0 -or $minute -gt 59) { return $false }

    return $true
}

function Get-TimeComponents {
    param([string]$TimeStr)

    $parts = $TimeStr -split ':'
    return @{
        Hour   = [int]$parts[0]
        Minute = [int]$parts[1]
    }
}

function Test-ValidOffset {
    param([string]$OffsetStr)

    # 必须以 + 开头
    if ($OffsetStr -notmatch '^\+\d+$') {
        return $false
    }

    $days = [int]$OffsetStr.Substring(1)
    if ($days -lt 1 -or $days -gt 3) {
        return $false
    }

    return $true
}

function Get-OffsetDays {
    param([string]$OffsetStr)

    return [int]$OffsetStr.Substring(1)
}

function Get-DayLabel {
    param([int]$DaysOffset)

    if ($DaysOffset -eq 0) { return "今天" }
    elseif ($DaysOffset -eq 1) { return "明天" }
    elseif ($DaysOffset -eq 2) { return "后天" }
    else { return "${DaysOffset} 天后" }
}

function Invoke-TimedShutdown {
    param(
        [string]$TimeStr,
        [int]$DaysOffset = 0
    )

    $now = Get-Date
    $components = Get-TimeComponents -TimeStr $TimeStr
    $target = Get-Date -Hour $components.Hour -Minute $components.Minute -Second 0

    # 加上天数偏移
    if ($DaysOffset -gt 0) {
        $target = $target.AddDays($DaysOffset)
    }

    # 计算延迟秒数
    $delaySeconds = [math]::Floor(($target - $now).TotalSeconds)

    # 如果目标时间已过
    if ($delaySeconds -le 0) {
        $nextOffset = $DaysOffset + 1
        $nextDay = Get-DayLabel -DaysOffset $nextOffset
        $response = Read-Host "当前时间已超过 $TimeStr，是否改为 $nextDay $TimeStr 关机？(y/n)"
        if ($response -eq 'y' -or $response -eq 'Y') {
            $DaysOffset = $nextOffset
            $target = $target.AddDays(1)
            $delaySeconds = [math]::Floor(($target - $now).TotalSeconds)
        } else {
            return
        }
    }

    # 计算剩余时间显示
    $remaining = New-TimeSpan -Start $now -End $target
    $remainingStr = ""
    if ($remaining.Days -gt 0) {
        $remainingStr += "$($remaining.Days) 天 "
    }
    if ($remaining.Hours -gt 0) {
        $remainingStr += "$($remaining.Hours) 小时 "
    }
    $remainingStr += "$($remaining.Minutes) 分钟后"

    # 执行关机
    & shutdown /s /f /t $delaySeconds 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 1190) {
        # 已有关机计划
        $response = Read-Host "已有关机计划，是否取消当前计划并设定新的关机时间？(y/n)"
        if ($response -eq 'y' -or $response -eq 'Y') {
            & shutdown /a 2>&1 | Out-Null
            & shutdown /s /f /t $delaySeconds 2>&1 | Out-Null
        } else {
            return
        }
    }

    if ($LASTEXITCODE -eq 0) {
        $dayStr = Get-DayLabel -DaysOffset $DaysOffset
        Write-ToolkitMessage -Kind Success -Text "关机计划已设定：将在 $dayStr $TimeStr 强制关机（$remainingStr）"
    }
}

# 入口逻辑
if ($Help) {
    Show-ToolkitHelp -Command 'tsd' -Title '定时关机' -Sections $helpSections -Compact
    exit 0
}

if ($Cancel) {
    Stop-TimedShutdown
    exit 0
}

# 无参数时显示帮助
if ([string]::IsNullOrWhiteSpace($Time)) {
    Show-ToolkitHelp -Command 'tsd' -Title '定时关机' -Sections $helpSections -Compact
    exit 0
}

# 解析时间格式
$Time = Convert-ToTimeFormat -InputTime $Time

# 校验时间格式
if (-not (Test-ValidTime -TimeStr $Time)) {
    Write-ToolkitMessage -Kind Error -Text "时间无效，小时应为 0-23，分应为 0-59"
    Write-ToolkitMessage -Kind Warning -Text "用法: tsd <HH:MM> [+N]，其中 N 为 1-3"
    exit 1
}

# 校验偏移量
if (-not [string]::IsNullOrWhiteSpace($Offset)) {
    if (-not (Test-ValidOffset -OffsetStr $Offset)) {
        Write-ToolkitMessage -Kind Error -Text "+N 中 N 必须为 1-3 的整数"
        exit 1
    }
    $daysOffset = Get-OffsetDays -OffsetStr $Offset
} else {
    $daysOffset = 0
}

# 执行关机调度
Invoke-TimedShutdown -TimeStr $Time -DaysOffset $daysOffset
