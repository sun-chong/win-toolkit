function Get-ToolkitLogFilePath {
    <#
    .SYNOPSIS
        返回共享按天日志文件的路径
    .DESCRIPTION
        返回 <Directory>\<yyyyMMdd>.log。Directory 省略时使用仓库根目录下的 logs。
        只计算路径，不创建目录、不写文件；Write-ToolkitLogLine 与需要展示日志路径的
        调用方共用本函数，保证展示路径与实际写入路径一致。
    .PARAMETER Directory
        日志目录；省略时使用仓库根目录下的 logs
    .EXAMPLE
        Get-ToolkitLogFilePath
        返回仓库根 logs\<今天>.log 的完整路径
    .EXAMPLE
        Get-ToolkitLogFilePath -Directory 'C:\Temp\logs'
        返回 C:\Temp\logs\<今天>.log，不创建该目录
    .OUTPUTS
        System.String：日志文件完整路径
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = Join-Path $script:ToolkitRoot 'logs'
    }
    return (Join-Path $Directory ((Get-Date).ToString('yyyyMMdd') + '.log'))
}

function Write-ToolkitLogLine {
    <#
    .SYNOPSIS
        向共享按天日志文件追加一行
    .DESCRIPTION
        把一行内容追加到 Get-ToolkitLogFilePath 返回的 <Directory>\<yyyyMMdd>.log，
        供仓库内所有工具共用同一份按天日志。
        行格式为 [HH:mm:ss] [工具名] 内容；-Text 为空字符串时写入空行。

        新建日志文件时写入 UTF-8 BOM，否则记事本与 type 会按 ANSI 解析而显示乱码。
        通过命名 Mutex（Local\ToolkitLog-<yyyyMMdd>）串行化同一天的并发追加，
        每次打开文件后定位到当前末尾再写入，多个进程写同一文件也不会互相覆盖或穿插。

        只保留最近 10 份匹配 <yyyyMMdd>.log 的日志，按文件名删除更早的。
        清理按进程每天只执行一次（当天首次成功写入时），避免每写一行都枚举目录；
        清理失败用 Write-Warning 提示，不影响本次写入。
        函数不向控制台输出成功信息；写入失败时用 Write-Warning 提示，不抛异常。
    .PARAMETER Text
        行内容；传空字符串写入空行
    .PARAMETER Tool
        日志行中的工具名，如 sync-skills
    .PARAMETER Directory
        日志目录，默认仓库根目录下的 logs；目录不存在时自动创建
    .EXAMPLE
        Write-ToolkitLogLine -Text '分发完成' -Tool 'sync-skills'
    .EXAMPLE
        Write-ToolkitLogLine -Text '' -Tool 'sync-skills' -Directory 'C:\Temp\logs'
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Tool,
        [string]$Directory
    )

    $now = Get-Date
    $day = $now.ToString('yyyyMMdd')
    $stamp = $now.ToString('HH:mm:ss')

    # 与展示日志路径的调用方共用同一计算规则，避免两处拼接结果不一致
    $path = Get-ToolkitLogFilePath -Directory $Directory
    $Directory = Split-Path -Parent $path

    $line = if ([string]::IsNullOrEmpty($Text)) {
        ''
    } else {
        "[$stamp] [$Tool] $Text"
    }

    $mutex = $null
    $stream = $null
    $acquired = $false

    try {
        [void][System.IO.Directory]::CreateDirectory($Directory)

        # 同一天的所有工具共用一把命名 Mutex：多进程追加时一次只允许一个写入者
        $mutex = [System.Threading.Mutex]::new($false, "Local\ToolkitLog-$day")
        try {
            # 上一个持有者异常退出时 WaitOne 会抛 AbandonedMutexException，但所有权已归当前调用者
            $acquired = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            Write-Warning "写入日志失败：等待日志 Mutex 超时（$path）"
            return
        }

        # 以共享读写打开：多个进程可同时持有句柄，真正的写入由 Mutex 串行化
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        # 打开后重新定位到当前文件末尾，避免覆盖其他实例刚追加的行
        [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
        if ($stream.Length -eq 0) {
            # 新建（或空）日志文件先写 BOM；已有文件保持原编码继续追加
            $bom = [System.Text.UTF8Encoding]::new($true).GetPreamble()
            $stream.Write($bom, 0, $bom.Length)
        }

        $payload = [System.Text.UTF8Encoding]::new($false).GetBytes($line + [System.Environment]::NewLine)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()

        # 只保留最近 10 份按天日志：每个进程每天只在首次成功写入时清理一次，
        # 避免每写一行都枚举目录；清理失败不影响本次写入
        if ($script:ToolkitLogCleanupDay -ne $day) {
            $script:ToolkitLogCleanupDay = $day
            try {
                $files = @(
                    Get-ChildItem -LiteralPath $Directory -File |
                        Where-Object { $_.Name -match '^\d{8}\.log$' } |
                        Sort-Object Name
                )
                if ($files.Count -gt 10) {
                    $files | Select-Object -First ($files.Count - 10) | ForEach-Object {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                Write-Warning "清理旧日志失败：$($_.Exception.Message)"
            }
        }
    } catch {
        Write-Warning "写入日志失败：$path — $($_.Exception.Message)"
    } finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { $null = $_ }
        }
        if ($null -ne $mutex) {
            if ($acquired) {
                try { [void]$mutex.ReleaseMutex() } catch { $null = $_ }
            }
            $mutex.Dispose()
        }
    }
}
