<#
.SYNOPSIS
    按进程名批量强杀进程

.DESCRIPTION
    输入进程名（大小写不敏感，可省略 .exe 后缀），列出所有同名进程（PID、进程名、内存占用），
    按 y 确认后全部强杀，逐个报告结果。
    未精确命中时，用输入做子串模糊匹配，列出候选进程名及实例数，仅作提示，不动手杀。

    杀进程走 Win32 OpenProcess + TerminateProcess 原生调用，而非 Stop-Process。
    原因：卡死的残留进程往往已处于「退出已信号、内核对象未回收」的半死状态（HasExited=True），
    PowerShell 的 Stop-Process 与 taskkill 会把它们当成已退出而跳过或报「找不到进程标识符」，
    只有直接调用 TerminateProcess 才能回收。

.PARAMETER Name
    要杀掉的进程名，可省略 .exe 后缀。
    示例：kp draw.io

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    kp draw.io
    列出所有 draw.io 进程，按 y 确认后全部强杀

.EXAMPLE
    kp verge-mihomo
    强杀所有 verge-mihomo 进程

.NOTES
    Author: SUNC
    Version: 1.1.0
#>

param(
    [Parameter(Position = 0)]
    [string]$Name,

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

if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-ToolkitMessage -Kind Warning -Text "用法：kp <进程名>（可省略 .exe 后缀），例如：kp draw.io"
    Write-ToolkitMessage -Color DarkGray -Text "详细帮助：kp -h"
    exit 1
}

# ============================================
# Win32 原生进程终止接口
# ============================================
# 不用 Stop-Process：半死进程（HasExited=True 但仍占 PID）会被 .NET 判定为已退出而跳过
if (-not ('KpWin32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KpWin32 {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr h, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);
}
'@
}

$PROCESS_TERMINATE = 0x0001

# 规范化输入：去空白、去 .exe 后缀（进程的 ProcessName 本身不含扩展名）
$inputName = $Name.Trim() -replace '\.exe$', ''

# 精确匹配（大小写不敏感）
$targets = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -ieq $inputName
})

if ($targets.Count -eq 0) {
    Write-ToolkitMessage -Kind Warning -Text "未找到名为「$inputName」的进程"

    # 子串模糊匹配，仅列出候选进程名作提示
    $candidates = @(Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName |
        Where-Object { $_.Name -ilike "*$inputName*" } |
        Sort-Object Count -Descending)

    if ($candidates.Count -gt 0) {
        Write-ToolkitMessage -Kind Info -Text "你可能想杀的是："
        foreach ($c in $candidates) {
            Write-Host ("  {0}  （{1} 个实例）" -f $c.Name, $c.Count)
        }
    } else {
        Write-ToolkitMessage -Color DarkGray -Text "模糊匹配也未找到名字包含「$inputName」的进程"
    }
    exit 1
}

# 列出待杀进程清单
Write-Host ""
Write-ToolkitMessage -Kind Info -Text "找到 $($targets.Count) 个「$inputName」进程："
foreach ($p in ($targets | Sort-Object Id)) {
    $memMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
    # 半死进程的退出已信号但 PID 未回收，.NET 判定为已退出；正常进程为 False
    $state = '活动'
    try { if ($p.HasExited) { $state = '残留' } } catch { $state = '?' }
    Write-Host ("  PID {0,-8} {1,-30} {2,8} MB  {3}" -f $p.Id, $p.ProcessName, $memMB, $state)
}

# 等待确认，其他输入一律取消
$answer = Read-Host "确认全部强杀？（y/N）"
if ($answer -notmatch '^(y|yes)$') {
    Write-ToolkitMessage -Color DarkGray -Text "已取消，未杀任何进程"
    exit 0
}

# 逐个强杀并报告结果
$okCount = 0
foreach ($p in $targets) {
    $h = [KpWin32]::OpenProcess($PROCESS_TERMINATE, $false, $p.Id)
    if ($h -eq [IntPtr]::Zero) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $reason = switch ($err) {
            5 { '拒绝访问（可能需要管理员权限）' }
            87 { '进程已退出' }
            1168 { '进程已退出' }
            default { "Win32 错误码 $err" }
        }
        Write-ToolkitMessage -Kind Error -Text "  失败 PID $($p.Id)（$($p.ProcessName)）：$reason"
        continue
    }
    try {
        if ([KpWin32]::TerminateProcess($h, 1)) {
            Write-ToolkitMessage -Kind Success -Text "  已杀 PID $($p.Id)（$($p.ProcessName)）"
            $okCount++
        } else {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-ToolkitMessage -Kind Error -Text "  失败 PID $($p.Id)（$($p.ProcessName)）：TerminateProcess Win32 错误码 $err"
        }
    } finally {
        [void][KpWin32]::CloseHandle($h)
    }
}

$resultKind = if ($okCount -eq $targets.Count) { 'Success' } else { 'Warning' }
Write-ToolkitMessage -Kind $resultKind -Text "完成：成功 $okCount / $($targets.Count)"
if ($okCount -lt $targets.Count) { exit 1 }
