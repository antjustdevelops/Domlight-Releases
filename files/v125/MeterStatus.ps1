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
    $dec = [Security.Cryptography.ProtectedData]::Unprotect(
        $bytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($dec)
}

function Load-WebSession {
    if (-not (Test-Path -LiteralPath $SessionFile)) {
        throw 'Сохранённая сессия Domlight не найдена. Сначала войдите в кабинет Domlight.'
    }

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
    if (-not (Test-Path $ConnectionFile)) {
        return $args
    }

    try {
        $cfg = Get-Content $ConnectionFile -Raw | ConvertFrom-Json
        if (-not [bool]$cfg.useProxy) {
            return $args
        }
        if ([string]::IsNullOrWhiteSpace([string]$cfg.proxyUrl)) {
            return $args
        }

        $args['Proxy'] = [string]$cfg.proxyUrl
        $args['ProxyUseDefaultCredentials'] = $false

        if (-not [string]::IsNullOrWhiteSpace([string]$cfg.proxyUser)) {
            $sec = ConvertTo-SecureString ([string]$cfg.proxyPassword) -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential ([string]$cfg.proxyUser, $sec)
            $args['ProxyCredential'] = $cred
        }
    }
    catch {}

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
    $m = [regex]::Match(
        $Html,
        '<meta[^>]+name=["'']csrf-token["''][^>]+content=["'']([^"'']+)["'']',
        'IgnoreCase'
    )
    if ($m.Success) {
        return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    }

    $m = [regex]::Match(
        $Html,
        '<input[^>]+name=["'']_csrf-lk["''][^>]+value=["'']([^"'']+)["'']',
        'IgnoreCase'
    )
    if ($m.Success) {
        return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    }

    $m = [regex]::Match(
        $Html,
        '<input[^>]+value=["'']([^"'']+)["''][^>]+name=["'']_csrf-lk["'']',
        'IgnoreCase'
    )
    if ($m.Success) {
        return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    }

    throw 'Не найден CSRF-токен Домлайта.'
}

function Parse-Accounts([string]$Html) {
    $forms = [regex]::Matches(
        $Html,
        '<form[^>]+action=["'']/account/set["''][\s\S]*?</form>',
        'IgnoreCase'
    )

    $result = @()
    $seen = @{}

    foreach ($formHtml in $forms) {
        $am = [regex]::Match(
            $formHtml.Value,
            '<input[^>]+name=["'']account["''][^>]+value=["'']([^"'']+)["'']',
            'IgnoreCase'
        )
        $cm = [regex]::Match(
            $formHtml.Value,
            '<input[^>]+name=["'']company["''][^>]+value=["'']([^"'']+)["'']',
            'IgnoreCase'
        )

        if (-not ($am.Success -and $cm.Success)) {
            continue
        }

        $account = [Net.WebUtility]::HtmlDecode($am.Groups[1].Value)
        $company = [Net.WebUtility]::HtmlDecode($cm.Groups[1].Value)
        $key = "$company|$account"

        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $result += [pscustomobject]@{
            Account = $account
            Company = $company
        }
    }

    return $result
}

function Load-AccountDetails {
    $map = @{}
    if (-not (Test-Path -LiteralPath $AccountsStateFile)) {
        return $map
    }

    try {
        $items = Get-Content -LiteralPath $AccountsStateFile -Raw | ConvertFrom-Json
        foreach ($item in @($items)) {
            $account = ([string]$item.Account).Trim()
            if ([string]::IsNullOrWhiteSpace($account)) {
                continue
            }

            $map[$account] = [pscustomobject]@{
                Address = ([string]$item.Address).Trim()
                Apartment = ([string]$item.Apartment).Trim()
                Excluded = [bool]$item.Excluded
            }
        }
    }
    catch {}

    return $map
}

function Switch-Account($Session, [string]$Company, [string]$Account) {
    $html = (Invoke-Get $ReceiptsUrl $Session).Content
    $csrf = Get-Csrf $html

    $body = '_csrf-lk=' + [uri]::EscapeDataString($csrf) +
        '&company=' + [uri]::EscapeDataString($Company) +
        '&account=' + [uri]::EscapeDataString($Account)

    $proxy = Get-ProxyArgs

    try {
        Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
            'Referer' = $ReceiptsUrl
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
        } -ContentType 'application/x-www-form-urlencoded' -Body $body | Out-Null
    }
    catch {
        $statusCode = $null
        try {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        catch {}

        if ($statusCode -ne 302) {
            throw
        }
    }
}

function Clean-Text([string]$Html) {
    if ($null -eq $Html) {
        return ''
    }

    return (([Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>', ' ')) -replace '\s+', ' ').Trim())
}

function Get-Attr([string]$Tag, [string]$Name) {
    $pattern = '(?is)(?:^|\s)' + [regex]::Escape($Name) + '\s*=\s*["'']([^"'']*)["'']'
    $m = [regex]::Match($Tag, $pattern)

    if ($m.Success) {
        return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    }

    return ''
}

function Get-MonthStatus([string]$LastDate) {
    if ([string]::IsNullOrWhiteSpace($LastDate)) {
        return 'Не передано'
    }

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $LastDate,
        'dd.MM.yyyy',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )

    if (-not $ok) {
        return 'Дата неизвестна'
    }

    $now = Get-Date
    if ($parsed.Year -eq $now.Year -and $parsed.Month -eq $now.Month) {
        return 'Передано'
    }

    return 'Не передано'
}

function Get-ShortAddress([string]$Address, [string]$Apartment) {
    if ([string]::IsNullOrWhiteSpace($Address)) {
        if (-not [string]::IsNullOrWhiteSpace($Apartment)) {
            return 'кв. ' + $Apartment
        }
        return ''
    }

    $parts = @(
        $Address.Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' }
    )

    $streetIndex = -1
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -match '(?i)(улиц|\bул\.?\b|бульвар|\bб-р\b|проспект|\bпр-т\b|шоссе|\bш\.?\b|переулок|\bпер\.?\b|набережн|\bнаб\.?\b|проезд|площад|аллея)') {
            $streetIndex = $i
            break
        }
    }

    if ($streetIndex -ge 0) {
        return ($parts[$streetIndex..($parts.Count - 1)] -join ', ')
    }

    $keep = @(
        $parts | Where-Object {
            $_ -notmatch '^\d{6}$' -and
            $_ -notmatch '(?i)^Москва$' -and
            $_ -notmatch '(?i)^г\.\s*Москва$' -and
            $_ -notmatch '(?i)вн\.тер' -and
            $_ -notmatch '(?i)муниципальн.*округ'
        }
    )

    if ($keep.Count -gt 0) {
        return ($keep -join ', ')
    }

    return $Address
}

function Parse-Meters([string]$Html, [string]$Account, [string]$Address) {
    $allStart = $Html.IndexOf('id="tab_meter_all"')
    if ($allStart -lt 0) {
        $allStart = $Html.IndexOf("id='tab_meter_all'")
    }

    $waterStart = $Html.IndexOf('id="tab_meter_water"')
    if ($waterStart -lt 0) {
        $waterStart = $Html.IndexOf("id='tab_meter_water'")
    }

    if ($allStart -ge 0 -and $waterStart -gt $allStart) {
        $scope = $Html.Substring($allStart, $waterStart - $allStart)
    }
    else {
        $scope = $Html
    }

    $cardPattern = '<div class="card mb-5 p-8">'
    $positions = New-Object System.Collections.Generic.List[int]
    $searchFrom = 0

    while ($true) {
        $position = $scope.IndexOf($cardPattern, $searchFrom, [StringComparison]::OrdinalIgnoreCase)
        if ($position -lt 0) {
            break
        }

        $positions.Add($position)
        $searchFrom = $position + $cardPattern.Length
    }

    $rows = @()
    $seen = @{}

    for ($i = 0; $i -lt $positions.Count; $i++) {
        $start = $positions[$i]
        if ($i + 1 -lt $positions.Count) {
            $end = $positions[$i + 1]
        }
        else {
            $end = $scope.Length
        }

        $card = $scope.Substring($start, $end - $start)
        $inputM = [regex]::Match(
            $card,
            '<input[^>]+class=["''][^"'']*meter-input[^"'']*["''][^>]*>',
            'IgnoreCase'
        )

        if (-not $inputM.Success) {
            continue
        }

        $tag = $inputM.Value
        $meterId = Get-Attr $tag 'data-id'
        if ([string]::IsNullOrWhiteSpace($meterId) -or $seen.ContainsKey($meterId)) {
            continue
        }
        $seen[$meterId] = $true

        $headM = [regex]::Match($card, '(?is)<h2[^>]*>(.*?)</h2>')
        if ($headM.Success) {
            $headText = Clean-Text $headM.Groups[1].Value
        }
        else {
            $headText = ''
        }

        $type = $headText
        $number = ''
        $numM = [regex]::Match($headText, '№\s*(.+)$')
        if ($numM.Success) {
            $number = $numM.Groups[1].Value.Trim()
            $type = $headText.Substring(0, $numM.Index).Trim()
        }

        $date = ''
        $dateM = [regex]::Match($card, 'Передавали\s+(\d{2}\.\d{2}\.\d{4})', 'IgnoreCase')
        if ($dateM.Success) {
            $date = $dateM.Groups[1].Value
        }

        $verification = ''
        $verM = [regex]::Match($card, 'title=["'']Поверка:\s*([^"'']*)["'']', 'IgnoreCase')
        if ($verM.Success) {
            $verification = [Net.WebUtility]::HtmlDecode($verM.Groups[1].Value)
        }

        $rows += [pscustomobject]@{
            Account = $Account
            Address = $Address
            MeterId = $meterId
            Type = $type
            Number = $number
            LastValue = Get-Attr $tag 'value'
            Unit = Get-Attr $tag 'data-unit'
            LastDate = $date
            MonthStatus = Get-MonthStatus $date
            Verification = $verification
        }
    }

    return $rows
}

function Build-ObjectRows {
    $result = @()

    foreach ($group in @($script:AllMeters | Group-Object Account)) {
        $meters = @($group.Group)
        if ($meters.Count -eq 0) {
            continue
        }

        $pending = @($meters | Where-Object { $_.MonthStatus -ne 'Передано' }).Count
        $sent = @($meters | Where-Object { $_.MonthStatus -eq 'Передано' }).Count
        $draftCount = 0

        foreach ($meter in $meters) {
            $key = $meter.Account + '|' + $meter.MeterId
            if ($script:Drafts.ContainsKey($key)) {
                $draft = $script:Drafts[$key]
                if ([bool]$draft.Selected -and -not [string]::IsNullOrWhiteSpace([string]$draft.Value)) {
                    $draftCount++
                }
            }
        }

        if ($pending -eq 0) {
            $state = 'Всё передано'
        }
        else {
            $state = 'Нужно передать: ' + $pending
        }

        $result += [pscustomobject]@{
            Account = $group.Name
            Address = [string]$meters[0].Address
            MeterCount = $meters.Count
            SentCount = $sent
            PendingCount = $pending
            DraftCount = $draftCount
            Status = $state
        }
    }

    $script:ObjectRows = @($result)
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Счётчики / показания — объекты'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(1180, 720)
$form.MinimumSize = New-Object Drawing.Size(900, 520)
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.KeyPreview = $true

$title = New-Object Windows.Forms.Label
$title.Text = 'Счётчики / показания'
$title.Location = New-Object Drawing.Point(20, 15)
$title.Size = New-Object Drawing.Size(450, 34)
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
$form.Controls.Add($title)

$summary = New-Object Windows.Forms.Label
$summary.Text = 'Загрузка данных с портала...'
$summary.Location = New-Object Drawing.Point(22, 51)
$summary.Size = New-Object Drawing.Size(1100, 25)
$summary.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($summary)

$searchLabel = New-Object Windows.Forms.Label
$searchLabel.Text = 'Поиск:'
$searchLabel.Location = New-Object Drawing.Point(20, 88)
$searchLabel.Size = New-Object Drawing.Size(55, 24)
$form.Controls.Add($searchLabel)

$txtSearch = New-Object Windows.Forms.TextBox
$txtSearch.Location = New-Object Drawing.Point(75, 84)
$txtSearch.Size = New-Object Drawing.Size(305, 28)
$form.Controls.Add($txtSearch)

$btnAll = New-Object Windows.Forms.Button
$btnAll.Text = 'Все'
$btnAll.Location = New-Object Drawing.Point(400, 82)
$btnAll.Size = New-Object Drawing.Size(90, 32)
$form.Controls.Add($btnAll)

$btnNeed = New-Object Windows.Forms.Button
$btnNeed.Text = 'Нужно передать'
$btnNeed.Location = New-Object Drawing.Point(500, 82)
$btnNeed.Size = New-Object Drawing.Size(140, 32)
$form.Controls.Add($btnNeed)

$btnDone = New-Object Windows.Forms.Button
$btnDone.Text = 'Передано'
$btnDone.Location = New-Object Drawing.Point(650, 82)
$btnDone.Size = New-Object Drawing.Size(110, 32)
$form.Controls.Add($btnDone)

$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(20, 126)
$grid.Size = New-Object Drawing.Size(1140, 510)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoGenerateColumns = $false
$grid.BackgroundColor = [Drawing.Color]::White
$form.Controls.Add($grid)

$objectColumns = @(
    @{ Name = 'Address'; Header = 'Объект'; Width = 430 },
    @{ Name = 'Account'; Header = 'Лицевой счёт'; Width = 145 },
    @{ Name = 'MeterCount'; Header = 'Счётчиков'; Width = 85 },
    @{ Name = 'Status'; Header = 'Статус месяца'; Width = 165 },
    @{ Name = 'DraftCount'; Header = 'Готово к отправке'; Width = 125 }
)

foreach ($spec in $objectColumns) {
    $column = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $spec.Name
    $column.DataPropertyName = $spec.Name
    $column.HeaderText = $spec.Header
    $column.Width = $spec.Width

    if ($spec.Name -eq 'Address') {
        $column.AutoSizeMode = 'Fill'
        $column.MinimumWidth = 330
    }

    [void]$grid.Columns.Add($column)
}

$btnOpen = New-Object Windows.Forms.Button
$btnOpen.Text = 'Открыть объект'
$btnOpen.Size = New-Object Drawing.Size(160, 38)
$btnOpen.Location = New-Object Drawing.Point(1000, 650)
$btnOpen.Anchor = 'Bottom,Right'
$form.Controls.Add($btnOpen)

function Refresh-Grid {
    Build-ObjectRows

    $query = $txtSearch.Text.Trim().ToLowerInvariant()
    $items = @(
        $script:ObjectRows | Where-Object {
            switch ($script:CurrentFilter) {
                'need' { $filterOk = $_.PendingCount -gt 0 }
                'done' { $filterOk = $_.PendingCount -eq 0 }
                default { $filterOk = $true }
            }

            $searchOk = [string]::IsNullOrWhiteSpace($query) -or
                $_.Address.ToLowerInvariant().Contains($query) -or
                $_.Account.ToLowerInvariant().Contains($query)

            $filterOk -and $searchOk
        }
    )

    $grid.DataSource = $null
    $grid.DataSource = $items
}

function Show-ObjectDialog([string]$Account) {
    $meters = @($script:AllMeters | Where-Object { $_.Account -eq $Account })
    if ($meters.Count -eq 0) {
        return
    }

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Показания — ' + $meters[0].Address
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object Drawing.Size(1040, 500)
    $dialog.MinimumSize = New-Object Drawing.Size(900, 430)
    $dialog.Font = New-Object Drawing.Font('Segoe UI', 10)
    $dialog.KeyPreview = $true

    $addressLabel = New-Object Windows.Forms.Label
    $addressLabel.Text = [string]$meters[0].Address
    $addressLabel.Location = New-Object Drawing.Point(18, 15)
    $addressLabel.Size = New-Object Drawing.Size(980, 30)
    $addressLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 15)
    $dialog.Controls.Add($addressLabel)

    $accountLabel = New-Object Windows.Forms.Label
    $accountLabel.Text = 'Лицевой счёт: ' + $Account + '   •   Передача на портал пока отключена'
    $accountLabel.Location = New-Object Drawing.Point(20, 48)
    $accountLabel.Size = New-Object Drawing.Size(950, 24)
    $accountLabel.ForeColor = [Drawing.Color]::DimGray
    $dialog.Controls.Add($accountLabel)

    $meterGrid = New-Object Windows.Forms.DataGridView
    $meterGrid.Location = New-Object Drawing.Point(18, 82)
    $meterGrid.Size = New-Object Drawing.Size(1004, 340)
    $meterGrid.Anchor = 'Top,Bottom,Left,Right'
    $meterGrid.AllowUserToAddRows = $false
    $meterGrid.AllowUserToDeleteRows = $false
    $meterGrid.RowHeadersVisible = $false
    $meterGrid.AutoGenerateColumns = $false
    $meterGrid.SelectionMode = 'CellSelect'
    $meterGrid.MultiSelect = $false
    $dialog.Controls.Add($meterGrid)

    $meterColumns = @(
        @{ Type = 'check'; Name = 'Selected'; Header = 'Передать'; Width = 75 },
        @{ Type = 'text'; Name = 'Type'; Header = 'Счётчик'; Width = 135 },
        @{ Type = 'text'; Name = 'Number'; Header = '№ прибора'; Width = 135 },
        @{ Type = 'text'; Name = 'LastValue'; Header = 'Последнее'; Width = 90 },
        @{ Type = 'text'; Name = 'Unit'; Header = 'Ед.'; Width = 55 },
        @{ Type = 'text'; Name = 'LastDate'; Header = 'Передавали'; Width = 100 },
        @{ Type = 'text'; Name = 'MonthStatus'; Header = 'Статус'; Width = 105 },
        @{ Type = 'text'; Name = 'NewValue'; Header = 'Новое показание'; Width = 120 },
        @{ Type = 'text'; Name = 'Verification'; Header = 'Поверка'; Width = 120 }
    )

    foreach ($spec in $meterColumns) {
        if ($spec.Type -eq 'check') {
            $column = New-Object Windows.Forms.DataGridViewCheckBoxColumn
        }
        else {
            $column = New-Object Windows.Forms.DataGridViewTextBoxColumn
        }

        $column.Name = $spec.Name
        $column.DataPropertyName = $spec.Name
        $column.HeaderText = $spec.Header
        $column.Width = $spec.Width

        if ($spec.Name -notin @('Selected', 'NewValue')) {
            $column.ReadOnly = $true
        }

        [void]$meterGrid.Columns.Add($column)
    }

    $data = New-Object System.Collections.ArrayList

    foreach ($meter in $meters) {
        $key = $meter.Account + '|' + $meter.MeterId
        $selected = $false
        $newValue = ''

        if ($script:Drafts.ContainsKey($key)) {
            $selected = [bool]$script:Drafts[$key].Selected
            $newValue = [string]$script:Drafts[$key].Value
        }

        [void]$data.Add([pscustomobject]@{
            MeterId = $meter.MeterId
            Selected = $selected
            Type = $meter.Type
            Number = $meter.Number
            LastValue = $meter.LastValue
            Unit = $meter.Unit
            LastDate = $meter.LastDate
            MonthStatus = $meter.MonthStatus
            NewValue = $newValue
            Verification = $meter.Verification
        })
    }

    $meterGrid.DataSource = $data

    $meterGrid.Add_CellBeginEdit({
        param($sender, $e)

        $row = $sender.Rows[$e.RowIndex]
        $columnName = $sender.Columns[$e.ColumnIndex].Name

        if ([string]$row.Cells['MonthStatus'].Value -eq 'Передано' -and $columnName -in @('Selected', 'NewValue')) {
            $e.Cancel = $true
        }
    })

    $meterGrid.Add_CellFormatting({
        param($sender, $e)

        if ($e.RowIndex -lt 0) {
            return
        }

        $row = $sender.Rows[$e.RowIndex]
        $statusText = [string]$row.Cells['MonthStatus'].Value
        $columnName = $sender.Columns[$e.ColumnIndex].Name

        if ($columnName -eq 'MonthStatus') {
            if ($statusText -eq 'Передано') {
                $e.CellStyle.ForeColor = [Drawing.Color]::DarkGreen
            }
            else {
                $e.CellStyle.ForeColor = [Drawing.Color]::DarkRed
            }
        }

        if ($statusText -eq 'Передано' -and $columnName -in @('Selected', 'NewValue')) {
            $e.CellStyle.BackColor = [Drawing.Color]::Gainsboro
        }
    })

    $btnSave = New-Object Windows.Forms.Button
    $btnSave.Text = 'Сохранить черновик'
    $btnSave.Size = New-Object Drawing.Size(170, 36)
    $btnSave.Location = New-Object Drawing.Point(650, 440)
    $btnSave.Anchor = 'Bottom,Right'
    $dialog.Controls.Add($btnSave)

    $btnClose = New-Object Windows.Forms.Button
    $btnClose.Text = 'Закрыть'
    $btnClose.Size = New-Object Drawing.Size(120, 36)
    $btnClose.Location = New-Object Drawing.Point(835, 440)
    $btnClose.Anchor = 'Bottom,Right'
    $dialog.Controls.Add($btnClose)

    $btnSave.Add_Click({
        $meterGrid.EndEdit()

        for ($rowIndex = 0; $rowIndex -lt $meterGrid.Rows.Count; $rowIndex++) {
            $row = $meterGrid.Rows[$rowIndex]
            $item = $data[$rowIndex]
            $key = $Account + '|' + [string]$item.MeterId

            $script:Drafts[$key] = [pscustomobject]@{
                Selected = [bool]$row.Cells['Selected'].Value
                Value = [string]$row.Cells['NewValue'].Value
            }
        }

        Build-ObjectRows
        $dialog.Close()
    })

    $btnClose.Add_Click({
        $dialog.Close()
    })

    $dialog.Add_KeyDown({
        if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $dialog.Close()
        }
    })

    [void]$dialog.ShowDialog($form)
}

$btnAll.Add_Click({
    $script:CurrentFilter = 'all'
    Refresh-Grid
})

$btnNeed.Add_Click({
    $script:CurrentFilter = 'need'
    Refresh-Grid
})

$btnDone.Add_Click({
    $script:CurrentFilter = 'done'
    Refresh-Grid
})

$txtSearch.Add_TextChanged({
    Refresh-Grid
})

$openSelected = {
    if ($grid.SelectedRows.Count -eq 0) {
        return
    }

    $account = [string]$grid.SelectedRows[0].Cells['Account'].Value
    if ([string]::IsNullOrWhiteSpace($account)) {
        return
    }

    Show-ObjectDialog $account
    Refresh-Grid
}

$btnOpen.Add_Click({
    & $openSelected
})

$grid.Add_CellDoubleClick({
    param($sender, $e)

    if ($e.RowIndex -ge 0) {
        $sender.Rows[$e.RowIndex].Selected = $true
        & $openSelected
    }
})

$form.Add_Shown({
    try {
        $session = Load-WebSession
        $page = Invoke-Get $ReceiptsUrl $session
        $accounts = @(Parse-Accounts ([string]$page.Content))

        if ($accounts.Count -eq 0) {
            throw 'Не удалось получить лицевые счета с портала.'
        }

        $details = Load-AccountDetails
        $meters = New-Object System.Collections.ArrayList
        $checked = 0

        foreach ($accountInfo in $accounts) {
            if ($details.ContainsKey([string]$accountInfo.Account) -and [bool]$details[[string]$accountInfo.Account].Excluded) {
                continue
            }

            $checked++
            $summary.Text = "Читаю объекты: $checked из $($accounts.Count) — ЛС $($accountInfo.Account)"
            [Windows.Forms.Application]::DoEvents()

            Switch-Account $session ([string]$accountInfo.Company) ([string]$accountInfo.Account)
            $meterPage = Invoke-Get $MeterUrl $session

            $fullAddress = ''
            $apartment = ''
            if ($details.ContainsKey([string]$accountInfo.Account)) {
                $fullAddress = [string]$details[[string]$accountInfo.Account].Address
                $apartment = [string]$details[[string]$accountInfo.Account].Apartment
            }

            $shortAddress = Get-ShortAddress $fullAddress $apartment
            foreach ($row in @(Parse-Meters ([string]$meterPage.Content) ([string]$accountInfo.Account) $shortAddress)) {
                [void]$meters.Add($row)
            }
        }

        $script:AllMeters = @($meters)
        Build-ObjectRows
        Refresh-Grid

        $needCount = @($script:ObjectRows | Where-Object { $_.PendingCount -gt 0 }).Count
        $doneCount = @($script:ObjectRows | Where-Object { $_.PendingCount -eq 0 }).Count

        $summary.Text = "Объектов: $($script:ObjectRows.Count)   •   Нужно передать: $needCount   •   Передано: $doneCount   •   Передача на портал пока отключена"
        $summary.ForeColor = [Drawing.Color]::DarkGreen
    }
    catch {
        $summary.Text = 'Ошибка: ' + $_.Exception.Message
        $summary.ForeColor = [Drawing.Color]::DarkRed
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Domlight — счётчики',
            'OK',
            'Error'
        ) | Out-Null
    }
})

$form.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
        $form.Close()
    }
})

[void]$form.ShowDialog()
