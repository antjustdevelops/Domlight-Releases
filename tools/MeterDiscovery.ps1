param(
    [Parameter(Mandatory=$true)][string]$Root
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference='Stop'

$DomlightFile = Join-Path $Root 'Domlight.ps1'
$DataDir = Join-Path $Root 'data'
$OutFile = Join-Path $DataDir 'meter_discovery_report.txt'

function Absolute-Url([string]$Href,[string]$From){ try { return ([Uri]::new([Uri]$From,$Href)).AbsoluteUri } catch { return '' } }
function Clean-Text([string]$Html){ if($null -eq $Html){return ''}; return (([Net.WebUtility]::HtmlDecode(($Html -replace '(?is)<script.*?</script>',' ' -replace '(?is)<style.*?</style>',' ' -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim()) }
function Redact([string]$Text){
    if($null -eq $Text){ return '' }
    $x=$Text
    $x=[regex]::Replace($x,'(?i)(csrf|token|authorization|cookie)(\s*[=:]\s*)[^\s&;"'']+','$1$2[REDACTED]')
    $x=[regex]::Replace($x,'\b\d{10,16}\b','[NUMBER]')
    return $x
}
function Attr([string]$Attrs,[string]$Name){
    $m=[regex]::Match($Attrs,'(?is)(?:^|\s)'+[regex]::Escape($Name)+'\s*=\s*["'']([^"'']*)["'']')
    if($m.Success){ return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    $m=[regex]::Match($Attrs,'(?is)(?:^|\s)'+[regex]::Escape($Name)+'\s*=\s*([^\s>]+)')
    if($m.Success){ return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    return ''
}
function Describe-Form([string]$Block,[string]$PageUrl){
    $open=[regex]::Match($Block,'(?is)<form\b(?<attrs>[^>]*)>')
    $attrs=$open.Groups['attrs'].Value
    $method=(Attr $attrs 'method'); if([string]::IsNullOrWhiteSpace($method)){$method='GET'}; $method=$method.ToUpperInvariant()
    $action=(Attr $attrs 'action'); if([string]::IsNullOrWhiteSpace($action)){$action=$PageUrl}else{$action=Absolute-Url $action $PageUrl}
    $items=@()
    foreach($m in [regex]::Matches($Block,'(?is)<input\b(?<attrs>[^>]*)>')){
        $a=$m.Groups['attrs'].Value; $name=Attr $a 'name'; $type=Attr $a 'type'; if([string]::IsNullOrWhiteSpace($type)){$type='text'}
        $value=Attr $a 'value'; $placeholder=Attr $a 'placeholder'
        if($name -match '(?i)csrf|token'){ $value='[REDACTED]' }
        $items += ('input name="'+$name+'" type="'+$type+'" value="'+(Redact $value)+'" placeholder="'+(Redact $placeholder)+'"')
    }
    foreach($m in [regex]::Matches($Block,'(?is)<select\b(?<attrs>[^>]*)>(?<body>.*?)</select>')){
        $name=Attr $m.Groups['attrs'].Value 'name'; $items += ('select name="'+$name+'"')
    }
    foreach($m in [regex]::Matches($Block,'(?is)<textarea\b(?<attrs>[^>]*)>(?<body>.*?)</textarea>')){
        $name=Attr $m.Groups['attrs'].Value 'name'; $items += ('textarea name="'+$name+'"')
    }
    [pscustomobject]@{Method=$method;Action=$action;Fields=$items;Text=(Clean-Text $Block)}
}

try {
    if(-not(Test-Path -LiteralPath $DomlightFile)){ throw "Domlight.ps1 не найден: $DomlightFile" }

    [Windows.Forms.MessageBox]::Show(
        "Сейчас откроется обычное окно Domlight.`r`n`r`nУбедитесь, что статус 'Подключено'. Затем ЗАКРОЙТЕ только это окно Domlight.`r`n`r`nПосле закрытия диагностика прочитает страницу счётчиков в той же живой сессии. Ничего отправляться не будет.",
        'Domlight - диагностика счётчиков','OK','Information'
    ) | Out-Null

    . $DomlightFile

    if($null -eq $script:WebSession){ throw 'Не удалось получить живую WebSession из Domlight.' }
    $verify=Invoke-DomlightGet $ReceiptsUrl
    if(-not(Is-Authenticated([string]$verify.Content))){ throw "Сессия не авторизована. Запустите диагностику снова и перед закрытием окна убедитесь, что статус 'Подключено'." }

    $MeterUrl="$BaseUrl/meter/index"
    $r=Invoke-DomlightGet $MeterUrl
    $html=[string]$r.Content
    if(-not(Is-Authenticated $html)){ throw 'Страница счётчиков открылась без авторизации.' }

    $title=''; $tm=[regex]::Match($html,'(?is)<title[^>]*>(.*?)</title>'); if($tm.Success){$title=Clean-Text $tm.Groups[1].Value}
    $pageText=Clean-Text $html

    $forms=@()
    foreach($fm in [regex]::Matches($html,'(?is)<form\b[^>]*>.*?</form>')){ $forms += Describe-Form $fm.Value $MeterUrl }

    $links=@()
    foreach($m in [regex]::Matches($html,'(?is)<a\b(?<attrs>[^>]*)>(?<body>.*?)</a>')){
        $href=Attr $m.Groups['attrs'].Value 'href'; if([string]::IsNullOrWhiteSpace($href)){continue}
        $abs=Absolute-Url $href $MeterUrl; $text=Clean-Text $m.Groups['body'].Value
        if($abs -match '(?i)/meter/|reading|counter|device|value'){ $links += [pscustomobject]@{Text=$text;Url=$abs} }
    }

    $inputs=@()
    foreach($m in [regex]::Matches($html,'(?is)<input\b(?<attrs>[^>]*)>')){
        $a=$m.Groups['attrs'].Value
        $name=Attr $a 'name'; $id=Attr $a 'id'; $type=Attr $a 'type'; if([string]::IsNullOrWhiteSpace($type)){$type='text'}
        $value=Attr $a 'value'; if($name -match '(?i)csrf|token'){$value='[REDACTED]'}
        $inputs += [pscustomobject]@{Name=$name;Id=$id;Type=$type;Value=(Redact $value);Placeholder=(Redact (Attr $a 'placeholder'));Min=(Attr $a 'min');Max=(Attr $a 'max');Step=(Attr $a 'step')}
    }

    $lines=New-Object Collections.Generic.List[string]
    $lines.Add('DOMLIGHT METER STRUCTURE DISCOVERY - LIVE SESSION - READ ONLY')
    $lines.Add('Generated: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('Authenticated session: YES')
    $lines.Add('HTTP: '+[int]$r.StatusCode)
    $lines.Add('URL: '+$MeterUrl)
    $lines.Add('Title: '+(Redact $title))
    $lines.Add('No POST/PUT/PATCH/DELETE requests were sent by this discovery stage.')
    $lines.Add('')
    $lines.Add('VISIBLE PAGE TEXT:')
    $lines.Add('  '+(Redact $pageText))
    $lines.Add('')
    $lines.Add('METER-RELATED LINKS:')
    if($links.Count -eq 0){$lines.Add('  NONE')}else{foreach($x in $links|Sort-Object Url,Text -Unique){$lines.Add('  '+(Redact $x.Text)+' -> '+(Redact $x.Url))}}
    $lines.Add('')
    $lines.Add('ALL INPUTS ON /meter/index:')
    if($inputs.Count -eq 0){$lines.Add('  NONE')}else{foreach($x in $inputs){$lines.Add(('  name={0} | id={1} | type={2} | value={3} | placeholder={4} | min={5} | max={6} | step={7}' -f $x.Name,$x.Id,$x.Type,$x.Value,$x.Placeholder,$x.Min,$x.Max,$x.Step))}}
    $lines.Add('')
    $lines.Add('FORMS ON /meter/index:')
    if($forms.Count -eq 0){$lines.Add('  NONE')}else{
        $i=0
        foreach($f in $forms){
            $i++
            $lines.Add(('  FORM #{0}: method={1} action={2}' -f $i,$f.Method,(Redact $f.Action)))
            $lines.Add('    text: '+(Redact $f.Text))
            foreach($field in $f.Fields){$lines.Add('    '+(Redact $field))}
        }
    }

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
    [Windows.Forms.MessageBox]::Show("Диагностика структуры счётчиков завершена.`r`nНичего на портал не отправлялось.`r`n`r`nОтчёт:`r`n$OutFile",'Domlight - счётчики','OK','Information')|Out-Null
    Start-Process notepad.exe ('"'+$OutFile+'"')
}
catch {
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight - диагностика счётчиков','OK','Error')|Out-Null
    exit 1
}
