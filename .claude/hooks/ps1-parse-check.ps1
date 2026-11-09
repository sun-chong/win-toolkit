<#
.SYNOPSIS
    PostToolUse 钩子：对刚编辑的 .ps1 文件做语法解析校验

.DESCRIPTION
    从 stdin 读取 Claude Code 的 hook JSON，取出被编辑的文件路径。
    若为 .ps1 且存在，则用 PowerShell 解析器校验语法；有错误时输出 JSON，
    通过 additionalContext 反馈给 Claude。非 .ps1 文件静默通过。

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

# 强制 UTF-8 读写，避免 Windows 控制台默认代码页（GBK）导致中文乱码
$stdin = [System.Console]::OpenStandardInput()
$reader = New-Object System.IO.StreamReader($stdin, [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try {
    $payload = $raw | ConvertFrom-Json
}
catch {
    exit 0
}

$file = $null
if ($payload.tool_input -and $payload.tool_input.file_path) {
    $file = [string]$payload.tool_input.file_path
}
elseif ($payload.tool_response -and $payload.tool_response.filePath) {
    $file = [string]$payload.tool_response.filePath
}

if ([string]::IsNullOrWhiteSpace($file)) { exit 0 }
if ([System.IO.Path]::GetExtension($file) -ne '.ps1') { exit 0 }
if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { exit 0 }

$parseErrors = $null
$tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors -and $parseErrors.Count -gt 0) {
    $lines = $parseErrors | ForEach-Object { "  行 $($_.Extent.StartLineNumber): $($_.Message)" }
    $message = "PowerShell 语法校验未通过 —— $file`n" + ($lines -join "`n") + "`n请修复后重新写入。"

    $output = @{
        systemMessage      = "PowerShell 语法校验失败：$file"
        hookSpecificOutput = @{
            hookEventName     = 'PostToolUse'
            additionalContext = $message
        }
    }
    $json = $output | ConvertTo-Json -Depth 5 -Compress

    # 直接以 UTF-8 字节写入标准输出，绕过控制台代码页
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $stdout = [System.Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

exit 0
