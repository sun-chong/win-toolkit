---
name: pwsh-verify
description: 验证本仓库的 PowerShell 脚本改动。修改或新增 .ps1 后、声称完成前使用，做语法解析校验、PSScriptAnalyzer 递归静态检查与冒烟测试；改动 lib/ 公共组件时另查导出登记、兼容性与版本号。
---

# pwsh-verify — PowerShell 脚本验证

规则以仓库 `AGENTS.md` 为准。本仓库无测试框架，验证靠「语法能过 + 静态检查干净 + 脚本能跑起来」。对改动/新增的 `.ps1` 依次执行以下三层验证。

## 1. 语法解析校验

对待验证文件逐个运行解析器（替换为实际文件绝对路径）：

```bash
pwsh -NoProfile -Command '
$files = @(
  "cli-tools/xxx.ps1"   # 替换为实际改动文件，相对仓库根目录
)
foreach ($f in $files) {
  $e = $null; $t = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$t, [ref]$e)
  if ($e.Count) { Write-Output "FAIL $f"; $e | ForEach-Object { Write-Output ("  " + $_.Message) } }
  else { Write-Output "OK   $f" }
}'
```

出现任何 `FAIL` 必须先修复再继续。

## 2. 静态检查（PSScriptAnalyzer）

递归覆盖 `cli-tools/`、`lib/`、`maintenance/`，排除 `.archive/` 与 `.scratch/`。用仓库根目录的配置文件运行（已排除 WriteHost / BOM / ShouldProcess / 复数命名 / 动词白名单）：

```bash
pwsh -NoProfile -Command '
Import-Module PSScriptAnalyzer
$root = (Get-Location).Path
$files = Get-ChildItem -Path $root -Recurse -Filter *.ps1 -File |
  Where-Object { $_.FullName -notmatch "\\\\(\.archive|\.scratch|\.agents|\.superpowers)\\\\" }
$files | ForEach-Object {
  Invoke-ScriptAnalyzer -Path $_.FullName -Settings (Join-Path $root "PSScriptAnalyzerSettings.psd1")
} | ForEach-Object { Write-Output ($_.RuleName + " | " + $_.ScriptName + ":" + $_.Line + " | " + $_.Message) }'
```

关注**本次改动新引入**的告警。已知的存量告警（可忽略，均为刻意写法）：

- `ef.ps1`、`v2p.ps1` — 空 catch，用于 Ctrl+C 静默退出 / COM 对象清理

## 3. 冒烟测试

语法与静态检查通过后，在 PowerShell 7 下实际加载受影响脚本：

- `util` 与 `util lib` 必须正常输出清单。
- 带 `-h` 的脚本：`pwsh -NoProfile -File <script> -h`，确认帮助正常输出、无异常。
- **有副作用的脚本不要直接执行**（如 `au` 改代理、`tsd` 定时关机、`excel-unlink` 改文件、`ghup` 会写状态并发起网络请求）。改为检查其 `-h` 输出或阅读代码确认逻辑；确需真实运行前先向用户确认。
- 依赖外部命令（`fzf` / `gh` / `es` / `z`）的脚本：确认依赖缺失时有中文报错提示，而非崩溃或静默失败。
- 新增工具：确认 `util` 清单中该工具出现且简介非空（`.SYNOPSIS` 解析成功）。

## 4. 公共库（lib/）专项验证

改动 `lib/` 时，在上面三层之外逐项检查（规则见 `AGENTS.md`「公共组件规则」与 `lib/README.md`）：

- **导出登记**：新增函数已在 `Toolkit.psd1` 的 `FunctionsToExport` 中显式登记（禁止 `*`）；内部辅助函数未登记。
- **兼容性**：没有删除或改名导出函数；行为变更走了新函数名，旧函数标 `[Obsolete]` 转调。
- **版本号**：`ModuleVersion` 与变更类型匹配——删除/重命名导出函数 = 主版本 +1，新增导出函数或新增参数 = 次版本 +1，内部调整 = 修订号 +1。
- **帮助可读**：`util lib <函数名>` 能输出完整帮助（`Get-Help -Full` 可读、`.SYNOPSIS` 非空）。
- **引用方冒烟**：找出所有调用该函数的脚本（如 `grep -rn "<函数名>" cli-tools maintenance system-init`），逐个确认仍能正常运行；有副作用的只跑 `-h` 或读代码确认。
- **领域表同步**：`lib/` 根目录每个 `*.ps1` 都在 `lib/README.md` 领域表中有条目（`bin/` 除外）。

## 5. 报告

逐个文件给出「语法 / 静态检查 / 冒烟测试」结论。若某脚本因副作用无法安全运行，明确说明「未实际运行」及原因——不要声称已验证。
