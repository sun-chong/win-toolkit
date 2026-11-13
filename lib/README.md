# Toolkit 公共库

`lib/` 是本仓库唯一的 PowerShell 公共组件目录，模块入口为 `Toolkit.psd1`。

## 检索

- `util lib` — 列出全部导出函数与简介
- `util lib <函数名>` — 查看完整帮助
- `Get-Command -Module Toolkit` — 在 PowerShell 内列出导出函数

## 领域

| 文件 | 职责 |
| --- | --- |
| `Path.ps1` | 逻辑目录解析、相对路径、配置路径值展开 |
| `Config.ps1` | 配置读取与路径探测、运行时状态 |
| `Output.ps1` | 语义消息、16 色语义色、ANSI 24-bit 着色与混色、显示宽度、补齐/截断/居中对齐、终端宽度读取 |
| `Help.ps1` | Comment-Based Help 解析、统一帮助渲染 |
| `Process.ps1` | 子进程、超时、外部命令检测 |
| `Proxy.ps1` | 代理探测与环境变量注入 |
| `File.ps1` | 唯一文件名、JSON 读写 |
| `Admin.ps1` | 管理员身份检测、UAC 提权重启 |
| `Environment.ps1` | 环境变量与 PATH 维护、目录变量转换、JDK/SQLcl 路径探测 |
| `bin/` | 以独立进程方式调用的入口 |

## 修改规则

以下为摘要，完整规则见 `AGENTS.md`「公共组件（lib/）」。

1. 新函数放进对应领域文件，补 `.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` / `.NOTES`。
2. 在 `Toolkit.psd1` 的 `FunctionsToExport` 中**显式**登记，禁止 `*`。
3. 内部辅助函数与导出函数放在同一领域文件内，不登记导出。
4. 只增参数、不删不改名；行为变更用新函数名承载，旧函数标 `[Obsolete]` 转调。
5. 版本号按语义化版本调整：删除或重命名导出函数 = 主版本；新增导出函数或新增参数 = 次版本；内部调整 = 修订号。
6. 修改后运行 `util lib` 与 `/pwsh-verify`，并冒烟所有引用方。
7. 领域表是领域文件的唯一清单，也是 `lib/` 领域信息的唯一来源：新增、删除或重命名 `lib/*.ps1` 时只更新本表，`AGENTS.md` 不再重复列出。
