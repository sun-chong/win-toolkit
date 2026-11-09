<#
.SYNOPSIS
    按配置分发与更新 Agent Skills

.DESCRIPTION
    读取 sync-skills.config.jsonc，把配置中的每个源转换为一条 npx skills add 命令执行。
    每条命令带超时、失败重试、日志落盘；本地源在 npx 失败时可降级为目录联接（Junction）。

    执行前会预检每个源：本地目录不存在、或远程仓库无法访问时直接报错并跳过该项，
    最终在汇总里列出，不会等到 npx 阶段才卡住。

    远程源走 HTTPS，而 git 与 node 都不读取 Windows 系统代理设置，
    因此运行时会经 Toolkit 公共库的代理函数探测可用代理，同时写入环境变量并传给子进程；
    探测不到则保持直连。

    不调用 npx skills update：add 每次都会重新解析源并重建目录，本身就是更新，
    而且 add 可以通过 -a 精确控制目标 Agent，update 不能。

    配置文件使用 JSONC 格式，依赖 PowerShell 7 的 ConvertFrom-Json 原生支持注释与尾随逗号；
    同时兼容 .json，默认优先读取同目录的 .jsonc。
    日志按天记录到 logs/skills-<yyyyMMdd>.log，只保留最近 10 个。

.PARAMETER Scope
    分发范围。local 只处理本地路径源，online 只处理远程源，all 处理全部。
    短参数：-s

.PARAMETER ConfigPath
    配置文件路径。默认在脚本同目录探测 sync-skills.config.jsonc 与
    sync-skills.config.json，优先 .jsonc。
    短参数：-c

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    .\sync-skills.ps1 -Scope local
    只分发本地路径源

.EXAMPLE
    .\sync-skills.ps1 -Scope online
    只分发远程源

.EXAMPLE
    .\sync-skills.ps1
    分发全部源

.NOTES
    Author: SUNC
    Version: 1.7.1
#>

param(
    [Alias("s")]
    [ValidateSet("local", "online", "all")]
    [string]$Scope = "all",

    [Alias("c")]
    [string]$ConfigPath,

    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

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

# 与 skills CLI 的 universal agent 判定保持一致：
# skillsDir 为 .agents/skills 的 Agent 只读 canonical 目录，不建独立链接。
$script:AgentSkillsDir = @{
    "claude-code" = ".claude/skills"
    "codex"       = ".agents/skills"
    "opencode"    = ".agents/skills"
    "pi"          = ".agents/skills"
}

$script:LogWriter = $null
$script:LogMutex = $null
# 本次运行探测到的可用代理，预检与 npx 阶段的子进程都要显式继承
$script:ProxyUrl = $null

function Write-LogLine {
    <#
    .SYNOPSIS
        同时输出到终端与日志文件
    #>
    param(
        [AllowEmptyString()][string]$Text = "",
        [string]$Color = "DarkGray",
        [int]$Indent = 0
    )

    $line = if ($Indent -gt 0 -and -not [string]::IsNullOrEmpty($Text)) {
        (' ' * $Indent) + $Text
    } else {
        $Text
    }

    Write-Host $line -ForegroundColor $Color
    if ($null -ne $script:LogWriter) {
        # 同一日期的多个分发实例共用日志；命名 Mutex 确保每行完整写入而不互相穿插
        if ($null -ne $script:LogMutex) { [void]$script:LogMutex.WaitOne() }
        try {
            # 每个实例都有独立文件句柄，等待 Mutex 后必须重新定位到当前文件末尾，避免覆盖另一个实例刚写入的行
            $script:LogWriter.Flush()
            [void]$script:LogWriter.BaseStream.Seek(0, [System.IO.SeekOrigin]::End)
            $script:LogWriter.WriteLine($line)
            $script:LogWriter.Flush()
        } catch {
            Write-Host "警告：写入日志失败，本行仅输出到终端：$($_.Exception.Message)" -ForegroundColor Yellow
        } finally {
            if ($null -ne $script:LogMutex) { [void]$script:LogMutex.ReleaseMutex() }
        }
    }
}

function Test-RemoteSource {
    <#
    .SYNOPSIS
        判断源是否为远程地址
    #>
    param([string]$Source)

    return $Source -match '^(https?://|git@|ssh://|git://)'
}

function Test-SourceAvailable {
    <#
    .SYNOPSIS
        预检源是否可访问
    .DESCRIPTION
        本地源检查目录是否存在；远程源用 git ls-remote 只查询 HEAD（不下载内容、不枚举全部 refs），
        同时持续排空输出管道并禁用交互认证。
        不排空 stdout 时，仓库 refs 输出会填满管道缓冲区导致 Git 阻塞，进而被超时误判为「无法访问」。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][bool]$IsRemote,
        [int]$TimeoutSeconds = 20
    )

    if (-not $IsRemote) {
        if (Test-Path -LiteralPath $Source) {
            return [PSCustomObject]@{ Ok = $true; Reason = "" }
        }
        return [PSCustomObject]@{ Ok = $false; Reason = "目录不存在" }
    }

    $environment = @{ GIT_TERMINAL_PROMPT = '0' }
    if ($script:ProxyUrl) {
        $environment['http_proxy'] = $script:ProxyUrl
        $environment['https_proxy'] = $script:ProxyUrl
    }

    $stderrLines = [System.Collections.Generic.List[string]]::new()
    $result = Invoke-ChildProcess `
        -Command "git ls-remote --exit-code `"$Source`" HEAD" `
        -TimeoutSeconds $TimeoutSeconds `
        -Environment $environment `
        -OnOutput {
            param($line, $stream)
            if ($stream -eq 'Error') { $stderrLines.Add($line) }
        }

    if ($result.TimedOut) {
        $proxyHint = if ($script:ProxyUrl) { "当前代理 $($script:ProxyUrl)" } else { "未走代理，HTTPS 直连可能被阻断" }
        return [PSCustomObject]@{ Ok = $false; Reason = "预检超时：${TimeoutSeconds} 秒内无响应，已终止进程（$proxyHint）" }
    }

    if ($result.ExitCode -eq 0) {
        return [PSCustomObject]@{ Ok = $true; Reason = "" }
    }

    $stderr = ($stderrLines -join ' ').Trim()
    $category = Get-GitFailureCategory -Stderr $stderr
    $detail = if ($stderr) { "：$stderr" } else { "" }
    return [PSCustomObject]@{ Ok = $false; Reason = "$category（git 退出码 $($result.ExitCode)$detail）" }
}

function Get-GitFailureCategory {
    <#
    .SYNOPSIS
        按 stderr 归类 git 远程操作失败原因
    #>
    param([string]$Stderr)

    if ($Stderr -match 'Authentication failed|could not read Username|terminal prompts disabled|Credential|403') {
        return "认证失败"
    }
    if ($Stderr -match 'Could not resolve host|Failed to connect|Connection refused|SSL/TLS|schannel|OpenSSL|timed out|Network is unreachable') {
        return "网络错误"
    }
    if ($Stderr -match 'Repository not found|does not appear to be a git repository') {
        return "仓库不存在或不可见"
    }
    return "git 错误"
}

function Get-AgentSkillsDir {
    <#
    .SYNOPSIS
        返回 Agent 的 skills 目录（相对路径）
    #>
    param([string]$Agent)

    if ($script:AgentSkillsDir.ContainsKey($Agent)) {
        return $script:AgentSkillsDir[$Agent]
    }
    Write-LogLine "警告：未识别 Agent '$Agent'，降级时按非 universal 处理" -Color Yellow -Indent 4
    return ".$Agent/skills"
}

function New-SafeJunction {
    <#
    .SYNOPSIS
        创建目录联接；目标已存在时先安全清理
    .DESCRIPTION
        已存在的链接只删除链接本身（不触碰目标内容），
        已存在的实体目录则重命名为 .bak-<时间戳> 保留。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LinkPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    if (-not (Test-Path $TargetPath)) {
        throw "Junction 目标不存在：$TargetPath"
    }

    # 用 Get-Item 而非 Test-Path：悬空 Junction 的 Test-Path 为 false，会被漏掉
    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if ($existing.LinkType -in @("Junction", "SymbolicLink")) {
            # 只删除重解析点本身；用 .NET 而非 Remove-Item -Recurse，后者会连带删除目标内容
            [System.IO.Directory]::Delete($LinkPath, $false)
        } else {
            $backupName = (Split-Path $LinkPath -Leaf) + ".bak-" + (Get-Date -Format "yyyyMMddHHmmss")
            Rename-Item -Path $LinkPath -NewName $backupName -Force
        }
    }

    $parent = Split-Path $LinkPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath -Force | Out-Null
}

function Invoke-JunctionFallback {
    <#
    .SYNOPSIS
        本地源降级：用目录联接替代 npx 分发
    .DESCRIPTION
        在 canonical 目录建 Junction 指向源目录；
        非 universal 的 Agent（如 claude-code）再建一条 Junction 指向 canonical。
    #>
    param(
        [Parameter(Mandatory = $true)]$Task
    )

    Write-LogLine "尝试 Junction 降级..." -Color Yellow -Indent 4

    $canonicalRoot = if ($Task.IsGlobal) {
        Get-ToolkitPath -Name UserHome -Child '.agents\skills'
    } else {
        Join-Path $Task.BaseDirectory ".agents\skills"
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    # skills 为 ["*"] 时展开为源目录下的全部子目录，避免把字面量 * 当目录名
    $skillNames = if ($Task.Skills -contains "*") {
        @(Get-ChildItem -Path $Task.Source -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    } else {
        @($Task.Skills)
    }

    if ($skillNames.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Message = "无法从源目录展开 skill：$($Task.Source)" }
    }

    foreach ($skillName in $skillNames) {
        $sourceDir = Join-Path $Task.Source $skillName
        if (-not (Test-Path $sourceDir)) {
            $errors.Add("源目录不存在：$sourceDir")
            continue
        }

        try {
            $canonicalDir = Join-Path $canonicalRoot $skillName
            New-SafeJunction -LinkPath $canonicalDir -TargetPath $sourceDir

            foreach ($agent in $Task.Agents) {
                $agentSkillsDir = Get-AgentSkillsDir -Agent $agent
                if ($agentSkillsDir -eq ".agents/skills") { continue }

                $agentRoot = if ($Task.IsGlobal) {
                    Join-Path (Get-ToolkitPath -Name UserHome) $agentSkillsDir
                } else {
                    Join-Path $Task.BaseDirectory $agentSkillsDir
                }
                New-SafeJunction -LinkPath (Join-Path $agentRoot $skillName) -TargetPath $canonicalDir
            }

            Write-LogLine "✓ $skillName → Junction" -Color Green -Indent 6
        } catch {
            $errors.Add("${skillName}: $($_.Exception.Message)")
        }
    }

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) {
            Write-LogLine "✗ $e" -Color Red -Indent 6
        }
        return [PSCustomObject]@{ Success = $false; Message = ($errors -join "; ") }
    }

    return [PSCustomObject]@{ Success = $true; Message = "" }
}

function Invoke-SkillTask {
    <#
    .SYNOPSIS
        执行单个分发任务：超时、重试、本地降级
    #>
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][int]$Retries,
        [Parameter(Mandatory = $true)][int]$RetryDelaySeconds,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Total
    )

    Write-LogLine ""
    Write-LogLine "[$Index/$Total] $($Task.ProjectName) / $($Task.Source)（超时 $($Task.TimeoutSeconds) 秒）" -Color Cyan
    Write-LogLine "    $($Task.CommandLine)"

    $attempt = 0
    $lastResult = $null

    while ($attempt -le $Retries) {
        $attempt++
        if ($attempt -gt 1) {
            Write-LogLine "第 $attempt 次尝试（等待 ${RetryDelaySeconds} 秒）..." -Color Yellow -Indent 4
            Start-Sleep -Seconds $RetryDelaySeconds
        }

        $childEnvironment = @{
            npm_config_fetch_timeout = '30000'
            npm_config_fetch_retries = '1'
        }
        if ($script:ProxyUrl) {
            $childEnvironment['http_proxy'] = $script:ProxyUrl
            $childEnvironment['https_proxy'] = $script:ProxyUrl
        }

        $lastResult = Invoke-ChildProcess -Command $Task.CommandLine -WorkingDirectory $Task.WorkingDirectory `
            -Environment $childEnvironment `
            -OnOutput {
                param($line, $stream)
                $color = if ($stream -eq 'Error') { 'DarkYellow' } else { 'DarkGray' }
                Write-LogLine $line -Color $color -Indent 6
            } `
            -HeartbeatSeconds 15 -TimeoutSeconds $Task.TimeoutSeconds

        if ($lastResult.ExitCode -eq 0) {
            Write-LogLine "✓ 成功（$($lastResult.ElapsedSeconds) 秒）" -Color Green -Indent 4
            return New-TaskResult -Task $Task -Status "ok" -Message ""
        }

        $reason = if ($lastResult.TimedOut) { "超时（$($Task.TimeoutSeconds) 秒）" } else { "退出码 $($lastResult.ExitCode)" }
        Write-LogLine "✗ 失败：$reason" -Color Red -Indent 4
    }

    # 仅本地源可以降级：远程源没有可链接的本地目录
    if (-not $Task.IsRemote) {
        $fallback = Invoke-JunctionFallback -Task $Task
        if ($fallback.Success) {
            Write-LogLine "✓ Junction 降级完成" -Color Yellow -Indent 4
            return New-TaskResult -Task $Task -Status "fallback" -Message ""
        }
        return New-TaskResult -Task $Task -Status "fail" -Message "npx 失败且 Junction 降级失败：$($fallback.Message)"
    }

    return New-TaskResult -Task $Task -Status "fail" -Message "npx 失败"
}

function New-TaskResult {
    <#
    .SYNOPSIS
        构造任务结果对象
    #>
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Message = ""
    )

    return [PSCustomObject]@{
        ProjectName = $Task.ProjectName
        Source      = $Task.Source
        Status      = $Status
        Success     = $Status -ne "fail"
        Message     = $Message
    }
}

function Get-TaskList {
    <#
    .SYNOPSIS
        按配置构建任务列表
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][int]$DefaultTimeoutSeconds
    )

    $tasks = [System.Collections.Generic.List[object]]::new()
    $defaultAgents = @($Config.agents | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($defaultAgents.Count -eq 0) {
        throw "配置缺少顶层 agents，或 agents 为空"
    }

    foreach ($projectProp in $Config.projects.PSObject.Properties) {
        $projectName = $projectProp.Name
        $project = $projectProp.Value

        $isGlobal = [bool]$project.global
        $projectAgents = if ($project.agents) { @($project.agents) } else { $defaultAgents }

        $baseDirectory = if ($isGlobal) {
            (Get-ToolkitPath -Name UserHome)
        } elseif ($project.cwd) {
            Resolve-ToolkitPathValue -Path $project.cwd
        } else {
            throw "项目 '$projectName' 既没有 global: true，也没有 cwd"
        }

        foreach ($source in $project.sources) {
            if ([string]::IsNullOrWhiteSpace($source.path)) {
                throw "项目 '$projectName' 中有 source 缺少 path"
            }
            # 必须先按原始值判定远程，再做本地路径解析：https:// 地址一旦被 Join-Path
            # 拼到项目目录下（C:\Users\...\https:\\github.com\...），既不再匹配远程前缀，
            # 也不再是有效本地目录，导致 Scope 分类与预检同时出错
            $rawPath = ([string]$source.path).Trim()
            $isRemote = Test-RemoteSource -Source $rawPath
            # 本地相对路径按项目目录解析：预检与 npx 的 WorkingDirectory 必须指向同一位置
            $sourcePath = if ($isRemote) { $rawPath } else { Resolve-ToolkitPathValue -Path $rawPath -Base $baseDirectory }

            if ($Scope -eq "local" -and $isRemote) { continue }
            if ($Scope -eq "online" -and -not $isRemote) { continue }

            $sourceAgents = if ($source.agents) { @($source.agents) } else { $projectAgents }
            $skills = if ($source.skills) { @($source.skills) } else { @("*") }

            $argParts = [System.Collections.Generic.List[string]]::new()
            $argParts.Add("skills")
            $argParts.Add("add")
            $argParts.Add("`"$sourcePath`"")
            foreach ($skill in $skills) {
                $argParts.Add("--skill")
                $argParts.Add("`"$skill`"")
            }
            foreach ($agent in $sourceAgents) {
                $argParts.Add("-a")
                $argParts.Add($agent)
            }
            if ($isGlobal) { $argParts.Add("-g") }
            $argParts.Add("-y")

            $tasks.Add([PSCustomObject]@{
                ProjectName      = $projectName
                Source           = $sourcePath
                Skills           = $skills
                Agents           = $sourceAgents
                IsGlobal         = $isGlobal
                IsRemote         = $isRemote
                BaseDirectory    = $baseDirectory
                WorkingDirectory = if ($isGlobal) { Get-ToolkitPath -Name UserHome } else { $baseDirectory }
                TimeoutSeconds   = [int]($source.timeoutSeconds ?? $DefaultTimeoutSeconds)
                # npx --yes：缓存中没有最新版 skills 时允许 npx 自动安装；缺失它会在
                # "Ok to proceed? (y)" 处等待标准输入，而子进程输出被重定向、退出后才回显，
                # 终端看不到提示，只能挂到超时。末尾的 -y 属于 skills CLI，二者作用不同
                CommandLine      = "chcp 65001 >nul & npx --yes " + ($argParts -join " ")
            })
        }
    }

    return $tasks
}

#region 主流程

if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path -Full
    return
}

# 默认在脚本同目录探测 .jsonc / .json；显式传入 -c 时同样归一化扩展名
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "sync-skills.config"
}
$ConfigPath = (Resolve-ToolkitConfigPath -BasePath $ConfigPath).Path

# git / node / npm 都不读 Windows 系统代理，统一由公共库探测并注入环境变量

try {
    $config = Read-ToolkitJson -Path $ConfigPath -ThrowOnError
} catch {
    Write-ToolkitMessage -Kind Error -Text "错误：$($_.Exception.Message)"
    exit 1
}

$timeoutSeconds = [int]($config.timeoutSeconds ?? 300)
$retries = [int]($config.retries ?? 2)
$retryDelay = [int]($config.retryDelaySeconds ?? 30)
$taskDelay = [int]($config.taskDelaySeconds ?? 5)

try {
    $tasks = Get-TaskList -Config $config -Scope $Scope -DefaultTimeoutSeconds $timeoutSeconds
} catch {
    Write-ToolkitMessage -Kind Error -Text "错误：$($_.Exception.Message)"
    exit 1
}

if ($tasks.Count -eq 0) {
    Write-ToolkitMessage -Kind Warning -Text "没有匹配 Scope='$Scope' 的任务"
    exit 0
}

$logDir = Join-Path $toolkitRoot "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# 日志按天记录：同一天多次运行追加到同一文件，只保留最近 10 个日志文件
$logFile = Join-Path $logDir ("skills-" + (Get-Date -Format "yyyyMMdd") + ".log")
Get-ChildItem -Path $logDir -Filter "skills-*.log" -File |
    Sort-Object Name -Descending |
    Select-Object -Skip 10 |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

# 日志带 UTF-8 BOM（无 BOM 时记事本/type 按 ANSI 解析会乱码）；
# 以共享读写打开：两个 au 并行执行时（如上一轮分发尚未结束），各自追加同一份按天日志而不是报错退出
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$script:LogMutex = [System.Threading.Mutex]::new($false, "Local\AuSkillsLog-$(Get-Date -Format 'yyyyMMdd')")
try {
    # 串行化 BOM 探测 / 新建 / 追加初始化，避免两个首次启动实例同时写 BOM
    try { [void]$script:LogMutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { $null = $_ }
    $exists = Test-Path -LiteralPath $logFile
    $legacyNoBom = $false
    if ($exists) {
        # 共享读探测 BOM：另一实例可能正持着写句柄，默认独占的 OpenRead 会被拒
        $probe = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $b1 = $probe.ReadByte()
            $b2 = $probe.ReadByte()
            $b3 = $probe.ReadByte()
        } finally {
            $probe.Dispose()
        }
        $legacyNoBom = -not ($b1 -eq 0xEF -and $b2 -eq 0xBB -and $b3 -eq 0xBF)
    }

    # 打开被拒（另一实例以非共享方式持有等）时短暂重试，仍失败则降级为仅终端输出
    $fileStream = $null
    foreach ($attempt in 1..3) {
        try {
            $fileStream = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            break
        } catch [System.IO.IOException] {
            if ($attempt -lt 3) {
                Write-ToolkitMessage -Kind Warning -Text "日志文件被其他分发进程占用，$attempt/3 次重试（等待 5 秒）..."
                Start-Sleep -Seconds 5
            } else {
                Write-ToolkitMessage -Kind Warning -Text "警告：无法打开日志文件，本次运行不落盘：$($_.Exception.Message)"
            }
        }
    }

    if ($null -ne $fileStream) {
        if (-not $exists) {
            # 新建文件先写 BOM
            $bom = $utf8Bom.GetPreamble()
            $fileStream.Write($bom, 0, $bom.Length)
        }
        $script:LogWriter = [System.IO.StreamWriter]::new($fileStream, [System.Text.UTF8Encoding]::new($false))
        $script:LogWriter.AutoFlush = $true
        if ($legacyNoBom) {
            Write-ToolkitMessage -Kind Warning -Text "提示：当日日志由旧版本脚本创建（无 BOM），本次为追加写入，中文在记事本中可能显示乱码"
        }
    }
} catch {
    Write-ToolkitMessage -Kind Warning -Text "警告：日志初始化失败，本次运行不落盘：$($_.Exception.Message)"
    $script:LogWriter = $null
} finally {
    if ($null -ne $script:LogMutex) {
        try { [void]$script:LogMutex.ReleaseMutex() } catch { $null = $_ }
    }
}

try {
    Write-LogLine ""
    Write-LogLine "=== Skills 分发（Scope: $Scope）===" -Color Cyan
    Write-LogLine "配置: $ConfigPath"
    Write-LogLine "日志: $logFile"
    Write-LogLine "任务: $($tasks.Count) 项，默认超时 ${timeoutSeconds} 秒（逐源可覆盖），重试 $retries 次，间隔 ${taskDelay} 秒"
    Write-LogLine "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    # 远程源走 HTTPS，git 与 node 都不认系统代理，先注入环境变量供子进程继承
    $script:ProxyUrl = Set-ProxyEnvironment
    if ($script:ProxyUrl) {
        Write-LogLine "代理: $($script:ProxyUrl)"
    } else {
        Write-LogLine "代理: 未检测到可用代理，HTTPS 源将直连" -Color Yellow
    }

    # 执行前预检每个源：目录不存在或网址不可达时立刻报错，不等到 npx 阶段才卡住
    Write-LogLine ""
    Write-LogLine "=== 源可用性预检 ===" -Color Cyan
    $runnableTasks = [System.Collections.Generic.List[object]]::new()
    $preflightFailures = [System.Collections.Generic.List[object]]::new()
    foreach ($task in $tasks) {
        # 项目目录不存在时任何源都无法安装，先于源检查报出
        if (-not $task.IsGlobal -and -not (Test-Path -LiteralPath $task.BaseDirectory)) {
            $reason = "项目目录不存在：$($task.BaseDirectory)"
            Write-LogLine "✗ $($task.ProjectName) / $($task.Source)：$reason" -Color Red
            $preflightFailures.Add((New-TaskResult -Task $task -Status 'fail' -Message "预检失败：$reason"))
            continue
        }

        $check = Test-SourceAvailable -Source $task.Source -IsRemote $task.IsRemote
        if ($check.Ok) {
            $runnableTasks.Add($task)
        } else {
            Write-LogLine "✗ $($task.ProjectName) / $($task.Source)：$($check.Reason)" -Color Red
            $preflightFailures.Add((New-TaskResult -Task $task -Status 'fail' -Message "预检失败：$($check.Reason)"))
        }
    }
    Write-LogLine "可执行 $($runnableTasks.Count) 项，预检失败 $($preflightFailures.Count) 项"

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($failure in $preflightFailures) { $results.Add($failure) }
    $roundStart = Get-Date

    for ($i = 0; $i -lt $runnableTasks.Count; $i++) {
        $results.Add((Invoke-SkillTask -Task $runnableTasks[$i] -Retries $retries -RetryDelaySeconds $retryDelay -Index ($i + 1) -Total $runnableTasks.Count))

        # 任务间隔：留出时间让 npx / git 的临时文件与网络连接彻底释放
        if ($i -lt ($runnableTasks.Count - 1) -and $taskDelay -gt 0) {
            Write-LogLine "等待 ${taskDelay} 秒后继续..." -Color DarkGray -Indent 4
            Start-Sleep -Seconds $taskDelay
        }
    }

    $elapsed = [int]((Get-Date) - $roundStart).TotalSeconds
    $successCount = @($results | Where-Object { $_.Success }).Count
    $failCount = $results.Count - $successCount
    $fallbackItems = @($results | Where-Object { $_.Status -eq "fallback" })

    Write-LogLine ""
    Write-LogLine "=========================================" -Color Cyan
    Write-LogLine "Skills 分发结果" -Color Cyan
    Write-LogLine "=========================================" -Color Cyan
    Write-LogLine "总计: $($results.Count) 项"
    Write-LogLine "成功: $successCount 项" -Color Green

    if ($fallbackItems.Count -gt 0) {
        Write-LogLine "其中 Junction 降级: $($fallbackItems.Count) 项" -Color Yellow
        foreach ($item in $fallbackItems) {
            Write-LogLine "  - $($item.ProjectName) / $($item.Source)" -Color Yellow
        }
    }

    if ($failCount -gt 0) {
        Write-LogLine "失败: $failCount 项" -Color Red
        foreach ($item in @($results | Where-Object { -not $_.Success })) {
            Write-LogLine "  - $($item.ProjectName) / $($item.Source)：$($item.Message)" -Color Red
        }
    }

    Write-LogLine "耗时: $([int]($elapsed / 60)) 分 $($elapsed % 60) 秒"
    Write-LogLine "日志: $logFile"

    if ($failCount -gt 0) { exit 1 } else { exit 0 }
} finally {
    if ($null -ne $script:LogWriter) {
        $script:LogWriter.Dispose()
        $script:LogWriter = $null
    }
}

#endregion
