param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'

$DomlightFile = Join-Path $Root 'Domlight.ps1'
$DataDir = Join-Path $Root 'data'
$OutFile = Join-Path $DataDir 'meter_discovery_report.txt'

function Get-AbsoluteUrl {
    param([string]$Href, [string]$From)
    try { return ([Uri]::new([Uri]$From, $Href)).AbsoluteUri } catch { return '' }
}

function Get-CleanText {
    param([string]$Html)
    if ($null -eq $Html) { return '' }
    $x = $Html -replace '(?is)<script.*?</script>', ' '
    $x = $x -replace '(?is)<style.*?</style>', ' '
    $x = $x -replace '<[^>]+>', ' '
    $x = [Net.WebUtility]::HtmlDecode($x)
    return (($x -replace '\s+', ' ').Trim())
}

function Get-Attr {
    param([string]$Attrs, [string]$Name)
    $pattern = '(?is)(?:^|\s)' + [regex]::Escape($Name) + '\s*=\s*["'']([^"'']*)["'']'
    $m = [regex]::Match($Attrs, $pattern)
    if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    return ''
}

function Redact-Text {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $x = $Text
    $x = [regex]::Replace($x, '(?i)(csrf|token|authorization|cookie)(\s*[=:]\s*)[^\s&;"'']+', '$1$2[REDACTED]')
    $x = [regex]::Replace($x, '\b\d{10,16}\b', '[NUMBER]')
    return $x
}

function Add-CodeMatches {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Label,
        [string]$Text
    )

    $Lines.Add($Label)
    $keywords = @('/meter/', 'meter', 'ajax', 'fetch(', 'XMLHttpRequest', 'Отправить', 'показан', '.post(', 'w0', 'w1', 'w2', 'w3', 'w4', 'w5')
    $found = 0

    foreach ($keyword in $keywords) {
        $start = 0
        while ($start -lt $Text.Length) {
            $index = $Text.IndexOf($keyword, $start, [System.StringComparison]::OrdinalIgnoreCase)
            if ($index -lt 0) { break }

            $left = [Math]::Max(0, $index - 180)
            $length = [Math]::Min(650, $Text.Length - $left)
            $snippet = $Text.Substring($left, $length)
            $snippet = (($snippet -replace '\s+', ' ').Trim())
            $Lines.Add(('  [{0}] {1}' -f ($found + 1), (Redact-Text $snippet)))
            $found++
            if ($found -ge 30) { return }
            $start = $index + [Math]::Max(1, $keyword.Length)
        }
    }

    if ($found -eq 0) { $Lines.Add('  NONE') }
}

try {
    if (-not (Test-Path -LiteralPath $DomlightFile)) {
        throw "Domlight.ps1 не найден: $DomlightFile"
    }

    [Windows.Forms.MessageBox]::Show(
        "Откроется обычный Domlight.`r`n`r`nУбедитесь, что статус 'Подключено', затем закройте только это окно.`r`n`r`nПосле закрытия диагностика прочитает кнопки и JavaScript страницы счётчиков. Ничего отправляться не будет.",
        'Domlight - диагностика счётчиков',
        'OK',
        'Information'
    ) | Out-Null

    . $DomlightFile

    $verify = Invoke-DomlightGet $ReceiptsUrl
    if (-not (Is-Authenticated ([string]$verify.Content))) {
        throw 'Сессия не авторизована.'
    }

    $MeterUrl = "$BaseUrl/meter/index"
    $response = Invoke-DomlightGet $MeterUrl
    $html = [string]$response.Content
    if (-not (Is-Authenticated $html)) {
        throw 'Нет авторизации на странице счётчиков.'
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('DOMLIGHT METER SUBMIT DISCOVERY - LIVE SESSION - READ ONLY')
    $lines.Add('Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('Authenticated session: YES')
    $lines.Add('URL: ' + $MeterUrl)
    $lines.Add('No POST/PUT/PATCH/DELETE requests were sent by this discovery stage.')
    $lines.Add('')

    $lines.Add('INTERACTIVE ELEMENTS:')
    $elementCount = 0

    foreach ($m in [regex]::Matches($html, '(?is)<button\b(?<attrs>[^>]*)>(?<body>.*?)</button>')) {
        $attrs = $m.Groups['attrs'].Value
        $body = $m.Groups['body'].Value
        $id = Get-Attr $attrs 'id'
        $class = Get-Attr $attrs 'class'
        $onclick = Get-Attr $attrs 'onclick'
        $type = Get-Attr $attrs 'type'
        $text = Get-CleanText $body
        $data = @()
        foreach ($dm in [regex]::Matches($attrs, '(?is)\s(data-[\w-]+)=["'']([^"'']*)["'']')) {
            $data += ($dm.Groups[1].Value + '=' + $dm.Groups[2].Value)
        }
        $combined = $id + ' ' + $class + ' ' + $onclick + ' ' + $type + ' ' + $text + ' ' + ($data -join ' ')
        if ($combined -match '(?i)meter|показан|отправ|send|submit|value|w[0-9]|ajax') {
            $lines.Add(('  BUTTON id={0} class={1} type={2} text="{3}" onclick="{4}" data="{5}"' -f $id, $class, $type, (Redact-Text $text), (Redact-Text $onclick), (Redact-Text ($data -join '; '))))
            $elementCount++
        }
    }

    foreach ($m in [regex]::Matches($html, '(?is)<a\b(?<attrs>[^>]*)>(?<body>.*?)</a>')) {
        $attrs = $m.Groups['attrs'].Value
        $body = $m.Groups['body'].Value
        $id = Get-Attr $attrs 'id'
        $class = Get-Attr $attrs 'class'
        $onclick = Get-Attr $attrs 'onclick'
        $href = Get-Attr $attrs 'href'
        $text = Get-CleanText $body
        $data = @()
        foreach ($dm in [regex]::Matches($attrs, '(?is)\s(data-[\w-]+)=["'']([^"'']*)["'']')) {
            $data += ($dm.Groups[1].Value + '=' + $dm.Groups[2].Value)
        }
        $combined = $id + ' ' + $class + ' ' + $onclick + ' ' + $href + ' ' + $text + ' ' + ($data -join ' ')
        if ($combined -match '(?i)meter|показан|отправ|send|submit|value|w[0-9]|ajax') {
            $lines.Add(('  A id={0} class={1} text="{2}" href="{3}" onclick="{4}" data="{5}"' -f $id, $class, (Redact-Text $text), (Redact-Text $href), (Redact-Text $onclick), (Redact-Text ($data -join '; '))))
            $elementCount++
        }
    }

    foreach ($m in [regex]::Matches($html, '(?is)<input\b(?<attrs>[^>]*)>')) {
        $attrs = $m.Groups['attrs'].Value
        $id = Get-Attr $attrs 'id'
        $class = Get-Attr $attrs 'class'
        $type = Get-Attr $attrs 'type'
        $name = Get-Attr $attrs 'name'
        $value = Get-Attr $attrs 'value'
        $onclick = Get-Attr $attrs 'onclick'
        $data = @()
        foreach ($dm in [regex]::Matches($attrs, '(?is)\s(data-[\w-]+)=["'']([^"'']*)["'']')) {
            $data += ($dm.Groups[1].Value + '=' + $dm.Groups[2].Value)
        }
        $combined = $id + ' ' + $class + ' ' + $type + ' ' + $name + ' ' + $onclick + ' ' + ($data -join ' ')
        if ($combined -match '(?i)meter|показан|отправ|send|submit|value|w[0-9]|ajax') {
            $lines.Add(('  INPUT id={0} class={1} type={2} name={3} value="{4}" onclick="{5}" data="{6}"' -f $id, $class, $type, $name, (Redact-Text $value), (Redact-Text $onclick), (Redact-Text ($data -join '; '))))
            $elementCount++
        }
    }

    if ($elementCount -eq 0) { $lines.Add('  NONE') }

    $lines.Add('')
    Add-CodeMatches -Lines $lines -Label 'INLINE HTML / SCRIPT MATCHES:' -Text $html

    $lines.Add('')
    $lines.Add('EXTERNAL JAVASCRIPT:')
    $scriptCount = 0
    foreach ($sm in [regex]::Matches($html, '(?is)<script\b[^>]*src=["'']([^"'']+)["''][^>]*>')) {
        $src = Get-AbsoluteUrl ([Net.WebUtility]::HtmlDecode($sm.Groups[1].Value)) $MeterUrl
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        $scriptCount++
        $lines.Add('  SCRIPT: ' + (Redact-Text $src))
        try {
            if (([Uri]$src).Host -eq ([Uri]$BaseUrl).Host) {
                $jsResponse = Invoke-DomlightGet $src
                $js = [string]$jsResponse.Content
                Add-CodeMatches -Lines $lines -Label '    MATCHES:' -Text $js
            }
            else {
                $lines.Add('    skipped external host')
            }
        }
        catch {
            $lines.Add('    read error: ' + $_.Exception.Message)
        }
    }
    if ($scriptCount -eq 0) { $lines.Add('  NONE') }

    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $lines | Set-Content -LiteralPath $OutFile -Encoding UTF8

    [Windows.Forms.MessageBox]::Show(
        "Диагностика JavaScript завершена.`r`nНичего на портал не отправлялось.`r`n`r`nОтчёт:`r`n$OutFile",
        'Domlight - счётчики',
        'OK',
        'Information'
    ) | Out-Null

    Start-Process notepad.exe ('"' + $OutFile + '"')
}
catch {
    [Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        'Domlight - диагностика счётчиков',
        'OK',
        'Error'
    ) | Out-Null
    exit 1
}
