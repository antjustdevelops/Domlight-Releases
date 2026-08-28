$ErrorActionPreference = 'Stop'

$script:DomlightBaseUrl = 'https://lk.kakdoma.life'
$script:DomlightReceiptsUrl = $script:DomlightBaseUrl + '/receipt/index'
$script:DomlightAccountSetUrl = $script:DomlightBaseUrl + '/account/set'
$script:DomlightMeterUrl = $script:DomlightBaseUrl + '/meter/index'

function Get-DomlightVersion {
    param([string]$Root)
    $path = Join-Path $Root 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $path)) { return 'UNKNOWN' }
    try {
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        return (($raw -replace '^Domlight\s+','').Trim())
    } catch { return 'UNKNOWN' }
}

function Unprotect-DomlightText {
    param([string]$Text)
    $bytes = [Convert]::FromBase64String($Text)
    $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Text.Encoding]::UTF8.GetString($dec)
}

function Import-DomlightSession {
    param([string]$SessionFile)
    if (-not (Test-Path -LiteralPath $SessionFile)) { throw 'Сохранённая сессия Domlight не найдена.' }
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $protected = Get-Content -LiteralPath $SessionFile -Raw
    $json = Unprotect-DomlightText $protected
    $arr = $json | ConvertFrom-Json
    foreach ($x in @($arr)) {
        $cookie = New-Object System.Net.Cookie($x.Name,$x.Value,$x.Path,$x.Domain)
        $session.Cookies.Add($cookie)
    }
    $session
}

function Get-DomlightProxyArgs {
    param([string]$ConnectionFile)
    $args = @{}
    if (-not (Test-Path -LiteralPath $ConnectionFile)) { return $args }
    try {
        $cfg = Get-Content -LiteralPath $ConnectionFile -Raw | ConvertFrom-Json
        if (-not [bool]$cfg.useProxy) { return $args }
        if ([string]::IsNullOrWhiteSpace([string]$cfg.proxyUrl)) { return $args }
        $args['Proxy'] = [string]$cfg.proxyUrl
        $args['ProxyUseDefaultCredentials'] = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$cfg.proxyUser)) {
            $sec = ConvertTo-SecureString ([string]$cfg.proxyPassword) -AsPlainText -Force
            $args['ProxyCredential'] = New-Object System.Management.Automation.PSCredential ([string]$cfg.proxyUser,$sec)
        }
    } catch {}
    return $args
}

function Invoke-DomlightGetShared {
    param([string]$Url,$Session,[string]$ConnectionFile)
    $proxy = Get-DomlightProxyArgs $ConnectionFile
    Invoke-WebRequest -Uri $Url -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
        'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
        'Accept-Language'='ru-RU,ru;q=0.9'
    }
}

function Get-DomlightCsrf {
    param([string]$Html)
    $patterns = @(
        '<meta[^>]+name=["'']csrf-token["''][^>]+content=["'']([^"'']+)["'']',
        '<input[^>]+name=["'']_csrf-lk["''][^>]+value=["'']([^"'']+)["'']',
        '<input[^>]+value=["'']([^"'']+)["''][^>]+name=["'']_csrf-lk["'']'
    )
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($Html,$pattern,'IgnoreCase')
        if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    }
    throw 'Не найден CSRF-токен Домлайта.'
}

function Get-DomlightAccountsFromHtml {
    param([string]$Html)
    $forms = [regex]::Matches($Html,'<form[^>]+action=["'']/account/set["''][\s\S]*?</form>','IgnoreCase')
    $result=@();$seen=@{}
    foreach($form in $forms){
        $am=[regex]::Match($form.Value,'<input[^>]+name=["'']account["''][^>]+value=["'']([^"'']+)["'']','IgnoreCase')
        $cm=[regex]::Match($form.Value,'<input[^>]+name=["'']company["''][^>]+value=["'']([^"'']+)["'']','IgnoreCase')
        if(-not($am.Success -and $cm.Success)){continue}
        $account=[Net.WebUtility]::HtmlDecode($am.Groups[1].Value)
        $company=[Net.WebUtility]::HtmlDecode($cm.Groups[1].Value)
        $key=$company+'|'+$account
        if($seen.ContainsKey($key)){continue}
        $seen[$key]=$true
        $result += [pscustomobject]@{Account=$account;Company=$company}
    }
    return @($result)
}

function Test-DomlightAuthenticatedHtml {
    param([string]$Html)
    return (@(Get-DomlightAccountsFromHtml $Html).Count -gt 0)
}

function Set-DomlightAccountContext {
    param($Session,[string]$Company,[string]$Account,[string]$ConnectionFile)
    $page = Invoke-DomlightGetShared -Url $script:DomlightReceiptsUrl -Session $Session -ConnectionFile $ConnectionFile
    $csrf = Get-DomlightCsrf ([string]$page.Content)
    $body = '_csrf-lk=' + [uri]::EscapeDataString($csrf) + '&company=' + [uri]::EscapeDataString($Company) + '&account=' + [uri]::EscapeDataString($Account)
    $proxy = Get-DomlightProxyArgs $ConnectionFile
    try {
        Invoke-WebRequest -Uri $script:DomlightAccountSetUrl -Method POST -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
            'Referer'=$script:DomlightReceiptsUrl
            'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
        } -ContentType 'application/x-www-form-urlencoded' -Body $body | Out-Null
    } catch {
        $status=$null
        try{$status=[int]$_.Exception.Response.StatusCode}catch{}
        if($status -ne 302){throw}
    }
}
