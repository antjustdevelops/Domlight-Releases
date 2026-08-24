$AppVersion = "v97 RELEASE"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root "data"
$ReceiptsDir = Join-Path $DataDir "receipts"
$ArchiveBackupRoot = Join-Path $DataDir "archive_backups"
$ReportFile = Join-Path $DataDir "DOMLIGHT_REPORT.txt"
$LastCheckFile = Join-Path $DataDir "last_check.json"
$MainScript = Join-Path $Root "Domlight.ps1"
$CheckDoneFile = Join-Path $DataDir "check_done.flag"
$ProgressPattern = "check_progress_*.json"
$ConnectionFile = Join-Path $DataDir "connection.json"
$IconFile = Join-Path $Root "Domlight.ico"
$AccountsStateFile = Join-Path $DataDir "accounts_state.json"
$TaskConfigScript = Join-Path $Root "ConfigureAutoCheckTask.ps1"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Keep the Windows background task healthy on every Domlight start.
try {
    if (Test-Path $TaskConfigScript) {
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $TaskConfigScript + '"')) -WindowStyle Hidden -Wait | Out-Null
    }
} catch {}

function Run-Hidden([string]$Script) {
    $ws = New-Object -ComObject WScript.Shell
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
    [void]$ws.Run($cmd, 0, $false)
}

function Read-LastCheck {
    if (-not (Test-Path $LastCheckFile)) {
        return [pscustomobject]@{
            CheckedAt = "—"; AttemptAt = "—"; LastSuccessAt = "—"; Result = "Нет данных"; NewCount = 0
            Details = "Проверок ещё не было"; Accounts = "—"; AccountsTotal = "—"; NewAccounts = 0
            InitialArchiveCount = 0; MissingAccounts = 0; InactiveAccounts = 0
        }
    }

    try {
        $x = Get-Content $LastCheckFile -Raw | ConvertFrom-Json
        $accounts = "—"
        $total = "—"
        if ($null -ne $x.ActiveAccounts) { $accounts = [string]$x.ActiveAccounts }
        elseif ([string]$x.Details -match 'Проверено(?: активных)? лицевых счетов:\s*(\d+)') { $accounts = $matches[1] }
        if ($null -ne $x.AccountsTotal) { $total = [string]$x.AccountsTotal } else { $total = $accounts }
        $attempt = if ($x.AttemptAt) { [string]$x.AttemptAt } else { [string]$x.CheckedAt }
        $lastSuccess = if ($x.LastSuccessAt) { [string]$x.LastSuccessAt } elseif ($x.Result -eq 'Успешно') { [string]$x.CheckedAt } else { '—' }
        return [pscustomobject]@{
            CheckedAt = [string]$x.CheckedAt
            AttemptAt = $attempt
            LastSuccessAt = $lastSuccess
            Result = [string]$x.Result
            NewCount = if ($null -ne $x.NewCount) { [int]$x.NewCount } else { 0 }
            Details = [string]$x.Details
            Accounts = $accounts
            AccountsTotal = $total
            NewAccounts = if ($null -ne $x.NewAccounts) { [int]$x.NewAccounts } else { 0 }
            InitialArchiveCount = if ($null -ne $x.InitialArchiveCount) { [int]$x.InitialArchiveCount } else { 0 }
            MissingAccounts = if ($null -ne $x.MissingAccounts) { [int]$x.MissingAccounts } else { 0 }
            InactiveAccounts = if ($null -ne $x.InactiveAccounts) { [int]$x.InactiveAccounts } else { 0 }
        }
    } catch {
        return [pscustomobject]@{
            CheckedAt = "—"; AttemptAt = "—"; LastSuccessAt = "—"; Result = "Ошибка"; NewCount = 0
            Details = "Не удалось прочитать статус"; Accounts = "—"; AccountsTotal = "—"; NewAccounts = 0
            InitialArchiveCount = 0; MissingAccounts = 0; InactiveAccounts = 0
        }
    }
}

function Get-NextAutoCheck {
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $task = $service.GetFolder('\').GetTask('Domlight Auto Check')
        if ($task.NextRunTime -and $task.NextRunTime.Year -gt 2000) {
            return $task.NextRunTime.ToString('dd.MM.yyyy HH:mm')
        }
    } catch {}
    return '—'
}


function Short-Date([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq "—") { return "—" }
    try { return ([datetime]::Parse($Value)).ToString("dd.MM.yyyy") } catch { return $Value }
}
function Short-Time([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq "—") { return "" }
    try { return ([datetime]::Parse($Value)).ToString("HH:mm:ss") } catch { return "" }
}

function Proxy-Status {
    if (-not (Test-Path $ConnectionFile)) { return "Прокси: выключен" }
    try {
        $x = Get-Content $ConnectionFile -Raw | ConvertFrom-Json
        if ([bool]$x.useProxy) { return "Прокси: включён" }
    } catch {}
    return "Прокси: выключен"
}


function Reset-ReceiptArchive {
    $answer = [Windows.Forms.MessageBox]::Show(
        "Старый архив квитанций будет сохранён в резервную папку, после чего будет создан новый пустой receipts.`r`n`r`n" +
        "Авторизация, Gmail, получатели, история контактов и настройки сохранятся.`r`n`r`n" +
        "Продолжить?",
        "Пересоздать архив квитанций",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }

    try {
        New-Item -ItemType Directory -Force -Path $ArchiveBackupRoot | Out-Null
        $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $backup = Join-Path $ArchiveBackupRoot ("receipts_BACKUP_" + $stamp)

        if (Test-Path -LiteralPath $ReceiptsDir) {
            Move-Item -LiteralPath $ReceiptsDir -Destination $backup -Force -ErrorAction Stop
        }
        New-Item -ItemType Directory -Force -Path $ReceiptsDir | Out-Null

        $outbox = Join-Path $DataDir "outbox"
        if (Test-Path -LiteralPath $outbox) {
            Get-ChildItem -LiteralPath $outbox -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

        [Windows.Forms.MessageBox]::Show(
            "Готово.`r`n`r`nСтарый архив сохранён:`r`n$backup`r`n`r`nТеперь нажмите «Проверить новые квитанции».",
            "Архив пересоздан",
            "OK",
            "Information"
        ) | Out-Null
    }
    catch {
        [Windows.Forms.MessageBox]::Show(
            "Не удалось пересоздать архив:`r`n`r`n$($_.Exception.Message)",
            "Domlight",
            "OK",
            "Error"
        ) | Out-Null
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = "Domlight"
$form.Size = New-Object Drawing.Size(720, 900)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [Drawing.Color]::FromArgb(244,246,249)
$form.Font = New-Object Drawing.Font("Segoe UI", 10)
if (Test-Path $IconFile) { try { $form.Icon = New-Object Drawing.Icon($IconFile) } catch {} }

# Header
$header = New-Object Windows.Forms.Panel
$header.Location = New-Object Drawing.Point(0,0)
$header.Size = New-Object Drawing.Size(720,105)
$header.BackColor = [Drawing.Color]::FromArgb(30,41,59)
$form.Controls.Add($header)

$logoBox = New-Object Windows.Forms.Label
$logoBox.Text = "▤"
$logoBox.Font = New-Object Drawing.Font("Segoe UI Symbol", 30, [Drawing.FontStyle]::Bold)
$logoBox.ForeColor = [Drawing.Color]::White
$logoBox.Location = New-Object Drawing.Point(28,22)
$logoBox.AutoSize = $true
$header.Controls.Add($logoBox)

$title = New-Object Windows.Forms.Label
$title.Text = "Domlight"
$title.Font = New-Object Drawing.Font("Segoe UI", 24, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::White
$title.Location = New-Object Drawing.Point(85,16)
$title.AutoSize = $true
$header.Controls.Add($title)

$sub = New-Object Windows.Forms.Label
$sub.Text = "Квитанции • аренда • контроль начислений"
$sub.Font = New-Object Drawing.Font("Segoe UI", 10)
$sub.ForeColor = [Drawing.Color]::Gainsboro
$sub.Location = New-Object Drawing.Point(89,59)
$sub.AutoSize = $true
$header.Controls.Add($sub)

$proxyStatus = New-Object Windows.Forms.Label
$proxyStatus.Text = Proxy-Status
$proxyStatus.ForeColor = [Drawing.Color]::Gainsboro
$proxyStatus.Location = New-Object Drawing.Point(525,35)
$proxyStatus.Size = New-Object Drawing.Size(160,24)
$proxyStatus.TextAlign = "MiddleRight"
$header.Controls.Add($proxyStatus)

$versionHeader = New-Object Windows.Forms.Label
$versionHeader.Text = $AppVersion
$versionHeader.ForeColor = [Drawing.Color]::Gainsboro
$versionHeader.Location = New-Object Drawing.Point(525,60)
$versionHeader.Size = New-Object Drawing.Size(160,22)
$versionHeader.TextAlign = "MiddleRight"
$versionHeader.Font = New-Object Drawing.Font("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$header.Controls.Add($versionHeader)


function Add-Card([string]$Caption, [int]$X, [string]$Value, [string]$SmallText, [int]$ValueFontSize = 18) {
    $panel = New-Object Windows.Forms.Panel
    $panel.Location = New-Object Drawing.Point($X,125)
    $panel.Size = New-Object Drawing.Size(205,105)
    $panel.BackColor = [Drawing.Color]::White
    $panel.BorderStyle = "FixedSingle"
    $form.Controls.Add($panel)

    $cap = New-Object Windows.Forms.Label
    $cap.Text = $Caption
    $cap.Location = New-Object Drawing.Point(14,12)
    $cap.Size = New-Object Drawing.Size(170,22)
    $cap.ForeColor = [Drawing.Color]::DimGray
    $panel.Controls.Add($cap)

    $val = New-Object Windows.Forms.Label
    $val.Text = $Value
    $val.Location = New-Object Drawing.Point(14,38)
    $val.Size = New-Object Drawing.Size(175,33)
    $val.Font = New-Object Drawing.Font("Segoe UI", $ValueFontSize, [Drawing.FontStyle]::Bold)
    $panel.Controls.Add($val)

    $small = New-Object Windows.Forms.Label
    $small.Text = $SmallText
    $small.Location = New-Object Drawing.Point(14,75)
    $small.Size = New-Object Drawing.Size(175,20)
    $small.ForeColor = [Drawing.Color]::Gray
    $small.Font = New-Object Drawing.Font("Segoe UI", 8.5)
    $panel.Controls.Add($small)

    return [pscustomobject]@{ Panel=$panel; Value=$val; Small=$small }
}

$state = Read-LastCheck
$accountSmall = if ($state.AccountsTotal -ne "—") { "всего: $($state.AccountsTotal)" } else { "по последней проверке" }
$cardAccounts = Add-Card "Активных лицевых счетов" 30 $state.Accounts $accountSmall
$cardLast = Add-Card "Последняя успешная" 255 (Short-Date $state.LastSuccessAt) (Short-Time $state.LastSuccessAt) 15
$newSmall = if ($state.InitialArchiveCount -gt 0) { "архив новых ЛС: $($state.InitialArchiveCount)" } else { $state.Result }
$cardNew = Add-Card "Новых квитанций" 480 ([string]$state.NewCount) $newSmall

$done = New-Object Windows.Forms.Label
$done.Text = ""
$done.Location = New-Object Drawing.Point(30,246)
$done.Size = New-Object Drawing.Size(655,62)
$done.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$done.AutoEllipsis = $false
$form.Controls.Add($done)

$progress = New-Object Windows.Forms.ProgressBar
$progress.Location = New-Object Drawing.Point(30,302)
$progress.Size = New-Object Drawing.Size(655,12)
$progress.Style = "Marquee"
$progress.MarqueeAnimationSpeed = 22
$progress.Visible = $false
$form.Controls.Add($progress)

function Add-Button([string]$Text, [int]$X, [int]$Y, [int]$W, [Drawing.Color]$Back, [scriptblock]$Action) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object Drawing.Point($X,$Y)
    $b.Size = New-Object Drawing.Size($W,54)
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = [Drawing.Color]::White
    $b.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Add_Click($Action)
    $form.Controls.Add($b)
    return $b
}

$blue = [Drawing.Color]::FromArgb(37,99,235)
$green = [Drawing.Color]::FromArgb(22,163,74)
$slate = [Drawing.Color]::FromArgb(71,85,105)
$amber = [Drawing.Color]::FromArgb(180,83,9)

$btnOpen = Add-Button "▣  Открыть кабинет Домлайт" 30 334 315 $blue {
    Run-Hidden $MainScript
}

$btnCheck = Add-Button "✓  Проверить новые квитанции" 370 334 315 $green {
    try {
        if (Test-Path $CheckDoneFile) { Remove-Item $CheckDoneFile -Force }
        Get-ChildItem -LiteralPath $DataDir -Filter $ProgressPattern -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $done.Text = "Проверяю кабинет и сравниваю квитанции с архивом..."
        $info.Text = "Идёт новая проверка.`r`nПредыдущая ошибка, если была, больше не относится к текущему процессу."
        $done.ForeColor = $amber
        $progress.Visible = $true
        $btnCheck.Enabled = $false
        Run-Hidden (Join-Path $Root "RunAutoCheckHidden.ps1")
        $timer.Start()
    } catch {
        $progress.Visible = $false
        $btnCheck.Enabled = $true
        $done.Text = "Не удалось запустить проверку"
        $done.ForeColor = [Drawing.Color]::DarkRed
    }
}

$btnReport = Add-Button "≡  Отчёт и история" 30 404 205 $slate {
    if (-not (Test-Path $ReportFile)) {
        "Отчёт ещё не создан. Сначала выполните проверку." | Set-Content $ReportFile -Encoding UTF8
    }
    Start-Process notepad.exe "`"$ReportFile`""
}

$btnFolder = Add-Button "▤  Папка квитанций" 255 404 205 $slate {
    New-Item -ItemType Directory -Force -Path $ReceiptsDir | Out-Null
    Start-Process explorer.exe "`"$ReceiptsDir`""
}

$btnProxy = Add-Button "⚙  Прокси / шлюз" 480 404 205 $amber {
    try {
        $settingsScript = Join-Path $Root "ConnectionSettings.ps1"
        if (-not (Test-Path $settingsScript)) {
            throw "Не найден файл настроек подключения: $settingsScript"
        }

        # Открываем мастер в этом же процессе PowerShell.
        # Так окно точно появляется поверх панели и не теряется в скрытом процессе.
        & $settingsScript
        $proxyStatus.Text = Proxy-Status
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось открыть настройки прокси.`r`n`r`n$($_.Exception.Message)",
            "Domlight",
            "OK",
            "Error"
        ) | Out-Null
    }
}


$btnAccounts = Add-Button "▦  Лицевые счета" 30 474 315 ([Drawing.Color]::FromArgb(75,85,99)) {
    try { & (Join-Path $Root 'AccountStatus.ps1') } catch {
        [Windows.Forms.MessageBox]::Show("Не удалось открыть список лицевых счетов.`r`n$($_.Exception.Message)",'Domlight','OK','Error') | Out-Null
    }
}

$btnResetArchive = Add-Button "↻  Пересоздать архив" 370 474 315 ([Drawing.Color]::FromArgb(100,116,139)) {
    Reset-ReceiptArchive
}

$btnMailing = Add-Button "✉  Рассылка квитанций" 30 544 655 ([Drawing.Color]::FromArgb(124,58,237)) {
    try {
        Run-Hidden (Join-Path $Root "Mailing.ps1")
    } catch {
        [Windows.Forms.MessageBox]::Show(
            "Не удалось открыть рассылку:`r`n$($_.Exception.Message)",
            "Domlight",
            "OK",
            "Error"
        ) | Out-Null
    }
}

$infoPanel = New-Object Windows.Forms.Panel
$infoPanel.Location = New-Object Drawing.Point(30,614)
$infoPanel.Size = New-Object Drawing.Size(655,190)
$infoPanel.BackColor = [Drawing.Color]::White
$infoPanel.BorderStyle = "FixedSingle"
$form.Controls.Add($infoPanel)

$infoTitle = New-Object Windows.Forms.Label
$infoTitle.Text = "Состояние"
$infoTitle.Location = New-Object Drawing.Point(16,12)
$infoTitle.AutoSize = $true
$infoTitle.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
$infoPanel.Controls.Add($infoTitle)

$info = New-Object Windows.Forms.TextBox
$info.Text = "Готово к работе.`r`nПоследняя попытка: $($state.AttemptAt) — $($state.Result)`r`nСледующая автопроверка: $(Get-NextAutoCheck)"
$info.Location = New-Object Drawing.Point(16,39)
$info.Size = New-Object Drawing.Size(620,125)
$info.Multiline = $true
$info.ReadOnly = $true
$info.ScrollBars = "Vertical"
$info.BorderStyle = "None"
$info.BackColor = [Drawing.Color]::White
$info.ForeColor = [Drawing.Color]::DimGray
$info.Font = New-Object Drawing.Font("Segoe UI", 9.5)
$infoPanel.Controls.Add($info)

function Refresh-Dashboard {
    $s = Read-LastCheck
    $cardAccounts.Value.Text = [string]$s.Accounts
    $cardAccounts.Small.Text = if ($s.AccountsTotal -ne '—') { "всего: $($s.AccountsTotal) • отсутствуют: $($s.MissingAccounts)" } else { '—' }
    $cardLast.Value.Text = Short-Date $s.LastSuccessAt
    $cardLast.Small.Text = Short-Time $s.LastSuccessAt
    $cardNew.Value.Text = [string]$s.NewCount
    $cardNew.Small.Text = if ($s.InitialArchiveCount -gt 0) { "архив новых ЛС: $($s.InitialArchiveCount)" } else { [string]$s.Result }
    $proxyStatus.Text = Proxy-Status
}


$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $latestProgress = @(
        Get-ChildItem -LiteralPath $DataDir -Filter $ProgressPattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    )
    if ($latestProgress.Count -gt 0) {
        try {
            $rawProgress = Get-Content -LiteralPath $latestProgress[0].FullName -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($rawProgress)) { throw "empty progress snapshot" }
            $p = $rawProgress | ConvertFrom-Json
            $parts = @()
            if ($p.AccountTotal -gt 0) {
                $parts += ("ЛС " + $p.AccountIndex + " из " + $p.AccountTotal)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$p.Account)) {
                $parts += ([string]$p.Account)
            }
            if ($p.FileTotal -gt 0) {
                $parts += ("файл " + $p.FileIndex + " из " + $p.FileTotal)
            }
            if ($p.Downloaded -gt 0) {
                $parts += ("скачано файлов: " + $p.Downloaded)
            }

            $prefix = [string]$p.Stage
            if ($parts.Count -gt 0) {
                $done.Text = $prefix + ": " + ($parts -join " • ")
                $info.Text = $done.Text
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$p.Message)) {
                $done.Text = $prefix + ": " + [string]$p.Message
                $info.Text = $done.Text
            }
            else {
                $done.Text = $prefix
            }
            $done.ForeColor = $amber
        } catch {}
    }

    if (Test-Path $CheckDoneFile) {
        $timer.Stop()
        $progress.Visible = $false
        $btnCheck.Enabled = $true
        Refresh-Dashboard

        $s = Read-LastCheck
        if ($s.Result -eq "Успешно") {
            $done.Text = "✓ Проверка завершена"
            $info.Text = "Успешно.`r`n" + [string]$s.Details + "`r`nПоследняя попытка: " + [string]$s.AttemptAt + "`r`nСледующая автопроверка: " + (Get-NextAutoCheck)
            $done.ForeColor = [Drawing.Color]::Green
        } else {
            $done.Text = "✖ Проверка завершена с ошибкой: " + [string]$s.Details
            $info.Text = "Ошибка текущей проверки.`r`n" + [string]$s.Details + "`r`nПоследняя успешная: " + [string]$s.LastSuccessAt + "`r`nСледующая автопроверка: " + (Get-NextAutoCheck)
            $done.ForeColor = [Drawing.Color]::DarkRed
        }
        try { Remove-Item $CheckDoneFile -Force } catch {}
    }
})


$btnUpdate = New-Object Windows.Forms.Button
$btnUpdate.Text = "Обновить программу"
$btnUpdate.Location = New-Object Drawing.Point(500,830)
$btnUpdate.Size = New-Object Drawing.Size(185,28)
$btnUpdate.FlatStyle = "Flat"
$btnUpdate.FlatAppearance.BorderSize = 0
$btnUpdate.BackColor = [Drawing.Color]::FromArgb(244,246,249)
$btnUpdate.ForeColor = [Drawing.Color]::DimGray
$btnUpdate.Cursor = [Windows.Forms.Cursors]::Hand
$btnUpdate.Add_Click({
    $updater = Join-Path $Root 'UpdateFromGitHub.ps1'
    if (-not (Test-Path $updater)) {
        [Windows.Forms.MessageBox]::Show('Модуль автоматического обновления не найден.','Domlight','OK','Error') | Out-Null
        return
    }
    try {
        $p = Start-Process powershell.exe -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $updater + '"'),
            '-Root',('"' + $Root + '"'),'-CurrentVersion',('"' + $AppVersion + '"')
        ) -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 10) {
            # Hide the old version before starting the updated one so windows never overlap.
            $form.Hide()
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200

            $launcher = Join-Path $Root 'DomlightLauncher.vbs'
            if (Test-Path $launcher) {
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $launcher + '"')
            } else {
                Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'MENU_DOMLIGHT.ps1')) -WindowStyle Hidden
            }
            $form.Close()
        }
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Ошибка обновления','OK','Error') | Out-Null
    }
})
$form.Controls.Add($btnUpdate)

$footerVersion = New-Object Windows.Forms.Label
$footerVersion.Text = "Установлено: " + $AppVersion
$footerVersion.Location = New-Object Drawing.Point(30,834)
$footerVersion.Size = New-Object Drawing.Size(260,22)
$footerVersion.ForeColor = [Drawing.Color]::DimGray
$footerVersion.Font = New-Object Drawing.Font("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$form.Controls.Add($footerVersion)


[void]$form.ShowDialog()
