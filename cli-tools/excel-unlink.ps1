<#
.SYNOPSIS
    Excel 工作簿链接清理

.DESCRIPTION
    批量删除当前目录下 Excel 文件（.xlsx/.xlsm/.xltx/.xltm）中的"工作簿链接"（外部链接 / External Links）。
    仅删除链接部件及与其相关的元数据，其余内容（工作表、公式、样式、图表、图片等）原样保留。
    旧版 .xls/.xlt 二进制格式无法自动处理，会提示在 Excel 中手动断开链接。

    使用方式：
    - excel-unlink           处理当前目录下所有 Excel 文件
    - excel-unlink -r        递归处理全部子目录
    - excel-unlink -d        只检测不修改（安全预览）
    - excel-unlink -b        修改前为每个文件生成 .bak 备份
    - excel-unlink -h        显示帮助信息

.PARAMETER Recurse
    递归处理当前目录及全部子目录中的 Excel 文件
    短参数：-r
    示例：excel-unlink -r

.PARAMETER DryRun
    只检测不修改，预览哪些文件含有工作簿链接（可与 -r 搭配使用）
    短参数：-d
    示例：excel-unlink -d -r

.PARAMETER Backup
    修改前为每个文件生成 .bak 备份
    短参数：-b
    示例：excel-unlink -b

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    excel-unlink
    处理当前目录下所有 Excel 文件

.EXAMPLE
    excel-unlink -r
    递归处理当前目录及全部子目录中的 Excel 文件

.EXAMPLE
    excel-unlink -d -r
    递归预览，只检测不修改

.EXAMPLE
    excel-unlink -b
    修改前为每个文件生成 .bak 备份

.NOTES
    Author: SUNC
    Version: 1.0.0
#>

param(
    [Alias("r")]
    [switch]$Recurse,

    [Alias("d")]
    [switch]$DryRun,

    [Alias("b")]
    [switch]$Backup,

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

# 统计变量
$CleanCount = 0
$NoneCount = 0
$FoundCount = 0
$FailCount = 0
$FailedFiles = @()  # 记录失败的文件名及原因

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$extNew = @('.xlsx', '.xlsm', '.xltx', '.xltm')   # OpenXML 格式，脚本可安全处理
$extOld = @('.xls', '.xlt')                       # 旧版二进制格式，需用 Excel 手动断开
$extRefNamePattern = '\[\d+\]'                    # 定义名称公式中的外部工作簿索引，如 [1]计划甘特图!$D$4

function Read-EntryText {
    param($Entry)
    $s = $Entry.Open()
    $r = New-Object System.IO.StreamReader($s, [System.Text.Encoding]::UTF8)
    try {
        return $r.ReadToEnd()
    } finally {
        $r.Dispose()
    }
}

function Write-EntryBytes {
    param($Entry, [byte[]]$Bytes)
    $s = $Entry.Open()
    try {
        $s.SetLength(0)
        $s.Write($Bytes, 0, $Bytes.Length)
        $s.Flush()
    } finally {
        $s.Dispose()
    }
}

function Save-XmlDocBytes {
    # 序列化为 UTF-8（无 BOM）字节。
    # 注意：必须通过 Stream 创建 XmlWriter，settings.Encoding 才会生效；
    # 若用 StringBuilder 创建，声明会被写成 encoding="utf-16" 而内容却是 UTF-8，导致文件损坏。
    param($Doc)
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $false
    $settings.OmitXmlDeclaration = $false
    $ms = New-Object System.IO.MemoryStream
    $xw = [System.Xml.XmlWriter]::Create($ms, $settings)
    $Doc.Save($xw)
    $xw.Close()
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return $bytes
}

function Test-NameUsage {
    # 检测定义名称是否被其他部件/公式引用（词边界匹配，大小写不敏感）
    param([string]$Name, [string[]]$PartTexts)
    $pattern = '(?<![A-Za-z0-9_.])' + [regex]::Escape($Name) + '(?![A-Za-z0-9_.])'
    foreach ($t in $PartTexts) {
        if ($t -match $pattern) { return $true }
    }
    return $false
}

# 获取当前终端所在目录（非脚本所在目录）
$WorkDir = (Get-Location).Path

# 扫描 Excel 文件（默认仅当前目录；-r 递归全部子目录）
$all = @(Get-ChildItem -LiteralPath $WorkDir -File -Recurse:$Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)

$targets = @($all | Where-Object { $extNew -contains $_.Extension.ToLowerInvariant() })
$legacy  = @($all | Where-Object { $extOld -contains $_.Extension.ToLowerInvariant() })

if ($targets.Count -eq 0 -and $legacy.Count -eq 0) {
    Write-ToolkitMessage -Kind Error -Text "错误：当前目录下未找到 Excel 文件。"
    exit 1
}

if ($Recurse) {
    Write-ToolkitMessage -Kind Info -Text "待处理 OpenXML 文件: $($targets.Count) 个（递归含所有子目录）"
} else {
    Write-ToolkitMessage -Kind Info -Text "待处理 OpenXML 文件: $($targets.Count) 个（仅当前目录）"
}
if ($DryRun) { Write-ToolkitMessage -Kind Warning -Text "当前为 [DryRun] 只检测模式，不会修改任何文件" }
if ($Backup) { Write-ToolkitMessage -Kind Warning -Text "已启用备份：修改前将为每个文件生成 .bak 副本" }

# 测试当前目录写入权限（DryRun 模式不修改文件，无需检查）
if (-not $DryRun) {
    try {
        $TestFile = Join-Path $WorkDir ".write_test_$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($TestFile, "test")
        Remove-Item $TestFile -Force
    }
    catch {
        Write-ToolkitMessage -Kind Error -Text "错误：当前目录无写入权限: $WorkDir"
        exit 1
    }
}

# DryRun 列表标题
if ($DryRun) {
    Write-Host ""
    Write-ToolkitMessage -Kind Warning -Text "发现工作簿链接的文件:"
}

# ---------- 批量处理循环 ----------
$rootPath = $WorkDir.TrimEnd('\')

foreach ($f in $targets) {
    $filePath = $f.FullName
    $relFile = Get-RelativePath $filePath $rootPath
    try {
        # 1) 只读检测
        $zipR = [System.IO.Compression.ZipFile]::OpenRead($filePath)
        $extEntries = @($zipR.Entries | Where-Object { $_.FullName -match '^xl/externalLinks/.+\.(xml|rels)$' })
        $wbEntryR = $zipR.GetEntry('xl/workbook.xml')
        $wbXmlRaw = $null
        if ($wbEntryR) { $wbXmlRaw = Read-EntryText $wbEntryR }
        $zipR.Dispose()

        if ($extEntries.Count -eq 0) {
            # 无链接部件，但可能残留 externalReferences 声明（无对应关系，不影响使用，属残留问题）
            $residual = $false
            if ($wbXmlRaw) {
                $d = New-Object System.Xml.XmlDocument
                $d.LoadXml($wbXmlRaw)
                if ($d.SelectSingleNode('//*[local-name()="externalReferences"]')) { $residual = $true }
            }
            if ($residual) {
                Write-ToolkitMessage -Color DarkYellow -Text ("  - " + $relFile + "  残留 externalReferences(无链接部件)")
            }
            $NoneCount++
            continue
        }

        # 检测引用外部工作簿的定义名称（DryRun 与正常模式均需统计数量）
        $extDnAll = @()
        if ($wbXmlRaw) {
            $d = New-Object System.Xml.XmlDocument
            $d.LoadXml($wbXmlRaw)
            $dnParent = $d.SelectSingleNode('//*[local-name()="definedNames"]')
            if ($dnParent) {
                $dnNodes = @($dnParent.SelectNodes('*[local-name()="definedName"]'))
                $extDnAll = @($dnNodes | Where-Object { $_.InnerText -match $extRefNamePattern })
            }
        }

        $FoundCount++

        # DryRun：只列出有问题文件，附简要描述
        if ($DryRun) {
            $desc = "$($extEntries.Count) 个链接部件"
            if ($extDnAll.Count -gt 0) { $desc += " + $($extDnAll.Count) 个外部引用定义名称" }
            Write-ToolkitMessage -Kind Warning -Text ("  - " + $relFile + "  (" + $desc + ")")
            continue
        }

        # 正常模式：实际清理（结果统一在验证后单行输出）
        if ($Backup) {
            Copy-Item -LiteralPath $filePath -Destination ($filePath + ".bak") -Force
        }

        # 2) 实际修改
        $removedNameCount = 0
        $warnNameCount = 0
        $zip = [System.IO.Compression.ZipFile]::Open($filePath, [System.IO.Compression.ZipArchiveMode]::Update)
        try {
            # 2.1 workbook.xml：删除 externalReferences 与"未被使用"的外部引用定义名称
            $wbEntry = $zip.GetEntry('xl/workbook.xml')
            if ($wbEntry) {
                $doc = New-Object System.Xml.XmlDocument
                $doc.LoadXml((Read-EntryText $wbEntry))
                $needWrite = $false

                $er = $doc.SelectSingleNode('//*[local-name()="externalReferences"]')
                if ($er) {
                    $er.ParentNode.RemoveChild($er) | Out-Null
                    $needWrite = $true
                }

                $dnParent = $doc.SelectSingleNode('//*[local-name()="definedNames"]')
                if ($dnParent) {
                    $dnNodes = @($dnParent.SelectNodes('*[local-name()="definedName"]'))
                    $extDn = @($dnNodes | Where-Object { $_.InnerText -match $extRefNamePattern })
                    if ($extDn.Count -gt 0) {
                        # 收集"可能包含公式引用"的部件文本，用于"是否被使用"检查。
                        # 注意排除 workbook.xml 自身（定义名称天然在其中）、sharedStrings、
                        # calcChain、styles、theme、docProps 等不可能出现名称引用的部件，
                        # 否则会把"名称定义本身"误判为"被使用"而全部保留。
                        $scan = New-Object System.Collections.Generic.List[string]
                        $scanExclude = @(
                            'xl/workbook.xml', 'xl/sharedStrings.xml',
                            'xl/calcChain.xml', 'xl/styles.xml'
                        )
                        foreach ($e2 in $zip.Entries) {
                            if ($e2.FullName -match '^xl/externalLinks/') { continue }
                            if ($scanExclude -contains $e2.FullName) { continue }
                            if ($e2.FullName -match '^xl/(theme|docProps)/') { continue }
                            if ($e2.FullName -match '\.(xml|rels|vml)$') {
                                $scan.Add((Read-EntryText $e2))
                            }
                        }
                        # 其他定义名称的公式也参与检查（防止名称之间互相引用后被误删）
                        foreach ($dn in $dnNodes) {
                            if ($extDn -notcontains $dn) { $scan.Add($dn.InnerText) }
                        }
                        foreach ($dn in $extDn) {
                            $nm = $dn.GetAttribute('name')
                            if (Test-NameUsage -Name $nm -PartTexts $scan.ToArray()) {
                                $warnNameCount++
                            } else {
                                $dnParent.RemoveChild($dn) | Out-Null
                                $removedNameCount++
                                $needWrite = $true
                            }
                        }
                    }
                }

                if ($needWrite) {
                    Write-EntryBytes $wbEntry (Save-XmlDocBytes $doc)
                }
            }

            # 2.2 xl/_rels/workbook.xml.rels：删除 externalLink 关系
            $relsEntry = $zip.GetEntry('xl/_rels/workbook.xml.rels')
            if ($relsEntry) {
                $relsDoc = New-Object System.Xml.XmlDocument
                $relsDoc.LoadXml((Read-EntryText $relsEntry))
                $relsRoot = $relsDoc.DocumentElement
                $relNodes = @($relsRoot.ChildNodes | Where-Object {
                    $_.LocalName -eq 'Relationship' -and $_.Type -like '*externalLink*'
                })
                if ($relNodes.Count -gt 0) {
                    foreach ($rn in $relNodes) { $relsRoot.RemoveChild($rn) | Out-Null }
                    Write-EntryBytes $relsEntry (Save-XmlDocBytes $relsDoc)
                }
            }

            # 2.3 [Content_Types].xml：删除 externalLinks 的 Override 声明
            $ctEntry = $zip.GetEntry('[Content_Types].xml')
            if ($ctEntry) {
                $ctDoc = New-Object System.Xml.XmlDocument
                $ctDoc.LoadXml((Read-EntryText $ctEntry))
                $ctRoot = $ctDoc.DocumentElement
                $ovNodes = @($ctRoot.ChildNodes | Where-Object {
                    $_.LocalName -eq 'Override' -and $_.PartName -like '/xl/externalLinks/*'
                })
                if ($ovNodes.Count -gt 0) {
                    foreach ($ov in $ovNodes) { $ctRoot.RemoveChild($ov) | Out-Null }
                    Write-EntryBytes $ctEntry (Save-XmlDocBytes $ctDoc)
                }
            }

            # 2.4 删除 externalLinks 部件（从 Update 归档中重新枚举，保证句柄属于当前归档）
            $extInZip = @($zip.Entries | Where-Object { $_.FullName -match '^xl/externalLinks/.+\.(xml|rels)$' })
            foreach ($e in $extInZip) { $e.Delete() }
        } finally {
            $zip.Dispose()
        }

        # 3) 验证：重新打开，确认链接部件与相关元数据已全部移除、ZIP 完整（逐项读取校验 CRC）
        $verifyOk = $true
        $leftoverNotes = @()  # 清理后的残留问题（简短说明）
        $vz = [System.IO.Compression.ZipFile]::OpenRead($filePath)

        $left = @($vz.Entries | Where-Object { $_.FullName -match '^xl/externalLinks/' })
        if ($left.Count -gt 0) { $verifyOk = $false }

        # 残留元数据检查（正常清理后不应存在）
        $wbV = $vz.GetEntry('xl/workbook.xml')
        if ($wbV) {
            $docV = New-Object System.Xml.XmlDocument
            $docV.LoadXml((Read-EntryText $wbV))
            if ($docV.SelectSingleNode('//*[local-name()="externalReferences"]')) {
                $leftoverNotes += "残留 externalReferences"
            }
        }
        $relsV = $vz.GetEntry('xl/_rels/workbook.xml.rels')
        if ($relsV) {
            $relsDocV = New-Object System.Xml.XmlDocument
            $relsDocV.LoadXml((Read-EntryText $relsV))
            $relLeft = @($relsDocV.DocumentElement.ChildNodes | Where-Object {
                $_.LocalName -eq 'Relationship' -and $_.Type -like '*externalLink*'
            })
            if ($relLeft.Count -gt 0) { $leftoverNotes += "残留 externalLink 关系" }
        }
        $ctV = $vz.GetEntry('[Content_Types].xml')
        if ($ctV) {
            $ctDocV = New-Object System.Xml.XmlDocument
            $ctDocV.LoadXml((Read-EntryText $ctV))
            $ovLeft = @($ctDocV.DocumentElement.ChildNodes | Where-Object {
                $_.LocalName -eq 'Override' -and $_.PartName -like '/xl/externalLinks/*'
            })
            if ($ovLeft.Count -gt 0) { $leftoverNotes += "残留链接声明" }
        }

        try {
            $buf = [byte[]]::new(65536)
            foreach ($e in $vz.Entries) {
                $es = $e.Open()
                try {
                    while ($es.Read($buf, 0, $buf.Length) -gt 0) { }
                } finally {
                    $es.Dispose()
                }
            }
        } catch {
            $verifyOk = $false
            $leftoverNotes += "ZIP 损坏"
        }
        $vz.Dispose()

        if ($verifyOk) {
            $result = "已清理: $($extEntries.Count) 个链接部件"
            if ($removedNameCount -gt 0) { $result += ", 删除定义名称 $removedNameCount 个" }
            if ($warnNameCount -gt 0) { $result += ", 保留 $warnNameCount 个(被公式引用)" }
            if ($leftoverNotes.Count -gt 0) { $result += "；残留: " + ($leftoverNotes -join ", ") }
            if ($Backup) { $result += " [已备份]" }
            Write-ToolkitMessage -Kind Success -Text ("  - " + $relFile + "  " + $result)
            $CleanCount++
        } else {
            $errDesc = "失败: 完整性验证未通过"
            if ($leftoverNotes.Count -gt 0) { $errDesc += "（" + ($leftoverNotes -join ", ") + "）" }
            if ($Backup) { $errDesc += "，可从 .bak 恢复" }
            Write-ToolkitMessage -Kind Error -Text ("  - " + $relFile + "  " + $errDesc)
            $FailCount++
        }
    } catch {
        $FailCount++
        Write-ToolkitMessage -Kind Error -Text ("  - " + $relFile + "  失败: " + $_.Exception.Message)
        $FailedFiles += "$($relFile) - $($_.Exception.Message)"
    }
}

# ---------- 旧版 .xls（仅 DryRun 列出，正常模式只在统计中提示数量） ----------
if ($DryRun -and $legacy.Count -gt 0) {
    Write-Host ""
    Write-ToolkitMessage -Kind Warning -Text "旧版 .xls（需在 Excel 中手动断开链接）:"
    foreach ($f in $legacy) {
        $relLegacy = Get-RelativePath $f.FullName $rootPath
        Write-ToolkitMessage -Kind Warning -Text ("  - " + $relLegacy)
    }
}

# ---------- 统计报告 ----------
Write-Host ""
Write-ToolkitMessage -Kind Info -Text "================ 结果统计 ================"
Write-Host "处理目录: $WorkDir"
Write-Host "文件总数: $($targets.Count)"
if ($DryRun) {
    Write-ToolkitMessage -Kind Success -Text "发现链接: $FoundCount"
} else {
    Write-ToolkitMessage -Kind Success -Text "清理链接: $CleanCount"
}
Write-ToolkitMessage -Kind Success -Text "无链接: $NoneCount"
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
if ($legacy.Count -gt 0) {
    Write-ToolkitMessage -Kind Warning -Text "旧版 .xls 文件: $($legacy.Count) 个（需用 Excel 手动断开链接）"
}
Write-ToolkitMessage -Kind Info -Text "=========================================="
