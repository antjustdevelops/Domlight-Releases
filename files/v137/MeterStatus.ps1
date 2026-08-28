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

$script:AllMeters = @()
$script:ObjectRows = @()
$script:CurrentFilter = 'all'
$script:Drafts = @{}

function Unprotect-Text([string]$Text) {
    $bytes = [Convert]::FromBase64String($Text)
    $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($dec)
}

function Load-WebSession {
    if (-not (Test-Path -LiteralPath $SessionFile)) { throw 'Сохранённая сессия Domlight не найдена.' }
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $protected = Get-Content $SessionFile -Raw
    $json = Unprotect-Text $protected
    $arr = $json | ConvertFrom-Json
    foreach ($x in @($arr)) {
        $cookie = New-Object System.Net.Cookie($x.Name, $x.Value, $x.Path, $x.Domain)
        $session.Cookies.Add($cookie)
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
            $args['ProxyCredential'] = New-Object System.Management.Automation.PSCredential ([string]$cfg.proxyUser, $sec)
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
    foreach ($formHtml in $forms) {
        $am = [regex]::Match($formHtml.Value, '<input[^>]+name=["'']account["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        $cm = [regex]::Match($formHtml.Value, '<input[^>]+name=["'']company["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
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
    $body = '_csrf-lk=' + [uri]::EscapeDataString($csrf) + '&company=' + [uri]::EscapeDataString($Company) + '&account=' + [uri]::EscapeDataString($Account)
    $proxy = Get-ProxyArgs
    try {
        Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
            'Referer' = $ReceiptsUrl
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
        } -ContentType 'application/x-www-form-urlencoded' -Body $body | Out-Null
    } catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        if ($statusCode -ne 302) { throw }
    }
}

function Clean-Text([string]$Html) {
    if ($null -eq $Html) { return '' }
    return (([Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>',' ')) -replace '\s+',' ').Trim())
}

function Get-Attr([string]$Tag,[string]$Name) {
    $pattern = '(?is)(?:^|\s)' + [regex]::Escape($Name) + '\s*=\s*["'']([^"'']*)["'']'
    $m = [regex]::Match($Tag,$pattern)
    if ($m.Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    return ''
}

function Get-MonthStatus([string]$LastDate) {
    if ([string]::IsNullOrWhiteSpace($LastDate)) { return 'Не передано' }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($LastDate,'dd.MM.yyyy',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)
    if (-not $ok) { return 'Дата неизвестна' }
    $now = Get-Date
    if ($parsed.Year -eq $now.Year -and $parsed.Month -eq $now.Month) { return 'Передано' }
    return 'Не передано'
}

function Get-ShortAddress([string]$Address,[string]$Apartment) {
    if ([string]::IsNullOrWhiteSpace($Address)) {
        if (-not [string]::IsNullOrWhiteSpace($Apartment)) { return 'кв. ' + $Apartment }
        return ''
    }
    $parts = @($Address.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $streetIndex = -1
    for ($i=0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -match '(?i)(улиц|\bул\.?\b|бульвар|\bб-р\b|проспект|\bпр-т\b|шоссе|\bш\.?\b|переулок|\bпер\.?\b|набережн|\bнаб\.?\b|проезд|площад|аллея)') { $streetIndex=$i; break }
    }
    if ($streetIndex -ge 0) {
        [int]$lastIndex = [int]$parts.Count - 1
        return ($parts[$streetIndex..$lastIndex] -join ', ')
    }
    $keep = @($parts | Where-Object {
        $_ -notmatch '^\d{6}$' -and $_ -notmatch '(?i)^Москва$' -and $_ -notmatch '(?i)^г\.\s*Москва$' -and $_ -notmatch '(?i)вн\.тер' -and $_ -notmatch '(?i)муниципальн.*округ'
    })
    if ($keep.Count -gt 0) { return ($keep -join ', ') }
    return $Address
}

function Parse-Meters([string]$Html,[string]$Account,[string]$Address) {
    $allStart = $Html.IndexOf('id="tab_meter_all"')
    if ($allStart -lt 0) { $allStart = $Html.IndexOf("id='tab_meter_all'") }
    $waterStart = $Html.IndexOf('id="tab_meter_water"')
    if ($waterStart -lt 0) { $waterStart = $Html.IndexOf("id='tab_meter_water'") }
    if ($allStart -ge 0 -and $waterStart -gt $allStart) { $scope = $Html.Substring($allStart,$waterStart-$allStart) } else { $scope = $Html }

    $cardPattern = '<div class="card mb-5 p-8">'
    $positions = New-Object System.Collections.Generic.List[int]
    [int]$searchFrom = 0
    while ($true) {
        [int]$position = $scope.IndexOf($cardPattern,$searchFrom,[StringComparison]::OrdinalIgnoreCase)
        if ($position -lt 0) { break }
        $positions.Add($position)
        $searchFrom = [int]$position + [int]$cardPattern.Length
    }

    $rows = @(); $seen = @{}
    for ($i=0; $i -lt $positions.Count; $i++) {
        [int]$start = $positions[$i]
        if ($i+1 -lt $positions.Count) { [int]$end = $positions[$i+1] } else { [int]$end = $scope.Length }
        [int]$length = $end - $start
        $card = $scope.Substring($start,$length)
        $inputM = [regex]::Match($card,'<input[^>]+class=["''][^"'']*meter-input[^"'']*["''][^>]*>','IgnoreCase')
        if (-not $inputM.Success) { continue }
        $tag = $inputM.Value
        $meterId = Get-Attr $tag 'data-id'
        if ([string]::IsNullOrWhiteSpace($meterId) -or $seen.ContainsKey($meterId)) { continue }
        $seen[$meterId] = $true

        $headM = [regex]::Match($card,'(?is)<h2[^>]*>(.*?)</h2>')
        if ($headM.Success) { $headText = Clean-Text $headM.Groups[1].Value } else { $headText = '' }
        $type=$headText; $number=''
        $numM=[regex]::Match($headText,'№\s*(.+)$')
        if ($numM.Success) { $number=$numM.Groups[1].Value.Trim(); $type=$headText.Substring(0,$numM.Index).Trim() }

        $date=''
        $dateM=[regex]::Match($card,'Передавали\s+(\d{2}\.\d{2}\.\d{4})','IgnoreCase')
        if($dateM.Success){$date=$dateM.Groups[1].Value}
        $verification=''
        $verM=[regex]::Match($card,'title=["'']Поверка:\s*([^"'']*)["'']','IgnoreCase')
        if($verM.Success){$verification=[Net.WebUtility]::HtmlDecode($verM.Groups[1].Value)}

        $rows += [pscustomobject]@{
            Account=$Account; Address=$Address; MeterId=$meterId; Type=$type; Number=$number
            LastValue=(Get-Attr $tag 'value'); Unit=(Get-Attr $tag 'data-unit'); LastDate=$date
            MonthStatus=(Get-MonthStatus $date); Verification=$verification
        }
    }
    return $rows
}

function Build-ObjectRows {
    $result=@()
    foreach($group in @($script:AllMeters | Group-Object Account)) {
        $meters=@($group.Group)
        if($meters.Count -eq 0){continue}
        $pending=@($meters | Where-Object {$_.MonthStatus -ne 'Передано'}).Count
        $draftCount=0
        foreach($meter in $meters){
            $key=$meter.Account+'|'+$meter.MeterId
            if($script:Drafts.ContainsKey($key)){
                $draft=$script:Drafts[$key]
                if([bool]$draft.Selected -and -not [string]::IsNullOrWhiteSpace([string]$draft.Value)){$draftCount++}
            }
        }
        if($pending -eq 0){$state='Всё передано'}else{$state='Нужно передать: '+$pending}
        $result += [pscustomobject]@{Account=$group.Name;Address=[string]$meters[0].Address;MeterCount=$meters.Count;PendingCount=$pending;DraftCount=$draftCount;Status=$state}
    }
    $script:ObjectRows=@($result)
}

$form=New-Object Windows.Forms.Form
$form.Text='Счётчики / показания — объекты'
$form.StartPosition='CenterScreen'
$form.ClientSize=New-Object Drawing.Size(1250,430)
$form.MinimumSize=New-Object Drawing.Size(980,330)
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.KeyPreview=$true
$form.MaximizeBox=$true

$title=New-Object Windows.Forms.Label;$title.Text='Счётчики / показания';$title.Location=New-Object Drawing.Point(20,15);$title.Size=New-Object Drawing.Size(450,34);$title.Font=New-Object Drawing.Font('Segoe UI Semibold',16);$form.Controls.Add($title)
$summary=New-Object Windows.Forms.Label;$summary.Text='Загрузка данных с портала...';$summary.Location=New-Object Drawing.Point(22,51);$summary.Size=New-Object Drawing.Size(1185,25);$summary.Anchor='Top,Left,Right';$summary.ForeColor=[Drawing.Color]::DimGray;$form.Controls.Add($summary)
$searchLabel=New-Object Windows.Forms.Label;$searchLabel.Text='Поиск:';$searchLabel.Location=New-Object Drawing.Point(20,88);$searchLabel.Size=New-Object Drawing.Size(55,24);$form.Controls.Add($searchLabel)
$txtSearch=New-Object Windows.Forms.TextBox;$txtSearch.Location=New-Object Drawing.Point(75,84);$txtSearch.Size=New-Object Drawing.Size(330,28);$form.Controls.Add($txtSearch)
$btnAll=New-Object Windows.Forms.Button;$btnAll.Text='Все';$btnAll.Location=New-Object Drawing.Point(425,82);$btnAll.Size=New-Object Drawing.Size(90,32);$form.Controls.Add($btnAll)
$btnNeed=New-Object Windows.Forms.Button;$btnNeed.Text='Нужно передать';$btnNeed.Location=New-Object Drawing.Point(525,82);$btnNeed.Size=New-Object Drawing.Size(145,32);$form.Controls.Add($btnNeed)
$btnDone=New-Object Windows.Forms.Button;$btnDone.Text='Передано';$btnDone.Location=New-Object Drawing.Point(680,82);$btnDone.Size=New-Object Drawing.Size(115,32);$form.Controls.Add($btnDone)

$grid=New-Object Windows.Forms.DataGridView
$grid.Location=New-Object Drawing.Point(20,126);$grid.Size=New-Object Drawing.Size(1210,225);$grid.Anchor='Top,Bottom,Left,Right'
$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.AutoGenerateColumns=$false;$grid.BackgroundColor=[Drawing.Color]::White;$grid.AutoSizeColumnsMode='Fill';$grid.ScrollBars='Vertical';$grid.ColumnHeadersHeight=28;$grid.RowTemplate.Height=24
$form.Controls.Add($grid)

foreach($spec in @(
    @{Name='Address';Header='Объект';Weight=44;Min=320},@{Name='Account';Header='Лицевой счёт';Weight=16;Min=130},@{Name='MeterCount';Header='Счётчиков';Weight=10;Min=85},@{Name='Status';Header='Статус месяца';Weight=18;Min=145},@{Name='DraftCount';Header='Готово к отправке';Weight=12;Min=120}
)){
    $column=New-Object Windows.Forms.DataGridViewTextBoxColumn;$column.Name=$spec.Name;$column.HeaderText=$spec.Header;$column.ReadOnly=$true;$column.AutoSizeMode='Fill';$column.FillWeight=$spec.Weight;$column.MinimumWidth=$spec.Min;[void]$grid.Columns.Add($column)
}

$btnOpen=New-Object Windows.Forms.Button;$btnOpen.Text='Открыть объект';$btnOpen.Size=New-Object Drawing.Size(170,38);$btnOpen.Location=New-Object Drawing.Point(1060,367);$btnOpen.Anchor='Bottom,Right';$form.Controls.Add($btnOpen)

function Set-MainCompactHeight {
    [int]$objectCount = @($script:ObjectRows).Count
    [int]$visibleRows = $objectCount
    if ($visibleRows -lt 1) { $visibleRows = 1 }
    if ($visibleRows -gt 12) { $visibleRows = 12 }

    [int]$gridHeight = 28 + ($visibleRows * 24) + 3
    [int]$clientHeight = 126 + $gridHeight + 78
    if ($clientHeight -lt 330) { $clientHeight = 330 }

    [int]$clientWidth = [int]$form.ClientSize.Width
    [int]$gridWidth = [int]$grid.Width
    [int]$buttonLeft = [int]$btnOpen.Left
    [int]$buttonTop = $clientHeight - 63

    $form.ClientSize = New-Object System.Drawing.Size -ArgumentList $clientWidth,$clientHeight
    $grid.Size = New-Object System.Drawing.Size -ArgumentList $gridWidth,$gridHeight
    $btnOpen.Location = New-Object System.Drawing.Point -ArgumentList $buttonLeft,$buttonTop
}

function Refresh-Grid {
    Build-ObjectRows
    $query=$txtSearch.Text.Trim().ToLowerInvariant();$grid.Rows.Clear()
    foreach($item in $script:ObjectRows){
        switch($script:CurrentFilter){'need'{$filterOk=$item.PendingCount-gt0};'done'{$filterOk=$item.PendingCount-eq0};default{$filterOk=$true}}
        if(-not$filterOk){continue}
        $searchOk=[string]::IsNullOrWhiteSpace($query)-or$item.Address.ToLowerInvariant().Contains($query)-or$item.Account.ToLowerInvariant().Contains($query)
        if(-not$searchOk){continue}
        $rowIndex=$grid.Rows.Add();$row=$grid.Rows[$rowIndex];$row.Height=24
        $row.Cells['Address'].Value=$item.Address;$row.Cells['Account'].Value=$item.Account;$row.Cells['MeterCount'].Value=$item.MeterCount;$row.Cells['Status'].Value=$item.Status;$row.Cells['DraftCount'].Value=$item.DraftCount;$row.Tag=$item.Account
        if($item.PendingCount-eq0){$row.Cells['Status'].Style.ForeColor=[Drawing.Color]::DarkGreen}else{$row.Cells['Status'].Style.ForeColor=[Drawing.Color]::DarkRed}
    }
}

function Show-ObjectDialog([string]$Account) {
    $meters=@($script:AllMeters | Where-Object {$_.Account -eq $Account})
    if($meters.Count -eq 0){return}

    [int]$visibleRows = [int]$meters.Count
    if ($visibleRows -lt 1) { $visibleRows = 1 }
    if ($visibleRows -gt 8) { $visibleRows = 8 }
    [int]$gridHeight = 28 + ($visibleRows * 24) + 3
    [int]$dialogHeight = 82 + $gridHeight + 78
    if ($dialogHeight -lt 270) { $dialogHeight = 270 }

    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Показания — '+$meters[0].Address;$dialog.StartPosition='CenterParent';$dialog.ClientSize=New-Object System.Drawing.Size -ArgumentList 1220,$dialogHeight;$dialog.MinimumSize=New-Object System.Drawing.Size -ArgumentList 1040,270;$dialog.Font=New-Object Drawing.Font('Segoe UI',10);$dialog.KeyPreview=$true;$dialog.MaximizeBox=$true

    $addressLabel=New-Object Windows.Forms.Label;$addressLabel.Text=[string]$meters[0].Address;$addressLabel.Location=New-Object Drawing.Point(18,15);$addressLabel.Size=New-Object Drawing.Size(1175,30);$addressLabel.Anchor='Top,Left,Right';$addressLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',15);$dialog.Controls.Add($addressLabel)
    $accountLabel=New-Object Windows.Forms.Label;$accountLabel.Text='Лицевой счёт: '+$Account+'   •   Передача на портал пока отключена';$accountLabel.Location=New-Object Drawing.Point(20,48);$accountLabel.Size=New-Object Drawing.Size(1160,24);$accountLabel.Anchor='Top,Left,Right';$accountLabel.ForeColor=[Drawing.Color]::DimGray;$dialog.Controls.Add($accountLabel)

    $meterGrid=New-Object Windows.Forms.DataGridView
    $meterGrid.Location=New-Object Drawing.Point(18,82);$meterGrid.Size=New-Object System.Drawing.Size -ArgumentList 1184,$gridHeight;$meterGrid.Anchor='Top,Bottom,Left,Right';$meterGrid.AllowUserToAddRows=$false;$meterGrid.AllowUserToDeleteRows=$false;$meterGrid.RowHeadersVisible=$false;$meterGrid.SelectionMode='CellSelect';$meterGrid.MultiSelect=$false;$meterGrid.AutoGenerateColumns=$false;$meterGrid.AutoSizeColumnsMode='Fill';$meterGrid.ScrollBars='Vertical';$meterGrid.ColumnHeadersHeight=28;$meterGrid.RowTemplate.Height=24
    $dialog.Controls.Add($meterGrid)

    $selectColumn=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$selectColumn.Name='Selected';$selectColumn.HeaderText='Передать';$selectColumn.ReadOnly=$false;$selectColumn.AutoSizeMode='Fill';$selectColumn.FillWeight=8;$selectColumn.MinimumWidth=70;[void]$meterGrid.Columns.Add($selectColumn)
    foreach($spec in @(
        @{Name='Type';Header='Счётчик';Weight=16;Min=125;ReadOnly=$true},@{Name='Number';Header='№ прибора';Weight=15;Min=125;ReadOnly=$true},@{Name='LastValue';Header='Последнее';Weight=11;Min=90;ReadOnly=$true},@{Name='Unit';Header='Ед.';Weight=6;Min=55;ReadOnly=$true},@{Name='LastDate';Header='Передавали';Weight=11;Min=95;ReadOnly=$true},@{Name='MonthStatus';Header='Статус';Weight=12;Min=100;ReadOnly=$true},@{Name='NewValue';Header='Новое показание';Weight=13;Min=115;ReadOnly=$false},@{Name='Verification';Header='Поверка';Weight=12;Min=105;ReadOnly=$true}
    )){
        $column=New-Object Windows.Forms.DataGridViewTextBoxColumn;$column.Name=$spec.Name;$column.HeaderText=$spec.Header;$column.ReadOnly=$spec.ReadOnly;$column.AutoSizeMode='Fill';$column.FillWeight=$spec.Weight;$column.MinimumWidth=$spec.Min;[void]$meterGrid.Columns.Add($column)
    }

    foreach($meter in $meters){
        $key=$meter.Account+'|'+$meter.MeterId;$selected=$false;$newValue=''
        if($script:Drafts.ContainsKey($key)){$selected=[bool]$script:Drafts[$key].Selected;$newValue=[string]$script:Drafts[$key].Value}
        $rowIndex=$meterGrid.Rows.Add();$row=$meterGrid.Rows[$rowIndex];$row.Tag=$meter.MeterId;$row.Height=24
        $row.Cells['Selected'].Value=$selected;$row.Cells['Type'].Value=$meter.Type;$row.Cells['Number'].Value=$meter.Number;$row.Cells['LastValue'].Value=$meter.LastValue;$row.Cells['Unit'].Value=$meter.Unit;$row.Cells['LastDate'].Value=$meter.LastDate;$row.Cells['MonthStatus'].Value=$meter.MonthStatus;$row.Cells['NewValue'].Value=$newValue;$row.Cells['Verification'].Value=$meter.Verification
        if($meter.MonthStatus-eq'Передано'){$row.Cells['MonthStatus'].Style.ForeColor=[Drawing.Color]::DarkGreen;$row.Cells['Selected'].ReadOnly=$true;$row.Cells['Selected'].Style.BackColor=[Drawing.Color]::Gainsboro;$row.Cells['NewValue'].ReadOnly=$true;$row.Cells['NewValue'].Style.BackColor=[Drawing.Color]::Gainsboro}else{$row.Cells['MonthStatus'].Style.ForeColor=[Drawing.Color]::DarkRed}
    }

    [int]$buttonTop = $dialogHeight - 58
    $btnSave=New-Object Windows.Forms.Button;$btnSave.Text='Сохранить черновик';$btnSave.Size=New-Object Drawing.Size(180,38);$btnSave.Location=New-Object System.Drawing.Point -ArgumentList 815,$buttonTop;$btnSave.Anchor='Bottom,Right';$dialog.Controls.Add($btnSave)
    $btnClose=New-Object Windows.Forms.Button;$btnClose.Text='Закрыть';$btnClose.Size=New-Object Drawing.Size(125,38);$btnClose.Location=New-Object System.Drawing.Point -ArgumentList 1015,$buttonTop;$btnClose.Anchor='Bottom,Right';$dialog.Controls.Add($btnClose)

    $btnSave.Add_Click({
        $meterGrid.EndEdit()
        foreach($row in $meterGrid.Rows){$meterId=[string]$row.Tag;if([string]::IsNullOrWhiteSpace($meterId)){continue};$key=$Account+'|'+$meterId;$script:Drafts[$key]=[pscustomobject]@{Selected=[bool]$row.Cells['Selected'].Value;Value=[string]$row.Cells['NewValue'].Value}}
        Build-ObjectRows;$dialog.Close()
    })
    $btnClose.Add_Click({$dialog.Close()})
    $dialog.Add_KeyDown({if($_.KeyCode-eq[Windows.Forms.Keys]::Escape){$dialog.Close()}})
    [void]$dialog.ShowDialog($form)
}

$btnAll.Add_Click({$script:CurrentFilter='all';Refresh-Grid});$btnNeed.Add_Click({$script:CurrentFilter='need';Refresh-Grid});$btnDone.Add_Click({$script:CurrentFilter='done';Refresh-Grid});$txtSearch.Add_TextChanged({Refresh-Grid})
$openSelected={if($grid.SelectedRows.Count-eq0){return};$account=[string]$grid.SelectedRows[0].Tag;if([string]::IsNullOrWhiteSpace($account)){return};Show-ObjectDialog $account;Refresh-Grid}
$btnOpen.Add_Click({&$openSelected});$grid.Add_CellDoubleClick({param($sender,$e);if($e.RowIndex-ge0){$sender.ClearSelection();$sender.Rows[$e.RowIndex].Selected=$true;&$openSelected}})

$form.Add_Shown({
    try{
        $session=Load-WebSession;$page=Invoke-Get $ReceiptsUrl $session;$accounts=@(Parse-Accounts([string]$page.Content));if($accounts.Count-eq0){throw'Не удалось получить лицевые счета с портала.'}
        $details=Load-AccountDetails;$meters=New-Object System.Collections.ArrayList;$checked=0
        foreach($accountInfo in $accounts){
            if($details.ContainsKey([string]$accountInfo.Account)-and[bool]$details[[string]$accountInfo.Account].Excluded){continue}
            $checked++;$summary.Text="Читаю объекты: $checked из $($accounts.Count) — ЛС $($accountInfo.Account)";[Windows.Forms.Application]::DoEvents()
            Switch-Account $session ([string]$accountInfo.Company) ([string]$accountInfo.Account);$meterPage=Invoke-Get $MeterUrl $session
            $fullAddress='';$apartment='';if($details.ContainsKey([string]$accountInfo.Account)){$fullAddress=[string]$details[[string]$accountInfo.Account].Address;$apartment=[string]$details[[string]$accountInfo.Account].Apartment}
            $shortAddress=Get-ShortAddress $fullAddress $apartment
            foreach($row in @(Parse-Meters([string]$meterPage.Content)([string]$accountInfo.Account)$shortAddress)){[void]$meters.Add($row)}
        }
        $script:AllMeters=@($meters);Build-ObjectRows;Set-MainCompactHeight;Refresh-Grid
        $needCount=@($script:ObjectRows|Where-Object{$_.PendingCount-gt0}).Count;$doneCount=@($script:ObjectRows|Where-Object{$_.PendingCount-eq0}).Count
        $summary.Text="Объектов: $($script:ObjectRows.Count)   •   Нужно передать: $needCount   •   Передано: $doneCount   •   Передача на портал пока отключена";$summary.ForeColor=[Drawing.Color]::DarkGreen
    }catch{
        $line = $_.InvocationInfo.ScriptLineNumber
        $summary.Text='Ошибка: '+$_.Exception.Message;$summary.ForeColor=[Drawing.Color]::DarkRed
        [Windows.Forms.MessageBox]::Show(('Строка '+$line+': '+$_.Exception.Message),'Domlight — счётчики','OK','Error')|Out-Null
    }
})
$form.Add_KeyDown({if($_.KeyCode-eq[Windows.Forms.Keys]::Escape){$form.Close()}})
[void]$form.ShowDialog()
