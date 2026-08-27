param(
    [Parameter(Mandatory=$true)][string]$Root
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

$BaseUrl='https://lk.kakdoma.life'
$DataDir=Join-Path $Root 'data'
$SessionFile=Join-Path $DataDir 'session.dat'
$ConnectionFile=Join-Path $DataDir 'connection.json'
$OutFile=Join-Path $DataDir 'meter_discovery_report.txt'

function Unprotect-Text([string]$Text){
    $bytes=[Convert]::FromBase64String($Text)
    $dec=[Security.Cryptography.ProtectedData]::Unprotect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Text.Encoding]::UTF8.GetString($dec)
}
function Get-ProxyArgs {
    $args=@{}
    if(-not(Test-Path $ConnectionFile)){return $args}
    try{
        $cfg=Get-Content $ConnectionFile -Raw|ConvertFrom-Json
        if(-not[bool]$cfg.useProxy){return $args}
        if([string]::IsNullOrWhiteSpace([string]$cfg.proxyUrl)){return $args}
        $args['Proxy']=[string]$cfg.proxyUrl
        $args['ProxyUseDefaultCredentials']=$false
        if(-not[string]::IsNullOrWhiteSpace([string]$cfg.proxyUser)){
            $sec=ConvertTo-SecureString ([string]$cfg.proxyPassword) -AsPlainText -Force
            $args['ProxyCredential']=New-Object Management.Automation.PSCredential ([string]$cfg.proxyUser,$sec)
        }
    }catch{}
    return $args
}
function New-Session {
    if(-not(Test-Path -LiteralPath $SessionFile)){throw 'Сохранённая сессия Domlight не найдена. Сначала откройте кабинет Domlight и убедитесь, что статус: Подключено.'}
    $s=New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $json=Unprotect-Text (Get-Content -LiteralPath $SessionFile -Raw)
    foreach($x in @($json|ConvertFrom-Json)){
        try{$s.Cookies.Add((New-Object Net.Cookie($x.Name,$x.Value,$x.Path,$x.Domain)))}catch{}
    }
    return $s
}
function Get-Page([string]$Url,$Session){
    $proxy=Get-ProxyArgs
    Invoke-WebRequest -Uri $Url -WebSession $Session -UseBasicParsing -TimeoutSec 30 @proxy -Headers @{
        'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
        'Accept-Language'='ru-RU,ru;q=0.9'
    }
}
function Absolute-Url([string]$Href,[string]$From){
    try{return ([Uri]::new([Uri]$From,$Href)).AbsoluteUri}catch{return ''}
}
function Is-SameHost([string]$Url){try{return ([Uri]$Url).Host -eq ([Uri]$BaseUrl).Host}catch{return $false}}
function Is-InterestingText([string]$Text){
    if([string]::IsNullOrWhiteSpace($Text)){return $false}
    return $Text -match '(?i)сч[её]тчик|показан|прибор\s+уч[её]т|meter|reading|counter|device'
}
function Redact([string]$Text){
    if($null-eq$Text){return ''}
    $x=$Text
    $x=[regex]::Replace($x,'(?i)(csrf|token|authorization|cookie)(\s*[=:]\s*)[^\s&;"'']+','$1$2[REDACTED]')
    $x=[regex]::Replace($x,'\b\d{10,16}\b','[NUMBER]')
    return $x
}

try{
    $session=New-Session
    $start=@(
        "$BaseUrl/receipt/index",
        "$BaseUrl/"
    )
    $queue=New-Object Collections.Generic.Queue[string]
    $seen=@{}
    foreach($u in $start){$queue.Enqueue($u)}
    $pages=@()
    $hits=@()
    $maxPages=30

    while($queue.Count-gt0 -and $pages.Count-lt$maxPages){
        $url=$queue.Dequeue()
        if($seen.ContainsKey($url)){continue};$seen[$url]=$true
        try{$r=Get-Page $url $session}catch{continue}
        $html=[string]$r.Content
        $title='';$tm=[regex]::Match($html,'(?is)<title[^>]*>(.*?)</title>');if($tm.Success){$title=([Net.WebUtility]::HtmlDecode(($tm.Groups[1].Value -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim()}
        $pages+=[pscustomobject]@{Url=$url;Title=$title;Status=[int]$r.StatusCode}

        foreach($m in [regex]::Matches($html,'(?is)<a\b[^>]*href=["''](?<href>[^"'']+)["''][^>]*>(?<text>.*?)</a>')){
            $href=[Net.WebUtility]::HtmlDecode($m.Groups['href'].Value)
            $text=([Net.WebUtility]::HtmlDecode(($m.Groups['text'].Value -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim()
            $abs=Absolute-Url $href $url
            if([string]::IsNullOrWhiteSpace($abs)-or-not(Is-SameHost $abs)){continue}
            if(Is-InterestingText ($text+' '+$abs)){$hits+=[pscustomobject]@{Type='LINK';Page=$url;Text=$text;Target=$abs}}
            if($abs -notmatch '(?i)/logout|/auth/|/file/get|\.(pdf|jpg|jpeg|png|gif|svg|css|js)(\?|$)' -and -not$seen.ContainsKey($abs)){$queue.Enqueue($abs)}
        }

        foreach($m in [regex]::Matches($html,'(?is)<form\b(?<attrs>[^>]*)>(?<body>.*?)</form>')){
            $block=$m.Value
            $action='';$am=[regex]::Match($m.Groups['attrs'].Value,'(?i)action=["'']([^"'']*)["'']');if($am.Success){$action=Absolute-Url ([Net.WebUtility]::HtmlDecode($am.Groups[1].Value)) $url}
            $method='GET';$mm=[regex]::Match($m.Groups['attrs'].Value,'(?i)method=["'']([^"'']+)["'']');if($mm.Success){$method=$mm.Groups[1].Value.ToUpperInvariant()}
            $plain=([Net.WebUtility]::HtmlDecode(($block -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim()
            $names=@([regex]::Matches($block,'(?i)name=["'']([^"'']+)["'']')|ForEach-Object{$_.Groups[1].Value}|Select-Object -Unique)
            if(Is-InterestingText ($plain+' '+$action+' '+($names -join ' '))){$hits+=[pscustomobject]@{Type='FORM';Page=$url;Text=('method='+$method+' fields='+($names -join ','));Target=$action}}
        }
    }

    $lines=New-Object Collections.Generic.List[string]
    $lines.Add('DOMLIGHT METER DISCOVERY - READ ONLY')
    $lines.Add('Generated: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('No POST/PUT/PATCH/DELETE requests were sent.')
    $lines.Add('')
    $lines.Add('PAGES VISITED:')
    foreach($p in $pages){$lines.Add(('  [{0}] {1}  {2}' -f $p.Status,(Redact $p.Url),(Redact $p.Title)))}
    $lines.Add('')
    $lines.Add('METER/READING CANDIDATES:')
    if($hits.Count-eq0){$lines.Add('  NONE FOUND')}else{foreach($h in $hits|Sort-Object Type,Target -Unique){$lines.Add(('  {0} | page={1} | target={2} | {3}' -f $h.Type,(Redact $h.Page),(Redact $h.Target),(Redact $h.Text)))}}
    $lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
    [Windows.Forms.MessageBox]::Show("Диагностика завершена.`r`nНичего на портал не отправлялось.`r`n`r`nОтчёт:`r`n$OutFile",'Domlight - счётчики','OK','Information')|Out-Null
    Start-Process notepad.exe ('"'+$OutFile+'"')
}catch{
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight - диагностика счётчиков','OK','Error')|Out-Null
    exit 1
}
