<#
.SYNOPSIS
    终端实时性能监视

.DESCRIPTION
    采用 C 版仪表盘网格：上排 CPU 大卡与内存卡，下排磁盘、网络、GPU 小卡。
    每秒刷新，保留最近 60 个采样点；CPU/GPU 浅蓝、内存紫红、磁盘浅绿、网络橙色。
    按 q、Esc 或 Ctrl+C 退出，退出后在主屏打印带颜色的文字快照。

.PARAMETER Interval
    采样与刷新间隔（秒），默认 1.0，最小 0.5。

.PARAMETER History
    保留的采样点数，默认 60。

.PARAMETER Full
    占满整个终端窗口；短参数 -f。默认只使用居中的 100×30 区域。

.PARAMETER Help
    查看帮助。

.EXAMPLE
    perf
    启动实时性能面板。

.EXAMPLE
    perf -f
    以全屏模式启动。

.EXAMPLE
    perf -h
    查看帮助。

.NOTES
    Author: SUNC
    Version: 1.0.1
#>

param(
    [Alias("h")]
    [switch]$Help,
    [Alias("f")]
    [switch]$Full,
    [double]$Interval = 1.0,
    [int]$History = 60
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
        'perf               启动实时性能面板（默认 100×30 区域）'
        'perf -f            以全屏模式启动'
        'perf -h            查看帮助'
        'f                  运行中切换全屏 / 默认 100×30'
        'q / Esc / Ctrl+C   退出并打印性能快照'
        '窗口最小 60×10；默认视口最多 100×30'
    ) }
    @{ Title = '参数'; Lines = @(
        '-Interval <秒>     采样与刷新间隔，默认 1.0，最小 0.5'
        '-History <点数>    保留的采样点数，默认 60'
        '-Full, -f          占满终端窗口；默认 100×30 区域'
    ) }
)

$script:PerfPdhSource = @'
using System;
using System.Runtime.InteropServices;

public class PdhSampler : IDisposable {
    [StructLayout(LayoutKind.Sequential)] public struct FmtVal { public uint CStatus; public double Value; }
    [StructLayout(LayoutKind.Sequential)] public struct FmtItem { public IntPtr Name; public FmtVal Val; }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhOpenQuery(string dataSource, IntPtr userData, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhAddEnglishCounter(IntPtr query, string path, IntPtr userData, out IntPtr counter);
    [DllImport("pdh.dll")] static extern int PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] static extern int PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out FmtVal value);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhGetFormattedCounterArray(IntPtr counter, uint format, ref uint bufferSize, out uint itemCount, IntPtr buffer);
    [DllImport("pdh.dll")] static extern int PdhCloseQuery(IntPtr query);

    const uint FMT_DOUBLE = 0x00000200;
    IntPtr query = IntPtr.Zero;
    IntPtr hCpu, hCpuFreq, hMem, hDiskIdle, hDiskRead, hDiskWrite, hNetRecv, hNetSend, hGpu;

    public bool CpuOk { get; private set; }
    public double CpuPercent { get; private set; }
    public bool CpuFreqOk { get; private set; }
    public double CpuFreqMhz { get; private set; }
    public bool MemOk { get; private set; }
    public double MemAvailMB { get; private set; }
    public bool DiskOk { get; private set; }
    public double DiskActivePct { get; private set; }
    public double DiskReadBps { get; private set; }
    public double DiskWriteBps { get; private set; }
    public bool NetOk { get; private set; }
    public double NetRecvBps { get; private set; }
    public double NetSendBps { get; private set; }
    public bool GpuOk { get; private set; }
    public double GpuPct { get; private set; }

    public void Init() {
        int rc = PdhOpenQuery(null, IntPtr.Zero, out query);
        if (rc != 0) throw new Exception("PdhOpenQuery failed: " + rc);
        int r = PdhAddEnglishCounter(query, @"\Processor Information(_Total)\% Processor Utility", IntPtr.Zero, out hCpu);
        if (r != 0) r = PdhAddEnglishCounter(query, @"\Processor(_Total)\% Processor Time", IntPtr.Zero, out hCpu);
        CpuOk = (r == 0);
        CpuFreqOk = PdhAddEnglishCounter(query, @"\Processor Information(_Total)\% Processor Performance", IntPtr.Zero, out hCpuFreq) == 0;
        MemOk = PdhAddEnglishCounter(query, @"\Memory\Available MBytes", IntPtr.Zero, out hMem) == 0;
        DiskOk = PdhAddEnglishCounter(query, @"\PhysicalDisk(_Total)\% Idle Time", IntPtr.Zero, out hDiskIdle) == 0
              && PdhAddEnglishCounter(query, @"\PhysicalDisk(_Total)\Disk Read Bytes/sec", IntPtr.Zero, out hDiskRead) == 0
              && PdhAddEnglishCounter(query, @"\PhysicalDisk(_Total)\Disk Write Bytes/sec", IntPtr.Zero, out hDiskWrite) == 0;
        NetOk = PdhAddEnglishCounter(query, @"\Network Interface(*)\Bytes Received/sec", IntPtr.Zero, out hNetRecv) == 0
             && PdhAddEnglishCounter(query, @"\Network Interface(*)\Bytes Sent/sec", IntPtr.Zero, out hNetSend) == 0;
        GpuOk = PdhAddEnglishCounter(query, @"\GPU Engine(*)\Utilization Percentage", IntPtr.Zero, out hGpu) == 0;
    }

    public int Collect() {
        return PdhCollectQueryData(query);
    }

    public void ReadAll(double baseMhz) {
        double v = 0, perf = 0, idle = 0, read = 0, write = 0;
        bool recvOk, sendOk, gpuOk;

        CpuOk = ReadSingle(hCpu, out v);
        CpuPercent = CpuOk ? ClampPercent(v) : 0;

        CpuFreqOk = ReadSingle(hCpuFreq, out perf) && perf > 0;
        CpuFreqMhz = CpuFreqOk ? perf * baseMhz / 100.0 : 0;

        MemOk = ReadSingle(hMem, out v);
        MemAvailMB = MemOk ? v : 0;

        bool idleOk = ReadSingle(hDiskIdle, out idle);
        bool readOk = ReadSingle(hDiskRead, out read);
        bool writeOk = ReadSingle(hDiskWrite, out write);
        DiskOk = idleOk && readOk && writeOk;
        DiskActivePct = DiskOk ? ClampPercent(100.0 - idle) : 0;
        DiskReadBps = readOk ? Math.Max(0, read) : 0;
        DiskWriteBps = writeOk ? Math.Max(0, write) : 0;

        NetRecvBps = ArraySum(hNetRecv, true, out recvOk);
        NetSendBps = ArraySum(hNetSend, true, out sendOk);
        NetOk = recvOk && sendOk;

        GpuPct = Math.Min(100.0, ArraySum(hGpu, false, out gpuOk));
        GpuOk = gpuOk;
    }

    bool ReadSingle(IntPtr counter, out double value) {
        value = 0;
        if (counter == IntPtr.Zero) return false;
        uint type; FmtVal v;
        int rc = PdhGetFormattedCounterValue(counter, FMT_DOUBLE, out type, out v);
        if (rc != 0 || (v.CStatus != 0 && v.CStatus != 1)) return false;
        value = v.Value;
        return true;
    }

    double ArraySum(IntPtr counter, bool skipLoopback, out bool ok) {
        ok = false;
        if (counter == IntPtr.Zero) return 0;
        uint size = 0, count = 0;
        PdhGetFormattedCounterArray(counter, FMT_DOUBLE, ref size, out count, IntPtr.Zero);
        if (size == 0) return 0;
        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try {
            int rc = PdhGetFormattedCounterArray(counter, FMT_DOUBLE, ref size, out count, buffer);
            if (rc != 0) return 0;
            double sum = 0;
            int valid = 0;
            int itemSize = Marshal.SizeOf(typeof(FmtItem));
            for (int i = 0; i < count; i++) {
                FmtItem item = (FmtItem)Marshal.PtrToStructure(new IntPtr(buffer.ToInt64() + i * itemSize), typeof(FmtItem));
                if (item.Val.CStatus != 0 && item.Val.CStatus != 1) continue;
                string name = Marshal.PtrToStringUni(item.Name);
                if (skipLoopback && name != null && name.IndexOf("Loopback", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                sum += item.Val.Value;
                valid++;
            }
            ok = valid > 0;
            return sum;
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    static double ClampPercent(double value) {
        return value < 0 ? 0 : (value > 100 ? 100 : value);
    }

    public void Dispose() {
        if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; }
    }
}
'@

function New-PerfPdhSampler {
    if (-not ('PdhSampler' -as [type])) {
        Add-Type -TypeDefinition $script:PerfPdhSource -ErrorAction Stop
    }
    return [PdhSampler]::new()
}

function Get-PerfStaticInfo {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance Win32_ComputerSystem
    $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Idd' -and $_.AdapterRAM }

    $cpuName = [string]$cpu.Name
    if ($cpuName.Length -gt 40) { $cpuName = $cpuName.Substring(0, 40) }
    $gpuName = 'GPU'
    if ($gpus) {
        $gpuName = [string]($gpus | Select-Object -First 1).Name
        if ($gpuName.Length -gt 24) { $gpuName = $gpuName.Substring(0, 24) }
    }

    return [pscustomobject]@{
        CpuName    = $cpuName
        Cores      = [int]$cpu.NumberOfCores
        Threads    = [int]$cpu.NumberOfLogicalProcessors
        BaseMhz    = [double]$cpu.MaxClockSpeed
        TotalMemGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        GpuName    = $gpuName
    }
}

function New-PerfHistory {
    param([int]$Capacity = 60)
    return [pscustomobject]@{
        Capacity = $Capacity
        Values   = [System.Collections.Generic.List[object]]::new()
        Valid    = [System.Collections.Generic.List[bool]]::new()
        Failures = 0
    }
}

function Add-PerfHistorySample {
    param(
        $History,
        $Value,
        [bool]$Valid = $true
    )
    $isValid = [bool]($Valid -and $null -ne $Value)
    $History.Values.Add($(if ($isValid) { [double]$Value } else { $null }))
    $History.Valid.Add($isValid)
    if ($isValid) {
        $History.Failures = 0
    } else {
        $History.Failures = [int]$History.Failures + 1
    }
    while ($History.Values.Count -gt $History.Capacity) {
        $History.Values.RemoveAt(0)
        $History.Valid.RemoveAt(0)
    }
}

function Get-PerfResampled {
    param(
        $History,
        [int]$Columns
    )
    if ($Columns -lt 1) { return @() }
    $count = $History.Values.Count
    $result = [System.Collections.Generic.List[object]]::new()
    for ($c = 0; $c -lt $Columns; $c++) {
        if ($count -eq 0) {
            $result.Add($null)
            continue
        }
        if ($Columns -ge $count) {
            $idx = [int][math]::Floor($c * $count / $Columns)
            if ($idx -ge $count) { $idx = $count - 1 }
            if ($History.Valid[$idx] -and $null -ne $History.Values[$idx]) {
                $result.Add([double]$History.Values[$idx])
            } else {
                $result.Add($null)
            }
            continue
        }
        $start = [int][math]::Floor($c * $count / $Columns)
        $end = [int][math]::Floor(($c + 1) * $count / $Columns) - 1
        $max = $null
        for ($i = $start; $i -le $end; $i++) {
            if ($History.Valid[$i] -and $null -ne $History.Values[$i]) {
                $value = [double]$History.Values[$i]
                if ($null -eq $max -or $value -gt $max) { $max = $value }
            }
        }
        $result.Add($max)
    }
    return @($result)
}

function Get-PerfScaleMax {
    param($History)
    $max = 0.0
    for ($i = 0; $i -lt $History.Values.Count; $i++) {
        if ($History.Valid[$i] -and $null -ne $History.Values[$i]) {
            $value = [double]$History.Values[$i]
            if ($value -gt $max) { $max = $value }
        }
    }
    if ($max -le 0) { return 1.0 }
    $pow = [math]::Pow(10, [math]::Floor([math]::Log10($max)))
    $scaled = $max / $pow
    if ($scaled -le 1) { return [double](1 * $pow) }
    if ($scaled -le 2) { return [double](2 * $pow) }
    if ($scaled -le 5) { return [double](5 * $pow) }
    return [double](10 * $pow)
}

function Format-PerfRate {
    param([double]$KBs)
    if ($KBs -ge 1048576) { return ('{0:N0} GB/s' -f ($KBs / 1048576)) }
    if ($KBs -ge 1024) { return ('{0:N0} MB/s' -f ($KBs / 1024)) }
    return ('{0:N0} KB/s' -f $KBs)
}

function Get-PerfMixedHex {
    param(
        [string]$HexColor,
        [int]$Percent
    )
    $hex = $HexColor.TrimStart('#')
    $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    $t = [math]::Max(0, [math]::Min(100, $Percent)) / 100.0
    $bg = 12
    $mr = [int][math]::Round($r * $t + $bg * (1 - $t))
    $mg = [int][math]::Round($g * $t + $bg * (1 - $t))
    $mb = [int][math]::Round($b * $t + $bg * (1 - $t))
    return ('#{0:X2}{1:X2}{2:X2}' -f $mr, $mg, $mb)
}

function Format-PerfAnsi {
    param(
        [string]$Text,
        [string]$HexColor
    )
    if (-not $HexColor) { return $Text }
    $hex = $HexColor.TrimStart('#')
    $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
    return ("`e[38;2;$r;$g;${b}m$Text`e[0m")
}

function Get-PerfChartLines {
    param(
        [object[]]$Values,
        [int]$Rows,
        [string]$HexColor,
        [bool]$ShowGrid = $false
    )
    $levels = $Rows * 2
    $mixed = Get-PerfMixedHex -HexColor $HexColor -Percent 62
    $gridRows = @(
        [int][math]::Round($Rows * 0.25)
        [int][math]::Round($Rows * 0.5)
        [int][math]::Round($Rows * 0.75)
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($row = 0; $row -lt $Rows; $row++) {
        $sb = [System.Text.StringBuilder]::new()
        $top = 2 * $row
        $bot = $top + 1
        for ($x = 0; $x -lt $Values.Count; $x++) {
            $value = $Values[$x]
            if ($null -eq $value) {
                if ($ShowGrid -and $gridRows -contains $row) {
                    [void]$sb.Append((Format-PerfAnsi -Text '─' -HexColor '#33333A'))
                } else {
                    [void]$sb.Append(' ')
                }
                continue
            }
            $clamped = [math]::Max(0, [math]::Min(100, [double]$value))
            $fill = [int][math]::Round($clamped / 100 * $levels)
            $topFilled = $top -ge ($levels - $fill)
            $botFilled = $bot -ge ($levels - $fill)
            if ($topFilled -and $botFilled) {
                $edge = ($top -eq ($levels - $fill)) -or ($bot -eq ($levels - $fill))
                $color = if ($edge) { $HexColor } else { $mixed }
                [void]$sb.Append((Format-PerfAnsi -Text '█' -HexColor $color))
            } elseif ($topFilled) {
                [void]$sb.Append((Format-PerfAnsi -Text '▀' -HexColor $HexColor))
            } elseif ($botFilled) {
                [void]$sb.Append((Format-PerfAnsi -Text '▄' -HexColor $HexColor))
            } else {
                if ($ShowGrid -and $gridRows -contains $row) {
                    [void]$sb.Append((Format-PerfAnsi -Text '─' -HexColor '#33333A'))
                } else {
                    [void]$sb.Append(' ')
                }
            }
        }
        $lines.Add($sb.ToString())
    }
    return @($lines)
}

function Pad-PerfWidth {
    param(
        [string]$Text,
        [int]$Width
    )
    $current = Get-DisplayWidth $Text
    if ($current -le $Width) {
        return $Text + (' ' * ($Width - $current))
    }
    $sb = [System.Text.StringBuilder]::new()
    $acc = 0
    foreach ($ch in $Text.ToCharArray()) {
        $w = Get-DisplayWidth ([string]$ch)
        if ($acc + $w -gt $Width) { break }
        [void]$sb.Append($ch)
        $acc += $w
    }
    return $sb.ToString()
}

function Get-PerfYAxisLines {
    param([int]$Rows)
    $labels = @{}
    $labels[0] = '100%'
    $labels[[int][math]::Round($Rows * 0.25)] = '75%'
    $labels[[int][math]::Round($Rows * 0.5)] = '50%'
    $labels[[int][math]::Round($Rows * 0.75)] = '25%'
    $labels[$Rows - 1] = '0'
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($r = 0; $r -lt $Rows; $r++) {
        $text = if ($labels.ContainsKey($r)) { $labels[$r] } else { '' }
        $lines.Add(('{0,4}' -f $text))
    }
    return @($lines)
}

function Get-PerfCardTitle {
    param(
        [string]$Name,
        [string]$Value,
        [string]$Sub,
        [string]$HexColor,
        [int]$Width,
        [bool]$Unavailable = $false
    )
    $valuePlain = if ($Unavailable) { '--' } else { $Value }
    $subPlain = if ($Unavailable) { '不可用' } else { $Sub }
    $bar = Format-PerfAnsi -Text '▌' -HexColor $HexColor
    $nameColored = Format-PerfAnsi -Text $Name -HexColor $HexColor
    $leftWidth = 2 + (Get-DisplayWidth $Name)
    $valueWidth = Get-DisplayWidth $valuePlain
    $subAllow = [math]::Max(0, $Width - $leftWidth - $valueWidth - 2)
    if ($subPlain -and (Get-DisplayWidth $subPlain) -gt $subAllow) {
        $subPlain = Pad-PerfWidth -Text $subPlain -Width $subAllow
    }
    $rightPlainWidth = $valueWidth + $(if ($subPlain) { 1 + (Get-DisplayWidth $subPlain) } else { 0 })
    $pad = [math]::Max(1, $Width - $leftWidth - $rightPlainWidth)
    $right = "`e[1m" + (Format-PerfAnsi -Text $valuePlain -HexColor '#FFFFFF')
    if ($subPlain) { $right += ' ' + (Format-PerfAnsi -Text $subPlain -HexColor '#8A8A92') }
    return "$bar $nameColored" + (' ' * $pad) + $right
}

function Get-PerfViewSize {
    param(
        [int]$WindowWidth,
        [int]$WindowHeight,
        [bool]$Full = $false
    )
    if ($Full) {
        return [pscustomobject]@{
            Width     = $WindowWidth
            Height    = $WindowHeight
            OffsetX   = 0
            OffsetY   = 0
            MinWidth  = 60
            MinHeight = 10
        }
    }
    $width = [math]::Min(100, $WindowWidth)
    $height = [math]::Min(30, $WindowHeight)
    return [pscustomobject]@{
        Width     = $width
        Height    = $height
        OffsetX   = 0
        OffsetY   = 0
        MinWidth  = 60
        MinHeight = 10
    }
}

function Get-PerfLayout {
    param(
        [int]$Width,
        [int]$Height
    )
    $gap = 6
    $small = [int][math]::Floor(($Width - 2 * $gap) / 3)
    $cpu = $Width - $gap - $small
    $chartRows = $Height - 8
    $topRows = [int][math]::Floor($chartRows / 2) + 1
    if ($topRows -gt ($chartRows - 1)) { $topRows = [math]::Max(1, $chartRows - 1) }
    $bottomRows = $chartRows - $topRows
    return [pscustomobject]@{
        CpuWidth    = $cpu
        MemWidth    = $small
        SmallWidth  = $small
        TopRows     = $topRows
        BottomRows  = $bottomRows
        Gap         = $gap
    }
}

function Render-PerfFrame {
    param(
        $Snapshot,
        $History,
        $Layout,
        $Static,
        [datetime]$Now
    )
    $width = $Layout.CpuWidth + $Layout.Gap + $Layout.MemWidth
    $leftPad = [int][math]::Floor(($Layout.Gap - 1) / 2)
    $rightPad = $Layout.Gap - 1 - $leftPad
    $divider = (' ' * $leftPad) + (Format-PerfAnsi -Text '│' -HexColor '#33333A') + (' ' * $rightPad)
    $lines = [System.Collections.Generic.List[string]]::new()

    $left = '性能监视'
    $right = "$([Environment]::MachineName) · $($Now.ToString('HH:mm:ss'))"
    $maxRight = [math]::Max(1, $width - (Get-DisplayWidth $left) - 1)
    $right = Pad-PerfWidth -Text $right -Width ([math]::Min((Get-DisplayWidth $right), $maxRight))
    $pad = [math]::Max(1, $width - (Get-DisplayWidth $left) - (Get-DisplayWidth $right))
    $lines.Add($left + (' ' * $pad) + $right)
    $lines.Add('')

    $cpuUnavailable = $History.cpu.Failures -ge 3
    $cpuValue = if ($Snapshot.CpuOk) { '{0:N0}%' -f $Snapshot.CpuPct } else { '--' }
    $cpuSub = if ($Snapshot.CpuOk -and $Snapshot.CpuMhz -gt 0) { '{0:N2} GHz · {1}C/{2}T' -f ($Snapshot.CpuMhz / 1000), $Static.Cores, $Static.Threads } else { '' }
    $memUnavailable = $History.mem.Failures -ge 3
    $memValue = if ($Snapshot.MemOk) { '{0:N0}%' -f $Snapshot.MemPct } else { '--' }
    $memSub = if ($Snapshot.MemOk) { '{0:N1} / {1:N1} GB' -f $Snapshot.MemUsedGB, $Snapshot.MemTotalGB } else { '' }

    $cpuTitle = Get-PerfCardTitle -Name 'CPU' -Value $cpuValue -Sub $cpuSub -HexColor '#4CC2FF' -Width $Layout.CpuWidth -Unavailable $cpuUnavailable
    $memTitle = Get-PerfCardTitle -Name '内存' -Value $memValue -Sub $memSub -HexColor '#D63AC0' -Width $Layout.MemWidth -Unavailable $memUnavailable
    $lines.Add($cpuTitle + $divider + $memTitle)

    $cpuValues = @(Get-PerfResampled -History $History.cpu -Columns ($Layout.CpuWidth - 5))
    $cpuChart = @(Get-PerfChartLines -Values $cpuValues -Rows $Layout.TopRows -HexColor '#4CC2FF' -ShowGrid $true)
    $memValues = @(Get-PerfResampled -History $History.mem -Columns $Layout.MemWidth)
    $memChart = @(Get-PerfChartLines -Values $memValues -Rows $Layout.TopRows -HexColor '#D63AC0' -ShowGrid $false)
    $yAxis = @(Get-PerfYAxisLines -Rows $Layout.TopRows)
    for ($r = 0; $r -lt $Layout.TopRows; $r++) {
        $lines.Add($yAxis[$r] + ' ' + $cpuChart[$r] + $divider + $memChart[$r])
    }
    $lines.Add('')
    $lines.Add((Format-PerfAnsi -Text ('─' * $width) -HexColor '#33333A'))
    $lines.Add('')

    $diskUnavailable = $History.disk.Failures -ge 3
    $diskValue = if ($Snapshot.DiskOk) { '{0:N0}%' -f $Snapshot.DiskPct } else { '--' }
    $diskSub = if ($Snapshot.DiskOk) { '读 {0:N1} · 写 {1:N1} MB/s' -f $Snapshot.DiskReadMBs, $Snapshot.DiskWriteMBs } else { '' }
    $netUnavailable = $History.net.Failures -ge 3
    $netValue = if ($Snapshot.NetOk) { Format-PerfRate -KBs $Snapshot.NetKBs } else { '--' }
    $netSub = if ($Snapshot.NetOk) { '↓ {0:N0} · ↑ {1:N0} KB/s' -f $Snapshot.NetRecvKBs, $Snapshot.NetSendKBs } else { '' }
    $gpuUnavailable = $History.gpu.Failures -ge 3
    $gpuValue = if ($Snapshot.GpuOk) { '{0:N0}%' -f $Snapshot.GpuPct } else { '--' }
    $gpuSub = if ($Snapshot.GpuOk) { $Static.GpuName } else { '' }

    $diskTitle = Get-PerfCardTitle -Name '磁盘' -Value $diskValue -Sub $diskSub -HexColor '#4ECB71' -Width $Layout.SmallWidth -Unavailable $diskUnavailable
    $netTitle = Get-PerfCardTitle -Name '网络' -Value $netValue -Sub $netSub -HexColor '#FFB020' -Width $Layout.SmallWidth -Unavailable $netUnavailable
    $gpuTitle = Get-PerfCardTitle -Name 'GPU' -Value $gpuValue -Sub $gpuSub -HexColor '#4CC2FF' -Width $Layout.SmallWidth -Unavailable $gpuUnavailable
    $lines.Add($diskTitle + $divider + $netTitle + $divider + $gpuTitle)

    $diskValues = @(Get-PerfResampled -History $History.disk -Columns $Layout.SmallWidth)
    $diskChart = @(Get-PerfChartLines -Values $diskValues -Rows $Layout.BottomRows -HexColor '#4ECB71' -ShowGrid $false)
    $netScale = Get-PerfScaleMax -History $History.net
    $netRaw = @(Get-PerfResampled -History $History.net -Columns $Layout.SmallWidth)
    $netValues = @($netRaw | ForEach-Object {
        if ($null -eq $_) { $null } else { [math]::Min(100.0, ([double]$_ / $netScale) * 100.0) }
    })
    $netChart = @(Get-PerfChartLines -Values $netValues -Rows $Layout.BottomRows -HexColor '#FFB020' -ShowGrid $false)
    $gpuValues = @(Get-PerfResampled -History $History.gpu -Columns $Layout.SmallWidth)
    $gpuChart = @(Get-PerfChartLines -Values $gpuValues -Rows $Layout.BottomRows -HexColor '#4CC2FF' -ShowGrid $false)
    for ($r = 0; $r -lt $Layout.BottomRows; $r++) {
        $lines.Add($diskChart[$r] + $divider + $netChart[$r] + $divider + $gpuChart[$r])
    }
    $lines.Add('q 退出 · Ctrl+C 退出 · f 全屏')

    return ($lines -join "`n")
}

function Get-PerfExitSnapshotLines {
    param(
        $Snapshot,
        $Static
    )
    $names = @('CPU', '内存', '磁盘', '网络', 'GPU')
    $colors = @('#4CC2FF', '#D63AC0', '#4ECB71', '#FFB020', '#4CC2FF')

    if ($null -eq $Snapshot) {
        $values = @('--', '--', '--', '--', '--')
        $subs = @('无有效采样', '无有效采样', '无有效采样', '无有效采样', '无有效采样')
    } else {
        $values = @(
            $(if ($Snapshot.CpuOk) { '{0:N0}%' -f $Snapshot.CpuPct } else { '--' }),
            $(if ($Snapshot.MemOk) { '{0:N0}%' -f $Snapshot.MemPct } else { '--' }),
            $(if ($Snapshot.DiskOk) { '{0:N0}%' -f $Snapshot.DiskPct } else { '--' }),
            $(if ($Snapshot.NetOk) { Format-PerfRate -KBs $Snapshot.NetKBs } else { '--' }),
            $(if ($Snapshot.GpuOk) { '{0:N0}%' -f $Snapshot.GpuPct } else { '--' })
        )
        $subs = @(
            $(if ($Snapshot.CpuOk -and $Snapshot.CpuMhz -gt 0) { '{0:N2} GHz · {1}C/{2}T' -f ($Snapshot.CpuMhz / 1000), $Static.Cores, $Static.Threads } elseif ($Snapshot.CpuOk) { '无频率数据' } else { '不可用' }),
            $(if ($Snapshot.MemOk) { '{0:N1} / {1:N1} GB' -f $Snapshot.MemUsedGB, $Snapshot.MemTotalGB } else { '不可用' }),
            $(if ($Snapshot.DiskOk) { '读 {0:N1} · 写 {1:N1} MB/s' -f $Snapshot.DiskReadMBs, $Snapshot.DiskWriteMBs } else { '不可用' }),
            $(if ($Snapshot.NetOk) { '↓ {0:N0} · ↑ {1:N0} KB/s' -f $Snapshot.NetRecvKBs, $Snapshot.NetSendKBs } else { '不可用' }),
            $(if ($Snapshot.GpuOk) { $Static.GpuName } else { '不可用' })
        )
    }

    $rows = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt 5; $i++) {
        $bar = Format-PerfAnsi -Text '▌' -HexColor $colors[$i]
        $name = Pad-PerfWidth -Text $names[$i] -Width 4
        $nameColored = Format-PerfAnsi -Text $name -HexColor $colors[$i]
        $value = Pad-PerfWidth -Text $values[$i] -Width 9
        $valueColored = "`e[1m" + (Format-PerfAnsi -Text $value -HexColor '#FFFFFF')
        $subColored = Format-PerfAnsi -Text $subs[$i] -HexColor '#8A8A92'
        $rows.Add("$bar $nameColored $valueColored $subColored")
    }
    return @($rows)
}

function New-PerfFailedSnapshot {
    param($Static)
    return [pscustomobject]@{
        CpuPct       = 0.0
        CpuMhz       = 0.0
        CpuOk        = $false
        MemPct       = 0.0
        MemUsedGB    = 0.0
        MemTotalGB   = $Static.TotalMemGB
        MemAvailMB   = 0.0
        MemOk        = $false
        DiskPct      = 0.0
        DiskReadMBs  = 0.0
        DiskWriteMBs = 0.0
        DiskOk       = $false
        NetKBs       = 0.0
        NetRecvKBs   = 0.0
        NetSendKBs   = 0.0
        NetOk        = $false
        GpuPct       = 0.0
        GpuOk        = $false
    }
}

function Get-PerfCenteredLine {
    param(
        [string]$Text,
        [int]$Width
    )
    $pad = [math]::Max(0, [math]::Floor(($Width - (Get-DisplayWidth $Text)) / 2))
    return (' ' * $pad) + $Text
}

function Get-PerfSnapshot {
    param(
        $Sampler,
        $Static
    )
    $totalMb = [double]$Static.TotalMemGB * 1024
    $memPct = if ($totalMb -gt 0) { 100.0 * (1.0 - ($Sampler.MemAvailMB / $totalMb)) } else { 0 }
    $memPct = [math]::Max(0, [math]::Min(100, $memPct))
    return [pscustomobject]@{
        CpuPct      = $Sampler.CpuPercent
        CpuMhz      = $Sampler.CpuFreqMhz
        CpuOk       = $Sampler.CpuOk
        MemPct      = $memPct
        MemUsedGB   = [math]::Round($Static.TotalMemGB - ($Sampler.MemAvailMB / 1024), 1)
        MemTotalGB  = $Static.TotalMemGB
        MemAvailMB  = $Sampler.MemAvailMB
        MemOk       = $Sampler.MemOk
        DiskPct     = $Sampler.DiskActivePct
        DiskReadMBs = $Sampler.DiskReadBps / 1MB
        DiskWriteMBs = $Sampler.DiskWriteBps / 1MB
        DiskOk      = $Sampler.DiskOk
        NetKBs      = ($Sampler.NetRecvBps + $Sampler.NetSendBps) / 1KB
        NetRecvKBs  = $Sampler.NetRecvBps / 1KB
        NetSendKBs  = $Sampler.NetSendBps / 1KB
        NetOk       = $Sampler.NetOk
        GpuPct      = $Sampler.GpuPct
        GpuOk       = $Sampler.GpuOk
    }
}

function Test-PerfConsoleEnvironment {
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected -or [Console]::IsInputRedirected) { return $false }
        $vt = $Host.UI.PSObject.Properties['SupportsVirtualTerminal']
        if ($null -eq $vt -or -not $vt.Value) { return $false }
        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
        return ($width -gt 0 -and $height -gt 0)
    } catch {
        return $false
    }
}

function Enter-PerfAltScreen {
    [Console]::Out.Write("`e[?1049h`e[?25l")
}

function Exit-PerfAltScreen {
    [Console]::Out.Write("`e[?25h`e[?1049l")
}

function Get-PerfExitSnapshotDisplayLines {
    param(
        $Snapshot,
        $Static,
        [datetime]$Now
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("性能快照 · {0}" -f $Now.ToString('HH:mm:ss'))
    foreach ($line in @(Get-PerfExitSnapshotLines -Snapshot $Snapshot -Static $Static)) {
        $lines.Add($line)
    }
    return @($lines)
}

function Write-PerfExitSnapshot {
    param(
        $Snapshot,
        $Static,
        [datetime]$Now
    )
    Write-Host ''
    foreach ($line in @(Get-PerfExitSnapshotDisplayLines -Snapshot $Snapshot -Static $Static -Now $Now)) {
        Write-Host $line
    }
}

function Invoke-PerfMain {
    param(
        [double]$Interval = 1.0,
        [int]$History = 60,
        [switch]$Full,
        [switch]$Help
    )
    if ($Help) {
        Show-ToolkitHelp -Command 'perf' -Title '终端实时性能监视' -Sections $helpSections
        return
    }
    if ($Interval -lt 0.5) {
        Write-ToolkitMessage -Kind Error -Text '采样间隔不能小于 0.5 秒'
        exit 1
    }
    if ($History -lt 1) {
        Write-ToolkitMessage -Kind Error -Text '历史点数至少为 1'
        exit 1
    }
    if (-not (Test-PerfConsoleEnvironment)) {
        Write-ToolkitMessage -Kind Error -Text 'perf 需要在支持 ANSI 的交互式终端中运行'
        exit 1
    }

    $static = $null
    $sampler = $null
    $snapshot = $null
    $entered = $false
    $fatalMessage = $null
    $fullScreen = [bool]$Full
    $lastViewKey = $null
    $histories = @{
        cpu  = (New-PerfHistory -Capacity $History)
        mem  = (New-PerfHistory -Capacity $History)
        disk = (New-PerfHistory -Capacity $History)
        net  = (New-PerfHistory -Capacity $History)
        gpu  = (New-PerfHistory -Capacity $History)
    }

    try {
        $static = Get-PerfStaticInfo
        $sampler = New-PerfPdhSampler

        Enter-PerfAltScreen
        $entered = $true
        [Console]::TreatControlCAsInput = $true
        [Console]::Out.Write("`e[H`e[2J")
        [Console]::Out.Write('正在采样…')

        $sampler.Init()
        [void]$sampler.Collect()
        Start-Sleep -Milliseconds ([math]::Max(1000, [int]($Interval * 1000)))

        $running = $true
        $frameTimer = [System.Diagnostics.Stopwatch]::StartNew()

        while ($running) {
            $width = [Console]::WindowWidth
            $height = [Console]::WindowHeight
            $view = Get-PerfViewSize -WindowWidth $width -WindowHeight $height -Full $fullScreen
            if ($width -lt $view.MinWidth -or $height -lt $view.MinHeight) {
                $modeText = if ($fullScreen) { '全屏' } else { '默认 100×30' }
                $message = "请将窗口调整为至少 $($view.MinWidth)×$($view.MinHeight)（$modeText；当前 ${width}×${height}）"
                [Console]::Out.Write("`e[H`e[2J")
                [Console]::Out.Write((Get-PerfCenteredLine -Text $message -Width $width))
                while ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    $isCtrlC = ($key.Key -eq 'C') -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
                    if ($key.Key -eq 'F') {
                        $fullScreen = -not $fullScreen
                        [Console]::Out.Write("`e[H`e[2J")
                        $lastViewKey = $null
                        break
                    }
                    if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape' -or $isCtrlC) {
                        $running = $false
                    }
                }
                if ($running) { Start-Sleep -Seconds 1 }
                continue
            }

            $collectRc = $sampler.Collect()
            if ($collectRc -eq 0) {
                $sampler.ReadAll($static.BaseMhz)
                $snapshot = Get-PerfSnapshot -Sampler $sampler -Static $static
            } else {
                $snapshot = New-PerfFailedSnapshot -Static $static
            }
            Add-PerfHistorySample -History $histories.cpu  -Value $snapshot.CpuPct -Valid $snapshot.CpuOk
            Add-PerfHistorySample -History $histories.mem  -Value $snapshot.MemPct -Valid $snapshot.MemOk
            Add-PerfHistorySample -History $histories.disk -Value $snapshot.DiskPct -Valid $snapshot.DiskOk
            Add-PerfHistorySample -History $histories.net  -Value $snapshot.NetKBs -Valid $snapshot.NetOk
            Add-PerfHistorySample -History $histories.gpu  -Value $snapshot.GpuPct -Valid $snapshot.GpuOk

            $layout = Get-PerfLayout -Width $view.Width -Height $view.Height
            $frame = Render-PerfFrame -Snapshot $snapshot -History $histories -Layout $layout -Static $static -Now (Get-Date)
            $viewKey = "$($view.Width)x$($view.Height)@$($view.OffsetX),$($view.OffsetY)"
            if ($viewKey -ne $lastViewKey) {
                [Console]::Out.Write("`e[H`e[2J")
                $lastViewKey = $viewKey
            }
            $frameLines = $frame -split "`n"
            $prefix = ' ' * $view.OffsetX
            $out = "`e[H"
            if ($view.OffsetY -gt 0) { $out += ("`n" * $view.OffsetY) }
            $out += (($frameLines | ForEach-Object { $prefix + $_ + "`e[K" }) -join "`n")
            [Console]::Out.Write($out)

            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $isCtrlC = ($key.Key -eq 'C') -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
                if ($key.Key -eq 'F') {
                    $fullScreen = -not $fullScreen
                    [Console]::Out.Write("`e[H`e[2J")
                    $lastViewKey = $null
                    break
                }
                if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape' -or $isCtrlC) {
                    $running = $false
                    break
                }
            }

            $elapsed = $frameTimer.ElapsedMilliseconds
            $wait = [int]($Interval * 1000) - $elapsed
            if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
            $frameTimer.Restart()
        }
    } catch {
        $fatalMessage = "perf 运行失败：$($_.Exception.Message)"
    } finally {
        try { [Console]::TreatControlCAsInput = $false } catch { $null = $_ }
        if ($entered) { try { Exit-PerfAltScreen } catch { $null = $_ } }
        if ($static) { Write-PerfExitSnapshot -Snapshot $snapshot -Static $static -Now (Get-Date) }
        if ($sampler) { $sampler.Dispose() }
    }

    if ($fatalMessage) {
        Write-ToolkitMessage -Kind Error -Text $fatalMessage
        exit 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PerfMain -Interval $Interval -History $History -Full:$Full -Help:$Help
}
