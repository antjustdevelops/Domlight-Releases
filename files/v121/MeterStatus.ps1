Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$ErrorActionPreference = 'Stop'
$BaseUrl = 'https://lk.kakdoma.life'
$ReceiptsUrl = "$BaseUrl/receipt/index"
$AccountSetUrl = "$BaseUrl/account/set"
$MeterUrl = "$BaseUrl/meter/index"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$SessionFile = Join-Path $DataDir 'session.dat'
$ConnectionFile = Join-Path $DataDir 'connection.json'
$AccountsStateFile = Join-Path $DataDir 'accounts_state.json'

function Unprotect-Text([string]$Text) {
    $bytes = [Convert]::FromBase64String($Text)
    $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($dec)
}

function Load-WebSession {
    if (-not (Test-Path -LiteralPath $SessionFile)) { throw 'Сохранённая сессия Domlight не найдена. Сначала войдите в кабинет Domlight.' }
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $protected = Get-Content $SessionFile -Raw
    $json = Unprotect-Text $protected
    $arr = $json | ConvertFrom-Json
    foreach ($x in @($arr)) {
        $c = New-Object System.Net.Cookie($x.Name, $x.Value, $x.Path, $x.Domain)
        $session.Cookies.Add($c)
    }
    return $session
}

function Get-ProxyArgs {
    $args = @{}
    if (-not (Test-Path $ConnectionFile)) { return $args }
    try {
        $cfg = Get-Content $ConnectionFile -Raw | ConvertFrom-Json
        if (-not [bool]$cfg.useProxy) { return $args }
        if ([string]::IsNullOrWhiteSpace([string]$cfg.proxyUrl)) { return $args }
        $args['Proxy'] = [string]$cfg.proxyUrl
        $args['ProxyUseDefaultCredentials'] = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$cfg.proxyUser)) {
            $sec = ConvertTo-SecureString ([string]$cfg.proxyPassword) -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential ([string]$cfg.proxyUser, $sec)
            $args['ProxyCredential'] = $cred
        }
    } catch {}
    return $args
}

function Invoke-Get([string]$Url, $Session) {
    $proxy = Get-ProxyArgs
    return Invoke-WebRequest -Uri $Url -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
        'Accept-Language' = 'ru-RU,ru;q=0.9'
    }
}

function Is-Authenticated([string]$Html) {
    return ($Html -match 'action=["'']/account/set["'']' -or $Html -match '/receipt/index')
}

function Get-Csrf([string]$Html) {
    $m = [regex]::Match($Html, '<meta[^>]+name=["'']csrf-token["''][^>]+content=["'']([^"'']+)["'']', 'IgnoreCase')
    if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    $m = [regex]::Match($Html, '<input[^>]+name=["'']_csrf-lk["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
    if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    $m = [regex]::Match($Html, '<input[^>]+value=["'']([^"'']+)["''][^>]+name=["'']_csrf-lk["'']', 'IgnoreCase')
    if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    throw 'Не найден CSRF-токен Домлайта.'
}

function Parse-Accounts([string]$Html) {
    $forms = [regex]::Matches($Html, '<form[^>]+action=["'']/account/set["''][\s\S]*?</form>', 'IgnoreCase')
    $result = @(); $seen = @{}
    foreach ($f in $forms) {
        $am = [regex]::Match($f.Value, '<input[^>]+name=["'']account["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        $cm = [regex]::Match($f.Value, '<input[^>]+name=["'']company["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        if (-not ($am.Success -and $cm.Success)) { continue }
        $account = [Net.WebUtility]::HtmlDecode($am.Groups[1].Value)
        $company = [Net.WebUtility]::HtmlDecode($cm.Groups[1].Value)
        $key = "$company|$account"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result += [pscustomobject]@{ Account=$account; Company=$company }
    }
    return $result
}

function Load-AccountDetails {
    $map = @{}
    if (-not (Test-Path -LiteralPath $AccountsStateFile)) { return $map }
    try {
        $items = Get-Content -LiteralPath $AccountsStateFile -Raw | ConvertFrom-Json
        foreach ($item in @($items)) {
            $account = ([string]$item.Account).Trim()
            if ([string]::IsNullOrWhiteSpace($account)) { continue }
            $map[$account] = [pscustomobject]@{
                Address = ([string]$item.Address).Trim()
                Apartment = ([string]$item.Apartment).Trim()
                Excluded = [bool]$item.Excluded
            }
        }
    } catch {}
    return $map
}

function Switch-Account($Session,[string]$Company,[string]$Account) {
    $html = (Invoke-Get $ReceiptsUrl $Session).Content
    $csrf = Get-Csrf $html
    $headers = @{
        'Referer' = $ReceiptsUrl
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
    }
    $body = '_csrf-lk=' + [uri]::EscapeDataString($csrf) + '&company=' + [uri]::EscapeDataString($Company) + '&account=' + [uri]::EscapeDataString($Account)
    try {
        $proxy = Get-ProxyArgs
        Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body $body | Out-Null
    } catch {
        $resp = $_.Exception.Response
        $status = $null
        try { $status = [int]$resp.StatusCode } catch {}
        if ($status -ne 302) { throw }
    }
}

function Clean-Text([string]$Html) {
    if ($null -eq $Html) { return '' }
    return (([Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim())
}

function Get-Attr([string]$Tag,[string]$Name) {
    $p = '(?is)(?:^|\s)' + [regex]::Escape($Name) + '\s*=\s*["'']([^"'']*)["'']'
    $m = [regex]::Match($Tag,$p)
    if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    return ''
}

function Parse-Meters([string]$Html,[string]$Account,[string]$Address) {
    $allStart = $Html.IndexOf('id="tab_meter_all"')
    if ($allStart -lt 0) { $allStart = $Html.IndexOf("id='tab_meter_all'") }
    $waterStart = $Html.IndexOf('id="tab_meter_water"')
    if ($waterStart -lt 0) { $waterStart = $Html.IndexOf("id='tab_meter_water'") }
    if ($allStart -ge 0 -and $waterStart -gt $allStart) { $scope = $Html.Substring($allStart,$waterStart-$allStart) } else { $scope = $Html }

    $cardPattern = '<div class="card mb-5 p-8">'
    $positions = New-Object System.Collections.Generic.List[int]
    $searchFrom = 0
    while ($true) {
        $p = $scope.IndexOf($cardPattern,$searchFrom,[StringComparison]::OrdinalIgnoreCase)
        if ($p -lt 0) { break }
        $positions.Add($p)
        $searchFrom = $p + $cardPattern.Length
    }

    $rows = @(); $seen = @{}
    for ($i=0; $i -lt $positions.Count; $i++) {
        $start = $positions[$i]
        $end = if ($i+1 -lt $positions.Count) { $positions[$i+1] } else { $scope.Length }
        $card = $scope.Substring($start,$end-$start)

        $inputM = [regex]::Match($card,'<input[^>]+class=["''][^"'']*meter-input[^"'']*["''][^>]*>','IgnoreCase')
        if (-not $inputM.Success) { continue }
        $tag = $inputM.Value
        $meterId = Get-Attr $tag 'data-id'
        if ([string]::IsNullOrWhiteSpace($meterId) -or $seen.ContainsKey($meterId)) { continue }
        $seen[$meterId] = $true

        $headM = [regex]::Match($card,'(?is)<h2[^>]*>(.*?)</h2>')
        $headText = if ($headM.Success) { Clean-Text $headM.Groups[1].Value } else { '' }
        $type = $headText; $number = ''
        $numM = [regex]::Match($headText,'№\s*(.+)$')
        if ($numM.Success) { $number=$numM.Groups[1].Value.Trim(); $type=$headText.Substring(0,$numM.Index).Trim() }

        $date=''; $dateM=[regex]::Match($card,'Передавали\s+(\d{2}\.\d{2}\.\d{4})','IgnoreCase'); if($dateM.Success){$date=$dateM.Groups[1].Value}
        $previous=''; $prevM=[regex]::Match($card,'Показания\s+прошлого\s+периода\s+([0-9.,]+)','IgnoreCase'); if($prevM.Success){$previous=$prevM.Groups[1].Value.Replace(',','.')}
        $verification=''; $verM=[regex]::Match($card,'title=["'']Поверка:\s*([^"'']*)["'']','IgnoreCase'); if($verM.Success){$verification=[Net.WebUtility]::HtmlDecode($verM.Groups[1].Value)}

        $rows += [pscustomobject]@{
            Account=$Account; Address=$Address; Type=$type; Number=$number
            Value=(Get-Attr $tag 'value'); Previous=$previous; Unit=(Get-Attr $tag 'data-unit')
            LastDate=$date; Verification=$verification
        }
    }
    return $rows
}

$form=New-Object Windows.Forms.Form
$form.Text='Счётчики / показания — только чтение'
$form.StartPosition='CenterScreen'
$form.ClientSize=New-Object Drawing.Size(1450,700)
$form.MinimumSize=New-Object Drawing.Size(1050,430)
$form.FormBorderStyle='Sizable'
$form.MaximizeBox=$true
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.KeyPreview=$true

$title=New-Object Windows.Forms.Label;$title.Text='Счётчики / показания';$title.Location=New-Object Drawing.Point(20,15);$title.Size=New-Object Drawing.Size(500,34);$title.Font=New-Object Drawing.Font('Segoe UI Semibold',16);$form.Controls.Add($title)
$status=New-Object Windows.Forms.Label;$status.Text='Загрузка данных с портала...';$status.Location=New-Object Drawing.Point(22,52);$status.Size=New-Object Drawing.Size(1300,25);$status.ForeColor=[Drawing.Color]::DimGray;$status.Anchor='Top,Left,Right';$form.Controls.Add($status)
$grid=New-Object Windows.Forms.DataGridView;$grid.Location=New-Object Drawing.Point(20,88);$grid.Size=New-Object Drawing.Size(1410,545);$grid.Anchor='Top,Bottom,Left,Right';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.SelectionMode='FullRowSelect';$grid.AutoGenerateColumns=$false;$grid.BackgroundColor=[Drawing.Color]::White;$grid.ScrollBars='Both';$form.Controls.Add($grid)

$specs=@(@{N='Account';H='Лицевой счёт';W=125},@{N='Address';H='Адрес';W=390},@{N='Type';H='Счётчик';W=150},@{N='Number';H='№ прибора';W=145},@{N='Value';H='Текущее';W=90},@{N='Previous';H='Прошлый период';W=115},@{N='Unit';H='Ед.';W=70},@{N='LastDate';H='Передавали';W=105},@{N='Verification';H='Поверка';W=120})
foreach($s in $specs){$c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$s.N;$c.DataPropertyName=$s.N;$c.HeaderText=$s.H;$c.Width=$s.W;if($s.N-eq'Address'){$c.AutoSizeMode='Fill';$c.MinimumWidth=300};[void]$grid.Columns.Add($c)}

$form.Add_Shown({
    try {
        $session=Load-WebSession
        $page=Invoke-Get $ReceiptsUrl $session
        if(-not(Is-Authenticated([string]$page.Content))){throw'Сессия Домлайта закончилась. Войдите в кабинет Domlight и повторите.'}
        $accounts=@(Parse-Accounts([string]$page.Content));if($accounts.Count-eq0){throw'Не удалось получить лицевые счета с портала.'}
        $details=Load-AccountDetails;$rows=New-Object System.Collections.ArrayList;$checked=0
        foreach($acc in $accounts){
            if($details.ContainsKey([string]$acc.Account)-and[bool]$details[[string]$acc.Account].Excluded){continue}
            $checked++;$status.Text="Читаю счётчики: ЛС $checked из $($accounts.Count) — $($acc.Account)";[Windows.Forms.Application]::DoEvents()
            Switch-Account $session ([string]$acc.Company) ([string]$acc.Account)
            $meterPage=Invoke-Get $MeterUrl $session
            $address='';if($details.ContainsKey([string]$acc.Account)){$address=[string]$details[[string]$acc.Account].Address;if([string]::IsNullOrWhiteSpace($address)){$apt=[string]$details[[string]$acc.Account].Apartment;if(-not[string]::IsNullOrWhiteSpace($apt)){$address='кв. '+$apt}}}
            foreach($row in @(Parse-Meters([string]$meterPage.Content)([string]$acc.Account)$address)){[void]$rows.Add($row)}
        }
        $grid.DataSource=$rows;$status.Text="Готово. Лицевых счетов проверено: $checked. Счётчиков найдено: $($rows.Count). Передача показаний отключена.";$status.ForeColor=[Drawing.Color]::DarkGreen
    } catch {$status.Text='Ошибка: '+$_.Exception.Message;$status.ForeColor=[Drawing.Color]::DarkRed;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight — счётчики','OK','Error')|Out-Null}
})
$form.Add_KeyDown({if($_.KeyCode-eq[Windows.Forms.Keys]::Escape){$form.Close()}})
[void]$form.ShowDialog()
