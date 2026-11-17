<#
.SYNOPSIS
    DGS 透明加密文件批量解密（原位替换）

.DESCRIPTION
    扫描当前目录下的 DGS 透明加密文件（深信服 DLP / Agile DGS，文件头特征由
    config/dgs.env 提供），解密后原位替换为明文。也可用 -p 指定任意位置的文件或目录，
    便于 Agent 自动调用。不按扩展名过滤——由 worker 读取磁盘真实文件头判断是否为密文；
    目录扫描包含隐藏文件（Get-ChildItem -Force）。

    重要：深信服 DLP 驱动对白名单进程（pwsh）读时透明解密、写时透明加密——pwsh 读到的
    不是磁盘真实密文，写出的明文也会被驱动再次加密落盘。因此本工具的全部磁盘 I/O 与
    RC4 解密均在内嵌的 Python worker（非白名单进程）中完成，pwsh 仅负责扫描、参数解析
    与结果报告。运行依赖 python 命令（非白名单进程即可）。

    安全：解密结果会按扩展名做文件头校验（zip / pdf / OLE2 等常见格式），校验失败说明
    密钥或格式可能已变更，此时保留原密文不替换，避免把乱码写回原件。

    注意：原位替换后明文将脱离 DLP 透明加密直接落盘，请确认文件用途后再操作。
    建议先加 -d 预览，或加 -b 在替换前生成 .bak 密文备份（还原时将备份文件改回原名即可；
    已存在的 .bak 不会被覆盖，同名备份按内容复用或编号为 .bak.1、.bak.2……）。

    退出码（扫描与 -p 模式一致）：
    0  全部目标均为明文（含原本就是明文）
    1  存在失败或路径缺失
    2  仅 -d 模式：发现密文（便于自动化判断；存在失败时仍返回 1）

    使用方式：
    - dgs-decrypt                      处理当前目录下全部密文文件
    - dgs-decrypt -r                   递归处理全部子目录
    - dgs-decrypt -d                   只检测不修改（安全预览）
    - dgs-decrypt -b                   替换前为每个密文生成 .bak 备份
    - dgs-decrypt -n 文件1,文件2       只处理指定文件名（支持通配符，如 *.pdf）
    - dgs-decrypt -p 路径1,路径2       处理指定文件或目录（可位于任意位置，供 Agent 调用）
    - dgs-decrypt -h                   显示帮助信息

.PARAMETER Path
    处理指定的文件或目录（绝对路径或相对当前目录），不再扫描当前目录。
    多个路径用逗号分隔（PowerShell 数组语法），如 -p "a.docx","b 目录"；不要用空格分隔，
    否则第二个值会被当作位置参数而报错。文件直接处理；目录作为扫描根（配合 -r 递归）。
    路径不存在会报错并以退出码 1 结束。
    退出码见 .DESCRIPTION：全部目标均为明文为 0，存在失败或缺失路径为 1。
    短参数：-p
    示例：dgs-decrypt -p "D:\资料\合同.xlsx"
    示例：dgs-decrypt -p "D:\资料\合同.xlsx","D:\资料\报表目录" -r -b

.PARAMETER Recurse
    递归处理当前目录及全部子目录
    短参数：-r
    示例：dgs-decrypt -r

.PARAMETER DryRun
    只检测不修改，列出发现的密文文件（可与 -r / -n 搭配使用）
    发现密文时退出码为 2，便于自动化判断；存在读取失败或路径缺失时仍为 1。
    短参数：-d
    示例：dgs-decrypt -d -r

.PARAMETER Backup
    原位替换前为每个密文文件生成同名 .bak 备份（.bak 内容为原始密文）。
    已存在备份时绝不覆盖：内容相同则复用，内容不同则自动编号为 .bak.1、.bak.2……
    短参数：-b
    示例：dgs-decrypt -b

.PARAMETER Name
    只处理指定文件名的文件，多个文件名用逗号分隔（PowerShell 数组语法），支持通配符
    短参数：-n
    示例：dgs-decrypt -n 报告.docx,合同.pdf
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
    dgs-decrypt -p "D:\资料\合同.xlsx","D:\资料\报表目录" -r
    解密指定文件与指定目录下的全部密文（多个路径用逗号分隔，Agent 调用场景按退出码判定结果）

.NOTES
    Author: SUNC
    Version: 1.4.2

    变更记录：
    1.4.2 (SUNC) — 代码清理：worker 单文件处理收敛为 process_one 并删除可推导的 ok 字段；
    解密改为 memoryview + 预分配缓冲，峰值内存由约 4N 降到 2N；PLAIN_MAGIC 去重；
    扫描与产物排除规则合并为 Get-DgsScanFiles；报告循环按 error 统一失败分支，失败数
    由列表派生；DGS_* 环境变量快照/设置/恢复合并为一个循环并移入 try；python 检测去掉
    额外进程探测，改用 CommandType 与 WindowsApps 路径判断；-p 路径解析去掉重复的
    Test-Path。
    1.4.1 (SUNC) — 代码审查修复：备份改为解密校验通过后才创建，失败时报告已生成的
    备份；备份文件名用 -LiteralPath 解析（兼容含 [ ] 的路径）；DGS_* 环境变量执行后
    恢复原值而非直接删除；校验 python 为可执行文件；校验 DGS_SEED 为可打印 ASCII；
    修正 $DoneCount 注释。
    1.4.0 (SUNC) — 备份改为不覆盖策略：.bak 已存在时，内容相同则复用，内容不同自动
    编号为 .bak.1、.bak.2……；扫描排除规则同步覆盖编号备份；解密报告显示实际备份名。
    1.3.0 (SUNC) — 修复：隐藏文件在目录扫描中被跳过、-p 显式指定时报“路径不存在”
    （Get-ChildItem / Test-Path / Get-Item 补 -Force）；失败项被计入“解密替换”统计；
    扫描模式解密失败仍返回 0；只读目标替换失败；-p 空格分隔的第二个路径被静默绑定
    为 -n 过滤器（现改为报错并提示用逗号分隔）。新增：解密结果按扩展名做文件头校验，
    校验失败保留原密文；-d 模式发现密文返回退出码 2；DryRun 不再整读文件；
    worker 执行后清理 DGS_* 环境变量；校验 DGS_KEY_LEN 必须为 32。
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
    [Parameter(Position = 0)]
    [Alias("p")]
    [string[]]$Path,

    [Alias("r")]
    [switch]$Recurse,

    [Alias("d")]
    [switch]$DryRun,

    [Alias("b")]
    [switch]$Backup,

    # 数组参数的多值写法统一为逗号分隔（-p a,b / -n a,b）。
    # PowerShell 仍会把 -p 后空格分隔的第二个值绑定到 -n，脚本开头有防呆检测兜底
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
import stat
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

# 常见格式解密后的文件头特征：用于识别密钥/格式变化导致的乱码，避免写回原件。
# 未列出的扩展名不做校验；只做宽松匹配，避免误伤同扩展名的合法变体。
PK = b'PK'
OLE2 = b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1'
PLAIN_MAGIC = {ext: PK for ext in (
    '.zip', '.docx', '.docm', '.dotx', '.xlsx', '.xlsm', '.xltx',
    '.pptx', '.pptm', '.potx')}
PLAIN_MAGIC.update({ext: OLE2 for ext in ('.doc', '.dot', '.xls', '.xlt', '.ppt', '.pps')})
PLAIN_MAGIC['.pdf'] = b'%PDF'


def validate_plain(path, plain):
    # 按扩展名校验解密结果；未知扩展名不判断。返回错误信息，None 表示通过
    magic = PLAIN_MAGIC.get(os.path.splitext(path)[1].lower())
    if magic is None or plain[:len(magic)] == magic:
        return None
    return ('解密结果校验失败：%s 的文件头与扩展名不匹配（可能密钥或格式已变更），'
            '已保留原密文' % os.path.basename(path))


def replace_atomic(tmp, path):
    # 原子替换；Windows 下目标只读时先清除只读位再重试
    try:
        os.replace(tmp, path)
        return
    except PermissionError:
        if os.name != 'nt' or not os.path.exists(path):
            raise
    mode = os.stat(path).st_mode
    os.chmod(path, mode | stat.S_IWRITE)
    try:
        os.replace(tmp, path)
    except Exception:
        # 重试失败时恢复原属性，避免留下被改动权限的原件
        try:
            os.chmod(path, mode)
        except OSError:
            pass
        raise


def same_file_content(path, data):
    # 分块比较文件内容与字节串，避免为比对大备份再整读一份
    try:
        if os.path.getsize(path) != len(data):
            return False
        with open(path, 'rb') as f:
            offset = 0
            while offset < len(data):
                chunk = f.read(1024 * 1024)
                if not chunk or chunk != data[offset:offset + len(chunk)]:
                    return False
                offset += len(chunk)
        return True
    except OSError:
        return False


def ensure_backup(path, raw):
    # 备份已存在时绝不覆盖：内容相同则复用，否则自动编号 .bak.1、.bak.2……
    # 使用 'xb' 独占创建，即使并发处理也不会覆盖已有备份
    base = path + '.bak'
    if os.path.exists(base) and same_file_content(base, raw):
        return base, False
    bak = base
    n = 0
    while True:
        try:
            with open(bak, 'xb') as bf:
                bf.write(raw)
            return bak, True
        except FileExistsError:
            n += 1
            bak = '%s.%d' % (base, n)


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
    payload = memoryview(raw)[HEADER_SIZE:]
    out = bytearray(len(payload))
    for off in range(0, len(payload), CHUNK):
        out[off:off + CHUNK] = rc4(payload[off:off + CHUNK], content_key)
    return out


def process_one(path, mode, backup):
    # 单个文件的检测/解密；返回记录，error 非空表示失败
    rec = {'path': path, 'state': 'plain', 'error': None,
           'backup': None, 'backup_created': False}
    try:
        with open(path, 'rb') as f:
            head = f.read(4)
            if head != MAGIC:
                # 非 DGS 魔数（含空文件/不足 4 字节的极小文件），按明文跳过
                return rec
            if mode == 'scan':
                # 只检测：不整读文件，用文件大小判断是否具备完整头部
                if os.fstat(f.fileno()).st_size > HEADER_SIZE:
                    rec['state'] = 'encrypted'
                return rec
            f.seek(0)
            raw = f.read()
        if len(raw) <= HEADER_SIZE:
            # 头部魔数存在但不足一个完整头部，与 1.0.0 判定规则一致按明文跳过
            return rec
        rec['state'] = 'encrypted'
        plain = decrypt(raw)
        invalid = validate_plain(path, plain)
        if invalid:
            # 解密结果与扩展名不符：保留原密文，避免损坏原件
            rec['error'] = invalid
            return rec
        if backup:
            # 仅在即将替换时备份原始密文；已存在同名备份时不覆盖
            rec['backup'], rec['backup_created'] = ensure_backup(path, raw)
        # 先写临时文件再原子替换，中途失败不会损坏原件
        tmp = path + '.dgs-tmp'
        try:
            with open(tmp, 'wb') as tf:
                tf.write(plain)
            replace_atomic(tmp, path)
        except Exception:
            # 清理残留的临时文件
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
    except PermissionError:
        if rec['state'] != 'encrypted':
            rec['state'] = 'failed'
        rec['error'] = '拒绝访问：文件只读或被其他程序占用，请关闭占用程序后重试'
    except Exception as e:
        if rec['state'] != 'encrypted':
            rec['state'] = 'failed'
        rec['error'] = str(e)
    return rec


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

    records = [process_one(p, mode, backup) for p in paths]

    # ensure_ascii=True：输出纯 ASCII JSON，规避两侧编码差异
    sys.stdout.write(json.dumps({'files': records}, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
'@

# ---------- 主流程 ----------

$ErrorActionPreference = 'Stop'

# 防呆：-n 只接受文件名。空格分隔的多值会在参数绑定阶段报错（Name 不是位置参数），
# 这里额外拦截显式把路径传给 -n 的用法，提示改用逗号分隔。
if ($Name) {
    $pathLikeNames = @($Name | Where-Object { $_ -match '[\\/:]' })
    if ($pathLikeNames.Count -gt 0) {
        Write-ToolkitMessage -Kind Error -Text "错误：-n 只接受文件名，检测到路径值：$($pathLikeNames -join ', ')"
        Write-ToolkitMessage -Kind Error -Text "多个路径请用逗号分隔，如：dgs-decrypt -p '路径1','路径2'"
        exit 1
    }
}

# 统计变量
$DoneCount = 0    # DryRun 时为发现的密文数；实际运行时为成功解密数
$PlainCount = 0   # 明文跳过
$FailedFiles = @()

# 获取当前终端所在目录（非脚本所在目录）
$WorkDir = (Get-Location).Path
$rootPath = $WorkDir.TrimEnd('\')

$PathMode = $false
$MissingPaths = @()
$scanList = @()

# 本工具产生的备份与临时文件（.bak / .bak.N / .dgs-tmp），目录扫描时排除
$toolArtifactName = '\.(?:bak(?:\.\d+)?|dgs-tmp)$'

# 目录扫描：包含隐藏文件，排除本工具产物；-p 显式指定的单个文件不经过此函数
function Get-DgsScanFiles {
    param([string]$Root, [switch]$Recurse)

    return @(Get-ChildItem -LiteralPath $Root -File -Recurse:$Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $toolArtifactName } | Sort-Object FullName)
}

if ($Path) {
    # -p 指定路径模式：不再扫描当前目录
    $PathMode = $true
    $resolved = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        # 精确路径优先；取不到再按通配符展开。Get-Item 需要 -Force 才能命中隐藏文件
        $items = @(Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue)
        if ($items.Count -eq 0) {
            $items = @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)
        }
        if ($items.Count -eq 0) {
            $MissingPaths += $p
            continue
        }
        foreach ($it in $items) {
            if ($it.PSIsContainer) {
                # 目录作为扫描根
                $files = @(Get-DgsScanFiles -Root $it.FullName -Recurse:$Recurse)
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
    $scanList = @(Get-DgsScanFiles -Root $WorkDir -Recurse:$Recurse)
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
if (-not (Test-ExternalCommand -Name 'python')) {
    Write-ToolkitMessage -Kind Error -Text "错误：未找到 python 命令。DGS 密文的读取与解密必须经由非白名单进程（python）完成，请先安装 Python 并加入 PATH。"
    exit 1
}
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
# 必须是可执行文件：函数/别名没有 .Source，无法作为外部进程的宿主
if (-not $pythonCmd -or $pythonCmd.CommandType -ne 'Application') {
    Write-ToolkitMessage -Kind Error -Text "错误：python 不是可执行文件（当前类型: $($pythonCmd.CommandType)），无法作为 worker 宿主。"
    exit 1
}
# Microsoft Store 的占位别名位于 WindowsApps 下，执行时只会打开应用商店
if ($pythonCmd.Source -like '*\Microsoft\WindowsApps\*') {
    Write-ToolkitMessage -Kind Error -Text "错误：python 指向 Microsoft Store 占位别名。请安装 Python，并在系统设置中关闭 python 的应用执行别名。"
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
if ($Backup -and -not $DryRun) { Write-ToolkitMessage -Kind Warning -Text "已启用备份：替换前将为每个密文生成 .bak 备份" }
if ($Backup -and $DryRun) { Write-ToolkitMessage -Kind Warning -Text "DryRun 模式不生成备份" }

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
if ($dgsSeed -notmatch '^[\x20-\x7E]+$') {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_SEED 必须是可打印 ASCII 字符串（与 dgs-encrypted-files 的密钥派生保持一致）。"
    exit 1
}
if ($dgsMask -notmatch '^[0-9A-Fa-f]{64}$') {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_MASK 必须是 32 字节十六进制（64 个字符）。"
    exit 1
}
foreach ($envKey in @('DGS_HEADER_SIZE', 'DGS_KEY_OFFSET', 'DGS_KEY_LEN', 'DGS_CHUNK')) {
    $value = [string]$dgsEnv[$envKey]
    if ($value -notmatch '^\d+$') {
        Write-ToolkitMessage -Kind Error -Text "错误：$envKey 必须是非负整数。"
        exit 1
    }
}
$headerSizeValue = [int]$dgsHeaderSize
$keyOffsetValue = [int]$dgsKeyOffset
$keyLenValue = [int]$dgsKeyLen
if ($keyLenValue -ne 32) {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_KEY_LEN 必须为 32（与 DGS_MASK 长度一致）。"
    exit 1
}
if ($keyOffsetValue + $keyLenValue -gt $headerSizeValue) {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_KEY_OFFSET + DGS_KEY_LEN 不能超过 DGS_HEADER_SIZE。"
    exit 1
}
if ([int]$dgsChunk -lt 1) {
    Write-ToolkitMessage -Kind Error -Text "错误：DGS_CHUNK 必须大于 0。"
    exit 1
}

# 通过环境变量传给 worker，避免密钥写入临时文件；快照与赋值统一在 try 内完成
$dgsEnvValues = [ordered]@{
    DGS_MAGIC       = $dgsMagic
    DGS_HEADER_SIZE = $dgsHeaderSize
    DGS_KEY_OFFSET  = $dgsKeyOffset
    DGS_KEY_LEN     = $dgsKeyLen
    DGS_CHUNK       = $dgsChunk
    DGS_SEED        = $dgsSeed
    DGS_MASK        = $dgsMask
}
$dgsEnvBackup = @{}

# 材料化 worker 与文件清单（UTF-8 无 BOM），执行后解析 JSON 结果
$tmpBase = Join-Path ([IO.Path]::GetTempPath()) ("dgs-decrypt-{0}-{1}" -f $PID, (Get-Random))
$workerFile = "$tmpBase.py"
$listFile = "$tmpBase.list"
try {
    foreach ($envKey in $dgsEnvValues.Keys) {
        $dgsEnvBackup[$envKey] = [Environment]::GetEnvironmentVariable($envKey, 'Process')
        [Environment]::SetEnvironmentVariable($envKey, [string]$dgsEnvValues[$envKey], 'Process')
    }
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
    # 恢复 worker 执行前的 DGS_* 环境变量（null 表示删除）
    foreach ($envKey in $dgsEnvValues.Keys) {
        [Environment]::SetEnvironmentVariable($envKey, $dgsEnvBackup[$envKey], 'Process')
    }
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
        Write-ToolkitMessage -Kind Error -Text ("  - " + $displayFile + "  失败: worker 未返回结果")
        $FailedFiles += "$($displayFile) - worker 未返回结果"
        continue
    }
    if ($rec.error) {
        # 处理失败（含 failed 状态）统一在这里报告
        $failText = "  - " + $displayFile + "  失败: " + $rec.error
        if ($rec.backup) {
            $failText += "（备份: " + [IO.Path]::GetFileName($rec.backup) + "）"
        }
        Write-ToolkitMessage -Kind Error -Text $failText
        $FailedFiles += "$($displayFile) - $($rec.error)"
    } elseif ($rec.state -eq 'plain') {
        $PlainCount++
        # 指定路径模式下逐文件给出结果，便于 Agent 判断；扫描模式保持安静
        if ($PathMode -and -not $DryRun) {
            Write-ToolkitMessage -Color DarkGray -Text ("  - " + $displayFile + "  明文，无需处理")
        }
    } else {
        # encrypted 且无错误：DryRun 列出，实际解密报告成功
        $DoneCount++
        if ($DryRun) {
            Write-ToolkitMessage -Kind Warning -Text ("  - " + $displayFile)
        } else {
            $result = "已解密并原位替换"
            if ($rec.backup) {
                $bakName = [IO.Path]::GetFileName($rec.backup)
                $bakState = if ($rec.backup_created) { '已备份' } else { '已有相同备份' }
                $result += " [$bakState $bakName]"
            }
            Write-ToolkitMessage -Kind Success -Text ("  - " + $displayFile + "  " + $result)
        }
    }
}
# 失败数由失败列表派生，避免多处递增漏改
$FailCount = $FailedFiles.Count

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

# 退出码契约（扫描与 -p 模式一致，供 Agent 自动判定）：
# 全部目标均为明文（含原本就是明文）→ 0；存在失败或缺失路径 → 1；
# 仅 -d 模式发现密文 → 2（存在失败时 1 优先）
if ($FailCount -gt 0 -or $MissingPaths.Count -gt 0) {
    exit 1
}
if ($DryRun -and $DoneCount -gt 0) {
    exit 2
}
