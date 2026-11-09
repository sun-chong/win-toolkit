<#
    PSScriptAnalyzer 配置
    排除的规则均与本仓库刻意的编码约定冲突，逐条给出理由。
    使用：Invoke-ScriptAnalyzer -Path <file> -Settings <本文件>
#>
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # CLI 工具依赖 Write-Host 输出彩色交互文本（非日志场景，故不适用该规则）
        'PSAvoidUsingWriteHost'

        # 仓库统一使用 UTF-8 无 BOM 读写，见 CLAUDE.md 的配置读写约定
        'PSUseBOMForUnicodeEncodedFile'

        # 个人交互式工具，不提供 -WhatIf / -Confirm 语义
        'PSUseShouldProcessForStateChangingFunctions'

        # 返回集合的函数按业务语义命名（Get-Tools / Get-SystemApps 等），不强制单数
        'PSUseSingularNouns'

        # Is- / Launch- 等动词在该工具集内语义清晰
        'PSUseApprovedVerbs'
    )
}
