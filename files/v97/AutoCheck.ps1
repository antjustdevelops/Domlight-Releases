
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web
$ErrorActionPreference = "Stop"

$BaseUrl = "https://lk.kakdoma.life"
$ReceiptsUrl = "$BaseUrl/receipt/index"
$AccountSetUrl = "$BaseUrl/account/set"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root "data"
$ReceiptsDir = Join-Path $DataDir "receipts"
$OrganizerFile = Join-Path $Root "OrganizeDownloadedAccount.ps1"
$SessionFile = Join-Path $DataDir "session.dat"
$ConnectionFile = Join-Path $DataDir "connection.json"
$LogFile = Join-Path $DataDir "auto_check.log"
$LastCheckFile = Join-Path $DataDir "last_check.json"
$AccountsStateFile = Join-Path $DataDir "accounts_state.json"
$ReportFile = Join-Path $DataDir "DOMLIGHT_REPORT.txt"
$ProgressPrefix = "check_progress_"
$ProgressPattern = $ProgressPrefix + "*.json"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReceiptsDir | Out-Null

function Save-Progress {
    param(
        [string]$Stage,
        [int]$AccountIndex = 0,
        [int]$AccountTotal = 0,
        [string]$Account = "",
        [int]$FileIndex = 0,
        [int]$FileTotal = 0,
        [int]$Downloaded = 0,
        [string]$Message = ""
    )

    $obj = [pscustomobject]@{
        UpdatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Stage = $Stage
        AccountIndex = $AccountIndex
        AccountTotal = $AccountTotal
        Account = $Account
        FileIndex = $FileIndex
        FileTotal = $FileTotal
        Downloaded = $Downloaded
        Message = $Message
    }

    # Every update gets its own tiny snapshot file.
    # Nothing is overwritten, so the dashboard can never lock the file being written.
    $name = $ProgressPrefix + ([DateTime]::UtcNow.Ticks) + "_" + ([guid]::NewGuid().ToString("N")) + ".json"
    $path = Join-Path $DataDir $name
    $obj | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8

    # Keep only a small tail of snapshots.
    $old = @(
        Get-ChildItem -LiteralPath $DataDir -Filter $ProgressPattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip 20
    )
    foreach ($f in $old) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Log([string]$Text) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Text" -Encoding UTF8
}

function Save-LastCheck {
    param(
        [string]$Result,
        [int]$NewCount,
        [string]$Details,
        [int]$AccountsTotal = 0,
        [int]$ActiveAccounts = 0,
        [int]$MissingAccounts = 0,
        [int]$InactiveAccounts = 0,
        [int]$NewAccounts = 0,
        [int]$InitialArchiveCount = 0
    )

    $attempt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $lastSuccess = ""
    if (Test-Path $LastCheckFile) {
        try {
            $oldState = Get-Content $LastCheckFile -Raw | ConvertFrom-Json
            if ($oldState.LastSuccessAt) { $lastSuccess = [string]$oldState.LastSuccessAt }
            elseif ($oldState.Result -eq "Успешно" -and $oldState.CheckedAt) { $lastSuccess = [string]$oldState.CheckedAt }
        } catch {}
    }
    if ($Result -eq "Успешно") { $lastSuccess = $attempt }

    [pscustomobject]@{
        CheckedAt = $attempt
        AttemptAt = $attempt
        LastSuccessAt = $lastSuccess
        Mode = "Автоматическая"
        Result = $Result
        NewCount = $NewCount
        NewAccounts = $NewAccounts
        InitialArchiveCount = $InitialArchiveCount
        AccountsTotal = $AccountsTotal
        ActiveAccounts = $ActiveAccounts
        MissingAccounts = $MissingAccounts
        InactiveAccounts = $InactiveAccounts
        Details = $Details
    } | ConvertTo-Json | Set-Content -Path $LastCheckFile -Encoding UTF8

    $header = @(
        "ДОМЛАЙТ — ОТЧЁТ",
        "==============================",
        "Последняя попытка: $attempt",
        "Последняя успешная проверка: $lastSuccess",
        "Тип проверки: Автоматическая",
        "Статус: $Result",
        "Активных лицевых счетов: $ActiveAccounts из $AccountsTotal",
        "Новых лицевых счетов: $NewAccounts",
        "Первичная загрузка архива: $InitialArchiveCount",
        "Новых квитанций: $NewCount",
        "Подробности: $Details",
        "",
        "ИСТОРИЯ"
    )

    $history = @()
    if (Test-Path $ReportFile) {
        $old = Get-Content $ReportFile
        $idx = [Array]::IndexOf($old, "ИСТОРИЯ")
        if ($idx -ge 0 -and $idx + 1 -lt $old.Count) {
            $history = $old[($idx+1)..($old.Count-1)]
        }
    }

    $entry = "$attempt | Автоматическая | $Result | ЛС: $ActiveAccounts/$AccountsTotal | Новых ЛС: $NewAccounts | Архив: $InitialArchiveCount | Новых квитанций: $NewCount | $Details"
    @($header + $history + $entry) | Set-Content -Path $ReportFile -Encoding UTF8
}

function Get-AccountFolderApartment {
    param([string]$Account)
    $folder = @(
        Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ($Account + ' - кв. *') } |
        Select-Object -First 1
    )
    if ($folder.Count -eq 0) { return "" }
    $prefix = $Account + ' - кв. '
    if ($folder[0].Name.StartsWith($prefix)) { return $folder[0].Name.Substring($prefix.Length) }
    return ""
}

function Load-AccountsState {
    $items = @()
    if (Test-Path $AccountsStateFile) {
        try { $items = @(Get-Content $AccountsStateFile -Raw | ConvertFrom-Json) } catch { $items = @() }
    }

    # First v97 run: bootstrap existing receipt folders as already-known accounts.
    $known = @{}
    foreach ($x in $items) { if ($x.Account) { $known[[string]$x.Account] = $true } }
    foreach ($folder in @(Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($folder.Name, '^(?<a>\d{9,20})(?:\s+-\s+кв\.\s*(?<apt>.+))?$')
        if (-not $m.Success) { continue }
        $account = $m.Groups['a'].Value
        if ($known.ContainsKey($account)) { continue }
        $items += [pscustomobject]@{
            Account = $account
            Company = ""
            Apartment = $m.Groups['apt'].Value
            Status = "active"
            MissingSuccessCount = 0
            ManuallyDisabled = $false
            FirstSeenAt = $folder.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
            LastSeenAt = $folder.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
        $known[$account] = $true
    }
    return @($items)
}

function Save-AccountsState([object[]]$Items) {
    @($Items) | ConvertTo-Json -Depth 5 | Set-Content -Path $AccountsStateFile -Encoding UTF8
}

function Unprotect-Text([string]$Text) {
    $bytes = [Convert]::FromBase64String($Text)
    $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($dec)
}

function Get-Csrf([string]$Html) {
    $m = [regex]::Match($Html, '<meta[^>]+name=["'']csrf-token["''][^>]+content=["'']([^"'']+)["'']', 'IgnoreCase')
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    $m = [regex]::Match($Html, '<input[^>]+name=["'']_csrf-lk["''][^>]+value=["'']([^"'']+)["'']', 'IgnoreCase')
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    $m = [regex]::Match($Html, '<input[^>]+value=["'']([^"'']+)["''][^>]+name=["'']_csrf-lk["'']', 'IgnoreCase')
    if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    throw "Не найден CSRF-токен."
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

function Invoke-Get([string]$Url, $Session) {
    $proxy = Get-ProxyArgs
    return Invoke-WebRequest -Uri $Url -WebSession $Session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
        "Accept-Language" = "ru-RU,ru;q=0.9"
    }
}

function Is-Authenticated([string]$Html) {
    return ($Html -match 'action=["'']/account/set["'']' -or $Html -match '/receipt/index')
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

try {
    Log "Начало автоматической проверки."
    Save-Progress -Stage "Подключение" -Message "Подключаюсь к кабинету Домлайт..."

    if (-not (Test-Path $SessionFile)) {
        Save-LastCheck -Result "Нужен вход" -NewCount 0 -Details "Нет сохранённой сессии. Откройте Домлайт и войдите через SMS."
        Log "Нет сохранённой сессии. Откройте программу и войдите через SMS."
        exit 2
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $protected = Get-Content $SessionFile -Raw
    $json = Unprotect-Text $protected
    $arr = $json | ConvertFrom-Json
    foreach ($x in @($arr)) {
        $c = New-Object System.Net.Cookie($x.Name, $x.Value, $x.Path, $x.Domain)
        $session.Cookies.Add($c)
    }

    $r = Invoke-Get $ReceiptsUrl $session
    if (-not (Is-Authenticated $r.Content)) {
        Save-LastCheck -Result "Нужен вход" -NewCount 0 -Details "Сессия закончилась. Нужно снова войти через SMS."
        Log "Сессия закончилась. Нужно снова войти через SMS."
        exit 3
    }

    $accounts = @(Parse-Accounts $r.Content)
    if ($accounts.Count -eq 0) {
        Save-LastCheck -Result "Ошибка" -NewCount 0 -Details "Лицевые счета не найдены."
        Log "Лицевые счета не найдены."
        exit 4
    }

    $state = @(Load-AccountsState)
    $stateByAccount = @{}
    foreach ($entry in $state) { if ($entry.Account) { $stateByAccount[[string]$entry.Account] = $entry } }

    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $currentAccounts = @{}
    $newAccountSet = @{}
    foreach ($item in $accounts) {
        $account = [string]$item.Account
        $currentAccounts[$account] = $true
        if (-not $stateByAccount.ContainsKey($account)) {
            $entry = [pscustomobject]@{
                Account = $account
                Company = [string]$item.Company
                Apartment = ""
                Status = "active"
                MissingSuccessCount = 0
                ManuallyDisabled = $false
                FirstSeenAt = $now
                LastSeenAt = $now
            }
            $state += $entry
            $stateByAccount[$account] = $entry
            $newAccountSet[$account] = $true
        } else {
            $entry = $stateByAccount[$account]
            $entry.Company = [string]$item.Company
            $entry.LastSeenAt = $now
            $entry.MissingSuccessCount = 0
            if (-not [bool]$entry.ManuallyDisabled) { $entry.Status = "active" }
        }
    }

    # Missing/inactive is changed only after a successful account-list read.
    foreach ($entry in $state) {
        $account = [string]$entry.Account
        if ([bool]$entry.ManuallyDisabled) {
            $entry.Status = "inactive"
            continue
        }
        if (-not $currentAccounts.ContainsKey($account)) {
            $entry.MissingSuccessCount = [int]$entry.MissingSuccessCount + 1
            if ([int]$entry.MissingSuccessCount -ge 3) { $entry.Status = "inactive" }
            else { $entry.Status = "missing" }
        }
    }
    Save-AccountsState $state

    $totalNew = 0
    $initialArchiveCount = 0
    $newAccountsCount = $newAccountSet.Count
    $accountIndex = 0
    Save-Progress -Stage "Счета" -AccountTotal $accounts.Count -Message ("Найдено лицевых счетов: " + $accounts.Count)

    foreach ($item in $accounts) {
        $account = [string]$item.Account
        $entry = $stateByAccount[$account]
        if ([bool]$entry.ManuallyDisabled) {
            Log "ЛС $account: отключён пользователем, проверка пропущена."
            continue
        }

        $accountIndex++
        $isNewAccount = $newAccountSet.ContainsKey($account)
        Save-Progress -Stage "Лицевой счет" -AccountIndex $accountIndex -AccountTotal $accounts.Count -Account $account -Downloaded $totalNew -Message ("Открываю лицевой счет " + $account)
        $html = (Invoke-Get $ReceiptsUrl $session).Content
        $csrf = Get-Csrf $html

        $headers = @{
            "Referer" = $ReceiptsUrl
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
        }
        $body = "_csrf-lk=$([uri]::EscapeDataString($csrf))&company=$([uri]::EscapeDataString($item.Company))&account=$([uri]::EscapeDataString($account))"
        try {
            $proxy = Get-ProxyArgs
            Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $session -UseBasicParsing -TimeoutSec 40 @proxy -Headers $headers -ContentType "application/x-www-form-urlencoded" -Body $body | Out-Null
        } catch {
            $resp = $_.Exception.Response
            $status = $null
            try { $status = [int]$resp.StatusCode } catch {}
            if ($status -ne 302) { throw }
            Log "ЛС $account: Домлайт переключил счёт (302 Redirect)."
        }

        $html = (Invoke-Get $ReceiptsUrl $session).Content
        $links = @(Get-ReceiptLinks $html)
        $folder = Get-ReceiptAccountFolder -Account $account
        $folderExistedBefore = Test-Path -LiteralPath $folder
        New-Item -ItemType Directory -Force -Path $folder | Out-Null

        $existing = Get-ExistingReceiptIdentitySet -Account $account
        $downloadedForAccount = 0
        $fileIndex = 0
        $messagePrefix = if ($isNewAccount) { "Новый ЛС $account" } else { "ЛС $account" }
        Save-Progress -Stage "Загрузка" -AccountIndex $accountIndex -AccountTotal $accounts.Count -Account $account -FileTotal $links.Count -Downloaded $totalNew -Message ($messagePrefix + ": найдено квитанций " + $links.Count)
        foreach ($x in $links) {
            $fileIndex++
            Save-Progress -Stage "Загрузка" -AccountIndex $accountIndex -AccountTotal $accounts.Count -Account $account -FileIndex $fileIndex -FileTotal $links.Count -Downloaded $totalNew -Message ("Скачиваю файл " + $fileIndex + " из " + $links.Count)
            $path = Join-Path $folder $x.Filename
            $identity = Get-ReceiptIdentityFromPortalName -Account $account -Name ([string]$x.Filename)
            if (-not [string]::IsNullOrWhiteSpace($identity) -and $existing.ContainsKey($identity)) { continue }
            if (Test-Path -LiteralPath $path) {
                if (-not [string]::IsNullOrWhiteSpace($identity)) { $existing[$identity] = $true }
                continue
            }
            $proxy = Get-ProxyArgs
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            Invoke-WebRequest -Uri $x.Url -WebSession $session -UseBasicParsing -TimeoutSec 60 @proxy -OutFile $path -Headers @{
                "Referer" = $ReceiptsUrl
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
            }
            if (-not [string]::IsNullOrWhiteSpace($identity)) { $existing[$identity] = $true }
            $downloadedForAccount++
            if ($isNewAccount) { $initialArchiveCount++ } else { $totalNew++ }
            $displayDownloaded = $totalNew + $initialArchiveCount
            Save-Progress -Stage "Загрузка" -AccountIndex $accountIndex -AccountTotal $accounts.Count -Account $account -FileIndex $fileIndex -FileTotal $links.Count -Downloaded $displayDownloaded -Message ("Скачано файлов: " + $displayDownloaded)
        }

        Save-Progress -Stage "Сортировка" -AccountIndex $accountIndex -AccountTotal $accounts.Count -Account $account -Downloaded ($totalNew + $initialArchiveCount) -Message ("Раскладываю квитанции ЛС " + $account)
        if (Test-Path -LiteralPath $OrganizerFile) {
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OrganizerFile -ReceiptsDir $ReceiptsDir -Account $account | Out-Null
            } catch {
                Log "ЛС $account: квитанции скачаны, но пакетная сортировка не завершилась: $($_.Exception.Message)"
            }
        }

        $apt = Get-AccountFolderApartment -Account $account
        if (-not [string]::IsNullOrWhiteSpace($apt)) { $entry.Apartment = $apt }
        if ($isNewAccount) {
            $aptLabel = if ([string]::IsNullOrWhiteSpace($apt)) { '' } else { ' - кв. ' + $apt }
            Log "Новый ЛС $account$aptLabel: первичная загрузка архива $downloadedForAccount файлов."
        } else {
            Log "ЛС $account: найдено $($links.Count), новых $downloadedForAccount."
        }
    }

    Save-AccountsState $state
    $activeCount = @($state | Where-Object { $_.Status -eq 'active' }).Count
    $missingCount = @($state | Where-Object { $_.Status -eq 'missing' }).Count
    $inactiveCount = @($state | Where-Object { $_.Status -eq 'inactive' }).Count
    $knownTotal = $state.Count

    $detailParts = @("Проверено активных лицевых счетов: $activeCount из $knownTotal.")
    if ($newAccountsCount -gt 0) { $detailParts += "Новых лицевых счетов: $newAccountsCount." }
    if ($initialArchiveCount -gt 0) { $detailParts += "Первичная загрузка архива: $initialArchiveCount файлов." }
    if ($missingCount -gt 0) { $detailParts += "Временно отсутствуют на портале: $missingCount." }
    if ($inactiveCount -gt 0) { $detailParts += "Неактивных: $inactiveCount." }
    $details = $detailParts -join " "

    Save-Progress -Stage "Готово" -AccountIndex $accounts.Count -AccountTotal $accounts.Count -Downloaded ($totalNew + $initialArchiveCount) -Message ("Готово. Новых квитанций: $totalNew. Архив новых ЛС: $initialArchiveCount")
    Log "Готово. Новых квитанций: $totalNew. Новых ЛС: $newAccountsCount. Первичная загрузка архива: $initialArchiveCount."
    Save-LastCheck -Result "Успешно" -NewCount $totalNew -Details $details -AccountsTotal $knownTotal -ActiveAccounts $activeCount -MissingAccounts $missingCount -InactiveAccounts $inactiveCount -NewAccounts $newAccountsCount -InitialArchiveCount $initialArchiveCount

    # IMPORTANT: background checks never show modal windows. They must always exit cleanly.
    exit 0
}
catch {
    $message = $_.Exception.Message
    $friendly = $message
    if ($message -match 'timed out|timeout|время ожидания') { $friendly = "Истекло время ожидания ответа портала." }
    elseif ($message -match 'name resolution|remote name|DNS') { $friendly = "Не удалось найти портал в сети (DNS)." }
    elseif ($message -match 'connect|connection|соедин') { $friendly = "Не удалось установить соединение с порталом." }
    elseif ($message -match 'proxy|прокси') { $friendly = "Ошибка подключения через прокси." }

    Save-Progress -Stage "Ошибка" -Downloaded 0 -Message $friendly
    $state = @(Load-AccountsState)
    $activeCount = @($state | Where-Object { $_.Status -eq 'active' }).Count
    $missingCount = @($state | Where-Object { $_.Status -eq 'missing' }).Count
    $inactiveCount = @($state | Where-Object { $_.Status -eq 'inactive' }).Count
    Save-LastCheck -Result "Ошибка" -NewCount 0 -Details $friendly -AccountsTotal $state.Count -ActiveAccounts $activeCount -MissingAccounts $missingCount -InactiveAccounts $inactiveCount
    Log "ОШИБКА: $message"
    exit 1
}
