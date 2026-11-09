# AGENTS.md

本文件是本仓库唯一的 AI 智能体约定。

## 项目性质

- Windows 个人脚本工具箱，技术栈为 PowerShell 7（`.ps1`）。
- 验收标准是「能正常运行」：无自动化测试，改动后按「验证改动」手动验证。
- 工具入口为 `util`（`cli-tools/util.ps1`）：递归发现 `cli-tools/` 下的 `.ps1`（排除 `.archive/`）；`util lib` 列出公共函数。

## 目录与职责

| 目录 | 职责 |
| --- | --- |
| `cli-tools/` | 可执行入口，一个 `.ps1` 一个工具；需要分类时建子目录，`util` 显示为 `分类/工具名` |
| `maintenance/` | 批量维护：`update-all`（按配置升级）、`sync-agents`（分发 Subagent 定义）、`sync-skills`（分发 Skills）；配置同目录，不进 `util` 清单；`au` 串联这三者 |
| `system-init/` | 新机初始化：`win-init.cmd` → `win-init.ps1`（兼容 5.1、提权、自举 pwsh）→ `win-init.main.ps1`（主流程）；`win-init.local.ps1` 为不入库的本机自定义步骤 |
| `lib/` | Toolkit 公共库；领域文件与职责见 `lib/README.md`；`bin/` 是独立进程入口 |
| `config/` | 跨脚本机器配置 `toolkit.config.jsonc`（不入库，模板为 `.example`） |
| `docs/` | 本地设计与 Agent 文档，不入库；`docs/agents/` 供本地 Agent 参考 |

## 新增脚本（强制约定）

1. **定归属**：一次性/交互式工具放 `cli-tools/`；周期性维护放 `maintenance/`；新机初始化放 `system-init/`。
2. **先检索公共组件**：运行 `util lib`；命中就直接 `Import-Module` 使用，不重复造轮子。通用逻辑按「公共组件」沉淀。
3. **写文件头**：中文 `.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` / `.NOTES`；`.NOTES` 固定 `Author: SUNC`、`Version: x.y.z`。`.SYNOPSIS` 缺失或格式不符会让 `util` 清单简介空白。
4. **加公共库引导**：放在 `param()` 之后（模板见下）。
5. **统一帮助**：开关为 `[Alias("h")] [switch]$Help`；新工具用 `Show-ToolkitHelp`；仍以 Comment-Based Help 描述帮助的脚本，`-h` 调 `Show-ToolkitScriptHelp`；禁止硬编码帮助版式。
6. **配置分层**：跨脚本值走 `Get-ToolkitConfig`；工具专属配置与运行时状态按「配置与路径」处理。
7. **中文与依赖**：面向用户的输出与代码注释用中文；外部依赖优先用 `Test-ExternalCommand` 检测，缺失时中文提示并 `exit 1`，不要静默失败。

### 公共库引导模板

```powershell
$toolkitRoot = $PSScriptRoot
while ($toolkitRoot -and -not (Test-Path -LiteralPath (Join-Path $toolkitRoot 'lib\Toolkit.psd1'))) {
    $toolkitRoot = Split-Path -Parent $toolkitRoot
}
if (-not $toolkitRoot) {
    Write-Host '错误：未找到公共库 lib/Toolkit.psd1；请确认脚本位于仓库内' -ForegroundColor Red
    exit 1
}
Import-Module (Join-Path $toolkitRoot 'lib\Toolkit.psd1') -Force
```

## 公共组件（lib/）

### 何时抽取

满足任一条即沉淀到 `lib/<领域>.ps1`：

- 同一逻辑将出现第二个调用方；
- 属于横切关注点（路径、配置、输出、帮助、子进程、代理、文件、管理员、环境变量）；
- 含机器相关常量；
- 需要在多个脚本间保持行为一致。

领域文件与职责以 `lib/README.md` 的领域表为唯一清单，本文件不再重复；新增、删除或重命名 `lib/*.ps1` 时只更新该表。

### 如何抽取

1. 在对应 `lib/<领域>.ps1` 增加函数，补 `.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` / `.NOTES`。
2. 在 `lib/Toolkit.psd1` 的 `FunctionsToExport` 中**显式**登记，禁止 `*`。
3. 内部辅助函数与导出函数放在同一领域文件内，不登记导出。
4. 运行 `util lib <函数名>` 确认 `Get-Help -Full` 可读。
5. 领域文件由 `lib/Toolkit.psm1` 按文件名顺序自动点源，无需改 `psm1`；不要在函数中调用 `Export-ModuleMember`，对外可见性只由 `FunctionsToExport` 控制。

### 兼容与版本

- 只增参数，不删、不改名；新参数必须有默认值。
- 行为变更用新函数名承载，旧函数标 `[Obsolete]` 转调，下一主版本删除。
- 删除或重命名导出函数 = `ModuleVersion` 主版本 +1；新增导出函数或新增参数 = 次版本 +1；内部调整 = 修订号 +1。

## 配置与路径

- 跨脚本机器值写 `config/toolkit.config.jsonc`，用 `Get-ToolkitConfig` 读取（`-Refresh` 强制重读）；真实配置不入库，模板为 `config/toolkit.config.jsonc.example`。
- 工具专属配置放同目录：`<工具名>.config.jsonc` 为真实配置（不入库），`<工具名>.config.jsonc.example` 为模板（必须入库）。用 `Resolve-ToolkitConfigPath` 解析路径（兼容 `.json`，优先 `.jsonc`），禁止手写扩展名探测。
- `system-init/win-init.local.ps1` 是本机自定义步骤，不入库；模板 `win-init.local.ps1.example` 入库。
- 运行时状态写 `%LOCALAPPDATA%\toolkit\state\<tool>.json`，用 `Read-ToolkitState` / `Write-ToolkitState`。
- 所有文本与 JSON 用 UTF-8 **无 BOM** 读写：
  `[System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))`
  例外：按天追加的日志文件（如 `sync-skills` 的 `logs/skills-<yyyyMMdd>.log`）写 UTF-8 **带 BOM**，否则记事本与 `type` 会按 ANSI 解析而显示乱码。
- 禁止字面量 `C:\Users\<用户名>`；用户目录用 `Get-ToolkitPath` 解析。`win-init.ps1` 是例外：它建立环境，允许使用 `$env:USERPROFILE`。
- `config/local.psd1` 已废弃，不再支持。

## 外部依赖

| 依赖 | 用途 |
| --- | --- |
| PowerShell 7 (`pwsh`) | 全部脚本；`win-init.ps1` 可在 Windows PowerShell 5.1 下运行并自举 |
| `fzf` | `util -f`、`ef`、`op`、`ph` 的交互选择 |
| Everything CLI (`es`) | `ef` 文件检索 |
| `gh`（需 `gh auth login`） | `ghup` 的 GitHub Release 检查 |
| `python` | `dgs-decrypt`、`ccstat`、`ppt`、`op`（拼音） |
| `npx` | `sync-skills` 分发在线 Skills |
| `winget` | `update-all` 升级、`win-init` 安装；`wglink` 依赖其便携包目录 |
| `git` | `update-all` 的 repos 阶段 |
| draw.io Desktop | `d2p` 转换 |
| Office COM | `excel-unlink`（Excel）、`v2p`（Visio） |
| VS Code (`code`) | `vsc` 打开项目 |
| Clash Verge | `au`、`ghup`、`sync-skills`、`win-init` 的代理；端口与路径见 `config/toolkit.config.jsonc` |

`update-all` 的 commands 阶段由本机配置定义，可能调用 `bun`、`uv`、`npm`、`pip` 等，不属于脚本硬依赖。

## 验证改动

无测试框架。改动 `.ps1` 后运行 `/pwsh-verify`，依次做三层验证：语法解析 → `PSScriptAnalyzer` → 冒烟。

- 静态检查递归覆盖全仓库 `*.ps1`，排除 `.archive/`、`.scratch/`、`.agents/`、`.superpowers/`，使用根目录 `PSScriptAnalyzerSettings.psd1`（已排除与本仓库约定冲突的规则）；依赖 CurrentUser 安装的 `PSScriptAnalyzer`。
- 冒烟至少运行 `util`、`util lib` 与受影响脚本的 `-h`；改动公共函数时，必须同时冒烟所有引用该函数的脚本。
- 改动 `lib/` 额外核对：新增函数已在 `Toolkit.psd1` 登记、`ModuleVersion` 按变更类型递增、`util lib <函数名>` 帮助可读、`lib/*.ps1` 与 `lib/README.md` 领域表一一对应（`bin/` 除外）。
- 不要直接执行有副作用的脚本（如 `au`、`update-all`、`tsd`、`excel-unlink`、`dgs-decrypt`、`ghup`、`win-init`）；用 `-h` 或读代码确认，确需真实运行先向用户确认。
- 冒烟 `au` / `update-all` 这类脚本时参数数组必须显式定义：`@($hash.MissingKey)` 会展开成含 `$null` 的数组，脚本将无参执行（会真的开始更新）。
- 不要声称「已验证」而未实际运行。

## 注意事项

- `.agents/skills/` 入库共享；`.claude/skills/` 由 `maintenance/sync-skills.ps1` 或 `npx skills add` 分发/链接生成，不入库。现有技能：`pwsh-new-script`（新增脚本与抽取公共组件）、`pwsh-verify`（改动验证）。
- 重命名文件/目录用 `git mv`，保留 Git 历史。

## PowerShell 踩坑记录

- `$Input`、`$input` 是 PowerShell 保留的自动变量，**禁止**用作函数参数名（函数内部会引用到空值）。
- `Write-Host` 仅用于 OSC 8 超链接、`Read-Host`/`ReadKey` 交互提示、`Write-LogLine` 与逐字符进度；其他彩色输出用 `Write-ToolkitMessage`。
- `Copy-Item -Force` 本身会覆盖目标文件，无需先 `Test-Path` + `Remove-Item`。
- JSON 值转义顺序：先 `\` -> `\\`，再 `"` -> `\"`，否则 `-replace` 会出现双重转义。
- PowerShell Comment-Based Help 仅支持特定标签（`.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` / `.NOTES` 等）；使用无效标签（如 `.AUTHOR` / `.VERSION`）会导致 `Get-Help -Full` 只显示参数签名。
- 函数内调用 `& cmd.exe /c "..."` 时，外部命令输出进入成功流，会被 `$var = FunctionCall` 捕捉。改用 `Start-Process -NoNewWindow -Wait -PassThru`，输出直达控制台，退出码从 `$process.ExitCode` 获取。
- 函数返回 `$true` / `$false` 若不处理会作为成功流打印到屏幕；用 `$null = FunctionCall` 或 `[void]FunctionCall` 丢弃。
- 处理加密文件前先用 `dgs-decrypt` 解密，禁止直接编辑密文字节；`Copy-Item` 会破坏密文，复制必须用 `[IO.File]::ReadAllBytes` + `WriteAllBytes` 字节级完成。
- 子进程调用 `npx` 时必须写 `npx --yes`：输出重定向后，缓存缺少最新版时 npx 会停在 `Ok to proceed? (y)` 等标准输入，提示又在进程退出后才回显，终端只看到超时；命令末尾的 `-y` 属于目标 CLI，不能替代。
