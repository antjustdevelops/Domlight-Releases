param(
    [Parameter(Mandatory=$true)][string]$Root
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference='Stop'

$DomlightFile = Join-Path $Root 'Domlight.ps1'
$DataDir = Join-Path $Root 'data'
$OutFile = Join-Path $DataDir 'meter_discovery_report.txt'

function Absolute-Url([string]$Href,[string]$From){
    try { return ([Uri]::new([Uri]$From,$Href)).AbsoluteUri } catch { return '' }
}
function Is-SameHost([string]$Url,[string]$BaseUrl){
    try { return ([Uri]$Url).Host -eq ([Uri]$BaseUrl).Host } catch { return $false }
}
function Is-InterestingText([string]$Text){
    if([string]::IsNullOrWhiteSpace($Text)){ return $false }
    return $Text -match '(?i)сч[её]тчик|показан|прибор\s+уч[её]т|meter|reading|counter|device'
}
function Redact([string]$Text){
    if($null -eq $Text){ return '' }
    $x = $Text
    $x = [regex]::Replace($x,'(?i)(csrf|token|authorization|cookie)(\s*[=:]\s*)[^\s&;"'']+','$1$2[REDACTED]')
    $x = [regex]::Replace($x,'\b\d{10,16}\b','[NUMBER]')
    return $x
}

try {
    if(-not(Test-Path -LiteralPath $DomlightFile)){
        throw "Domlight.ps1 не найден: $DomlightFile"
    }

    [Windows.Forms.MessageBox]::Show(
        "Сейчас откроется обычное окно Domlight.`r`n`r`nУбедитесь, что статус 'Подключено'. Если потребуется - войдите по SMS.`r`nПосле этого ЗАКРОЙТЕ только это окно Domlight.`r`n`r`nДиагностика продолжится автоматически в той же интернет-сессии. Ничего на портал отправляться не будет.",
        'Domlight - диагностика счётчиков',
        'OK',
        'Information'
    ) | Out-Null

    # Dot-source the real Domlight client so its authenticated WebSession remains
    # in this exact PowerShell process after the window is closed.
    . $DomlightFile

    if($null -eq $script:WebSession){
        throw 'Не удалось получить живую WebSession из Domlight.'
    }
    if([string]::IsNullOrWhiteSpace([string]$BaseUrl)){
        throw 'Domlight не передал BaseUrl.'
    }

    $verify = Invoke-DomlightGet $ReceiptsUrl
    if(-not (Is-Authenticated ([string]$verify.Content))){
        throw "После закрытия окна Domlight сессия не авторизована. Запустите диагностику снова и перед закрытием окна убедитесь, что статус 'Подключено'."
    }

    $queue = New-Object Collections.Generic.Queue[string]
    $seen = @{}
    $pages = @()
    $hits = @()
    $maxPages = 40
    $queue.Enqueue($ReceiptsUrl)

    while($queue.Count -gt 0 -and $pages.Count -lt $maxPages){
        $url = $queue.Dequeue()
        if($seen.ContainsKey($url)){ continue }
        $seen[$url] = $true

        try { $r = Invoke-DomlightGet $url } catch { continue }
        $html = [string]$r.Content

        $title=''
        $tm=[regex]::Match($html,'(?is)<title[^>]*>(.*?)</title>')
        if($tm.Success){
            $title=([Net.WebUtility]::HtmlDecode(($tm.Groups[1].Value -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim()
        }
        $pages += [pscustomobject]@{Url=$url;Title=$title;Status=[int]$r.StatusCode}

        foreach($m in [regex]::Matches($html,'(?is)<a\b[^>]*href=["''](?<href>[^"'']+)["''][^>]*>(?<text>.*?)</a>')){
            $href=[Net.WebUtility]::HtmlDecode($m.Groups['href'].Value)
            $text=([Net.WebUtility]::HtmlDecode(($m.Groups['text'].Value -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim()
            $abs=Absolute-Url $href $url
            if([string]::IsNullOrWhiteSpace($abs) -or -not(Is-SameHost $abs $BaseUrl)){ continue }

            if(Is-InterestingText ($text+' '+$abs)){
                $hits += [pscustomobject]@{Type='LINK';Page=$url;Text=$text;Target=$abs}
            }

            if($abs -notmatch '(?i)/logout|/auth/|/file/get|\.(pdf|jpg|jpeg|png|gif|svg|css|js)(\?|$)' -and -not $seen.ContainsKey($abs)){
                $queue.Enqueue($abs)
            }
        }

        foreach($m in [regex]::Matches($html,'(?is)<form\b(?<attrs>[^>]*)>(?<body>.*?)</form>')){
            $block=$m.Value
            $action=''
            $am=[regex]::Match($m.Groups['attrs'].Value,'(?i)action=["'']([^"'']*)["'']')
            if($am.Success){ $action=Absolute-Url ([Net.WebUtility]::HtmlDecode($am.Groups[1].Value)) $url }

            $method='GET'
            $mm=[regex]::Match($m.Groups['attrs'].Value,'(?i)method=["'']([^"'']+)["'']')
            if($mm.Success){ $method=$mm.Groups[1].Value.ToUpperInvariant() }

            $plain=([Net.WebUtility]::HtmlDecode(($block -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim()
            $names=@([regex]::Matches($block,'(?i)name=["'']([^"'']+)["'']') | ForEach-Object {$_.Groups[1].Value} | Select-Object -Unique)

            if(Is-InterestingText ($plain+' '+$action+' '+($names -join ' '))){
                $hits += [pscustomobject]@{Type='FORM';Page=$url;Text=('method='+$method+' fields='+($names -join ','));Target=$action}
            }
        }
    }

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('DOMLIGHT METER DISCOVERY - LIVE SESSION - READ ONLY')
    $lines.Add('Generated: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('Authenticated session: YES')
    $lines.Add('No POST/PUT/PATCH/DELETE requests were sent by the discovery stage.')
    $lines.Add('')
    $lines.Add('PAGES VISITED:')
    foreach($p in $pages){
        $lines.Add(('  [{0}] {1}  {2}' -f $p.Status,(Redact $p.Url),(Redact $p.Title)))
    }
    $lines.Add('')
    $lines.Add('METER/READING CANDIDATES:')
    if($hits.Count -eq 0){
        $lines.Add('  NONE FOUND')
    } else {
        foreach($h in $hits | Sort-Object Type,Target -Unique){
            $lines.Add(('  {0} | page={1} | target={2} | {3}' -f $h.Type,(Redact $h.Page),(Redact $h.Target),(Redact $h.Text)))
        }
    }

    $lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
    [Windows.Forms.MessageBox]::Show(
        "Диагностика завершена.`r`nНичего на портал не отправлялось.`r`n`r`nОтчёт:`r`n$OutFile",
        'Domlight - счётчики',
        'OK',
        'Information'
    ) | Out-Null
    Start-Process notepad.exe ('"'+$OutFile+'"')
}
catch {
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight - диагностика счётчиков','OK','Error') | Out-Null
    exit 1
}
