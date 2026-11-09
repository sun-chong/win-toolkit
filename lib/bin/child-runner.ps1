<#
.SYNOPSIS
    Toolkit 子进程入口

.DESCRIPTION
    由 lib/Process.ps1 的 Invoke-ChildProcess 调用。
    只负责读取 payload、执行命令或 ScriptBlock、回传退出码；
    超时由父进程负责，本脚本不重复计时。

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
    [Parameter(Mandatory = $true)][string]$PayloadFile,
    [Parameter(Mandatory = $true)][ValidateSet('Command', 'ScriptBlock')][string]$PayloadKind,
    [int]$TimeoutSeconds = 0
)

$ErrorActionPreference = 'Stop'
$null = $TimeoutSeconds

$payload = Get-Content -LiteralPath $PayloadFile -Raw -Encoding UTF8

try {
    $global:LASTEXITCODE = 0
    if ($PayloadKind -eq 'ScriptBlock') {
        $block = [scriptblock]::Create($payload)
        & $block
    }
    else {
        # /S 让 cmd 按「去掉首尾引号、其余原样」处理整条命令，
        # 否则 PowerShell 对含空格参数的自动加引号会让输出多出尾引号。
        & $env:ComSpec /d /s /c $payload
    }

    $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    exit $code
}
catch {
    [Console]::Error.WriteLine($_)
    exit 1
}
