Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web

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
    $protected = Get-Content -LiteralPath $SessionFile -Raw
    $json = Unprotect-Text $protected
    $arr = @($json | ConvertFrom-Json)
    foreach ($x in $arr) {
        $cookie = [System.Net.Cookie]::new([string]$x.Name, [string]$x.Value, [string]$x.Path, [string]$x.Domain)
        $session.Cookies.Add($cookie)
    }
    return $session
}

function Get-ProxyArgs {
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
            $args['ProxyCredential'] = [System.Management.Automation.PSCredential]::new([string]$cfg.proxyUser, $sec)
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
        $acc = [regex]::Match($f.Value, '<input[^>]+name=["'']account["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        $comp = [regex]::Match($f.Value, '<input[^>]+name=["'']company["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        if ($acc.Success -and $comp.Success) {
            $a = [Net.WebUtility]::HtmlDecode($acc.Groups[1].Value)
            $c = [Net.WebUtility]::HtmlDecode($comp.Groups[1].Value)
            $key = "$c|$a"
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $result += [pscustomobject]@{Account=$a;Company=$c} }
        }
    }
    return $result
}

function Load-AccountDetails {
    $map = @{}
    if (-not (Test-Path -LiteralPath $AccountsStateFile)) { return $map }
    try {
        $items = @(Get-Content -LiteralPath $AccountsStateFile -Raw | ConvertFrom-Json)
        foreach ($item in $items) {
            $a = ([string]$item.Account).Trim()
            if ([string]::IsNullOrWhiteSpace($a)) { continue }
            $map[$a] = [pscustomobject]@{
                Address = ([string]$item.Address).Trim()
                Apartment = ([string]$item.Apartment).Trim()
                Excluded = [bool]$item.Excluded
            }
        }
    } catch {}
    return $map
}

function Switch-Account($Session, [string]$Company, [string]$Account) {
    $page = Invoke-Get $ReceiptsUrl $Session
    $csrf = Get-Csrf ([string]$page.Content)
    $body = '_csrf-lk=' + [uri]::EscapeDataString($csrf) + '&company=' + [uri]::EscapeDataString($Company) + '&account=' + [uri]::EscapeDataString($Account)
    $proxy = Get-ProxyArgs
    try {
        Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
            'Referer' = $ReceiptsUrl
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'
        } -ContentType 'application/x-www-form-urlencoded' -Body $body | Out-Null
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -ne 302) { throw }
    }
}

function Clean-Text([string]$Html) {
    if ($null -eq $Html) { return '' }
    $x = [Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>', ' '))
    return (($x -replace '\s+', ' ').Trim())
}

function Parse-Meters([string]$Html, [string]$Account, [string]$Address) {
    $allTab = [regex]::Match($Html, '(?is)<div\s+id=["'']tab_meter_all["''][^>]*>(?<body>.*?)<div\s+id=["'']tab_meter_water["'']')
    $scope = if ($allTab.Success) { $allTab.Groups['body'].Value } else { $Html }
    $cards = [regex]::Matches($scope, '(?is)<div\s+class=["''][^"'']*card\s+mb-5\s+p-8[^"'']*["''][^>]*>(?<card>.*?)(?=<div\s+class=["''][^"'']*card\s+mb-5\s+p-8|$)')
    $rows = @(); $seen = @{}

    foreach ($cm in $cards) {
        $card = $cm.Groups['card'].Value
        $input = [regex]::Match($card, '<input[^>]+class=["''][^"'']*meter-input[^"'']*["''][^>]*>', 'IgnoreCase')
        if (-not $input.Success) { continue }
        $tag = $input.Value

        $idM = [regex]::Match($tag, 'data-id=["'']([^"'']+)["'']', 'IgnoreCase')
        $valM = [regex]::Match($tag, 'value=["'']([^"'']*)["'']', 'IgnoreCase')
        $unitM = [regex]::Match($tag, 'data-unit=["'']([^"'']*)["'']', 'IgnoreCase')
        if (-not $idM.Success) { continue }
        $meterId = [string]$idM.Groups[1].Value
        if ($seen.ContainsKey($meterId)) { continue }
        $seen[$meterId] = $true

        $head = [regex]::Match($card, '(?is)<h2[^>]*>(?<head>.*?)</h2>')
        $headText = if ($head.Success) { Clean-Text $head.Groups['head'].Value } else { '' }
        $number = ''
        $numM = [regex]::Match($headText, '№\s*(.+)$')
        if ($numM.Success) { $number = $numM.Groups[1].Value.Trim(); $type = ($headText.Substring(0, $numM.Index)).Trim() } else { $type = $headText }

        $date = ''
        $dateM = [regex]::Match($card, 'Передавали\s+(\d{2}\.\d{2}\.\d{4})', 'IgnoreCase')
        if ($dateM.Success) { $date = $dateM.Groups[1].Value }

        $previous = ''
        $prevM = [regex]::Match($card, 'Показания\s+прошлого\s+периода\s+([0-9.,]+)', 'IgnoreCase')
        if ($prevM.Success) { $previous = $prevM.Groups[1].Value.Replace(',', '.') }

        $verify = ''
        $verifyM = [regex]::Match($card, 'title=["'']Поверка:\s*([^"'']*)["'']', 'IgnoreCase')
        if ($verifyM.Success) { $verify = [Net.WebUtility]::HtmlDecode($verifyM.Groups[1].Value) }

        $rows += [pscustomobject]@{
            Account = $Account
            Address = $Address
            Type = $type
            Number = $number
            Value = if ($valM.Success) { $valM.Groups[1].Value } else { '' }
            Previous = $previous
            Unit = if ($unitM.Success) { [Net.WebUtility]::HtmlDecode($unitM.Groups[1].Value) } else { '' }
            LastDate = $date
            Verification = $verify
            MeterId = $meterId
        }
    }
    return $rows
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Счётчики / показания — только чтение'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(1450, 700)
$form.MinimumSize = New-Object Drawing.Size(1050, 430)
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.KeyPreview = $true

$title = New-Object Windows.Forms.Label
$title.Text = 'Счётчики / показания'
$title.Location = New-Object Drawing.Point(20, 15)
$title.Size = New-Object Drawing.Size(600, 34)
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
$form.Controls.Add($title)

$status = New-Object Windows.Forms.Label
$status.Text = 'Загрузка данных с портала...'
$status.Location = New-Object Drawing.Point(22, 52)
$status.Size = New-Object Drawing.Size(1200, 25)
$status.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($status)

$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(20, 88)
$grid.Size = New-Object Drawing.Size(1410, 545)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoGenerateColumns = $false
$grid.BackgroundColor = [Drawing.Color]::White
$grid.ScrollBars = 'Both'
$form.Controls.Add($grid)

$specs = @(
    @{Name='Account';Header='Лицевой счёт';Width=125},
    @{Name='Address';Header='Адрес';Width=390},
    @{Name='Type';Header='Счётчик';Width=150},
    @{Name='Number';Header='№ прибора';Width=145},
    @{Name='Value';Header='Текущее';Width=90},
    @{Name='Previous';Header='Прошлый период';Width=115},
    @{Name='Unit';Header='Ед.';Width=70},
    @{Name='LastDate';Header='Передавали';Width=105},
    @{Name='Verification';Header='Поверка';Width=120}
)
foreach ($s in $specs) {
    $c = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $s.Name; $c.DataPropertyName = $s.Name; $c.HeaderText = $s.Header; $c.Width = $s.Width
    if ($s.Name -eq 'Address') { $c.AutoSizeMode = 'Fill'; $c.MinimumWidth = 300 }
    [void]$grid.Columns.Add($c)
}

$form.Add_Shown({
    try {
        [Windows.Forms.Application]::DoEvents()
        $session = Load-WebSession
        $page = Invoke-Get $ReceiptsUrl $session
        if (-not (Is-Authenticated ([string]$page.Content))) {
            throw 'Сессия Домлайта закончилась. Откройте «Открыть кабинет Домлайт», войдите по SMS и повторите.'
        }
        $accounts = @(Parse-Accounts ([string]$page.Content))
        if ($accounts.Count -eq 0) { throw 'Не удалось получить лицевые счета с портала.' }
        $details = Load-AccountDetails
        $result = New-Object System.Collections.ArrayList
        $checked = 0

        foreach ($acc in $accounts) {
            if ($details.ContainsKey([string]$acc.Account) -and [bool]$details[[string]$acc.Account].Excluded) { continue }
            $checked++
            $status.Text = "Читаю счётчики: ЛС $checked из $($accounts.Count) — $($acc.Account)"
            [Windows.Forms.Application]::DoEvents()

            Switch-Account $session ([string]$acc.Company) ([string]$acc.Account)
            $meterPage = Invoke-Get $MeterUrl $session
            $address = ''
            if ($details.ContainsKey([string]$acc.Account)) {
                $address = [string]$details[[string]$acc.Account].Address
                if ([string]::IsNullOrWhiteSpace($address)) {
                    $apt = [string]$details[[string]$acc.Account].Apartment
                    if (-not [string]::IsNullOrWhiteSpace($apt)) { $address = 'кв. ' + $apt }
                }
            }
            foreach ($row in @(Parse-Meters ([string]$meterPage.Content) ([string]$acc.Account) $address)) { [void]$result.Add($row) }
        }

        $grid.DataSource = $result
        $status.Text = "Готово. Лицевых счетов проверено: $checked. Счётчиков найдено: $($result.Count). Только чтение — передача показаний отключена."
        $status.ForeColor = [Drawing.Color]::DarkGreen
    }
    catch {
        $status.Text = 'Ошибка: ' + $_.Exception.Message
        $status.ForeColor = [Drawing.Color]::DarkRed
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Domlight — счётчики', 'OK', 'Error') | Out-Null
    }
})

$form.Add_KeyDown({ if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) { $form.Close() } })
[void]$form.ShowDialog()
