function Get-ToolkitEnvironmentKey {
    # 内部辅助：环境变量所在的注册表路径
    param([Parameter(Mandatory = $true)][ValidateSet('Machine', 'User')][string]$Scope)
    if ($Scope -eq 'Machine') {
        return 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    }
    return 'HKCU:\Environment'
}

function Convert-ToolkitPathToEnvVar {
    <#
    .SYNOPSIS
        把绝对路径前缀替换为 Windows 默认目录变量
    .DESCRIPTION
        写入环境变量时保留 %ProgramFiles%、%LocalAppData% 这类引用，
        避免把本机真实目录固化进注册表。
        顺序很重要：更长、更具体的目录必须排在前面，否则会被短前缀抢先匹配。
        不在映射表中的路径原样返回。

        Machine 范围只映射系统级目录：%UserProfile%、%LocalAppData% 等用户目录变量
        在系统上下文中会展开为系统账户目录（systemprofile），指向错误位置。
    .PARAMETER Path
        要转换的绝对路径
    .PARAMETER Scope
        变量写入范围：User（默认，可使用用户目录变量）或 Machine（仅系统级目录变量）
    .EXAMPLE
        Convert-ToolkitPathToEnvVar -Path 'C:\Program Files\Microsoft\jdk-25'
        返回 %ProgramFiles%\Microsoft\jdk-25
    .EXAMPLE
        Convert-ToolkitPathToEnvVar -Path 'C:\Users\alice\tools' -Scope Machine
        返回原路径（用户目录不转换为 %UserProfile%）
    .OUTPUTS
        System.String
    .NOTES
        Author: SUNC
        Version: 1.1.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [ValidateSet('Machine', 'User')][string]$Scope = 'User'
    )

    # 用户级与系统级目录变量分开维护：Machine 上下文只展开系统级变量，
    # 混入用户目录会指向 systemprofile。新增变量只需加进对应一张表。
    $userMap = [ordered]@{
        '%Temp%'         = $env:TEMP
        '%LocalAppData%' = $env:LOCALAPPDATA
        '%AppData%'      = $env:APPDATA
        '%UserProfile%'  = $env:USERPROFILE
        '%Public%'       = $env:PUBLIC
    }
    $systemMap = [ordered]@{
        '%CommonProgramFiles%' = $env:CommonProgramFiles
        '%ProgramFiles(x86)%'  = ${env:ProgramFiles(x86)}
        '%ProgramFiles%'       = $env:ProgramFiles
        '%ProgramData%'        = $env:ProgramData
        '%SystemRoot%'         = $env:SystemRoot
        '%SystemDrive%'        = $env:SystemDrive
    }

    # 保持「用户级在前、系统级在后」的匹配顺序
    $map = [ordered]@{}
    if ($Scope -ne 'Machine') {
        foreach ($key in $userMap.Keys) { $map[$key] = $userMap[$key] }
    }
    foreach ($key in $systemMap.Keys) { $map[$key] = $systemMap[$key] }

    foreach ($entry in $map.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($entry.Value)) { continue }
        $prefix = $entry.Value.TrimEnd('\')

        if ($Path.Equals($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry.Key
        }
        if ($Path.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry.Key + $Path.Substring($prefix.Length)
        }
    }

    return $Path
}

function Set-ToolkitEnvironmentVariable {
    <#
    .SYNOPSIS
        写入一个环境变量，值为空时跳过
    .DESCRIPTION
        使用注册表 ExpandString 写入，%ProgramFiles% 这类引用才能在新终端里展开。
        绝对路径会自动转换成变量形式；只影响注册表，不修改系统设置界面里的其他项。
        Machine 范围不把用户目录转换为 %UserProfile% 等用户变量（系统上下文会指向错误目录）。
        写入后同步当前进程，便于后续步骤立即使用。
    .PARAMETER Name
        变量名
    .PARAMETER Value
        变量值；可以是 %VAR% 形式或绝对路径
    .PARAMETER Scope
        Machine（系统，需要管理员）或 User（用户）
    .EXAMPLE
        Set-ToolkitEnvironmentVariable -Name 'EDITOR' -Value 'code --wait' -Scope User
    .NOTES
        Author: SUNC
        Version: 1.0.1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('Machine', 'User')][string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Warning "跳过 $Scope 变量 $Name：值为空"
        return
    }

    $finalValue = Convert-ToolkitPathToEnvVar -Path $Value -Scope $Scope
    $key = Get-ToolkitEnvironmentKey -Scope $Scope

    New-ItemProperty -Path $key -Name $Name -Value $finalValue -PropertyType ExpandString -Force | Out-Null
    $expandedValue = [Environment]::ExpandEnvironmentVariables($finalValue)
    Set-Item -Path "Env:$Name" -Value $expandedValue -ErrorAction SilentlyContinue

    Write-Verbose "$Scope 变量 $Name = $finalValue"
}

function Add-ToolkitEnvironmentPathEntry {
    <#
    .SYNOPSIS
        向环境变量 PATH 追加一项，已存在则跳过
    .DESCRIPTION
        读取注册表原始值而不是 Get-ItemProperty 的展开结果，
        避免把其他 %VAR% 引用固化；比较时同时考虑原始形式与展开形式。
        变量不存在或目录不存在时给出警告并跳过。
    .PARAMETER Entry
        要追加的条目，可以是 %VAR%\子目录 或绝对路径
    .PARAMETER Scope
        Machine（系统，需要管理员）或 User（用户）
    .EXAMPLE
        Add-ToolkitEnvironmentPathEntry -Entry '%JAVA_HOME%\bin' -Scope Machine
    .NOTES
        Author: SUNC
        Version: 1.1.1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Entry,
        [Parameter(Mandatory = $true)][ValidateSet('Machine', 'User')][string]$Scope
    )

    # 绝对路径转成 %ProgramFiles% 等变量形式，避免把本机真实目录固化进 PATH
    $Entry = Convert-ToolkitPathToEnvVar -Path $Entry -Scope $Scope

    if ($Entry -match '^%([^%]+)%') {
        $varName = $matches[1]
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($varName))) {
            Write-Warning "跳过 $Scope PATH 项 $Entry：变量 $varName 不存在"
            return
        }
        # 变量存在但指向的目录未创建时同样无效，按帮助文档统一跳过
        $expandedForCheck = [Environment]::ExpandEnvironmentVariables($Entry)
        if (-not (Test-Path -LiteralPath $expandedForCheck)) {
            Write-Warning "跳过 $Scope PATH 项 $Entry：展开后目录不存在（$expandedForCheck）"
            return
        }
    }
    elseif (-not (Test-Path -LiteralPath $Entry)) {
        Write-Warning "跳过 $Scope PATH 项 $Entry：目录不存在"
        return
    }

    $keyPath = Get-ToolkitEnvironmentKey -Scope $Scope
    $registryKey = Get-Item -LiteralPath $keyPath
    $current = $registryKey.GetValue(
        'Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    )
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $expandedEntry = [Environment]::ExpandEnvironmentVariables($Entry)
    foreach ($part in $parts) {
        if ($part -eq $Entry) { return }
        if ($expandedEntry -and [Environment]::ExpandEnvironmentVariables($part) -eq $expandedEntry) { return }
    }

    $updated = (@($parts) + $Entry) -join ';'
    Set-ItemProperty -Path $keyPath -Name 'Path' -Value $updated -Type ExpandString

    Write-Verbose "$Scope PATH += $Entry"
}

function Send-ToolkitEnvironmentChange {
    <#
    .SYNOPSIS
        广播环境变量变更，通知资源管理器等程序刷新
    .DESCRIPTION
        不广播时，新开的终端能读到新值，但已运行的资源管理器可能仍持有旧环境。
    .EXAMPLE
        Send-ToolkitEnvironmentChange
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()

    try {
        if (-not ('Toolkit.NativeMethods' -as [type])) {
            $signature = '[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
            Add-Type -MemberDefinition $signature -Name 'NativeMethods' -Namespace 'Toolkit'
        }
        $result = [UIntPtr]::Zero
        [Toolkit.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result
        ) | Out-Null
    }
    catch {
        Write-Warning "环境变量变更广播失败：$($_.Exception.Message)"
    }
}

function Get-ToolkitJdkHome {
    <#
    .SYNOPSIS
        查找 %ProgramFiles%\Microsoft\jdk-*-hotspot 中版本最高的目录
    .DESCRIPTION
        不写死版本号：winget 升级 OpenJDK 后目录名会变化。
    .OUTPUTS
        System.String 或 $null
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()

    try {
        $base = Join-Path $env:ProgramFiles 'Microsoft'
        $dir = Get-ChildItem -LiteralPath $base -Directory -Filter 'jdk-*-hotspot' -ErrorAction Stop |
            Sort-Object {
                try { [version]($_.Name -replace '^jdk-', '' -replace '-hotspot$', '') }
                catch { [version]'0.0.0' }
            } -Descending |
            Select-Object -First 1
        if ($dir) { return $dir.FullName }
    }
    catch {
        return $null
    }
    return $null
}

function Get-ToolkitSqlclHome {
    <#
    .SYNOPSIS
        查找 winget 安装的 SQLcl bin 目录
    .DESCRIPTION
        winget 包目录名带源后缀，用通配符匹配，不写死版本与源标识。
    .OUTPUTS
        System.String 或 $null
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()

    try {
        $base = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        $dir = Get-ChildItem -LiteralPath $base -Directory -Filter 'Oracle.SQLcl_*' -ErrorAction Stop |
            Select-Object -First 1
        if ($dir) { return (Join-Path $dir.FullName 'sqlcl\bin') }
    }
    catch {
        return $null
    }
    return $null
}
