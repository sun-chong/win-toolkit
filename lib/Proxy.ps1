function Test-TcpEndpoint {
    <#
    .SYNOPSIS
        快速探测 TCP 端口是否可连接
    .PARAMETER HostName
        主机名或 IP
    .PARAMETER Port
        端口
    .PARAMETER TimeoutMilliseconds
        连接超时毫秒数
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 800
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-UsableProxyUrl {
    <#
    .SYNOPSIS
        找出可用的 HTTP 代理地址
    .DESCRIPTION
        候选依次为：已有的代理环境变量、Windows 系统代理、Clash Verge 默认端口。
        逐个实测 TCP 连通性，第一个连通的作为结果；全部不通时返回 $null。
    .PARAMETER ClashPort
        Clash 代理端口；省略时取 config/toolkit.config.jsonc 的 ClashProxyPort
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [int]$ClashPort = 0
    )

    if ($ClashPort -le 0) {
        $ClashPort = (Get-ToolkitConfig).ClashProxyPort
    }

    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidates.Add($value)
            break
        }
    }

    try {
        $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($settings.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace($settings.ProxyServer)) {
            # 系统代理可能是 "http=host:port;https=host:port" 形式，逐段取用
            foreach ($entry in ($settings.ProxyServer -split ';')) {
                if (-not [string]::IsNullOrWhiteSpace($entry)) { $candidates.Add($entry) }
            }
        }
    }
    catch {
        # 读不到系统代理时继续尝试后面的候选
        $null = $_
    }

    $candidates.Add("127.0.0.1:$ClashPort")

    foreach ($candidate in $candidates) {
        $value = ($candidate -split '=')[-1].Trim()
        if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $value = "http://$value" }

        $uri = $null
        if (-not [System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri)) { continue }
        if (Test-TcpEndpoint -HostName $uri.Host -Port $uri.Port) {
            return $value.TrimEnd('/')
        }
    }

    return $null
}

function Set-ProxyEnvironment {
    <#
    .SYNOPSIS
        把可用代理写入当前进程的 http_proxy / https_proxy
    .DESCRIPTION
        写入后的环境变量会被 Start-Process / cmd / pwsh 子进程继承，
        因此 git、node、npm 都能正确走代理。
        探测不到可用代理时清空这些变量，避免沿用指向已失效代理的旧值。
        返回采用的代理地址；无可用代理时返回 $null。
    .PARAMETER ClashPort
        Clash 代理端口；省略时取 config/toolkit.config.jsonc 的 ClashProxyPort
    .NOTES
        Author: SUNC
        Version: 1.0.0
    #>
    param(
        [int]$ClashPort = 0
    )

    $proxyUrl = Get-UsableProxyUrl -ClashPort $ClashPort

    if (-not $proxyUrl) {
        Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:http_proxy, Env:https_proxy -ErrorAction SilentlyContinue
        return $null
    }

    # Windows 环境变量名不区分大小写，大小写各设一份以兼容只查小写的工具
    $env:HTTP_PROXY = $proxyUrl
    $env:HTTPS_PROXY = $proxyUrl
    $env:http_proxy = $proxyUrl
    $env:https_proxy = $proxyUrl

    return $proxyUrl
}
