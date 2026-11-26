function Invoke-ChildProcess {
    <#
    .SYNOPSIS
        启动子进程并等待结束，支持超时、环境注入、输出回调与控制台透传
    .DESCRIPTION
        命令或 ScriptBlock 以临时文件传给 lib/bin/child-runner.ps1，避免命令行
        长度限制与引号转义。TimeoutSeconds 为 0 或省略时不限时；超时后结束整棵
        进程树并返回 TimedOut = $true。
        注意：-OnOutput 在进程退出后按行触发，运行期间只有心跳实时输出。
    .PARAMETER Command
        交由 cmd.exe /d /c 执行的一条命令
    .PARAMETER ScriptBlock
        交由独立 pwsh 执行的代码块
    .PARAMETER TimeoutSeconds
        超时秒数，0 表示不限时
    .PARAMETER WorkingDirectory
        子进程工作目录
    .PARAMETER Environment
        追加到子进程环境的键值对
    .PARAMETER OnOutput
        逐行回调：param($Line, $Stream)，Stream 为 Output 或 Error。
        回调在进程退出后触发；运行期间只有心跳实时输出。
    .PARAMETER HeartbeatSeconds
        心跳间隔，0 表示关闭
    .PARAMETER PassThruConsole
        继承当前控制台，不重定向标准流
    .EXAMPLE
        Invoke-ChildProcess -Command 'git status' -TimeoutSeconds 60
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding(DefaultParameterSetName = 'Command')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Command')][string]$Command,
        [Parameter(Mandatory = $true, ParameterSetName = 'ScriptBlock')][scriptblock]$ScriptBlock,
        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0,
        [string]$WorkingDirectory,
        [hashtable]$Environment,
        [scriptblock]$OnOutput,
        [int]$HeartbeatSeconds = 0,
        [switch]$PassThruConsole
    )

    $isScriptBlock = $PSCmdlet.ParameterSetName -eq 'ScriptBlock'
    $payloadPath = $null

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = -not $PassThruConsole

    if ($isScriptBlock) {
        $runnerPath = Join-Path $script:ToolkitRoot 'lib\bin\child-runner.ps1'
        if (-not (Test-Path -LiteralPath $runnerPath)) {
            throw "缺少子进程入口：$runnerPath"
        }

        $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("toolkit-child-{0}.txt" -f [guid]::NewGuid())
        [System.IO.File]::WriteAllText($payloadPath, $ScriptBlock.ToString(), [System.Text.UTF8Encoding]::new($false))

        $psi.FileName = (Get-Process -Id $PID).Path
        foreach ($argument in @(
                '-NoProfile', '-File', $runnerPath,
                '-PayloadFile', $payloadPath,
                '-PayloadKind', 'ScriptBlock',
                '-TimeoutSeconds', [string]$TimeoutSeconds
            )) {
            $psi.ArgumentList.Add($argument)
        }
    }
    else {
        # 命令直接交给 cmd，避免每次调用都多起一层 pwsh
        $psi.FileName = $env:ComSpec
        # 必须用 Arguments 原样拼接，不能放进 ArgumentList：
        # ArgumentList 会把整条命令当一个参数再次转义（" 变成 \"），
        # cmd.exe 不识别 C 风格转义，会把 \"C:\...\pwsh.exe\" 当成命令名报「不是内部或外部命令」。
        # 外层补一对引号，由 /s /c 规则剥离首尾，内部引号原样保留。
        $psi.Arguments = '/d /s /c "' + $Command + '"'
    }

    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $psi.Environment[[string]$key] = [string]$Environment[$key]
        }
    }
    if (-not $PassThruConsole) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }

    $stdinHandle = [IntPtr]::Zero
    $savedConsoleMode = $null
    if ($PassThruConsole) {
        try {
            if (-not ('Win32.ToolkitConsole' -as [type])) {
                Add-Type -Name ToolkitConsole -Namespace Win32 -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@
            }
            $stdinHandle = [Win32.ToolkitConsole]::GetStdHandle(-10)
            $mode = [uint32]0
            if ([Win32.ToolkitConsole]::GetConsoleMode($stdinHandle, [ref]$mode)) {
                $savedConsoleMode = $mode
            }
        }
        catch {
            $null = $_
        }
    }

    $process = $null
    $startTime = Get-Date
    $timedOut = $false
    $stdout = ''
    $stderr = ''

    try {
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        if (-not $process.Start()) {
            throw '无法启动子进程'
        }

        $stdoutTask = if (-not $PassThruConsole) { $process.StandardOutput.ReadToEndAsync() } else { $null }
        $stderrTask = if (-not $PassThruConsole) { $process.StandardError.ReadToEndAsync() } else { $null }

        $deadline = if ($TimeoutSeconds -gt 0) { $startTime.AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }
        $lastHeartbeat = $startTime

        while (-not $process.HasExited) {
            $now = Get-Date
            if ($now -gt $deadline) {
                $timedOut = $true
                break
            }

            $waitMilliseconds = if ($HeartbeatSeconds -gt 0 -and $OnOutput) {
                [int][math]::Max(50, [math]::Min(1000, ($lastHeartbeat.AddSeconds($HeartbeatSeconds) - $now).TotalMilliseconds))
            }
            elseif ($TimeoutSeconds -gt 0) {
                [int][math]::Max(50, [math]::Min(1000, ($deadline - $now).TotalMilliseconds))
            }
            else {
                [System.Threading.Timeout]::Infinite
            }

            if ($process.WaitForExit($waitMilliseconds)) { break }

            $now = Get-Date
            if ($HeartbeatSeconds -gt 0 -and $OnOutput -and
                ($now - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
                & $OnOutput ("已运行 {0} 秒..." -f [int]($now - $startTime).TotalSeconds) 'Output'
                $lastHeartbeat = $now
            }
        }

        if ($timedOut) {
            $taskkill = Join-Path $env:WINDIR 'System32\taskkill.exe'
            & $taskkill /PID $process.Id /T /F *> $null
            $exited = $process.WaitForExit(5000)
            if (-not $exited) {
                Write-Warning "进程树未能在 5 秒内退出：$($process.Id)"
            }
        }
        else {
            $process.WaitForExit()
        }

        if (-not $PassThruConsole) {
            # 进程被强杀或孙进程仍持有管道时，不能让 GetResult 无限等待
            $streamsCompleted = [System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 3000)
            if (-not $streamsCompleted) {
                try { $process.StandardOutput.Close() } catch { $null = $_ }
                try { $process.StandardError.Close() } catch { $null = $_ }
            }

            try { $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.GetAwaiter().GetResult() } else { '' } } catch { $stdout = '' }
            try { $stderr = if ($stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() } else { '' } } catch { $stderr = '' }

            if ($OnOutput) {
                # 保留内部空行，只裁掉 split 产生的末尾空元素
                $stdoutLines = @($stdout -split "`r?`n")
                if ($stdoutLines.Count -gt 0 -and $stdoutLines[-1] -eq '') {
                    $stdoutLines = @($stdoutLines | Select-Object -SkipLast 1)
                }
                foreach ($line in $stdoutLines) { & $OnOutput $line 'Output' }

                $stderrLines = @($stderr -split "`r?`n")
                if ($stderrLines.Count -gt 0 -and $stderrLines[-1] -eq '') {
                    $stderrLines = @($stderrLines | Select-Object -SkipLast 1)
                }
                foreach ($line in $stderrLines) { & $OnOutput $line 'Error' }
            }
        }

        $exitCode = if ($timedOut) { -1 } elseif ($process.HasExited) { $process.ExitCode } else { -1 }
        return [pscustomobject]@{
            ExitCode       = $exitCode
            TimedOut       = $timedOut
            ElapsedSeconds = [double][math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
        }
    }
    catch {
        Write-Warning "子进程执行失败：$($_.Exception.Message)"
        return [pscustomobject]@{
            ExitCode       = -1
            TimedOut       = $false
            ElapsedSeconds = [double][math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
        }
    }
    finally {
        if ($process) { $process.Dispose() }
        if ($payloadPath -and (Test-Path -LiteralPath $payloadPath)) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
        if ($PassThruConsole) {
            try {
                if ($null -ne $savedConsoleMode) {
                    [void][Win32.ToolkitConsole]::SetConsoleMode($stdinHandle, $savedConsoleMode)
                }
            }
            catch { $null = $_ }
            try { [Console]::ResetColor() } catch { $null = $_ }
            try { [Console]::CursorVisible = $true } catch { $null = $_ }
        }
    }
}

function Invoke-WithTimeout {
    <#
    .SYNOPSIS
        带强制超时的子进程执行（Invoke-ChildProcess 的便捷包装）
    .PARAMETER Command
        交由 cmd.exe 执行的一条命令
    .PARAMETER ScriptBlock
        交由独立 pwsh 执行的代码块
    .PARAMETER TimeoutSeconds
        超时秒数，必须大于 0
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding(DefaultParameterSetName = 'Command')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Command')][string]$Command,
        [Parameter(Mandatory = $true, ParameterSetName = 'ScriptBlock')][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds
    )

    if ($PSCmdlet.ParameterSetName -eq 'ScriptBlock') {
        return Invoke-ChildProcess -ScriptBlock $ScriptBlock -TimeoutSeconds $TimeoutSeconds
    }
    return Invoke-ChildProcess -Command $Command -TimeoutSeconds $TimeoutSeconds
}

function Find-ToolkitWindowProcess {
    <#
    .SYNOPSIS
        查找拥有主窗口的目标进程
    .DESCRIPTION
        按进程名查找拥有主窗口（MainWindowHandle 非零）的进程；指定
        -TitleContains 时再要求主窗口标题包含该文本（大小写不敏感）。
        多个实例同时有主窗口时取启动时间最新的一个。只读检测，不调用任何
        置前或抢焦点 API。内部辅助函数，不导出。
    .PARAMETER ProcessName
        目标进程名（不含 .exe）
    .PARAMETER TitleContains
        主窗口标题必须包含的子串；省略时不按标题过滤
    .OUTPUTS
        System.Diagnostics.Process；没有匹配时返回 $null
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [string]$TitleContains
    )

    $requireTitle = -not [string]::IsNullOrWhiteSpace($TitleContains)
    $candidate = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $_.Refresh()
                $hasWindow = $_.MainWindowHandle.ToInt64() -ne 0
                $titleMatches = if ($requireTitle) {
                    -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) -and
                    $_.MainWindowTitle.IndexOf($TitleContains, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                } else {
                    $true
                }
                $hasWindow -and $titleMatches
            } catch {
                $false
            }
        } |
        Sort-Object -Property { try { $_.StartTime } catch { [datetime]::MinValue } } -Descending |
        Select-Object -First 1

    return $candidate
}

function Wait-ToolkitWindowHandle {
    <#
    .SYNOPSIS
        轮询等待目标进程出现主窗口并返回窗口句柄
    .DESCRIPTION
        按进程名轮询查找拥有主窗口（MainWindowHandle 非零）的进程；指定
        -TitleContains 时再要求主窗口标题包含该文本（大小写不敏感）。
        多个实例同时有主窗口时取启动时间最新的一个。单实例应用会让新启动的
        进程立刻退出、由已有实例展示窗口，因此这里按进程名查找，而不是只看
        新进程。只读检测，不调用任何置前或抢焦点 API；超时返回零句柄。
    .PARAMETER ProcessName
        目标进程名（不含 .exe）
    .PARAMETER TitleContains
        可选的窗口标题子串；指定后只接受标题包含该文本的主窗口
    .PARAMETER TimeoutMs
        最长等待毫秒数，默认 10000；0 表示只检测一次
    .PARAMETER IntervalMs
        轮询间隔毫秒数，默认 100
    .EXAMPLE
        Wait-ToolkitWindowHandle -ProcessName 'notepad' -TimeoutMs 5000
        等待记事本主窗口最多 5 秒，返回窗口句柄；超时返回零句柄
    .EXAMPLE
        Wait-ToolkitWindowHandle -ProcessName 'Code' -TitleContains 'ProjectX'
        等待标题包含 ProjectX 的 VS Code 窗口
    .OUTPUTS
        System.IntPtr；找到时为主窗口句柄，超时为 [IntPtr]::Zero
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [string]$TitleContains,
        [int]$TimeoutMs = 10000,
        [int]$IntervalMs = 100
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        $candidate = Find-ToolkitWindowProcess -ProcessName $ProcessName -TitleContains $TitleContains
        if ($candidate) {
            return $candidate.MainWindowHandle
        }
        if ((Get-Date) -ge $deadline) { return [IntPtr]::Zero }
        Start-Sleep -Milliseconds $IntervalMs
    }
}

function Start-ToolkitGuiProcess {
    <#
    .SYNOPSIS
        启动 GUI 应用并把主窗口切到前台
    .DESCRIPTION
        以非阻塞方式启动可执行文件，轮询等待主窗口出现后强制把它切到前台。
        从终端启动的 GUI 程序默认没有前台权限（Windows 前台锁），窗口常被压在
        终端窗口之后；单实例应用还会让 Start-Process 返回的进程立刻退出、由已有
        实例展示窗口，因此这里按进程名查找窗口，而不是只看新进程。
        等待主窗口由 Wait-ToolkitWindowHandle 完成，本函数只负责启动、置前与返回进程。
    .PARAMETER FilePath
        可执行文件路径
    .PARAMETER ArgumentList
        传给应用的参数数组
    .PARAMETER WorkingDirectory
        应用的工作目录
    .PARAMETER ProcessName
        定位窗口的进程名；省略时取 FilePath 的文件名
    .PARAMETER TimeoutSeconds
        等待主窗口出现的秒数，超时后不再尝试置前
    .EXAMPLE
        Start-ToolkitGuiProcess -FilePath "$env:LOCALAPPDATA\Programs\magpie\magpie.exe"
        启动 magpie 并把窗口切到前台
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [string]$ProcessName,
        [ValidateRange(0, 60)][int]$TimeoutSeconds = 10
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "可执行文件不存在：$FilePath"
    }
    if (-not $ProcessName) {
        $ProcessName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    }

    $startParams = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList) { $startParams['ArgumentList'] = $ArgumentList }
    if ($WorkingDirectory) { $startParams['WorkingDirectory'] = $WorkingDirectory }
    $started = Start-Process @startParams

    $process = $null
    # 与原先一致：TimeoutSeconds 为 0 时仍至少等待 1 秒
    $timeoutMs = [math]::Max(1, $TimeoutSeconds) * 1000
    $handle = Wait-ToolkitWindowHandle -ProcessName $ProcessName -TimeoutMs $timeoutMs -IntervalMs 100

    if ($handle.ToInt64() -ne 0) {
        $null = Set-ToolkitForegroundWindow -Handle $handle
        $process = Find-ToolkitWindowProcess -ProcessName $ProcessName
    }

    if ($process) { return $process }
    return $started
}

function Set-ToolkitForegroundWindow {
    <#
    .SYNOPSIS
        把指定窗口切到前台
    .DESCRIPTION
        先用 SW_RESTORE 还原最小化窗口，再临时附加到当前前台线程的输入队列，
        以绕过 Windows 前台锁对 SetForegroundWindow 的限制，最后解除附加。
    .PARAMETER Handle
        窗口句柄
    .EXAMPLE
        $null = Set-ToolkitForegroundWindow -Handle $process.MainWindowHandle
        把指定进程的主窗口切到前台
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Handle
    )

    if ($Handle.ToInt64() -eq 0) { return $false }

    if (-not ('Win32.ToolkitWindow' -as [type])) {
        Add-Type -Name ToolkitWindow -Namespace Win32 -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
"@
    }

    if ([Win32.ToolkitWindow]::IsIconic($Handle)) {
        [void][Win32.ToolkitWindow]::ShowWindow($Handle, 9) # SW_RESTORE
    }

    $currentThread = [Win32.ToolkitWindow]::GetCurrentThreadId()
    $foreground = [Win32.ToolkitWindow]::GetForegroundWindow()
    $foregroundThread = [uint32]0
    if ($foreground.ToInt64() -ne 0) {
        [uint32]$foregroundPid = 0
        $foregroundThread = [Win32.ToolkitWindow]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
    }

    # 附加到前台线程的输入队列后，本线程才被视为可设置前台的进程
    $attached = $false
    if ($foregroundThread -and $foregroundThread -ne $currentThread) {
        $attached = [Win32.ToolkitWindow]::AttachThreadInput($currentThread, $foregroundThread, $true)
    }
    try {
        [void][Win32.ToolkitWindow]::BringWindowToTop($Handle)
        return [Win32.ToolkitWindow]::SetForegroundWindow($Handle)
    }
    finally {
        if ($attached) {
            [void][Win32.ToolkitWindow]::AttachThreadInput($currentThread, $foregroundThread, $false)
        }
    }
}

function Test-ExternalCommand {
    <#
    .SYNOPSIS
        判断外部命令是否可用
    .PARAMETER Name
        命令名
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}
