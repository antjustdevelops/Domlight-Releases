
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$VersionFile = Join-Path $Root "VERSION.txt"
$AppVersion = "UNKNOWN"
if (Test-Path -LiteralPath $VersionFile) {
    try {
        $rawVersion = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rawVersion)) {
            $AppVersion = ($rawVersion -replace '^Domlight\s+','').Trim()
        }
    } catch {}
}

$BaseUrl = "https://lk.kakdoma.life"
$LoginUrl = "$BaseUrl/login"
$AuthPhoneUrl = "$BaseUrl/auth/phone"
$AuthCodeUrl = "$BaseUrl/auth/code"
$ReceiptsUrl = "$BaseUrl/receipt/index"
$AccountSetUrl = "$BaseUrl/account/set"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root "data"
$ReceiptsDir = Join-Path $DataDir "receipts"
$OrganizerFile = Join-Path $Root "OrganizeDownloadedAccount.ps1"
$ArchiveBackupRoot = Join-Path $DataDir "archive_backups"
$SessionFile = Join-Path $DataDir "session.dat"
$ConnectionFile = Join-Path $DataDir "connection.json"
$StateFile = Join-Path $DataDir "state.json"
$LastCheckFile = Join-Path $DataDir "last_check.json"
$ReportFile = Join-Path $DataDir "DOMLIGHT_REPORT.txt"
$AccountsStateFile = Join-Path $DataDir "accounts_state.json"
$AccountStateModule = Join-Path $Root "AccountState.ps1"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReceiptsDir | Out-Null
if (Test-Path -LiteralPath $AccountStateModule) { . $AccountStateModule }

$script:WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$script:LoginCsrf = $null
$script:CodeCsrf = $null
$script:Phone = $null

function Log([string]$Text) {
    $txtLog.AppendText("$(Get-Date -Format 'HH:mm:ss')  $Text`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-Csrf([string]$Html) {
    $m = [regex]::Match($Html, '<meta[^>]+name=["'']csrf-token["''][^>]+content=["'']([^"'']+)["'']', 'IgnoreCase')
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }

    $m = [regex]::Match($Html, '<input[^>]+name=["'']_csrf-lk["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }

    $m = [regex]::Match($Html, '<input[^>]+value=["'']([^"'']+)["''][^>]+name=["'']_csrf-lk["'']', 'IgnoreCase')
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }

    throw "Не найден CSRF-токен Домлайта."
}

function Normalize-Phone([string]$Value) {
    $digits = ($Value -replace '\D','')
    if ($digits.Length -eq 11 -and ($digits.StartsWith("7") -or $digits.StartsWith("8"))) {
        $digits = $digits.Substring(1)
    }
    if ($digits.Length -ne 10) { throw "Введите номер телефона: +7 и 10 цифр." }
    return "+7 ($($digits.Substring(0,3))) $($digits.Substring(3,3))-$($digits.Substring(6,2))-$($digits.Substring(8,2))"
}

function Protect-Text([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-Text([string]$Text) {
    $bytes = [Convert]::FromBase64String($Text)
    $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($dec)
}

function Save-Session {
    try {
        $uri = [Uri]$BaseUrl
        $cookies = $script:WebSession.Cookies.GetCookies($uri)
        $arr = @()
        foreach ($c in $cookies) {
            $arr += [pscustomobject]@{
                Name = $c.Name
                Value = $c.Value
                Domain = $c.Domain
                Path = $c.Path
            }
        }
        $json = $arr | ConvertTo-Json -Depth 4 -Compress
        Set-Content -Path $SessionFile -Value (Protect-Text $json) -Encoding ASCII
    } catch {
        Log "Не удалось сохранить сессию: $($_.Exception.Message)"
    }
}

function Load-Session {
    if (-not (Test-Path $SessionFile)) { return }
    try {
        $protected = Get-Content $SessionFile -Raw
        $json = Unprotect-Text $protected
        $arr = $json | ConvertFrom-Json
        foreach ($x in @($arr)) {
            $c = New-Object System.Net.Cookie($x.Name, $x.Value, $x.Path, $x.Domain)
            $script:WebSession.Cookies.Add($c)
        }
        Log "Сохранённая сессия загружена."
    } catch {
        Log "Сохранённая сессия не загрузилась. Можно войти заново."
    }
}


function Get-ProxyArgs {
    $args = @{}
    if (-not (Test-Path $ConnectionFile)) { return $args }
    try {
        $cfg = Get-Content $ConnectionFile -Raw | ConvertFrom-Json
        if (-not [bool]$cfg.useProxy) { return $args }
        if ([string]::IsNullOrWhiteSpace([string]$cfg.proxyUrl)) { return $args }

        $args["Proxy"] = [string]$cfg.proxyUrl
        $args["ProxyUseDefaultCredentials"] = $false

        if (-not [string]::IsNullOrWhiteSpace([string]$cfg.proxyUser)) {
            $sec = ConvertTo-SecureString ([string]$cfg.proxyPassword) -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential ([string]$cfg.proxyUser, $sec)
            $args["ProxyCredential"] = $cred
        }
    } catch {}
    return $args
}

function Invoke-DomlightGet([string]$Url) {
    $proxy = Get-ProxyArgs
    return Invoke-WebRequest -Uri $Url -WebSession $script:WebSession -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
        "Accept-Language" = "ru-RU,ru;q=0.9"
    }
}

function Is-Authenticated([string]$Html) {
    return (@(Parse-Accounts $Html).Count -gt 0)
}

function Start-PhoneLogin {
    $btnSms.Enabled = $false
    try {
        $phone = Normalize-Phone $txtPhone.Text
        Log "Открываю Домлайт..."
        $r = Invoke-DomlightGet $LoginUrl
        $script:LoginCsrf = Get-Csrf $r.Content
        $script:Phone = $phone

        $headers = @{
            "X-CSRF-Token" = $script:LoginCsrf
            "X-Requested-With" = "XMLHttpRequest"
            "Origin" = $BaseUrl
            "Referer" = $LoginUrl
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
        }

        $body = "_csrf-lk=$([uri]::EscapeDataString($script:LoginCsrf))&phone=$([uri]::EscapeDataString($phone))&iAgree=0&iAgree=1&policy_agree=0&policy_agree=1"
        $proxy = Get-ProxyArgs
        $resp = Invoke-WebRequest -Uri $AuthPhoneUrl -Method POST -WebSession $script:WebSession -UseBasicParsing -TimeoutSec 40 @proxy -Headers $headers -ContentType "application/x-www-form-urlencoded; charset=UTF-8" -Body $body
        Log "Ответ /auth/phone: HTTP $($resp.StatusCode)"
        Log "Ответ Домлайта: $($resp.Content)"

        try {
            $data = $resp.Content | ConvertFrom-Json
        } catch {
            throw "Домлайт вернул не JSON. HTTP $($resp.StatusCode). Ответ: $($resp.Content)"
        }

        if (-not $data.status) {
            $msg = $null
            if ($data.message) { $msg = [string]$data.message }
            elseif ($data.error) { $msg = [string]$data.error }
            elseif ($data.errors) { $msg = ($data.errors | ConvertTo-Json -Compress) }
            else { $msg = "Домлайт не отправил SMS. Полный ответ: $($resp.Content)" }
            throw $msg
        }

        $html = [string]$data.html
        $script:CodeCsrf = Get-Csrf $html

        $mPhone = [regex]::Match($html, '<input[^>]+name=["'']phone["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        if ($mPhone.Success) { $script:Phone = [System.Net.WebUtility]::HtmlDecode($mPhone.Groups[1].Value) }

        $grpCode.Enabled = $true
        $txtCode.Focus()
        Log "SMS отправлено. Введите код."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Домлайт", "OK", "Error") | Out-Null
        Log "Ошибка: $($_.Exception.Message)"
    } finally {
        $btnSms.Enabled = $true
    }
}

function Confirm-Code {
    $btnConfirm.Enabled = $false
    try {
        $code = ($txtCode.Text -replace '\D','')
        if ([string]::IsNullOrWhiteSpace($code)) { throw "Введите код из SMS." }
        if (-not $script:CodeCsrf -or -not $script:LoginCsrf) { throw "Сначала нажмите «Получить SMS»." }

        $headers = @{
            "X-CSRF-Token" = $script:LoginCsrf
            "X-Requested-With" = "XMLHttpRequest"
            "Origin" = $BaseUrl
            "Referer" = $LoginUrl
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
        }

        $body = "_csrf-lk=$([uri]::EscapeDataString($script:CodeCsrf))&phone=$([uri]::EscapeDataString($script:Phone))&code=$([uri]::EscapeDataString($code))"
        # Domlight normally answers successful code confirmation with HTTP 302 Redirect.
        # Windows PowerShell can surface that normal redirect as an exception, so accept 302
        # and then verify authorization by opening the receipts page.
        try {
            $proxy = Get-ProxyArgs
            Invoke-WebRequest -Uri $AuthCodeUrl -Method POST -WebSession $script:WebSession -UseBasicParsing -TimeoutSec 40 @proxy -Headers $headers -ContentType "application/x-www-form-urlencoded; charset=UTF-8" -Body $body | Out-Null
        } catch {
            $resp = $_.Exception.Response
            $status = $null
            try { $status = [int]$resp.StatusCode } catch {}
            if ($status -ne 302) {
                throw
            }
            Log "Домлайт подтвердил код и выполнил перенаправление."
        }

        Start-Sleep -Milliseconds 500
        $r = Invoke-DomlightGet $ReceiptsUrl
        if (-not (Is-Authenticated $r.Content)) { throw "Код не принят или Домлайт не завершил вход." }

        Save-Session
        $lblStatus.Text = "Подключено"
        $lblStatus.ForeColor = [Drawing.Color]::Green
        $btnSync.Enabled = $true
        Log "Вход выполнен. Сессия сохранена."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Домлайт", "OK", "Error") | Out-Null
        Log "Ошибка входа: $($_.Exception.Message)"
    } finally {
        $btnConfirm.Enabled = $true
    }
}


function Get-ReceiptAccountFolder {
    param([string]$Account)

    # Prefer the new human-readable folder name if it already exists.
    $decorated = @(
        Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq $Account -or
            $_.Name -like ($Account + ' - кв. *')
        } |
        Sort-Object {
            if ($_.Name -like ($Account + ' - кв. *')) { 0 } else { 1 }
        } |
        Select-Object -First 1
    )

    if ($decorated.Count -gt 0) {
        return [string]$decorated[0].FullName
    }

    return (Join-Path $ReceiptsDir $Account)
}


function Get-ReceiptIdentityFromPortalName {
    param([string]$Account, [string]$Name)

    $m = [regex]::Match(
        $Name,
        '^(?<y>20\d{2})[_-](?<m>0[1-9]|1[0-2])[_-](?<kind>[12])[_-]',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $m.Success) { return '' }

    return ($Account + '|' + $m.Groups['y'].Value + '|' + $m.Groups['m'].Value + '|' + $m.Groups['kind'].Value)
}

function Get-ReceiptIdentityFromArchiveFile {
    param([string]$Account, [string]$Name)

    # Readable Domlight filename:
    # YYYY_MM_ЖКХ_кв_..._ЛС_ACCOUNT.pdf
    # YYYY_MM_Капремонт_кв_..._ЛС_ACCOUNT.pdf
    $m = [regex]::Match(
        $Name,
        '^(?<y>20\d{2})[_-](?<m>0[1-9]|1[0-2])[_-](?<type>ЖКХ|Капремонт)_',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($m.Success) {
        $kind = if ($m.Groups['type'].Value -match '^ЖКХ$') { '1' } else { '2' }
        return ($Account + '|' + $m.Groups['y'].Value + '|' + $m.Groups['m'].Value + '|' + $kind)
    }

    # Technical filename still lying in archive.
    return (Get-ReceiptIdentityFromPortalName -Account $Account -Name $Name)
}

function Get-ExistingReceiptIdentitySet {
    param([string]$Account)

    $set = @{}
    $folders = @(
        Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq $Account -or
            $_.Name -like ($Account + ' - кв. *')
        }
    )

    foreach ($folder in $folders) {
        foreach ($f in @(Get-ChildItem -LiteralPath $folder.FullName -Recurse -Filter *.pdf -File -ErrorAction SilentlyContinue)) {
            $id = Get-ReceiptIdentityFromArchiveFile -Account $Account -Name $f.Name
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $set[$id] = $true
            }
        }
    }

    return $set
}

function Parse-Accounts([string]$Html) {
    $forms = [regex]::Matches($Html, '<form[^>]+action=["'']/account/set["''][\s\S]*?</form>', 'IgnoreCase')
    $result = @()
    $seen = @{}
    foreach ($f in $forms) {
        $acc = [regex]::Match($f.Value, '<input[^>]+name=["'']account["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        $comp = [regex]::Match($f.Value, '<input[^>]+name=["'']company["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
        if ($acc.Success -and $comp.Success) {
            $a = [System.Net.WebUtility]::HtmlDecode($acc.Groups[1].Value)
            $c = [System.Net.WebUtility]::HtmlDecode($comp.Groups[1].Value)
            $key = "$c|$a"
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $result += [pscustomobject]@{ Company=$c; Account=$a }
            }
        }
    }
    return $result
}

function Get-ReceiptLinks([string]$Html) {
    $matches = [regex]::Matches($Html, 'href=["'']([^"'']*/file/get\?[^"'']*bucket=receipt[^"'']*)["'']', 'IgnoreCase')
    $res = @()
    $seen = @{}
    foreach ($m in $matches) {
        $href = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
        if ($href.StartsWith("/")) { $href = "$BaseUrl$href" }
        if (-not $seen.ContainsKey($href)) {
            $seen[$href] = $true
            $uri = [Uri]$href
            $q = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
            $fn = $q["filename"]
            if ([string]::IsNullOrWhiteSpace($fn)) { $fn = "receipt_$($res.Count+1).pdf" }
            $fn = [IO.Path]::GetFileName($fn)
            $res += [pscustomobject]@{ Url=$href; Filename=$fn }
        }
    }
    return $res
}

function Sync-Receipts {
    $btnSync.Enabled = $false
    try {
        Log "Проверяю сессию..."
        $r = Invoke-DomlightGet $ReceiptsUrl
        if (-not (Is-Authenticated $r.Content)) {
            $lblStatus.Text = "Нужен вход"
            $lblStatus.ForeColor = [Drawing.Color]::DarkRed
            throw "Сессия Домлайта закончилась. Введите телефон и новый SMS-код."
        }

        $accounts = @(Parse-Accounts $r.Content)
        if ($accounts.Count -eq 0) { throw "Не удалось найти лицевые счета." }

        Log "Найдено лицевых счетов: $($accounts.Count)"
        $accountsToCheck = @($accounts)
        $effectivePortalCount = $accounts.Count
        if (Test-Path -LiteralPath $AccountStateModule) {
            try {
                $previous = @(Read-DomlightAccountState -Path $AccountsStateFile)
                if ($previous.Count -eq 0) {
                    $previous = @(Get-DomlightArchiveAccounts -ReceiptsDir $ReceiptsDir)
                }
                $snapshot = @($accounts | ForEach-Object {
                    [pscustomobject]@{
                        Account   = [string]$_.Account
                        Company   = [string]$_.Company
                        Apartment = ''
                    }
                })
                $merged = @(Merge-DomlightAccountSnapshot -Previous $previous -PortalAccounts $snapshot -MissingThreshold 3)

                # Core invariant: any account actually present in the current successful
                # portal snapshot is active again immediately (unless manually disabled).
                # This guarantees recovery from missing/inactive on the first successful
                # check after the account returns.
                $presentNow = @{}
                foreach ($p in @($snapshot)) {
                    $key = ([string]$p.Account).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($key)) { $presentNow[$key] = $true }
                }
                foreach ($stateItem in @($merged)) {
                    $key = ([string]$stateItem.Account).Trim()
                    if ($presentNow.ContainsKey($key) -and -not [bool]$stateItem.Excluded) {
                        $stateItem.Status = 'active'
                        $stateItem.MissingSuccessCount = 0
                        $stateItem.LastSeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    }
                }

                Write-DomlightAccountState -Path $AccountsStateFile -Items $merged

                $summary = Get-DomlightAccountStateSummary -Items $merged
                Log ("Состояние ЛС: активных {0}, временно отсутствуют {1}, неактивных {2}, всего {3}." -f $summary.Active,$summary.Missing,$summary.Inactive,$summary.Total)

                $excluded = @{}
                foreach ($stateItem in @($merged)) {
                    if ([bool]$stateItem.Excluded) { $excluded[[string]$stateItem.Account] = $true }
                }
                $accountsToCheck = @($accounts | Where-Object { -not $excluded.ContainsKey([string]$_.Account) })
                $effectivePortalCount = $accountsToCheck.Count
                if ($excluded.Count -gt 0) { Log ("Постоянно исключено из Domlight: " + $excluded.Count + ".") }
            } catch {
                Log ("Не удалось обновить состояние лицевых счетов; проверка квитанций продолжится для всех: " + $_.Exception.Message)
                $accountsToCheck = @($accounts)
            }
        }
        $totalNew = 0

        foreach ($item in $accountsToCheck) {
            Log "ЛС $($item.Account): проверяю квитанции..."
            $html = (Invoke-DomlightGet $ReceiptsUrl).Content
            $csrf = Get-Csrf $html

            $headers = @{
                "Referer" = $ReceiptsUrl
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
            }
            $body = "_csrf-lk=$([uri]::EscapeDataString($csrf))&company=$([uri]::EscapeDataString($item.Company))&account=$([uri]::EscapeDataString($item.Account))"
            try {
                $proxy = Get-ProxyArgs
                Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $script:WebSession -UseBasicParsing -TimeoutSec 40 @proxy -Headers $headers -ContentType "application/x-www-form-urlencoded" -Body $body | Out-Null
            } catch {
                $resp = $_.Exception.Response
                $status = $null
                try { $status = [int]$resp.StatusCode } catch {}
                if ($status -ne 302) { throw }
                Log "ЛС $($item.Account): Домлайт переключил счёт (302 Redirect)."
            }

            $html = (Invoke-DomlightGet $ReceiptsUrl).Content
            $links = @(Get-ReceiptLinks $html)
            $folder = Get-ReceiptAccountFolder -Account ([string]$item.Account)
            New-Item -ItemType Directory -Force -Path $folder | Out-Null

            $existing = Get-ExistingReceiptIdentitySet -Account ([string]$item.Account)
            $new = 0
            foreach ($x in $links) {
                $path = Join-Path $folder $x.Filename
                $identity = Get-ReceiptIdentityFromPortalName -Account ([string]$item.Account) -Name ([string]$x.Filename)
                if (-not [string]::IsNullOrWhiteSpace($identity) -and $existing.ContainsKey($identity)) {
                    continue
                }
                if (Test-Path -LiteralPath $path) {
                    if (-not [string]::IsNullOrWhiteSpace($identity)) { $existing[$identity] = $true }
                    continue
                }
                $proxy = Get-ProxyArgs
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
                Invoke-WebRequest -Uri $x.Url -WebSession $script:WebSession -UseBasicParsing -TimeoutSec 60 @proxy -OutFile $path -Headers @{
                    "Referer" = $ReceiptsUrl
                    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
                }
            $new++
                $totalNew++
            }
            if (Test-Path -LiteralPath $OrganizerFile) {
                try {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OrganizerFile `
                        -ReceiptsDir $ReceiptsDir `
                        -Account ([string]$item.Account) | Out-Null
                }
                catch {
                    Log "ЛС $($item.Account): квитанции скачаны, но пакетная сортировка не завершилась: $($_.Exception.Message)"
                }
            }

            Log "ЛС $($item.Account): найдено $($links.Count), новых $new."
        }

        # Enrich account state with apartment numbers discovered by the receipt organizer.
        # The organizer names account folders as: <account> - кв. <apartment>.
        # This keeps apartment mapping automatic and avoids any hard-coded account list.
        if (Test-Path -LiteralPath $AccountStateModule) {
            try {
                $stateItems = @(Read-DomlightAccountState -Path $AccountsStateFile)
                $archiveItems = @(Get-DomlightArchiveAccounts -ReceiptsDir $ReceiptsDir)
                if ($stateItems.Count -gt 0 -and $archiveItems.Count -gt 0) {
                    $aptMap = @{}
                    $addressMap = @{}
                    foreach ($archiveItem in $archiveItems) {
                        $a = ([string]$archiveItem.Account).Trim()
                        $apt = ([string]$archiveItem.Apartment).Trim()
                        $addr = ([string]$archiveItem.Address).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($a)) {
                            if (-not [string]::IsNullOrWhiteSpace($apt)) { $aptMap[$a] = $apt }
                            if (-not [string]::IsNullOrWhiteSpace($addr)) { $addressMap[$a] = $addr }
                        }
                    }
                    $changedDetails = $false
                    foreach ($stateItem in $stateItems) {
                        $a = ([string]$stateItem.Account).Trim()
                        if ($aptMap.ContainsKey($a)) {
                            $newApartment = [string]$aptMap[$a]
                            if ([string]$stateItem.Apartment -ne $newApartment) {
                                $stateItem.Apartment = $newApartment
                                $changedDetails = $true
                            }
                        }
                        if ($addressMap.ContainsKey($a)) {
                            $newAddress = [string]$addressMap[$a]
                            if ([string]$stateItem.Address -ne $newAddress) {
                                $stateItem.Address = $newAddress
                                $changedDetails = $true
                            }
                        }
                    }
                    if ($changedDetails) {
                        Write-DomlightAccountState -Path $AccountsStateFile -Items $stateItems
                        Log "Адреса и номера квартир синхронизированы с архивом квитанций."
                    }
                }
            } catch {
                Log "Не удалось обновить номера квартир в состоянии ЛС: $($_.Exception.Message)"
            }
        }

        Save-Session
        Log "Готово. Новых PDF: $totalNew."
        Save-LastCheck "Ручная" "Успешно" $totalNew "Проверено лицевых счетов: $($accountsToCheck.Count) из $effectivePortalCount."
        Refresh-LastCheck
        [System.Windows.Forms.MessageBox]::Show("Готово.`r`nНовых квитанций: $totalNew", "Домлайт", "OK", "Information") | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Домлайт", "OK", "Error") | Out-Null
        Log "Ошибка: $($_.Exception.Message)"
    } finally {
        $btnSync.Enabled = $true
    }
}


function Save-LastCheck([string]$Mode, [string]$Result, [int]$NewCount, [string]$Details) {
    $checked = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    [pscustomobject]@{
        CheckedAt = $checked
        Mode = $Mode
        Result = $Result
        NewCount = $NewCount
        Details = $Details
    } | ConvertTo-Json | Set-Content -Path $LastCheckFile -Encoding UTF8

    $summary = @(
        "ДОМЛАЙТ — ОТЧЁТ",
        "==============================",
        "Последняя проверка: $checked",
        "Тип проверки: $Mode",
        "Статус: $Result",
        "Новых квитанций: $NewCount",
        "Подробности: $Details",
        "",
        "Последнее обновление файла: $checked",
        "",
        "История скачиваний находится ниже.",
        "=============================="
    )
    if (-not (Test-Path $ReportFile)) {
        $summary | Set-Content -Path $ReportFile -Encoding UTF8
    } else {
        $old = Get-Content $ReportFile -Raw
        $historyMark = "ИСТОРИЯ`r`n"
        $idx = $old.IndexOf("ИСТОРИЯ", [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) {
            ($summary -join "`r`n") + "`r`n`r`nИСТОРИЯ`r`n" | Set-Content -Path $ReportFile -Encoding UTF8
        } else {
            $history = $old.Substring($idx)
            (($summary -join "`r`n") + "`r`n`r`n" + $history) | Set-Content -Path $ReportFile -Encoding UTF8
        }
    }

    $entry = "$checked | $Mode | $Result | Новых: $NewCount | $Details"
    Add-Content -Path $ReportFile -Value $entry -Encoding UTF8
}

function Refresh-LastCheck {
    if (Test-Path $LastCheckFile) {
        try {
            $x = Get-Content $LastCheckFile -Raw | ConvertFrom-Json
            $lblLastTime.Text = "Последняя проверка: $($x.CheckedAt)"
            $lblLastReport.Text = "Отчёт: $($x.Result). Новых: $($x.NewCount). $($x.Details)"
        } catch {
            $lblLastTime.Text = "Последняя проверка: данные не читаются"
            $lblLastReport.Text = "Отчёт: —"
        }
    } else {
        $lblLastTime.Text = "Последняя проверка: ещё не было"
        $lblLastReport.Text = "Отчёт: —"
    }
}


function Reset-ReceiptArchive {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Domlight создаст резервную копию старого архива и заново скачает квитанции с сайта.`r`n`r`n" +
        "НЕ будут удалены:`r`n" +
        "• авторизация Domlight`r`n" +
        "• Gmail OAuth`r`n" +
        "• получатели`r`n" +
        "• история E-mail/WhatsApp`r`n" +
        "• настройки подключения`r`n`r`n" +
        "Старый receipts будет сохранён в data\archive_backups.`r`n`r`n" +
        "Продолжить?",
        "Пересоздать архив квитанций",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        New-Item -ItemType Directory -Force -Path $ArchiveBackupRoot | Out-Null

        $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $backup = Join-Path $ArchiveBackupRoot ("receipts_BACKUP_" + $stamp)

        # Move, not copy: fast and safe even for a large OneDrive archive.
        if (Test-Path -LiteralPath $ReceiptsDir) {
            Move-Item -LiteralPath $ReceiptsDir -Destination $backup -Force -ErrorAction Stop
            Log "Старый архив сохранён: $backup"
        }

        New-Item -ItemType Directory -Force -Path $ReceiptsDir | Out-Null

        # Prepared files are disposable copies; clear them so they cannot point to the old archive.
        $outbox = Join-Path $DataDir "outbox"
        if (Test-Path -LiteralPath $outbox) {
            Get-ChildItem -LiteralPath $outbox -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Старый архив сохранён в резервной копии.`r`n`r`n" +
            "Сейчас Domlight начнёт заново скачивать доступные квитанции.",
            "Архив подготовлен",
            "OK",
            "Information"
        ) | Out-Null

        if ($btnSync.Enabled) {
            Sync-Receipts
        }
        else {
            Log "Архив очищен. Для повторной загрузки сначала подключитесь к Domlight через SMS."
            [System.Windows.Forms.MessageBox]::Show(
                "Архив пересоздан, но текущая сессия сайта не активна.`r`n`r`n" +
                "Введите телефон, получите SMS и подтвердите код. После этого нажмите «Скачать новые квитанции».",
                "Нужен вход в Domlight",
                "OK",
                "Information"
            ) | Out-Null
        }
    }
    catch {
        Log "Ошибка пересоздания архива: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось пересоздать архив:`r`n`r`n$($_.Exception.Message)",
            "Domlight",
            "OK",
            "Error"
        ) | Out-Null
    }
}

# GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = "Домлайт — квитанции — " + $AppVersion
$form.Size = New-Object Drawing.Size(650, 755)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Segoe UI", 10)
$form.MaximizeBox = $false

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Домлайт"
$lblTitle.Font = New-Object Drawing.Font("Segoe UI", 20, [Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object Drawing.Point(24, 18)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = $AppVersion
$lblVersion.Location = New-Object Drawing.Point(470, 25)
$lblVersion.Size = New-Object Drawing.Size(140, 24)
$lblVersion.TextAlign = "MiddleRight"
$lblVersion.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($lblVersion)


$lblStatusCaption = New-Object System.Windows.Forms.Label
$lblStatusCaption.Text = "Статус:"
$lblStatusCaption.Location = New-Object Drawing.Point(28, 65)
$lblStatusCaption.AutoSize = $true
$form.Controls.Add($lblStatusCaption)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Не подключено"
$lblStatus.ForeColor = [Drawing.Color]::DarkRed
$lblStatus.Location = New-Object Drawing.Point(90, 65)
$lblStatus.AutoSize = $true
$form.Controls.Add($lblStatus)

$grpPhone = New-Object System.Windows.Forms.GroupBox
$grpPhone.Text = "1. Телефон"
$grpPhone.Location = New-Object Drawing.Point(24, 95)
$grpPhone.Size = New-Object Drawing.Size(585, 100)
$form.Controls.Add($grpPhone)

$txtPhone = New-Object System.Windows.Forms.TextBox
$txtPhone.Location = New-Object Drawing.Point(18, 35)
$txtPhone.Size = New-Object Drawing.Size(260, 30)
$txtPhone.Text = "+7 "
$grpPhone.Controls.Add($txtPhone)

$btnSms = New-Object System.Windows.Forms.Button
$btnSms.Text = "Получить SMS"
$btnSms.Location = New-Object Drawing.Point(300, 33)
$btnSms.Size = New-Object Drawing.Size(160, 34)
$btnSms.Add_Click({ Start-PhoneLogin })
$grpPhone.Controls.Add($btnSms)

$grpCode = New-Object System.Windows.Forms.GroupBox
$grpCode.Text = "2. Код из SMS"
$grpCode.Location = New-Object Drawing.Point(24, 205)
$grpCode.Size = New-Object Drawing.Size(585, 100)
$grpCode.Enabled = $false
$form.Controls.Add($grpCode)

$txtCode = New-Object System.Windows.Forms.TextBox
$txtCode.Location = New-Object Drawing.Point(18, 35)
$txtCode.Size = New-Object Drawing.Size(260, 30)
$grpCode.Controls.Add($txtCode)

$btnConfirm = New-Object System.Windows.Forms.Button
$btnConfirm.Text = "Подтвердить"
$btnConfirm.Location = New-Object Drawing.Point(300, 33)
$btnConfirm.Size = New-Object Drawing.Size(160, 34)
$btnConfirm.Add_Click({ Confirm-Code })
$grpCode.Controls.Add($btnConfirm)

$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = "Скачать новые квитанции"
$btnSync.Location = New-Object Drawing.Point(24, 325)
$btnSync.Size = New-Object Drawing.Size(265, 42)
$btnSync.Enabled = $false
$btnSync.Add_Click({ Sync-Receipts })
$form.Controls.Add($btnSync)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = "Открыть папку с квитанциями"
$btnFolder.Location = New-Object Drawing.Point(310, 325)
$btnFolder.Size = New-Object Drawing.Size(299, 42)
$btnFolder.Add_Click({ Start-Process explorer.exe $ReceiptsDir })
$form.Controls.Add($btnFolder)

$btnReport = New-Object System.Windows.Forms.Button
$btnReport.Text = "Открыть текстовый отчёт"
$btnReport.Location = New-Object Drawing.Point(24, 373)
$btnReport.Size = New-Object Drawing.Size(265, 36)
$btnReport.Add_Click({
    if (-not (Test-Path $ReportFile)) {
        "Отчёт ещё не создан. Сначала выполните проверку." | Set-Content -Path $ReportFile -Encoding UTF8
    }
    Start-Process notepad.exe $ReportFile
})
$form.Controls.Add($btnReport)

$btnResetArchive = New-Object System.Windows.Forms.Button
$btnResetArchive.Text = "Пересоздать архив квитанций"
$btnResetArchive.Location = New-Object Drawing.Point(310, 373)
$btnResetArchive.Size = New-Object Drawing.Size(299, 36)
$btnResetArchive.Add_Click({ Reset-ReceiptArchive })
$form.Controls.Add($btnResetArchive)

function Show-AccountStatusWindow {
    try {
        if (-not (Test-Path -LiteralPath $AccountStateModule)) { throw "Не найден AccountState.ps1" }

        $statusForm = New-Object System.Windows.Forms.Form
        $statusForm.Text = "Лицевые счета"
        $statusForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $statusForm.ClientSize = [System.Drawing.Size]::new(1380, 650)
        $statusForm.Font = [System.Drawing.Font]::new("Segoe UI", 10)
        $statusForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
        $statusForm.MaximizeBox = $true
        $statusForm.MinimizeBox = $true
        $statusForm.MinimumSize = [System.Drawing.Size]::new(1120, 330)

        $title = New-Object System.Windows.Forms.Label
        $title.Text = "Лицевые счета"
        $title.Location = [System.Drawing.Point]::new(20, 14)
        $title.Size = [System.Drawing.Size]::new(600, 30)
        $title.Font = [System.Drawing.Font]::new("Segoe UI Semibold", 15)
        $statusForm.Controls.Add($title)

        $summary = New-Object System.Windows.Forms.Label
        $summary.Text = "Загрузка..."
        $summary.Location = [System.Drawing.Point]::new(22, 46)
        $summary.Size = [System.Drawing.Size]::new(1330, 24)
        $summary.ForeColor = [System.Drawing.Color]::DimGray
        $statusForm.Controls.Add($summary)

        $hint = New-Object System.Windows.Forms.Label
        $hint.Text = "История сохраняется. После 1-2 отсутствий счёт помечается как временно отсутствующий, после 3 - как неактивный."
        $hint.Location = [System.Drawing.Point]::new(22, 72)
        $hint.Size = [System.Drawing.Size]::new(1330, 24)
        $hint.ForeColor = [System.Drawing.Color]::DimGray
        $statusForm.Controls.Add($hint)

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Location = [System.Drawing.Point]::new(20, 104)
        $grid.Size = [System.Drawing.Size]::new(1340, 405)
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.AllowUserToResizeRows = $false
        $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
        $grid.MultiSelect = $false
        $grid.AutoGenerateColumns = $false
        $grid.RowHeadersVisible = $false
        $grid.ColumnHeadersHeight = 34
        $grid.RowTemplate.Height = 30
        $grid.BackgroundColor = [System.Drawing.Color]::White
        $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
        $grid.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(225,235,248)
        $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
        $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(248,248,248)
        $grid.EnableHeadersVisualStyles = $true
        $statusForm.Controls.Add($grid)

        $columns = @(
            [pscustomobject]@{ Name='Account'; Header='Лицевой счёт'; Width=145 },
            [pscustomobject]@{ Name='Address'; Header='Адрес'; Width=620 },
            [pscustomobject]@{ Name='StatusText'; Header='Статус'; Width=195 },
            [pscustomobject]@{ Name='MissingSuccessCount'; Header='Пропуски'; Width=75 },
            [pscustomobject]@{ Name='LastSeenAt'; Header='Последняя проверка'; Width=165 }
        )
        foreach ($spec in $columns) {
            $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $column.Name = [string]$spec.Name
            $column.DataPropertyName = [string]$spec.Name
            $column.HeaderText = [string]$spec.Header
            $column.Width = [int]$spec.Width
            if ($spec.Name -eq 'Address') {
                $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
                $column.MinimumWidth = 520
                $column.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
            } else {
                $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
            }
            if ($spec.Name -eq 'MissingSuccessCount') {
                $column.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
                $column.HeaderCell.Style.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
            }
            [void]$grid.Columns.Add($column)
        }

        $getItems = {
            $items = @(Read-DomlightAccountState -Path $AccountsStateFile)
            $archiveItems = @(Get-DomlightArchiveAccounts -ReceiptsDir $ReceiptsDir)
            if ($items.Count -eq 0) {
                $items = @($archiveItems)
                if ($items.Count -gt 0) { Write-DomlightAccountState -Path $AccountsStateFile -Items $items }
            } elseif ($archiveItems.Count -gt 0) {
                $aptMap = @{}; $addressMap = @{}
                foreach ($archiveItem in $archiveItems) {
                    $a = ([string]$archiveItem.Account).Trim()
                    if ([string]::IsNullOrWhiteSpace($a)) { continue }
                    $apt = ([string]$archiveItem.Apartment).Trim()
                    $addr = ([string]$archiveItem.Address).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($apt)) { $aptMap[$a] = $apt }
                    if (-not [string]::IsNullOrWhiteSpace($addr)) { $addressMap[$a] = $addr }
                }
                $changed = $false
                foreach ($stateItem in $items) {
                    $a = ([string]$stateItem.Account).Trim()
                    if ($aptMap.ContainsKey($a) -and [string]$stateItem.Apartment -ne [string]$aptMap[$a]) { $stateItem.Apartment=[string]$aptMap[$a]; $changed=$true }
                    if ($addressMap.ContainsKey($a) -and [string]$stateItem.Address -ne [string]$addressMap[$a]) { $stateItem.Address=[string]$addressMap[$a]; $changed=$true }
                }
                if ($changed) { Write-DomlightAccountState -Path $AccountsStateFile -Items $items }
            }
            return @($items)
        }

        $refreshGrid = {
            $selectedAccount = ''
            if ($grid.SelectedRows.Count -gt 0) { $selectedAccount = [string]$grid.SelectedRows[0].Cells['Account'].Value }
            $rows = New-Object System.Collections.ArrayList
            $itemsNow = @(& $getItems)
            $showExcluded = $false
            try { $showExcluded = [bool]$chkShowExcluded.Checked } catch {}
            foreach ($item in $itemsNow) {
                if ([bool]$item.Excluded -and -not $showExcluded) { continue }
                $statusText = [string]$item.Status
                if ([bool]$item.Excluded) { $statusText = 'Исключен' }
                elseif ($statusText -eq 'active') { $statusText = 'Активен' }
                elseif ($statusText -eq 'missing') { $statusText = 'Временно отсутствует' }
                elseif ($statusText -eq 'inactive') { $statusText = 'Неактивен' }

                $displayAddress = ([string]$item.Address).Trim()
                if ([string]::IsNullOrWhiteSpace($displayAddress)) {
                    $apt = ([string]$item.Apartment).Trim()
                    $displayAddress = $(if ([string]::IsNullOrWhiteSpace($apt)) { '—' } else { 'кв. ' + $apt })
                }
                $safeMissing = 0
                try { $rawMissing=@($item.MissingSuccessCount); if($rawMissing.Count -gt 0 -and $null -ne $rawMissing[0]){$safeMissing=[Convert]::ToInt32($rawMissing[0])} } catch { $safeMissing=0 }
                [void]$rows.Add([pscustomobject]@{
                    Account=[string]$item.Account; Address=$displayAddress; StatusText=$statusText; MissingSuccessCount=$safeMissing;
                    LastSeenAt=[string]$item.LastSeenAt
                })
            }
            $grid.DataSource=$null; $grid.DataSource=$rows
            $current=@($itemsNow | Where-Object { -not [bool]$_.Excluded })
            $total=$current.Count
            $active=@($current | Where-Object { $_.Status -eq 'active' }).Count
            $missing=@($current | Where-Object { $_.Status -eq 'missing' }).Count
            $inactive=@($current | Where-Object { $_.Status -eq 'inactive' }).Count
            $excludedCount=@($itemsNow | Where-Object { [bool]$_.Excluded }).Count
            $summary.Text = "$total актуальных  •  $active активных  •  $missing временно отсутствуют  •  $inactive неактивных  •  $excludedCount исключено"
            if ($grid.Rows.Count -gt 0) {
                $target = 0
                if (-not [string]::IsNullOrWhiteSpace($selectedAccount)) {
                    for ($i=0; $i -lt $grid.Rows.Count; $i++) { if ([string]$grid.Rows[$i].Cells['Account'].Value -eq $selectedAccount) { $target=$i; break } }
                }
                $grid.ClearSelection(); $grid.Rows[$target].Selected=$true
            }
        }

        $manualLabel = New-Object System.Windows.Forms.Label
        $manualLabel.Text = "Управление объектом"
        $manualLabel.Location = [System.Drawing.Point]::new(20, 520)
        $manualLabel.Size = [System.Drawing.Size]::new(300, 22)
        $manualLabel.Font = [System.Drawing.Font]::new("Segoe UI Semibold", 10)
        $statusForm.Controls.Add($manualLabel)
        $manualLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

        $btnExclude = New-Object System.Windows.Forms.Button
        $btnExclude.Text = "Исключить из Domlight"
        $btnExclude.Location = [System.Drawing.Point]::new(20, 546)
        $btnExclude.Size = [System.Drawing.Size]::new(200, 36)
        $statusForm.Controls.Add($btnExclude)
        $btnExclude.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

        $btnRestoreExcluded = New-Object System.Windows.Forms.Button
        $btnRestoreExcluded.Text = "Восстановить"
        $btnRestoreExcluded.Location = [System.Drawing.Point]::new(230, 546)
        $btnRestoreExcluded.Size = [System.Drawing.Size]::new(140, 36)
        $statusForm.Controls.Add($btnRestoreExcluded)
        $btnRestoreExcluded.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

        $chkShowExcluded = New-Object System.Windows.Forms.CheckBox
        $chkShowExcluded.Text = "Показать исключенные"
        $chkShowExcluded.Location = [System.Drawing.Point]::new(20, 588)
        $chkShowExcluded.Size = [System.Drawing.Size]::new(230, 24)
        $statusForm.Controls.Add($chkShowExcluded)
        $chkShowExcluded.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

        $btnCloseStatus = New-Object System.Windows.Forms.Button
        $btnCloseStatus.Text = "Закрыть"
        $btnCloseStatus.Location = [System.Drawing.Point]::new(1190, 546)
        $btnCloseStatus.Size = [System.Drawing.Size]::new(170, 36)
        $statusForm.Controls.Add($btnCloseStatus)
        $btnCloseStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

        $chkShowExcluded.Add_CheckedChanged({ & $refreshGrid })
        $btnExclude.Add_Click({
            try {
                if ($grid.SelectedRows.Count -eq 0) { return }
                $account=[string]$grid.SelectedRows[0].Cells['Account'].Value
                $items=@(& $getItems)
                $item=@($items | Where-Object { [string]$_.Account -eq $account }) | Select-Object -First 1
                if ($null -eq $item) { throw "Лицевой счёт не найден: $account" }
                if ([bool]$item.Excluded) { return }
                $msg="ЛС $account будет постоянно исключён из Domlight.`r`n`r`nОн исчезнет из основной таблицы, не будет проверяться и не будет автоматически возвращён порталом.`r`n`r`nУдалить также локальные квитанции этого ЛС?`r`nДа — исключить и удалить архив`r`nНет — исключить, но оставить архив`r`nОтмена — ничего не менять"
                $choice=[System.Windows.Forms.MessageBox]::Show($msg,"Исключить из Domlight",[System.Windows.Forms.MessageBoxButtons]::YesNoCancel,[System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
                $items=@(Set-DomlightAccountExcluded -Items $items -Account $account -Excluded $true)
                Write-DomlightAccountState -Path $AccountsStateFile -Items $items
                if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                    foreach($folder in @(Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match ('^'+[regex]::Escape($account)+'(?:\s+-|$)') })) {
                        Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
                    }
                }
                & $refreshGrid
            } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Domlight","OK","Error") | Out-Null }
        })
        $btnRestoreExcluded.Add_Click({
            try {
                if ($grid.SelectedRows.Count -eq 0) { return }
                $account=[string]$grid.SelectedRows[0].Cells['Account'].Value
                $items=@(& $getItems)
                $item=@($items | Where-Object { [string]$_.Account -eq $account }) | Select-Object -First 1
                if ($null -eq $item -or -not [bool]$item.Excluded) { [System.Windows.Forms.MessageBox]::Show("Выберите исключённый лицевой счёт. Для этого включите «Показать исключенные».","Domlight","OK","Information") | Out-Null; return }
                $items=@(Set-DomlightAccountExcluded -Items $items -Account $account -Excluded $false)
                Write-DomlightAccountState -Path $AccountsStateFile -Items $items
                & $refreshGrid
            } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Domlight","OK","Error") | Out-Null }
        })
        $btnCloseStatus.Add_Click({ $statusForm.Close() })
        $statusForm.CancelButton=$btnCloseStatus
        & $refreshGrid

        # Initial height follows the actual number/height of rows.
        # The user can freely resize the window vertically; when the grid becomes
        # shorter than its content, DataGridView shows its vertical scrollbar.
        try {
            $grid.AutoResizeRows([System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells)
            $contentHeight = [int]$grid.ColumnHeadersHeight + 4
            foreach ($row in $grid.Rows) { $contentHeight += [int]$row.Height }
            $contentHeight = [Math]::Max(150, [Math]::Min(360, $contentHeight))
            $targetClientHeight = 104 + $contentHeight + 135
            $targetClientHeight = [Math]::Max(350, [Math]::Min(620, $targetClientHeight))
            $statusForm.ClientSize = [System.Drawing.Size]::new(1380, $targetClientHeight)
        } catch { }

        [void]$statusForm.ShowDialog($form)
        $statusForm.Dispose()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Не удалось открыть лицевые счета:`r`n$($_.Exception.Message)","Domlight","OK","Error") | Out-Null
    }
}

$btnAccounts = New-Object System.Windows.Forms.Button
$btnAccounts.Text = "Лицевые счета / статус"
$btnAccounts.Location = New-Object Drawing.Point(24, 420)
$btnAccounts.Size = New-Object Drawing.Size(585, 42)
$btnAccounts.Add_Click({ Show-AccountStatusWindow })
$form.Controls.Add($btnAccounts)

$lblLastTime = New-Object System.Windows.Forms.Label
$lblLastTime.Text = "Последняя проверка: ещё не было"
$lblLastTime.Location = New-Object Drawing.Point(24, 472)
$lblLastTime.Size = New-Object Drawing.Size(585, 24)
$lblLastTime.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$form.Controls.Add($lblLastTime)

$lblLastReport = New-Object System.Windows.Forms.Label
$lblLastReport.Text = "Отчёт: —"
$lblLastReport.Location = New-Object Drawing.Point(24, 500)
$lblLastReport.Size = New-Object Drawing.Size(585, 48)
$form.Controls.Add($lblLastReport)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object Drawing.Point(24, 557)
$txtLog.Size = New-Object Drawing.Size(585, 125)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

$lblFooterVersion = New-Object System.Windows.Forms.Label
$lblFooterVersion.Text = "Текущая версия: " + $AppVersion
$lblFooterVersion.Location = New-Object Drawing.Point(365, 692)
$lblFooterVersion.Size = New-Object Drawing.Size(245, 22)
$lblFooterVersion.TextAlign = "MiddleRight"
$lblFooterVersion.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($lblFooterVersion)


try {
    Add-Type -AssemblyName System.Web
    Load-Session
    try {
        $r = Invoke-DomlightGet $ReceiptsUrl
        if (Is-Authenticated $r.Content) {
            $lblStatus.Text = "Подключено"
            $lblStatus.ForeColor = [Drawing.Color]::Green
            $btnSync.Enabled = $true
            Log "Домлайт уже подключён. Можно сразу скачивать квитанции."
        } else {
            Log "Введите телефон и получите SMS. Версия v3 покажет точный ответ Домлайта."
        }
    } catch {
        Log "Введите телефон и получите SMS."
    }
} catch {
    Log "Старт: $($_.Exception.Message)"
}

Refresh-LastCheck
[void]$form.ShowDialog()

