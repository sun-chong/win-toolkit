---
name: pwsh-new-script
description: 在本仓库新增一个 PowerShell 脚本，按仓库约定选择归属目录、引入 Toolkit 公共库、生成中文 .SYNOPSIS 与统一帮助，并把可复用的通用逻辑沉淀进 lib/ 公共组件。当用户要添加新的命令行工具、维护脚本或抽取公共函数时使用。
---

# pwsh-new-script — 新增脚本

规则以仓库 `AGENTS.md` 为准；本技能只提供步骤与模板。

## 步骤

1. **定归属**：一次性/交互式工具 → `cli-tools/`；周期性维护 → `maintenance/`；新机初始化 → `system-init/`。需要分类时在 `cli-tools/` 下建子目录，`util` 会显示为 `分类/工具名`。
2. **先检索公共组件**：运行 `util lib` 查看全部公共函数；命中就直接 `Import-Module` 使用，不重复实现。脚本中出现值得下沉的通用逻辑时，按下方「公共组件」处理。
3. 创建 `<归属目录>/<工具名>.ps1`，**无需注册** —— `util.ps1` 递归扫描 `cli-tools/` 下的 `*.ps1`。
4. 顶部写中文 `.SYNOPSIS` 注释块：`.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` / `.NOTES`；`.SYNOPSIS` 是 `util` 清单的一句话简介，必须存在且格式正确；`.NOTES` 署名 `Author: SUNC`，版本 `Version: x.y.z`。
5. 在 `param()` 之后加入公共库引导（见模板）。
6. 帮助开关统一 `[Alias("h")] [switch]$Help`；`-h` 调用 `Show-ToolkitHelp`，禁止写硬编码帮助版式。
7. 配置分层：跨脚本配置统一写 `config/toolkit.config.jsonc`（真实配置不入库，模板为 `toolkit.config.jsonc.example`）；单脚本配置 → 同目录 `<工具名>.config.json` 或 `.config.jsonc`（优先 `.jsonc`）；运行时状态 → `Read-ToolkitState` / `Write-ToolkitState`。全部 UTF-8 无 BOM。
8. 输出与注释用中文；外部依赖缺失时给出中文提示并 `exit 1`。

## 公共组件（lib/）

权威规则见 `AGENTS.md`「公共组件规则」与 `lib/README.md`；这里是执行时需要的要点。

**何时抽取**（满足任一条即沉淀，不要留在单脚本里）：

- 同一逻辑将出现第二个调用方
- 属于横切关注点（路径、配置、输出、帮助、子进程、代理、文件、环境变量等）
- 含机器相关常量
- 需要在多个脚本间保持一致行为

**如何抽取**：

1. 放进对应的领域文件 `lib/<领域>.ps1`；不确定归属时先看 `lib/README.md` 的领域表与现有文件。新增、删除或重命名领域文件时，同步更新该表（`AGENTS.md` 不重复列出领域文件）。
2. 补 `.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` / `.NOTES`。
3. 在 `lib/Toolkit.psd1` 的 `FunctionsToExport` 中**显式**登记，禁止 `*`。
4. 内部辅助函数与导出函数放在同一领域文件内，不登记导出。
5. 运行 `util lib <函数名>` 确认 `Get-Help -Full` 可读。

**兼容与版本**：只增参数，不删、不改名；行为变更用新函数名承载，旧函数标 `[Obsolete]` 转调。删除或重命名导出函数 = `ModuleVersion` 主版本 +1；新增导出函数或新增参数 = 次版本 +1；内部调整 = 修订号 +1。

## 模板骨架

```powershell
<#
.SYNOPSIS
    一句话简介（显示在 util 清单中）
.DESCRIPTION
    详细说明这个工具做什么
.PARAMETER Help
    显示帮助信息
    短参数：-h
.EXAMPLE
    <工具名>
    示例说明
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

$helpSections = @(
    @{ Title = '使用方式'; Lines = @(
        '<工具名>            说明'
        '<工具名> -h         查看帮助信息'
    ) }
)

if ($Help) {
    Show-ToolkitHelp -Command '<工具名>' -Title '一句话标题' -Sections $helpSections
    exit 0
}

# TODO: 主逻辑
```

## 完成后

- 运行 `util` 确认新工具出现在清单且简介非空。
- 运行 `util lib` 确认公共函数清单可用。
- 运行 `/pwsh-verify` 做语法解析、递归静态检查与冒烟测试。
