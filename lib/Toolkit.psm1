# Toolkit 公共库加载器
# 领域文件直接放在 lib 根目录，按文件名顺序点源；不递归，bin/ 不会被加载。
# 不调用 Export-ModuleMember，对外可见性由 Toolkit.psd1 的 FunctionsToExport
# 控制，避免模块清单与导出语句两处维护。
$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot
# 显式初始化模块级缓存，避免调用方启用 StrictMode 时首次读取未定义变量报错
$script:ConfigCache = $null

Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object {
    . $_.FullName
}
