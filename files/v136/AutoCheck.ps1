
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Windows.Forms
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
$ReportFile = Join-Path $DataDir "DOMLIGHT_REPORT.txt"
$AccountsStateFile = Join-Path $DataDir "accounts_state.json"
$AccountStateModule = Join-Path $Root "AccountState.ps1"
$ProgressPrefix = "check_progress_"
$ProgressPattern = $ProgressPrefix + "*.json"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReceiptsDir | Out-Null
if (Test-Path -LiteralPath $AccountStateModule) { . $AccountStateModule }

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

function Save-LastCheck([string]$Result, [int]$NewCount, [string]$Details) {
    $checked = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    [pscustomobject]@{
        CheckedAt = $checked
        Mode = "Автоматическая"
        Result = $Result
        NewCount = $NewCount
        Details = $Details
    } | ConvertTo-Json | Set-Content -Path $LastCheckFile -Encoding UTF8

    $header = @(
        "ДОМЛАЙТ — ОТЧЁТ",
        "==============================",
        "Последняя проверка: $checked",
        "Тип проверки: Автоматическая",
        "Статус: $Result",
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

    $entry = "$checked | Автоматическая | $Result | Новых: $NewCount | $Details"
    @($header + $history + $entry) | Set-Content -Path $ReportFile -Encoding UTF8
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
    return (@(Parse-Accounts $Html).Count -gt 0)
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
        Save-LastCheck "Нужен вход" 0 "Нет сохранённой сессии. Откройте Домлайт и войдите через SMS."
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
        Save-LastCheck "Нужен вход" 0 "Сессия закончилась. Нужно снова войти через SMS."
        Log "Сессия закончилась. Нужно снова войти через SMS."
        exit 3
    }

    $accounts = @(Parse-Accounts $r.Content)
    if ($accounts.Count -eq 0) {
        Save-LastCheck "Ошибка" 0 "Лицевые счета не найдены."
        Log "Лицевые счета не найдены."
        exit 4
    }

    # v105: update durable account state only after a successful portal account-list read.
    $accountsToCheck = @($accounts)
    $effectivePortalCount = $accounts.Count
    if (Test-Path -LiteralPath $AccountStateModule) {
        try {
            $previous = @(Read-DomlightAccountState -Path $AccountsStateFile)
            if ($previous.Count -eq 0) { $previous = @(Get-DomlightArchiveAccounts -ReceiptsDir $ReceiptsDir) }
            $snapshot = @($accounts | ForEach-Object { [pscustomobject]@{Account=[string]$_.Account;Company=[string]$_.Company;Apartment=''} })
            $merged = @(Merge-DomlightAccountSnapshot -Previous $previous -PortalAccounts $snapshot -MissingThreshold 3)
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
            Log ("Не удалось обновить состояние лицевых счетов, проверка квитанций продолжается: " + $_.Exception.Message)
        }
    }

    $totalNew = 0
    $accountIndex = 0
    Save-Progress -Stage "Счета" -AccountTotal $accountsToCheck.Count -Message ("Будет проверено лицевых счетов: " + $accountsToCheck.Count + " из " + $effectivePortalCount)

    foreach ($item in $accountsToCheck) {
        $accountIndex++
        Save-Progress -Stage "Лицевой счет" -AccountIndex $accountIndex -AccountTotal $accountsToCheck.Count -Account ([string]$item.Account) -Downloaded $totalNew -Message ("Открываю лицевой счет " + $item.Account)
        $html = (Invoke-Get $ReceiptsUrl $session).Content
        $csrf = Get-Csrf $html

        $headers = @{
            "Referer" = $ReceiptsUrl
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
        }
        $body = "_csrf-lk=$([uri]::EscapeDataString($csrf))&company=$([uri]::EscapeDataString($item.Company))&account=$([uri]::EscapeDataString($item.Account))"
        try {
            $proxy = Get-ProxyArgs
            Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $session -UseBasicParsing -TimeoutSec 40 @proxy -Headers $headers -ContentType "application/x-www-form-urlencoded" -Body $body | Out-Null
        } catch {
            $resp = $_.Exception.Response
            $status = $null
            try { $status = [int]$resp.StatusCode } catch {}
            if ($status -ne 302) { throw }
            Log "ЛС $($item.Account): Домлайт переключил счёт (302 Redirect)."
        }

        $html = (Invoke-Get $ReceiptsUrl $session).Content
        $links = @(Get-ReceiptLinks $html)
        $folder = Get-ReceiptAccountFolder -Account ([string]$item.Account)
        New-Item -ItemType Directory -Force -Path $folder | Out-Null

        $existing = Get-ExistingReceiptIdentitySet -Account ([string]$item.Account)
        $new = 0
        $fileIndex = 0
        Save-Progress -Stage "Загрузка" -AccountIndex $accountIndex -AccountTotal $accountsToCheck.Count -Account ([string]$item.Account) -FileTotal $links.Count -Downloaded $totalNew -Message ("ЛС " + $item.Account + ": найдено квитанций " + $links.Count)
        foreach ($x in $links) {
            $fileIndex++
            Save-Progress -Stage "Загрузка" -AccountIndex $accountIndex -AccountTotal $accountsToCheck.Count -Account ([string]$item.Account) -FileIndex $fileIndex -FileTotal $links.Count -Downloaded $totalNew -Message ("Скачиваю файл " + $fileIndex + " из " + $links.Count)
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
            Invoke-WebRequest -Uri $x.Url -WebSession $session -UseBasicParsing -TimeoutSec 60 @proxy -OutFile $path -Headers @{
                "Referer" = $ReceiptsUrl
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0"
            }
            if (-not [string]::IsNullOrWhiteSpace($identity)) { $existing[$identity] = $true }
            $new++
            $totalNew++
            Save-Progress -Stage "Загрузка" -AccountIndex $accountIndex -AccountTotal $accountsToCheck.Count -Account ([string]$item.Account) -FileIndex $fileIndex -FileTotal $links.Count -Downloaded $totalNew -Message ("Скачано новых файлов: " + $totalNew)
        }

        Save-Progress -Stage "Сортировка" -AccountIndex $accountIndex -AccountTotal $accountsToCheck.Count -Account ([string]$item.Account) -Downloaded $totalNew -Message ("Раскладываю квитанции ЛС " + $item.Account)
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

    Save-Progress -Stage "Готово" -AccountIndex $accountsToCheck.Count -AccountTotal $accountsToCheck.Count -Downloaded $totalNew -Message ("Готово. Новых квитанций: " + $totalNew)
    Log "Готово. Новых квитанций: $totalNew."
    Save-LastCheck "Успешно" $totalNew "Проверено лицевых счетов: $($accountsToCheck.Count) из $effectivePortalCount."

    # Background/silent checker must never open modal UI.
    # Results are written to last_check.json, DOMLIGHT_REPORT.txt and auto_check.log.
    if ($totalNew -gt 0) {
        Log ("Фоновая проверка: скачаны новые квитанции. Новых файлов: " + $totalNew)
    }

    exit 0
}
catch {
    Save-Progress -Stage "Ошибка" -Downloaded 0 -Message $_.Exception.Message
    Save-LastCheck "Ошибка" 0 $_.Exception.Message
    Log "ОШИБКА: $($_.Exception.Message)"
    exit 1
}

