function Test-ToolkitAdministrator {
    <#
    .SYNOPSIS
        判断当前进程是否以管理员身份运行
    .DESCRIPTION
        只使用 Windows PowerShell 5.1 也支持的语法与类型，
        便于入口脚本在自举 PowerShell 7 之前直接点源本文件调用。
    .EXAMPLE
        if (-not (Test-ToolkitAdministrator)) { ... }
    .OUTPUTS
        System.Boolean
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ToolkitElevation {
    <#
    .SYNOPSIS
        以管理员身份重新启动指定的 PowerShell 脚本
    .DESCRIPTION
        非管理员时用当前宿主（powershell.exe 或 pwsh.exe）通过 UAC 重新启动脚本，
        等待结束后返回进程对象，调用方用 ExitCode 传递真实结果。
        已经是管理员时返回 $null，不做任何操作。
        只使用 Windows PowerShell 5.1 也支持的语法，入口脚本可点源本文件后调用。
    .PARAMETER ScriptPath
        要重新启动的脚本绝对路径
    .PARAMETER ArgumentList
        原样传给脚本的附加参数
    .PARAMETER WorkingDirectory
        子进程的工作目录；省略时继承当前目录
    .EXAMPLE
        $process = Invoke-ToolkitElevation -ScriptPath $PSCommandPath
        if ($process) { exit $process.ExitCode }
    .OUTPUTS
        System.Diagnostics.Process 或 $null
    .NOTES
        Author: SUNC
        Version: 1.1.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory
    )

    if (Test-ToolkitAdministrator) { return $null }

    $hostExe = (Get-Process -Id $PID).Path
    $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ArgumentList)

    # Start-Process 的 -ArgumentList 不会自动为含空格的参数加引号
    $quotedArguments = @(
        foreach ($argument in $allArguments) {
            if ($argument -match '\s') { '"' + $argument + '"' }
            else { $argument }
        }
    )

    $startParams = @{
        FilePath     = $hostExe
        Verb         = 'RunAs'
        ArgumentList = $quotedArguments
        Wait         = $true
        PassThru     = $true
    }
    if ($WorkingDirectory) { $startParams.WorkingDirectory = $WorkingDirectory }

    return Start-Process @startParams
}
