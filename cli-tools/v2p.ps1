<#
.SYNOPSIS
    Visio 转 PDF

.DESCRIPTION
    将当前终端目录下的 Visio .vsdx 文件批量转换为 PDF。

    使用方式：
    - v2p：转换当前目录下的所有 .vsdx 文件
    - v2p -o <子目录>：转换并输出到指定子目录
    - v2p -h：显示帮助信息

.PARAMETER OutputSubdir
    指定输出子目录名，默认当前目录
    短参数：-o
    示例：-o pdfs

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    v2p
    转换当前目录下的所有 .vsdx 文件

.EXAMPLE
    v2p -o pdfs
    转换并输出到当前目录下的 pdfs 子目录

.EXAMPLE
    v2p -h
    显示帮助信息

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
    [Alias("o")]
    [string]$OutputSubdir,

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

# Visio 常量
$visFixedFormatPDF = 1
$visDocExIntentScreen = 1
$visAlways = 1

# 统计变量
$SuccessCount = 0
$FailCount = 0
$FailedFiles = @()  # 记录失败的文件名及原因

# 获取当前终端所在目录（非脚本所在目录）
$WorkDir = (Get-Location).Path

# 扫描 vsdx 文件
$VsdxFiles = Get-ChildItem -Path $WorkDir -Filter "*.vsdx" -File

if ($VsdxFiles.Count -eq 0) {
    Write-ToolkitMessage -Kind Error -Text "错误：当前目录下未找到 .vsdx 文件。"
    exit 1
}

# 处理输出目录
if ($OutputSubdir) {
    $OutputDir = Join-Path $WorkDir $OutputSubdir

    # 处理子目录重名：递增括号法
    $Counter = 1
    while (Test-Path $OutputDir -PathType Container) {
        $OutputDir = Join-Path $WorkDir "$OutputSubdir($Counter)"
        $Counter++
    }

    # 创建输出目录
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
} else {
    $OutputDir = $WorkDir
}

# 测试输出目录写入权限
try {
    $TestFile = Join-Path $OutputDir ".write_test_$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($TestFile, "test")
    Remove-Item $TestFile -Force
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误：输出目录无写入权限: $OutputDir"
    exit 1
}

Write-Host "输出目录: $OutputDir"

# 显示进度条（原地刷新）
function Write-ProgressBar {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Current,

        [Parameter(Mandatory = $true)]
        [int]$Total,

        [Parameter(Mandatory = $true)]
        [string]$CurrentFile
    )

    $Percent = [math]::Round(($Current / $Total) * 100)
    $FilledCount = [math]::Floor($Percent / 2)
    $EmptyCount = 50 - $FilledCount

    # 使用█表示已填充，使用░表示未填充
    $FilledBar = "█" * $FilledCount
    $EmptyBar = "░" * $EmptyCount

    $ProgressBar = "$FilledBar$EmptyBar"

    # 首次调用时输出占位行
    if (-not $script:ProgressBarInitialized) {
        Write-Host ""
        Write-Host ""
        $script:ProgressBarInitialized = $true
    }

    # 尝试使用 VT 序列实现原地刷新
    # 如果终端不支持，回退到逐行输出
    try {
        $ESC = [char]27
        $up2 = "${ESC}[2A"
        $clearLine = "${ESC}[2K"

        [Console]::Write($up2)
        [Console]::Write($clearLine)
        [Console]::Write("${ProgressBar} ${Percent}%`n")
        [Console]::Write($clearLine)
        [Console]::Write("[$Current/$Total] 正在转换: $CurrentFile`n")
    }
    catch {
        # 回退方案：逐行输出
        Write-Host "${ProgressBar} ${Percent}%"
        Write-Host "[$Current/$Total] 正在转换: $CurrentFile"
    }
}

# 启动 Visio
$VisioApp = $null
try {
    Write-Host "正在启动 Visio..." -NoNewline
    $VisioApp = New-Object -ComObject Visio.Application

    $VisioApp.Visible = $false
    $VisioApp.AlertResponse = $visAlways
    $VisioApp.ShowChanges = $false
    $VisioApp.ScreenUpdating = $false

    Write-ToolkitMessage -Kind Success -Text " [成功]"
}
catch {
    Write-ToolkitMessage -Kind Error -Text " [失败]"
    Write-ToolkitMessage -Kind Error -Text "错误：无法启动 Visio，请确认已安装 Microsoft Visio。"
    Write-ToolkitMessage -Color DarkGray -Text "详情：$($_.Exception.Message)"

    # 启动失败时尝试清理可能残留的进程
    if ($null -ne $VisioApp) {
        try {
            $VisioApp.Quit()
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($VisioApp) | Out-Null
        }
        catch { }
    }
    exit 1
}

# 批量转换循环
$TotalCount = $VsdxFiles.Count
$CurrentIndex = 0

foreach ($File in $VsdxFiles) {
    $CurrentIndex++
    $Doc = $null

    # 显示进度
    Write-ProgressBar -Current $CurrentIndex -Total $TotalCount -CurrentFile $File.Name

    try {
        # 打开文档
        $InputPath = $File.FullName
        $Doc = $VisioApp.Documents.Open($InputPath)

        # 生成唯一输出文件名
        $PdfName = $File.BaseName + ".pdf"
        $OutputPath = Get-UniqueFileName -Directory $OutputDir -BaseName $PdfName

        # 导出 PDF
        $Doc.ExportAsFixedFormat($visFixedFormatPDF, $OutputPath, $visDocExIntentScreen, 0)

        # 关闭文档
        $Doc.Close()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Doc) | Out-Null
        $Doc = $null

        $SuccessCount++
    }
    catch {
        $ErrorMessage = $_.Exception.Message

        # 判断错误类型
        if ($ErrorMessage -match "被另一进程使用|另一个程序正在使用|is being used") {
            Write-ToolkitMessage -Kind Error -Text "    错误: 文件被其他程序锁定"
            $FailedFiles += "$($File.Name) - 文件被其他程序锁定"
        }
        elseif ($ErrorMessage -match "无法读取|无法打开|cannot read|cannot open|无效的格式") {
            Write-ToolkitMessage -Kind Error -Text "    错误: 文件损坏或格式无效"
            $FailedFiles += "$($File.Name) - 文件损坏或格式无效"
        }
        else {
            Write-ToolkitMessage -Kind Error -Text "    错误: $ErrorMessage"
            $FailedFiles += "$($File.Name) - $ErrorMessage"
        }

        $FailCount++

        if ($null -ne $Doc) {
            try {
                $Doc.Close()
                [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Doc) | Out-Null
            }
            catch {}
        }
    }
}

# 清除进度条
Write-Progress -Activity "Visio 转 PDF" -Completed

# Visio 清理
Write-Host "正在清理 Visio 进程..." -NoNewline
try {
    if ($null -ne $VisioApp) {
        $VisioApp.Quit()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($VisioApp) | Out-Null
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Write-ToolkitMessage -Kind Success -Text " [完成]"
}
catch {
    Write-ToolkitMessage -Kind Warning -Text " [警告: 清理不完全]"
}

# 统计报告
Write-Host ""
Write-ToolkitMessage -Kind Info -Text "================ 结果统计 ================"
Write-Host "输出目录: $OutputDir"
Write-Host "文件总数: $TotalCount"
Write-ToolkitMessage -Kind Success -Text "成功数量: $SuccessCount"
if ($FailCount -gt 0) {
    Write-ToolkitMessage -Kind Error -Text "失败数量: $FailCount"

    # 显示失败文件列表
    Write-Host ""
    Write-ToolkitMessage -Kind Warning -Text "失败文件列表:"
    foreach ($FailedFile in $FailedFiles) {
        Write-ToolkitMessage -Color DarkGray -Text "  - $FailedFile"
    }
} else {
    Write-ToolkitMessage -Kind Success -Text "失败数量: 0"
}
Write-ToolkitMessage -Kind Info -Text "=========================================="
