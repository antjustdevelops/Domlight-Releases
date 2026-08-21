param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$CurrentVersion
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManifestUrl = 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/latest.json'

function Get-VersionNumber([string]$Value) {
    if ($Value -match 'v?(\d+)') { return [int]$matches[1] }
    return 0
}

function Show-Info([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text,'Domlight','OK','Information') | Out-Null
}
function Show-Error([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text,'Domlight - обновление','OK','Error') | Out-Null
}

try {
    $manifest = Invoke-RestMethod -Uri $ManifestUrl -Method Get -TimeoutSec 20
    if (-not $manifest.version) { throw 'Сервер обновлений вернул некорректные данные.' }

    $localNumber = Get-VersionNumber $CurrentVersion
    $remoteNumber = Get-VersionNumber ([string]$manifest.version)

    if ($remoteNumber -le $localNumber) {
        Show-Info "Установлена последняя версия: $CurrentVersion"
        exit 0
    }

    $answer = [Windows.Forms.MessageBox]::Show(
        "Доступна новая версия $($manifest.version).`r`n`r`nУстановить обновление сейчас?`r`nВаши данные и квитанции будут сохранены.",
        'Domlight - обновление',
        'YesNo',
        'Question'
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }

    $temp = Join-Path $env:TEMP ('DomlightGitHubUpdate_' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $temp 'stage'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    $backup = Join-Path $Root ('data\update_backups\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $backup | Out-Null

    $downloaded = @()
    foreach ($file in @($manifest.files)) {
        $relative = [string]$file.path
        if ([string]::IsNullOrWhiteSpace($relative)) { throw 'В манифесте обновления отсутствует путь файла.' }
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('..')) { throw "Недопустимый путь обновления: $relative" }
        if ($relative -match '^(?i)data[\\/]') { throw 'Обновление не может изменять папку data.' }

        $stagePath = Join-Path $stage $relative
        $stageDir = Split-Path -Parent $stagePath
        if ($stageDir) { New-Item -ItemType Directory -Force -Path $stageDir | Out-Null }

        Invoke-WebRequest -UseBasicParsing -Uri ([string]$file.url) -OutFile $stagePath -TimeoutSec 30
        if (-not (Test-Path $stagePath)) { throw "Не удалось скачать: $relative" }

        if ($file.sha256) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $stagePath).Hash.ToLowerInvariant()
            $expected = ([string]$file.sha256).ToLowerInvariant()
            if ($actual -ne $expected) { throw "Проверка целостности не пройдена: $relative" }
        }
        $downloaded += [pscustomobject]@{ Relative=$relative; Stage=$stagePath }
    }

    foreach ($item in $downloaded) {
        $dest = Join-Path $Root $item.Relative
        if (Test-Path $dest) {
            $backupPath = Join-Path $backup $item.Relative
            $backupDir = Split-Path -Parent $backupPath
            if ($backupDir) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
            Copy-Item $dest $backupPath -Force
        }
    }

    try {
        foreach ($item in $downloaded) {
            $dest = Join-Path $Root $item.Relative
            $destDir = Split-Path -Parent $dest
            if ($destDir) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Copy-Item $item.Stage $dest -Force
            try { Unblock-File -Path $dest -ErrorAction SilentlyContinue } catch {}
        }
    } catch {
        Get-ChildItem $backup -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($backup.Length).TrimStart('\\','/')
            $dest = Join-Path $Root $rel
            $destDir = Split-Path -Parent $dest
            if ($destDir) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Copy-Item $_.FullName $dest -Force
        }
        throw
    }

    foreach ($versionScriptName in @('MENU_DOMLIGHT.ps1','Domlight.ps1')) {
        $versionScriptPath = Join-Path $Root $versionScriptName
        if (Test-Path $versionScriptPath) {
            $txt = Get-Content $versionScriptPath -Raw
            $txt = [regex]::Replace($txt, '\$AppVersion\s*=\s*["''][^"'']+["'']', ('$AppVersion = "' + [string]$manifest.version + '"'), 1)
            Set-Content -Path $versionScriptPath -Value $txt -Encoding UTF8
        }
    }
    Set-Content -Path (Join-Path $Root 'VERSION.txt') -Value ('Domlight ' + [string]$manifest.version) -Encoding UTF8

    try { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}

    [Windows.Forms.MessageBox]::Show(
        "Обновление до $($manifest.version) установлено.`r`nDomlight сейчас перезапустится.",
        'Domlight',
        'OK',
        'Information'
    ) | Out-Null

    # Start the updated window only after the old main window has had time to close.
    # This avoids two Domlight windows being visible at once.
    $launcher = Join-Path $Root 'DomlightLauncher.vbs'
    $menu = Join-Path $Root 'MENU_DOMLIGHT.ps1'
    if (Test-Path $launcher) {
        $escapedLauncher = $launcher.Replace("'", "''")
        $cmd = "Start-Sleep -Milliseconds 1200; Start-Process -FilePath '$env:WINDIR\System32\wscript.exe' -ArgumentList '""$escapedLauncher""'"
    } else {
        $escapedMenu = $menu.Replace("'", "''")
        $cmd = "Start-Sleep -Milliseconds 1200; Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','""$escapedMenu""'"
    }
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-Command',$cmd) -WindowStyle Hidden
    exit 10
} catch {
    Show-Error ("Не удалось обновить Domlight.`r`n`r`n" + $_.Exception.Message)
    exit 1
}
