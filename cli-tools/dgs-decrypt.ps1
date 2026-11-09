<#
.SYNOPSIS
    DGS 透明加密文件批量解密（原位替换）

.DESCRIPTION
    扫描当前目录下的 DGS 透明加密文件（深信服 DLP / Agile DGS，文件头特征由
    config/dgs.env 提供），解密后原位替换为明文。也可用 -p 指定任意位置的文件或目录，
    便于 Agent 自动调用。不按扩展名过滤——由 worker 读取磁盘真实文件头判断是否为密文。

    重要：深信服 DLP 驱动对白名单进程（pwsh）读时透明解密、写时透明加密——pwsh 读到的
    不是磁盘真实密文，写出的明文也会被驱动再次加密落盘。因此本工具的全部磁盘 I/O 与
    RC4 解密均在内嵌的 Python worker（非白名单进程）中完成，pwsh 仅负责扫描、参数解析
    与结果报告。运行依赖 python 命令（非白名单进程即可）。

    注意：原位替换后明文将脱离 DLP 透明加密直接落盘，请确认文件用途后再操作。
    建议先加 -d 预览，或加 -b 在替换前生成 .bak 密文备份（还原时将 .bak 改回原名即可）。

    使用方式：
    - dgs-decrypt                      处理当前目录下全部密文文件
    - dgs-decrypt -r                   递归处理全部子目录
    - dgs-decrypt -d                   只检测不修改（安全预览）
    - dgs-decrypt -b                   替换前为每个密文生成 .bak 备份
    - dgs-decrypt -n 文件1 文件2        只处理指定文件名（支持通配符，如 *.pdf）
    - dgs-decrypt -p 路径1 路径2        处理指定文件或目录（可位于任意位置，供 Agent 调用）
    - dgs-decrypt -h                   显示帮助信息

.PARAMETER Path
    处理指定的文件或目录（可提供多个，绝对路径或相对当前目录），不再扫描当前目录。
    文件直接处理；目录作为扫描根（配合 -r 递归）。路径不存在会报错并以退出码 1 结束。
    提供本参数时启用严格退出码契约：全部目标在处理后均为明文则退出码 0，
    存在失败或缺失路径则为 1，便于 Agent 自动判定结果。
    短参数：-p
    示例：dgs-decrypt -p "D:\资料\合同.xlsx"
    示例：dgs-decrypt -p "D:\资料" -r -b

.PARAMETER Recurse
    递归处理当前目录及全部子目录
    短参数：-r
    示例：dgs-decrypt -r

.PARAMETER DryRun
    只检测不修改，列出发现的密文文件（可与 -r / -n 搭配使用）
    短参数：-d
    示例：dgs-decrypt -d -r

.PARAMETER Backup
    原位替换前为每个密文文件生成同名 .bak 备份（.bak 内容为原始密文）
    短参数：-b
    示例：dgs-decrypt -b

.PARAMETER Name
    只处理指定文件名的文件，可提供多个（空格或逗号分隔），支持通配符
    短参数：-n
    示例：dgs-decrypt -n 报告.docx 合同.pdf
    示例：dgs-decrypt -n *.pdf -r

.PARAMETER Help
    显示帮助信息
    短参数：-h

.EXAMPLE
    dgs-decrypt
    处理当前目录下全部 DGS 密文文件，解密后原位替换

.EXAMPLE
    dgs-decrypt -r
    递归处理当前目录及全部子目录

.EXAMPLE
    dgs-decrypt -d -r
    递归预览，只检测不修改

.EXAMPLE
    dgs-decrypt -b -n *.xlsx
    只处理 Excel 文件，替换前生成 .bak 备份

.EXAMPLE
    dgs-decrypt -p "D:\资料\合同.xlsx" "D:\资料\报表目录" -r
    解密指定文件与指定目录下的全部密文（Agent 调用场景，按退出码判定结果）

.NOTES
    Author: SUNC
    Version: 1.2.1

    变更记录：
    1.2.1 (SUNC) — 密钥与格式常量外置到 config/dgs.env（不入库），
    脚本仅保留读取、校验与 worker 调用逻辑。
    1.2.0 (SUNC) — 新增 -Path 指定文件/目录模式，可对任意路径的原文件原位解密，
    便于 Agent 自动调用；提供 -Path 时启用严格退出码契约（全部明文=0，否则=1）。
    1.1.0 (SUNC) — DLP 驱动对 pwsh 透明加解密 I/O，导致 pwsh 内既检测不到密文、
    解密结果写盘也会被再次加密。解密核心与文件读写自 pwsh 迁移至内嵌 Python
    worker（非白名单进程），接口参数保持不变。
    1.0.0 — 初版，加解密核心内嵌自 dgs-encrypted-files skill 的 dgs_common.ps1。

    加解密核心逆向自 Agile DGS ac.dll，格式参数与密钥由 config/dgs.env 提供：
    - 文件头大小、内容密钥位置与长度、载荷分块大小均从环境读取
    - 载荷用内容密钥做 RC4，每块重置一次 RC4 状态；RC4 对称，加解密同一实现
#>

param(
    [Alias("p")]
    [string[]]$Path,

    [Alias("r")]
    [switch]$Recurse,

    [Alias("d")]
    [switch]$DryRun,

    [Alias("b")]
    [switch]$Backup,

    [Alias("n")]
    [string[]]$Name,

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
    exit 0
}

# ---------- DGS 解密 worker（内嵌 Python，负责全部磁盘 I/O） ----------

$DgsWorkerPy = @'
# -*- coding: utf-8 -*-
# DGS 解密 worker：由 dgs-decrypt.ps1 内嵌生成，负责全部磁盘 I/O 与 RC4 解密。
# 必须运行在非白名单进程（python）内：DLP 驱动对白名单进程（pwsh）读时透明解密、
# 写时透明加密，只有本进程能读到磁盘真实密文，写出的明文才能保持明文落盘。
import json
import os
import sys

# 密钥与格式常量由 PowerShell 从 config/dgs.env 读取后经环境变量传入，
# 不写入本文件，避免随仓库分发。
MAGIC = bytes.fromhex(os.environ['DGS_MAGIC'])
HEADER_SIZE = int(os.environ['DGS_HEADER_SIZE'])
KEY_OFFSET = int(os.environ['DGS_KEY_OFFSET'])
KEY_LEN = int(os.environ['DGS_KEY_LEN'])
CHUNK = int(os.environ['DGS_CHUNK'])
SEED = os.environ['DGS_SEED']
MASK = bytes.fromhex(os.environ['DGS_MASK'])


def rc4(data, key):
    # RC4 对称加解密
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 0xFF
        s[i], s[j] = s[j], s[i]
    out = bytearray(len(data))
    i = j = 0
    for n, b in enumerate(data):
        i = (i + 1) & 0xFF
        j = (j + s[i]) & 0xFF
        s[i], s[j] = s[j], s[i]
        out[n] = b ^ s[(s[i] + s[j]) & 0xFF]
    return bytes(out)


def header_key():
    # 由固定种子派生头部 RC4 密钥：每个字符加上 (下标 % 7)
    return bytes(((ord(c) + (i % 7)) & 0xFF) for i, c in enumerate(SEED))


def decrypt(raw):
    # 头部恢复内容密钥 → 载荷分块 RC4（每 10KB 重置一次 RC4 状态）
    plain_header = rc4(raw[:HEADER_SIZE], header_key())
    content_key = bytes(plain_header[KEY_OFFSET + i] ^ MASK[i] for i in range(KEY_LEN))
    payload = raw[HEADER_SIZE:]
    out = bytearray()
    for off in range(0, len(payload), CHUNK):
        out += rc4(payload[off:off + CHUNK], content_key)
    return bytes(out)


def main():
    # 参数解析：--mode scan|decrypt，--list <文件清单>，--backup 可选
    mode = None
    list_path = None
    backup = False
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == '--mode' and i + 1 < len(args):
            mode = args[i + 1]
            i += 2
        elif a == '--list' and i + 1 < len(args):
            list_path = args[i + 1]
            i += 2
        elif a == '--backup':
            backup = True
            i += 1
        else:
            i += 1
    if mode not in ('scan', 'decrypt') or not list_path:
        sys.stderr.write('worker 参数错误：需要 --mode scan|decrypt 与 --list <文件清单>\n')
        return 2

    # 文件清单为 UTF-8 无 BOM、每行一个完整路径（Windows 路径不含 \r \n，按行切分安全）
    with open(list_path, encoding='utf-8', newline='') as lf:
        paths = [line.rstrip('\r\n') for line in lf]
    paths = [p for p in paths if p]

    records = []
    for path in paths:
        rec = {'path': path, 'state': 'plain', 'ok': True, 'error': None}
        try:
            try:
                with open(path, 'rb') as f:
                    head = f.read(4)
            except Exception:
                # 连文件头都读不出（如被占用），无法判定状态
                rec['state'] = 'failed'
                raise
            if head != MAGIC:
                # 非 DGS 魔数（含空文件/不足 4 字节的极小文件），按明文跳过
                records.append(rec)
                continue
            with open(path, 'rb') as f:
                raw = f.read()
            if len(raw) <= HEADER_SIZE:
                # 头部魔数存在但不足一个完整头部，与 1.0.0 判定规则一致按明文跳过
                records.append(rec)
                continue
            rec['state'] = 'encrypted'
            if mode == 'decrypt':
                if backup:
                    # .bak 备份：原始密文字节原样写出（python 写盘无加密转换）
                    with open(path + '.bak', 'wb') as bf:
                        bf.write(raw)
                plain = decrypt(raw)
                # 先写临时文件再原子替换，中途失败不会损坏原件
                tmp = path + '.dgs-tmp'
                try:
                    with open(tmp, 'wb') as tf:
                        tf.write(plain)
                    os.replace(tmp, path)
                except Exception:
                    # 清理残留的临时文件
                    try:
                        if os.path.exists(tmp):
                            os.remove(tmp)
                    except OSError:
                        pass
                    raise
        except Exception as e:
            rec['ok'] = False
            rec['error'] = str(e)
        records.append(rec)

    # ensure_ascii=True：输出纯 ASCII JSON，规避两侧编码差异
    sys.stdout.write(json.dumps({'files': records}, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
'@

# ---------- 主流程 ----------

$ErrorActionPreference = 'Stop'

# 统计变量
$DoneCount = 0    # 发现的密文数（DryRun 时为待解密数）
$PlainCount = 0   # 明文跳过
$FailCount = 0
$FailedFiles = @()

# 获取当前终端所在目录（非脚本所在目录）
$WorkDir = (Get-Location).Path
$rootPath = $WorkDir.TrimEnd('\')

$PathMode = $false
$MissingPaths = @()
$scanList = @()

if ($Path) {
    # -p 指定路径模式：不再扫描当前目录
    $PathMode = $true
    $resolved = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        # 精确路径优先，其次按通配符展开
        if (Test-Path -LiteralPath $p) {
            $items = @(Get-Item -LiteralPath $p -ErrorAction SilentlyContinue)
        } else {
            $items = @(Get-Item -Path $p -ErrorAction SilentlyContinue)
        }
        if ($items.Count -eq 0) {
            $MissingPaths += $p
            continue
        }
        foreach ($it in $items) {
            if ($it.PSIsContainer) {
                # 目录作为扫描根；排除本工具产生的备份与临时文件
                $files = @(Get-ChildItem -LiteralPath $it.FullName -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '\.bak$' -and $_.Name -notmatch '\.dgs-tmp$' })
            } else {
                # 显式指定的文件按原样处理（即使扩展名恰好是 .bak）
                $files = @($it)
            }
            foreach ($f in $files) {
                if ($seen.Add($f.FullName)) { $resolved.Add($f) }
            }
        }
    }
    $scanList = @($resolved | Sort-Object FullName)
} else {
    # 扫描当前目录全部文件（默认仅当前目录；-r 递归全部子目录），不按扩展名过滤
    $scanList = @(Get-ChildItem -LiteralPath $WorkDir -File -Recurse:$Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)

    # 排除本工具产生的备份与临时文件
    $scanList = @($scanList | Where-Object { $_.Name -notmatch '\.bak$' -and $_.Name -notmatch '\.dgs-tmp$' })
}

# 文件名过滤（-n：多个文件名，支持通配符，按文件名匹配不含路径）
$names = @()
if ($Name) {
    $names = @($Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($names.Count -gt 0) {
        $scanList = @($scanList | Where-Object {
            $f = $_.Name
            @($names | Where-Object { $f -like $_ }).Count -gt 0
        })
    }
}

if ($MissingPaths.Count -gt 0) {
    Write-ToolkitMessage -Kind Error -Text "错误：以下路径不存在或无匹配项："
    foreach ($mp in $MissingPaths) { Write-ToolkitMessage -Kind Error -Text "  - $mp" }
}

if ($scanList.Count -eq 0) {
    if ($names.Count -gt 0) {
        Write-ToolkitMessage -Kind Error -Text "错误：未找到匹配的文件（过滤条件: $($names -join ', ')）。"
    } elseif (-not $PathMode) {
        Write-ToolkitMessage -Kind Error -Text "错误：当前目录下未找到任何文件。"
    } elseif ($MissingPaths.Count -eq 0) {
        Write-ToolkitMessage -Kind Error -Text "错误：指定路径中未找到任何文件。"
    }
    # -Path 模式下缺失路径已在上面逐项报告
    exit 1
}

# python 依赖检测：密文 I/O 必须由非白名单进程完成，pwsh 内无法替代
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-ToolkitMessage -Kind Error -Text "错误：未找到 python 命令。DGS 密文的读取与解密必须经由非白名单进程（python）完成，请先安装 Python 并加入 PATH。"
    exit 1
}

if ($PathMode) {
    Write-ToolkitMessage -Kind Info -Text "指定路径: $($Path -join ', ')"
    Write-ToolkitMessage -Kind Info -Text "待处理文件: $($scanList.Count) 个$(if ($Recurse) { '（目录递归含所有子目录）' })"
} elseif ($Recurse) {
    Write-ToolkitMessage -Kind Info -Text "待扫描文件: $($scanList.Count) 个（递归含所有子目录）"
} else {
    Write-ToolkitMessage -Kind Info -Text "待扫描文件: $($scanList.Count) 个（仅当前目录）"
}
if ($names.Count -gt 0) { Write-ToolkitMessage -Kind Info -Text "文件名过滤: $($names -join ', ')" }
if ($DryRun) { Write-ToolkitMessage -Kind Warning -Text "当前为 [DryRun] 只检测模式，不会修改任何文件" }
if ($Backup) { Write-ToolkitMessage -Kind Warning -Text "已启用备份：替换前将为每个密文生成 .bak 备份" }

# DGS 参数从本地 .env 读取；真实文件不入库，模板见 config/dgs.env.example
$dgsEnvPath = Join-Path $toolkitRoot 'config\dgs.env'
if (-not (Test-Path -LiteralPath $dgsEnvPath)) {
    Write-ToolkitMessage -Kind Error -Text "错误：未找到 DGS 参数文件：$dgsEnvPath"
    Write-ToolkitMessage -Kind Error -Text "请复制 config\dgs.env.example 为 config\dgs.env，并填入实际值。"
    exit 1
}
try {
    $dgsEnv = Read-ToolkitEnvFile -Path $dgsEnvPath
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误：读取 DGS 参数文件失败：$($_.Exception.Message)"
    exit 1
}

$dgsMagic = [string]$dgsEnv['DGS_MAGIC']
$dgsSeed = [string]$dgsEnv['DGS_SEED']
$dgsMask = [string]$dgsEnv['DGS_MASK']
$dgsHeaderSize = [string]$dgsEnv['DGS_HEADER_SIZE']
$dgsKeyOffset = [string]$dgsEnv['DGS_KEY_OFFSET']
$dgsKeyLen = [string]$dgsEnv['DGS_KEY_LEN']
$dgsChunk = [string]$dgsEnv['DGS_CHUNK']

if ($dgsMagic -notmatch '^[0-9A-Fa-f]{8}$') {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_MAGIC 必须是 4 字节十六进制（8 个字符）。"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($dgsSeed)) {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_SEED 不能为空。"
    exit 1
}
if ($dgsMask -notmatch '^[0-9A-Fa-f]{64}$') {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_MASK 必须是 32 字节十六进制（64 个字符）。"
    exit 1
}
foreach ($name in @('DGS_HEADER_SIZE', 'DGS_KEY_OFFSET', 'DGS_KEY_LEN', 'DGS_CHUNK')) {
    $value = [string]$dgsEnv[$name]
    if ($value -notmatch '^\d+$') {
        Write-ToolkitMessage -Kind Error -Text "错误：$name 必须是非负整数。"
        exit 1
    }
}
$headerSizeValue = [int]$dgsHeaderSize
$keyOffsetValue = [int]$dgsKeyOffset
$keyLenValue = [int]$dgsKeyLen
if ($keyOffsetValue + $keyLenValue -gt $headerSizeValue) {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_KEY_OFFSET + DGS_KEY_LEN 不能超过 DGS_HEADER_SIZE。"
    exit 1
}
if ([int]$dgsChunk -lt 1) {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_CHUNK 必须大于 0。"
    exit 1
}

# 通过环境变量传给 worker，避免密钥写入临时文件
$env:DGS_MAGIC = $dgsMagic
$env:DGS_HEADER_SIZE = $dgsHeaderSize
$env:DGS_KEY_OFFSET = $dgsKeyOffset
$env:DGS_KEY_LEN = $dgsKeyLen
$env:DGS_CHUNK = $dgsChunk
$env:DGS_SEED = $dgsSeed
$env:DGS_MASK = $dgsMask

# 材料化 worker 与文件清单（UTF-8 无 BOM），执行后解析 JSON 结果
$tmpBase = Join-Path ([IO.Path]::GetTempPath()) ("dgs-decrypt-{0}-{1}" -f $PID, (Get-Random))
$workerFile = "$tmpBase.py"
$listFile = "$tmpBase.list"
try {
    [IO.File]::WriteAllText($workerFile, $DgsWorkerPy, [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($listFile, @($scanList | ForEach-Object { $_.FullName }), [System.Text.UTF8Encoding]::new($false))

    $workerMode = 'decrypt'
    if ($DryRun) { $workerMode = 'scan' }
    $pyArgs = @($workerFile, '--mode', $workerMode, '--list', $listFile)
    if ($Backup) { $pyArgs += '--backup' }

    $out = & $pythonCmd.Source @pyArgs
    if ($LASTEXITCODE -ne 0) {
        Write-ToolkitMessage -Kind Error -Text "错误：解密 worker 执行失败（python 退出码 $LASTEXITCODE）。若已安装 Python 仍报错，请确认 python 命令可用（Microsoft Store 的占位别名无效）。"
        exit 1
    }

    $report = ($out -join "`n") | ConvertFrom-Json
} catch {
    Write-ToolkitMessage -Kind Error -Text "错误：解密 worker 运行异常：$($_.Exception.Message)"
    exit 1
} finally {
    $null = Remove-Item -LiteralPath $workerFile, $listFile -Force -ErrorAction SilentlyContinue
}

# 按 worker 返回的磁盘真实状态统计报告（pwsh 自身读到的内容已被 DLP 驱动透明解密，不可作为判据）
$recMap = @{}
foreach ($rec in $report.files) { $recMap[$rec.path] = $rec }

# DryRun 列表标题
if ($DryRun) {
    Write-Host ""
    Write-ToolkitMessage -Kind Warning -Text "发现 DGS 密文文件:"
}

foreach ($f in $scanList) {
    # 指定路径模式显示完整路径，扫描模式显示相对当前目录的路径
    $displayFile = if ($PathMode) { $f.FullName } else { Get-RelativePath $f.FullName $rootPath }
    $rec = $recMap[$f.FullName]
    if (-not $rec) {
        # worker 未返回该文件的结果（不应发生），按失败计
        $FailCount++
        Write-ToolkitMessage -Kind Error -Text ("  - " + $displayFile + "  失败: worker 未返回结果")
        $FailedFiles += "$($displayFile) - worker 未返回结果"
        continue
    }
    switch ($rec.state) {
        'plain' {
            $PlainCount++
            # 指定路径模式下逐文件给出结果，便于 Agent 判断；扫描模式保持安静
            if ($PathMode -and -not $DryRun) {
                Write-ToolkitMessage -Color DarkGray -Text ("  - " + $displayFile + "  明文，无需处理")
            }
        }
        'encrypted' {
            $DoneCount++
            if ($DryRun) {
                Write-ToolkitMessage -Kind Warning -Text ("  - " + $displayFile)
            } elseif ($rec.ok) {
                $result = "已解密并原位替换"
                if ($Backup) { $result += " [已备份 .bak]" }
                Write-ToolkitMessage -Kind Success -Text ("  - " + $displayFile + "  " + $result)
            } else {
                $FailCount++
                Write-ToolkitMessage -Kind Error -Text ("  - " + $displayFile + "  失败: " + $rec.error)
                $FailedFiles += "$($displayFile) - $($rec.error)"
            }
        }
        default {
            # failed：连文件头都读不出（如被占用），无法判定状态
            $FailCount++
            Write-ToolkitMessage -Kind Error -Text ("  - " + $displayFile + "  失败: " + $rec.error)
            $FailedFiles += "$($displayFile) - $($rec.error)"
        }
    }
}

# ---------- 统计报告 ----------
Write-Host ""
Write-ToolkitMessage -Kind Info -Text "================ 结果统计 ================"
if ($PathMode) {
    Write-Host "指定路径: $($Path -join ', ')"
} else {
    Write-Host "处理目录: $WorkDir"
}
Write-Host "扫描文件: $($scanList.Count)"
if ($names.Count -gt 0) {
    Write-Host "名称过滤: $($names -join ', ')"
}
if ($DryRun) {
    Write-ToolkitMessage -Kind Success -Text "发现密文: $DoneCount"
} else {
    Write-ToolkitMessage -Kind Success -Text "解密替换: $DoneCount"
}
Write-ToolkitMessage -Kind Success -Text "明文跳过: $PlainCount"
if ($FailCount -gt 0) {
    Write-ToolkitMessage -Kind Error -Text "失败数量: $FailCount"

    Write-Host ""
    Write-ToolkitMessage -Kind Warning -Text "失败文件列表:"
    foreach ($FailedFile in $FailedFiles) {
        Write-ToolkitMessage -Color DarkGray -Text "  - $FailedFile"
    }
} else {
    Write-ToolkitMessage -Kind Success -Text "失败数量: 0"
}
Write-ToolkitMessage -Kind Info -Text "=========================================="

# 指定路径模式的严格退出码契约（供 Agent 自动判定）：
# 所有目标在处理后均为明文（含原本就是明文）且没有缺失路径 → 0，否则 → 1
if ($PathMode -and ($FailCount -gt 0 -or $MissingPaths.Count -gt 0)) {
    exit 1
}
