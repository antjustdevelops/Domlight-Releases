
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$ErrorActionPreference = "Stop"
$AppVersion = "v97 RELEASE"

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

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReceiptsDir | Out-Null

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
    return ($Html -match 'action=["'']/account/set["'']' -or $Html -match '/receipt/index')
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
        $resp = $proxy = Get-ProxyArgs
        Invoke-WebRequest -Uri $AuthPhoneUrl -Method POST -WebSession $script:WebSession -UseBasicParsing -TimeoutSec 40 @proxy -Headers $headers -ContentType "application/x-www-form-urlencoded; charset=UTF-8" -Body $body
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
        $totalNew = 0

        foreach ($item in $accounts) {
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

        Save-Session
        Log "Готово. Новых PDF: $totalNew."
        Save-LastCheck "Ручная" "Успешно" $totalNew "Проверено лицевых счетов: $($accounts.Count)."
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
    $lastSuccess = ""
    if (Test-Path $LastCheckFile) {
        try {
            $oldState = Get-Content $LastCheckFile -Raw | ConvertFrom-Json
            if ($oldState.LastSuccessAt) { $lastSuccess = [string]$oldState.LastSuccessAt }
            elseif ($oldState.Result -eq 'Успешно' -and $oldState.CheckedAt) { $lastSuccess = [string]$oldState.CheckedAt }
        } catch {}
    }
    if ($Result -eq 'Успешно') { $lastSuccess = $checked }
    $accounts = 0
    if ($Details -match 'Проверено лицевых счетов:\s*(\d+)') { $accounts = [int]$matches[1] }

    [pscustomobject]@{
        CheckedAt = $checked
        AttemptAt = $checked
        LastSuccessAt = $lastSuccess
        Mode = $Mode
        Result = $Result
        NewCount = $NewCount
        NewAccounts = 0
        InitialArchiveCount = 0
        AccountsTotal = $accounts
        ActiveAccounts = $accounts
        MissingAccounts = 0
        InactiveAccounts = 0
        Details = $Details
    } | ConvertTo-Json | Set-Content -Path $LastCheckFile -Encoding UTF8

    $summary = @(
        "ДОМЛАЙТ — ОТЧЁТ",
        "==============================",
        "Последняя попытка: $checked",
        "Последняя успешная проверка: $lastSuccess",
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
        if ($old -notmatch "ИСТОРИЯ") {
            ($summary -join "`r`n") + "`r`n`r`nИСТОРИЯ`r`n" | Set-Content -Path $ReportFile -Encoding UTF8
        } else {
            $idx = $old.IndexOf("ИСТОРИЯ")
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
$form.Size = New-Object Drawing.Size(650, 705)
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

$lblLastTime = New-Object System.Windows.Forms.Label
$lblLastTime.Text = "Последняя проверка: ещё не было"
$lblLastTime.Location = New-Object Drawing.Point(24, 420)
$lblLastTime.Size = New-Object Drawing.Size(585, 24)
$lblLastTime.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$form.Controls.Add($lblLastTime)

$lblLastReport = New-Object System.Windows.Forms.Label
$lblLastReport.Text = "Отчёт: —"
$lblLastReport.Location = New-Object Drawing.Point(24, 448)
$lblLastReport.Size = New-Object Drawing.Size(585, 48)
$form.Controls.Add($lblLastReport)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object Drawing.Point(24, 505)
$txtLog.Size = New-Object Drawing.Size(585, 125)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

$lblFooterVersion = New-Object System.Windows.Forms.Label
$lblFooterVersion.Text = "Текущая версия: " + $AppVersion
$lblFooterVersion.Location = New-Object Drawing.Point(365, 640)
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
