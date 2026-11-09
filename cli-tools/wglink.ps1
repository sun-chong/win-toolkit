<#
.SYNOPSIS
    为 WinGet 便携包一键创建符号链接

.DESCRIPTION
    扫描 %LOCALAPPDATA%\Microsoft\WinGet\Packages 下各包目录根层的 .exe，
    在 %LOCALAPPDATA%\Microsoft\WinGet\Links 中创建同名符号链接。

    仅处理包目录根层的主程序，不递归子目录（如 SQLcl 的 sql.exe 不会链接）。

    行为（幂等，可重复执行）：
    - 链接不存在 → 新建
    - 链接已存在且指向同一目标 → 跳过
    - 链接已存在但失效或指向别处 → 重建
    - Links 中指向 Packages 的失效链接（包已卸载）→ 清理
    - Links 中存在同名普通文件（非链接）→ 视为冲突，跳过并提示

    创建符号链接需要开发者模式或管理员权限，失败时给出中文提示。

    使用方式：
    - wglink：扫描并一键补齐 / 修复所有链接
    - wglink -h：显示帮助信息

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    wglink
    扫描 Packages 并一键创建 / 修复 Links 中的符号链接

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
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

# 帮助信息
if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path -Full
    exit
}

$PackagesDir = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
$LinksDir = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"

# 前置检查：Packages 目录必须存在
if (-not (Test-Path -LiteralPath $PackagesDir)) {
    Write-ToolkitMessage -Kind Error -Text "未找到 WinGet 包目录：$PackagesDir"
    Write-ToolkitMessage -Kind Error -Text "请确认 WinGet 便携包已安装（winget install --portable）。"
    exit 1
}

# Links 目录不存在则创建（正常由 winget 维护，属兜底）
if (-not (Test-Path -LiteralPath $LinksDir)) {
    New-Item -ItemType Directory -Path $LinksDir -Force | Out-Null
}

# 统计变量
$CreatedCount = 0   # 新建
$SkippedCount = 0   # 跳过（已存在且指向一致）
$RebuiltCount = 0   # 重建（失效或指向别处）
$CleanedCount = 0   # 清理（目标已卸载的失效链接）
$ConflictCount = 0  # 冲突（同名普通文件，非链接）
$FailedCount = 0    # 创建失败
$SeenNames = @{}    # 已处理过的链接名，用于包间重名检测

# 第一遍：清理 Links 中指向 Packages 但目标已不存在的失效链接
$ExistingLinks = Get-ChildItem -Path $LinksDir -Filter "*.exe" -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LinkType -eq "SymbolicLink" -and $_.Target }
foreach ($link in $ExistingLinks) {
    $targetPath = @($link.Target)[0]
    # 只清理指向 Packages 目录的链接，不碰用户自建的其他链接
    if ($targetPath -like "$PackagesDir*" -and -not (Test-Path -LiteralPath $targetPath)) {
        Write-ToolkitMessage -Kind Warning -Text "清理失效链接：$($link.Name) → $targetPath"
        Remove-Item -LiteralPath $link.FullName -Force
        $CleanedCount++
    }
}

# 第二遍：扫描各包目录根层的 exe，创建 / 修复链接
$Exes = Get-ChildItem -Path $PackagesDir -Directory | ForEach-Object {
    Get-ChildItem -Path $_.FullName -Filter "*.exe" -File -ErrorAction SilentlyContinue
}

if (-not $Exes) {
    Write-ToolkitMessage -Kind Warning -Text "Packages 目录下未发现任何可执行程序。"
    exit 0
}

foreach ($exe in $Exes) {
    $linkPath = Join-Path $LinksDir $exe.Name

    # 包间重名：后面的包不再处理，避免互相覆盖
    if ($SeenNames.ContainsKey($exe.Name)) {
        Write-ToolkitMessage -Kind Warning -Text "冲突跳过：$($exe.Name)（已由 $($SeenNames[$exe.Name]) 提供）"
        $ConflictCount++
        continue
    }
    $SeenNames[$exe.Name] = $exe.Directory.Name

    $existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue

    if ($existing) {
        # 同名普通文件（非链接）视为冲突，不覆盖
        if ($existing.LinkType -ne "SymbolicLink") {
            Write-ToolkitMessage -Kind Warning -Text "冲突跳过：$($exe.Name)（Links 中已存在普通文件，非链接）"
            $ConflictCount++
            continue
        }

        $existingTarget = @($existing.Target)[0]
        $sameTarget = [string]::Equals(
            [IO.Path]::GetFullPath($existingTarget),
            [IO.Path]::GetFullPath($exe.FullName),
            [StringComparison]::OrdinalIgnoreCase
        )

        if ($sameTarget -and (Test-Path -LiteralPath $linkPath)) {
            $SkippedCount++
            continue
        }

        # 失效或指向别处 → 重建
        Remove-Item -LiteralPath $linkPath -Force
    }

    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $exe.FullName -ErrorAction Stop | Out-Null
        $action = if ($existing) { "重建" } else { "新建" }
        Write-ToolkitMessage -Kind Success -Text "${action}链接：$($exe.Name) → $($exe.FullName)"
        if ($existing) { $RebuiltCount++ } else { $CreatedCount++ }
    }
    catch {
        Write-ToolkitMessage -Kind Error -Text "创建失败：$($exe.Name) —— $($_.Exception.Message)"
        Write-ToolkitMessage -Kind Error -Text "提示：创建符号链接需要开启 Windows 开发者模式，或以管理员身份运行。"
        $FailedCount++
    }
}

# 汇总
Write-Host ""
Write-Host "完成：新建 $CreatedCount，跳过 $SkippedCount，重建 $RebuiltCount，清理 $CleanedCount，冲突 $ConflictCount，失败 $FailedCount"

if ($FailedCount -gt 0) {
    exit 1
}
