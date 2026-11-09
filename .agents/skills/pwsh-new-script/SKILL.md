---
name: pwsh-new-script
description: 在本仓库新增一个 PowerShell 脚本，按仓库约定选择归属目录、引入 Toolkit 公共库、生成中文 .SYNOPSIS 与统一帮助，并把可复用的通用逻辑沉淀进 lib/ 公共组件。当用户要添加新的命令行工具、维护脚本或抽取公共函数时使用。
---

# pwsh-new-script — 新增脚本

新增脚本按本技能的步骤与模板执行；编写或修改任何脚本时，必须同时遵守 `AGENTS.md` 的「脚本编写约定（新增与修改均适用）」与「公共组件（lib/）」。

## 步骤

1. **先检索公共组件**：运行 `util lib` 查看全部公共函数；命中就直接 `Import-Module` 使用，不重复实现。
2. **定归属**：一次性/交互式工具 → `cli-tools/`；周期性维护 → `maintenance/`；新机初始化 → `system-init/`。需要分类时在 `cli-tools/` 下建子目录，`util` 会显示为 `分类/工具名`。
3. **创建文件**：`<归属目录>/<工具名>.ps1`，**无需注册** —— `util.ps1` 递归扫描 `cli-tools/` 下的 `*.ps1`。
4. **写头部与实现**：按 `AGENTS.md`「脚本编写约定（新增与修改均适用）」写中文文件头、帮助开关、配置分层与依赖检测；在 `param()` 之后加入公共库引导（见模板）。
5. **完成后验证**：运行 `util` 确认新工具出现在清单且简介非空；运行 `util lib` 确认公共函数清单可用；运行 `/pwsh-verify` 做语法解析、递归静态检查与冒烟测试。

## 公共组件（lib/）

何时抽取、如何抽取与版本规则见 `AGENTS.md`「公共组件（lib/）」；领域文件的唯一清单是 `lib/README.md` 的领域表。

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
