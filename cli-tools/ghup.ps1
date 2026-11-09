<#
.SYNOPSIS
    GitHub / Claude 桌面版更新检查

.DESCRIPTION
    检查关注来源是否有新版本。通过交互式菜单查看更新内容。

    来源类型由配置项 type 指定（cli-tools/ghup.config.json 或 .jsonc，优先 .jsonc）：
    - github（默认，缺省 type 时）：GitHub 仓库 Release，字段 name 为 "owner/repo"
    - claude：Claude 桌面版 changelog，字段 url 为 changelog 页面地址；
      脚本请求该地址加 .md 的 Markdown 版并解析首个 **vX.Y.Z** 条目（页面倒序，首条即最新）；
      仅适配 claude.com changelog 页面格式，不支持任意网页

.PARAMETER Help
    显示帮助信息
    短参数：-h

.PARAMETER All
    显示全部仓库（包括次要仓库），显示来源链接，不显示交互式菜单
    短参数：-a

.EXAMPLE
    ghup
    检查所有仓库并进入交互菜单

.EXAMPLE
    ghup -h
    显示帮助信息

.EXAMPLE
    ghup -a
    显示全部仓库的版本信息和 GitHub 链接

.EXAMPLE
    ghup -all
    同上

.NOTES
    Author: SUNC
    Version: 1.2.0
#>

param(
    [Alias("h")]
    [switch]$Help,
    [Alias("a")]
    [switch]$All
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

# 常量定义
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# 配置文件同时支持 .json 与 .jsonc，优先 .jsonc；读写都用解析结果，避免配置分裂
$script:ConfigPath = (Resolve-ToolkitConfigPath -BasePath (Join-Path $script:ScriptDir "ghup.config")).Path
# Clash 本地代理端口（网页来源直连失败时的备用出口）与网页请求超时（秒：直连快速失败 / 代理放宽）
$script:ClashProxyPort = (Get-ToolkitConfig).ClashProxyPort
$script:WebDirectTimeoutSec = 5
$script:WebProxyTimeoutSec = 15

# 默认配置（首次运行时使用）
$script:DefaultConfig = @{
    repositories = @(
        @{
            name = "anthropics/claude-code"
            alias = "claude-code"
            primary = "Y"
        }
    )
}

# ============================================================
# 配置文件操作
# ============================================================

function New-DefaultConfig {
    <#
    .SYNOPSIS
        创建默认配置文件
    #>
    try {
        $json = $script:DefaultConfig | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($script:ConfigPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-ToolkitMessage -Kind Info -Text "已创建默认配置文件: $script:ConfigPath"
        return $script:DefaultConfig
    }
    catch {
        throw "创建配置文件失败: $_"
    }
}

function Merge-GhupState {
    <#
    .SYNOPSIS
        把仓库对象上的 lastVersion / lastChecked 合并进状态哈希表
    .DESCRIPTION
        返回是否发生了迁移：仓库对象上原本存在 lastVersion 或 lastChecked。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    $migrated = $false
    foreach ($repo in $Config.repositories) {
        $key = if ($repo.alias) { $repo.alias } else { $repo.name }
        if ($repo.PSObject.Properties['lastVersion'] -or $repo.PSObject.Properties['lastChecked']) {
            $State[$key] = @{
                lastVersion = if ($repo.PSObject.Properties['lastVersion']) { $repo.lastVersion } else { $null }
                lastChecked = if ($repo.PSObject.Properties['lastChecked']) { $repo.lastChecked } else { $null }
            }
            $migrated = $true
        }
    }
    return $migrated
}

function Read-Config {
    <#
    .SYNOPSIS
        读取配置文件，不存在则创建默认配置
    #>
    if (-not (Test-Path $script:ConfigPath)) {
        return New-DefaultConfig
    }

    try {
        $content = Get-Content -Path $script:ConfigPath -Raw -Encoding UTF8
        $config = $content | ConvertFrom-Json

        # 运行时状态与配置分离：旧配置中的 lastVersion / lastChecked 迁移到状态文件
        $state = Read-ToolkitState -Name 'ghup'
        $migrated = Merge-GhupState -Config $config -State $state
        if ($migrated) {
            try {
                Write-Config -Config $config
            }
            catch {
                Write-Warning "状态迁移未完成，保留原配置：$($_.Exception.Message)"
            }
        }

        # 从状态文件回填内存对象，供本次版本比较使用
        foreach ($repo in $config.repositories) {
            $key = if ($repo.alias) { $repo.alias } else { $repo.name }
            if ($state.ContainsKey($key)) {
                $repo | Add-Member -NotePropertyName lastVersion -NotePropertyValue $state[$key].lastVersion -Force
                $repo | Add-Member -NotePropertyName lastChecked -NotePropertyValue $state[$key].lastChecked -Force
            }
        }

        return $config
    }
    catch {
        throw "配置文件格式损坏，请检查或删除后重试: $script:ConfigPath"
    }
}

function Test-ConfigValidity {
    <#
    .SYNOPSIS
        校验配置文件有效性
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    # 检查 repositories 是否存在且为数组
    if ($null -eq $Config.repositories -or -not ($Config.repositories -is [array])) {
        throw "配置文件缺少 repositories 数组"
    }

    # 检查是否为空
    if ($Config.repositories.Count -eq 0) {
        throw "配置中无仓库，请编辑配置文件添加: $script:ConfigPath"
    }

    # 检查每个仓库的必要字段
    $aliases = @()
    for ($i = 0; $i -lt $Config.repositories.Count; $i++) {
        $repo = $Config.repositories[$i]

        # 校验 type（缺省视为 github；claude 用 url 定位 changelog，github 用 name 定位仓库）
        if ($null -ne $repo.type -and $repo.type -notin @("github", "claude")) {
            throw "第 $($i + 1) 个仓库 ($($repo.alias)) 的 type 字段值无效: $($repo.type)，只允许 github 或 claude"
        }

        if ($repo.type -eq "claude") {
            if (-not $repo.url) {
                throw "第 $($i + 1) 个仓库 ($($repo.alias)) 为 claude 类型，缺少 url 字段"
            }
        }
        elseif (-not $repo.name) {
            throw "第 $($i + 1) 个仓库缺少 name 字段"
        }

        if (-not $repo.alias) {
            throw "第 $($i + 1) 个仓库缺少 alias 字段"
        }
        # 检查 alias 唯一性
        if ($aliases -contains $repo.alias) {
            throw "alias 重复: $($repo.alias)"
        }
        $aliases += $repo.alias

        # 校验 primary 字段（null 或空字符串均视为缺失，自动补 "N"）
        if ([string]::IsNullOrEmpty($repo.primary)) {
            # 字段缺失或为空，自动补 "N"（次要仓库）
            $Config.repositories[$i].primary = "N"
        }
        else {
            # 统一转大写
            $Config.repositories[$i].primary = $repo.primary.ToUpper()
            # 校验值
            if ($Config.repositories[$i].primary -ne "Y" -and $Config.repositories[$i].primary -ne "N") {
                throw "第 $($i + 1) 个仓库 ($($repo.alias)) 的 primary 字段值无效: $($repo.primary)，只允许 Y 或 N"
            }
        }
    }

    return $true
}

function Write-Config {
    <#
    .SYNOPSIS
        写入配置文件
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    try {
        # 运行时状态写入独立文件，配置文件只保留用户编辑的仓库列表
        $state = Read-ToolkitState -Name 'ghup'
        $null = Merge-GhupState -Config $Config -State $state
        $outputRepos = @()

        foreach ($repo in $Config.repositories) {
            # 输出副本剔除运行时状态，不修改调用方对象
            $copy = [ordered]@{}
            foreach ($prop in $repo.PSObject.Properties) {
                if ($prop.Name -in @('lastVersion', 'lastChecked')) { continue }
                $copy[$prop.Name] = $prop.Value
            }
            $outputRepos += [pscustomobject]$copy
        }

        if (-not (Write-ToolkitState -Name 'ghup' -Data $state)) {
            throw '状态文件写入失败，未修改配置文件'
        }

        $output = [ordered]@{}
        foreach ($prop in $Config.PSObject.Properties) {
            if ($prop.Name -eq 'repositories') { continue }
            $output[$prop.Name] = $prop.Value
        }
        $output['repositories'] = $outputRepos
        Write-ToolkitJson -Path $script:ConfigPath -Data ([pscustomobject]$output)
    }
    catch {
        throw "写入配置文件失败: $_"
    }
}

# ============================================================
# GitHub CLI 操作
# ============================================================

function Test-GitHubCli {
    <#
    .SYNOPSIS
        检查 gh CLI 是否可用且已认证
    #>
    # 检查 gh 是否安装
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghCmd) {
        throw "未找到 gh CLI，请安装: https://cli.github.com/"
    }

    # 检查是否已认证
    # 仅需 gh auth status 的退出码，输出丢弃
    $null = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh CLI 未认证，请运行: gh auth login"
    }

    return $true
}

function Get-LatestRelease {
    <#
    .SYNOPSIS
        获取仓库的最新 Release tagName

    .OUTPUTS
        成功: @{ Success = $true; TagName = "v1.0.0" }
        失败: @{ Success = $false; Error = "错误信息" }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoName
    )

    try {
        $result = gh release view --repo $RepoName --json tagName --jq .tagName 2>&1

        if ($LASTEXITCODE -ne 0) {
            return @{
                Success = $false
                Error = if ($result -match "not found") { "无 Release" } else { $result }
            }
        }

        return @{
            Success = $true
            TagName = $result.Trim()
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-SourceLink {
    <#
    .SYNOPSIS
        获取来源对应的浏览器链接（GitHub Releases 页或 changelog 页）
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Repo
    )

    if ($Repo.type -eq "claude") {
        return $Repo.url
    }
    return "https://github.com/$($Repo.name)/releases"
}

function Get-LatestClaudeVersion {
    <#
    .SYNOPSIS
        获取 Claude 桌面版 changelog 的最新版本号

    .OUTPUTS
        成功: @{ Success = $true; TagName = "v4.4212.0" }
        失败: @{ Success = $false; Error = "错误信息" }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    # changelog 页约定同地址加 .md 返回 Markdown 版，便于正则解析
    $mdUrl = $Url.TrimEnd('/') + '.md'

    # 先直连（短超时快速失败，claude.com 直连常不可达）；失败后经可用代理重试
    $proxyUrl = Get-UsableProxyUrl
    $attempts = @(@{ TimeoutSec = $script:WebDirectTimeoutSec })
    if ($proxyUrl) {
        $attempts += @{ Proxy = $proxyUrl; TimeoutSec = $script:WebProxyTimeoutSec }
    }
    $content = $null
    $lastError = $null
    foreach ($attempt in $attempts) {
        try {
            $content = (Invoke-WebRequest -Uri $mdUrl -ProgressAction SilentlyContinue -ErrorAction Stop @attempt).Content
            break
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    if ($null -eq $content) {
        $proxyLabel = if ($proxyUrl) { $proxyUrl } else { '未探测到可用代理' }
        return @{
            Success = $false
            Error = "直连与代理 ($proxyLabel) 均获取失败: $lastError"
        }
    }

    # 页面按时间倒序，首个 **vX.Y.Z** 条目标题即最新版本
    if ($content -notmatch '(?m)^\*\*(v[\d.]+)\*\*\s*$') {
        return @{
            Success = $false
            Error = "页面格式不符，未解析到版本号条目"
        }
    }

    return @{
        Success = $true
        TagName = $Matches[1]
    }
}

function Invoke-VersionCheck {
    <#
    .SYNOPSIS
        检查所有仓库版本并更新配置

    .OUTPUTS
        更新后的配置对象 + 检查结果数组

    .NOTES
        版本比较逻辑：使用字符串比较检测 tagName 是否变化（不判断版本高低）
        - 例如 "v1.15.6" != "v1.15.10" → 标记为"有更新"
        - 我们只检测是否变化，不比较版本号大小
        - 原始 tagName 直接比较，不做任何格式转换
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [switch]$All
    )

    $results = @()
    $configChanged = $false

    # 根据模式过滤仓库
    if ($All) {
        $reposToCheck = $Config.repositories
    }
    else {
        $reposToCheck = @($Config.repositories | Where-Object { $_.primary -eq "Y" })
    }

    # 零仓库保护
    if ($reposToCheck.Count -eq 0) {
        Write-Host ""
        Write-ToolkitMessage -Kind Warning -Text "没有可用的主要仓库，请检查配置或使用 -a 参数查看全部仓库"
        return $null
    }

    # gh CLI 仅 github 类型来源需要，纯 claude 配置不依赖 gh
    if (@($reposToCheck | Where-Object { $_.type -ne "claude" }).Count -gt 0) {
        $null = Test-GitHubCli
        Write-ToolkitMessage -Kind Success -Text "gh CLI 检查通过"
    }

    Write-Host ""
    Write-ToolkitMessage -Kind Info -Text "正在检查仓库版本..."

    for ($i = 0; $i -lt $reposToCheck.Count; $i++) {
        $repo = $reposToCheck[$i]
        $displayIndex = $i + 1

        Write-Host "  [$displayIndex] $($repo.alias)..." -NoNewline

        # 按来源类型分派检查
        if ($repo.type -eq "claude") {
            $release = Get-LatestClaudeVersion -Url $repo.url
        }
        else {
            $release = Get-LatestRelease -RepoName $repo.name
        }

        if (-not $release.Success) {
            Write-ToolkitMessage -Kind Error -Text " ❌ 获取失败 ($($release.Error))"
            $results += @{
                Index = $displayIndex
                Repo = $repo
                Status = "error"
                Error = $release.Error
            }
            continue
        }

        $currentTag = $release.TagName
        $cachedTag = $repo.lastVersion

        # 判断状态（使用字符串比较检测 tagName 是否变化）
        $status = if ($null -eq $cachedTag) {
            # 首次检查，不标记为更新
            "new"
        }
        elseif ($currentTag -ne $cachedTag) {
            # tagName 变化，标记为有更新
            "updated"
        }
        else {
            # tagName 未变，已是最新
            "current"
        }

        # $reposToCheck 是 $Config.repositories 过滤所得，元素为同一对象引用，直接写回
        if ($status -eq "updated" -or $status -eq "new") {
            $repo | Add-Member -NotePropertyName lastVersion -NotePropertyValue $currentTag -Force
        }
        $repo | Add-Member -NotePropertyName lastChecked -NotePropertyValue (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK") -Force
        $configChanged = $true  # 无条件标记，确保 lastChecked 始终写回

        # 输出状态
        if ($status -eq "updated") {
            Write-ToolkitMessage -Kind Warning -Text " 🆕 $cachedTag → $currentTag"
        }
        elseif ($status -eq "new") {
            Write-ToolkitMessage -Kind Success -Text " ✅ $currentTag (首次)"
        }
        else {
            Write-ToolkitMessage -Kind Success -Text " ✅ $currentTag"
        }

        $results += @{
            Index = $displayIndex
            Repo = $repo
            Status = $status
            CurrentTag = $currentTag
            CachedTag = $cachedTag
        }
    }

    # 写回配置
    if ($configChanged) {
        Write-Config -Config $Config
    }

    return @{
        Config = $Config
        Results = $results
        CheckedCount = $reposToCheck.Count
    }
}

function Show-StatusTable {
    <#
    .SYNOPSIS
        展示仓库状态表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Results,
        [switch]$All
    )

    Write-Host ""
    Write-ToolkitMessage -Kind Info -Text "========================================"
    Write-ToolkitMessage -Kind Info -Text "           版本更新状态            "
    Write-ToolkitMessage -Kind Info -Text "========================================"
    Write-Host ""

    # 计算最大 alias 长度用于对齐
    $maxAliasLength = ($Results | ForEach-Object { $_.Repo.alias.Length } | Measure-Object -Maximum).Maximum

    # 计算版本号文本的最大长度用于对齐状态符号
    $versionTexts = @(
        foreach ($r in $Results) {
            switch ($r.Status) {
                "updated" { "$($r.CachedTag) → $($r.CurrentTag)" }
                "new" { $r.CurrentTag }
                "current" { $r.CurrentTag }
                "error" { "" }
            }
        }
    )
    $maxVersionLength = ($versionTexts | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

    # 全量模式下计算链接文本最大长度
    if ($All) {
        $linkTexts = @(
            foreach ($r in $Results) {
                if ($r.Status -ne "error") {
                    Get-SourceLink -Repo $r.Repo
                }
            }
        )
        $maxLinkLength = ($linkTexts | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    }

    foreach ($result in $Results) {
        $index = $result.Index
        $alias = $result.Repo.alias.PadRight($maxAliasLength)

        # 分离版本号和状态符号，便于对齐
        $versionText, $statusSymbol = switch ($result.Status) {
            "updated" {
                "$($result.CachedTag) → $($result.CurrentTag)", "🆕"
            }
            "new" {
                $result.CurrentTag, "✅"
            }
            "current" {
                $result.CurrentTag, "✅"
            }
            "error" {
                "", "❌ 获取失败"
            }
        }

        $linkSuffix = ""
        if ($All -and $result.Status -ne "error") {
            $link = Get-SourceLink -Repo $result.Repo
            $linkSuffix = "  $($link.PadRight($maxLinkLength))"
        }

        $line = "  [$index] $alias  $($versionText.PadRight($maxVersionLength))  $statusSymbol$linkSuffix"
        if ($result.Status -eq "updated") {
            Write-ToolkitMessage -Kind Warning -Text $line
        }
        elseif ($result.Status -eq "error") {
            Write-ToolkitMessage -Kind Error -Text $line
        }
        else {
            Write-Host $line
        }
    }

    Write-Host ""
}

function Show-InteractiveMenu {
    <#
    .SYNOPSIS
        显示交互式菜单并处理用户选择
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Results
    )

    # 显示菜单选项
    Write-ToolkitMessage -Kind Info -Text "选择要打开的链接:"
    Write-ToolkitMessage -Color White -Text "  [a]  全部打开"

    foreach ($result in $Results) {
        if ($result.Status -ne "error") {
            $sourceLink = Get-SourceLink -Repo $result.Repo
            Write-ToolkitMessage -Color White -Text "  [$($result.Index)]  $sourceLink"
        }
    }

    Write-ToolkitMessage -Color White -Text "  [q]  跳过  (Esc 退出)"
    Write-ToolkitMessage -Color DarkGray -Text "──────────────────────────"

    # 输入验证循环（使用 ReadKey 以支持 Esc 退出）
    while ($true) {
        $buffer = ""
        Write-ToolkitMessage -Kind Info -Text "选择 > " -NoNewline

        while ($true) {
            $key = [Console]::ReadKey($true)

            # Esc → 终止整个脚本
            if ($key.Key -eq "Escape") {
                Write-Host ""
                return @{ Action = "exit" }
            }

            # Enter → 提交
            if ($key.Key -eq "Enter") {
                Write-Host ""
                break
            }

            # Backspace → 删除最后一个字符
            if ($key.Key -eq "Backspace") {
                if ($buffer.Length -gt 0) {
                    $buffer = $buffer.Substring(0, $buffer.Length - 1)
                    Write-Host "`b `b" -NoNewline
                }
                continue
            }

            # 跳过不可打印字符（方向键、功能键等）
            if ($key.KeyChar -eq [char]0) {
                continue
            }

            # 普通字符 → 追加到缓冲区
            $buffer += $key.KeyChar
            Write-Host $key.KeyChar -NoNewline
        }

        # 空输入 → 重新提示
        if ([string]::IsNullOrEmpty($buffer)) {
            continue
        }

        # 解析输入
        if ($buffer -eq "a") {
            return @{ Action = "open-all"; Results = $Results }
        }

        if ($buffer -eq "q") {
            return @{ Action = "skip" }
        }

        $selectedIndex = 0
        if ([int]::TryParse($buffer, [ref]$selectedIndex)) {
            $validResult = $Results | Where-Object { $_.Index -eq $selectedIndex -and $_.Status -ne "error" }
            if ($validResult) {
                return @{ Action = "open-one"; Result = $validResult }
            }
        }

        Write-ToolkitMessage -Kind Error -Text "无效输入，请重新选择"
    }
}

# ============================================================
# 帮助信息
# ============================================================

if ($Help) {
    Show-ToolkitScriptHelp -Path $MyInvocation.MyCommand.Path -Full
    exit 0
}

# ============================================================
# 主流程
# ============================================================

try {
    # 加载配置
    $config = Read-Config

    # 校验配置
    $null = Test-ConfigValidity -Config $config

    $primaryCount = @($config.repositories | Where-Object { $_.primary -eq "Y" }).Count
    $secondaryCount = $config.repositories.Count - $primaryCount
    if ($All) {
        Write-ToolkitMessage -Kind Success -Text "配置加载成功，共 $($config.repositories.Count) 个仓库（主要 $primaryCount 个，次要 $secondaryCount 个）"
    }
    else {
        Write-ToolkitMessage -Kind Success -Text "配置加载成功，共 $($config.repositories.Count) 个仓库（主要 $primaryCount 个）"
    }

    # 检查版本
    $checkResult = Invoke-VersionCheck -Config $config -All:$All
    if ($null -eq $checkResult) {
        return
    }
    $config = $checkResult.Config
    $results = $checkResult.Results

    # 展示状态表
    Show-StatusTable -Results $results -All:$All

    if (-not $All) {
        # 交互式菜单
        $menuResult = Show-InteractiveMenu -Results $results

        # 处理菜单选择
        switch ($menuResult.Action) {
            "open-all" {
                Write-Host ""
                Write-ToolkitMessage -Kind Info -Text "正在打开浏览器..."
                foreach ($result in $menuResult.Results) {
                    if ($result.Status -ne "error") {
                        Start-Process (Get-SourceLink -Repo $result.Repo)
                    }
                }
            }
            "open-one" {
                Write-Host ""
                Write-ToolkitMessage -Kind Info -Text "正在打开浏览器..."
                Start-Process (Get-SourceLink -Repo $menuResult.Result.Repo)
            }
            "skip" {
                # 直接进入下一步
            }
            "exit" {
                return
            }
        }
    }
}
catch {
    Write-ToolkitMessage -Kind Error -Text "错误: $_"
    exit 1
}
