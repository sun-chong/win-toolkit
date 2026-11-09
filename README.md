# win-toolkit

Windows 个人 PowerShell 7 脚本工具箱：日常工具、批量维护与新机初始化。

## 环境要求

- Windows 10 / 11
- PowerShell 7（`pwsh`）
- 按工具需要安装：`fzf`、`es`、`gh`、`python`、`npx`、`winget`

## 快速开始

```powershell
git clone <仓库地址>
cd win-toolkit

# 首次使用：从模板创建公共配置，按需修改
Copy-Item config/toolkit.config.jsonc.example config/toolkit.config.jsonc

# 查看全部工具
pwsh -NoProfile -File cli-tools/util.ps1
```

将 `cli-tools/` 加入 `PATH` 后，可直接运行 `util`。

## 目录

```text
cli-tools/    可执行工具，一个 .ps1 一个工具
maintenance/  批量维护脚本及其配置
system-init/  新机初始化入口
lib/          Toolkit 公共库
config/       跨脚本机器配置
```

## 配置

- 公共配置：`config/toolkit.config.jsonc`，模板 `config/toolkit.config.jsonc.example`
- 工具配置：同目录 `*.config.jsonc`，模板 `*.config.jsonc.example`
- 新机初始化：`system-init/win-init.config.jsonc` 与 `win-init.local.ps1`，均有 `.example` 模板
- `dgs-decrypt`：密钥参数在 `config/dgs.env`，模板 `config/dgs.env.example`
