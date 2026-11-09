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
