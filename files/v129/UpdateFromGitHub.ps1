param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$CurrentVersion
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'
$ManifestUrl = 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/latest.json'

function Show-Info([string]$Message) {
    [Windows.Forms.MessageBox]::Show($Message,'Domlight - обновление','OK','Information') | Out-Null
}

function Show-Error([string]$Message) {
    [Windows.Forms.MessageBox]::Show($Message,'Domlight - обновление','OK','Error') | Out-Null
}

function Get-VersionNumber([string]$Value) {
    if ($Value -match 'v?(\d+)') { return [int]$Matches[1] }
    return 0
}

function Get-GitBlobSha([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $bytes.Length + [char]0))
    $all = New-Object byte[] ($header.Length + $bytes.Length)
    [Buffer]::BlockCopy($header,0,$all,0,$header.Length)
    [Buffer]::BlockCopy($bytes,0,$all,$header.Length,$bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        return (($sha1.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha1.Dispose() }
}

function Assert-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Пустой путь файла в manifest.' }
    if ([IO.Path]::IsPathRooted($Path)) { throw "Недопустимый абсолютный путь: $Path" }
    $norm = $Path.Replace('/','\')
    if ($norm -match '(^|\\)\.\.(\\|$)') { throw "Недопустимый путь: $Path" }
    if ($norm -match '^(?i)data(\\|$)') { throw "Обновление data запрещено: $Path" }
}

try {
    $cacheBust = [DateTime]::UtcNow.Ticks
    $manifest = Invoke-RestMethod -Uri ($ManifestUrl + '?t=' + $cacheBust) -Method Get -TimeoutSec 25
    if (-not $manifest.version -or -not $manifest.files) { throw 'Manifest повреждён или неполный.' }

    $localNumber = Get-VersionNumber $CurrentVersion
    $remoteNumber = Get-VersionNumber ([string]$manifest.version)
    if ($remoteNumber -lt $localNumber) {
        Show-Info "На компьютере установлена более новая версия: $CurrentVersion"
        exit 0
    }

    $required = New-Object System.Collections.ArrayList
    foreach ($file in @($manifest.files)) {
        $rel = [string]$file.path
        Assert-SafeRelativePath $rel
        if ([string]::IsNullOrWhiteSpace([string]$file.url)) { throw "Нет URL для $rel" }
        if ([string]::IsNullOrWhiteSpace([string]$file.gitBlobSha)) { throw "Нет контрольной суммы для $rel" }

        $dest = Join-Path $Root $rel
        $matches = $false
        if (Test-Path -LiteralPath $dest) {
            try { $matches = ((Get-GitBlobSha $dest) -eq ([string]$file.gitBlobSha).ToLowerInvariant()) } catch { $matches = $false }
        }
        if (-not $matches) { [void]$required.Add($file) }
    }

    if ($remoteNumber -eq $localNumber -and $required.Count -eq 0) {
        Show-Info "Установлена последняя версия: $CurrentVersion`r`nВсе файлы проверены."
        exit 0
    }

    if ($remoteNumber -gt $localNumber) {
        $question = "Доступна версия $($manifest.version).`r`nБудут обновлены только файлы, не совпадающие с manifest.`r`n`r`nУстановить?"
    }
    else {
        $question = "Версия $CurrentVersion уже установлена, но найдено файлов для восстановления: $($required.Count).`r`n`r`nВосстановить их по контрольным суммам?"
    }

    $answer = [Windows.Forms.MessageBox]::Show($question,'Domlight - обновление','YesNo','Question')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stageRoot = Join-Path $Root ("data\update_stage\" + $stamp)
    $backupRoot = Join-Path $Root ("data\update_backups\" + $stamp)
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    $staged = New-Object System.Collections.ArrayList
    foreach ($file in @($required)) {
        $rel = [string]$file.path
        $stage = Join-Path $stageRoot $rel
        $stageDir = Split-Path -Parent $stage
        if ($stageDir) { New-Item -ItemType Directory -Force -Path $stageDir | Out-Null }

        Invoke-WebRequest -Uri ([string]$file.url) -OutFile $stage -UseBasicParsing -TimeoutSec 40
        $actual = Get-GitBlobSha $stage
        $expected = ([string]$file.gitBlobSha).ToLowerInvariant()
        if ($actual -ne $expected) { throw "Контрольная сумма не совпала: $rel" }
        [void]$staged.Add([pscustomobject]@{ File=$file; Stage=$stage })
    }

    $replaced = New-Object System.Collections.ArrayList
    try {
        foreach ($item in @($staged)) {
            $rel = [string]$item.File.path
            $dest = Join-Path $Root $rel
            $destDir = Split-Path -Parent $dest
            if ($destDir) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

            $backup = Join-Path $backupRoot $rel
            $hadOriginal = Test-Path -LiteralPath $dest
            if ($hadOriginal) {
                $backupDir = Split-Path -Parent $backup
                if ($backupDir) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
                Copy-Item -LiteralPath $dest -Destination $backup -Force
            }

            Copy-Item -LiteralPath $item.Stage -Destination $dest -Force
            try { Unblock-File -Path $dest -ErrorAction SilentlyContinue } catch {}
            if ((Get-GitBlobSha $dest) -ne ([string]$item.File.gitBlobSha).ToLowerInvariant()) {
                throw "Проверка после установки не пройдена: $rel"
            }
            [void]$replaced.Add([pscustomobject]@{ Dest=$dest; Backup=$backup; HadOriginal=$hadOriginal })
        }
    }
    catch {
        foreach ($r in @($replaced | Select-Object -Reverse)) {
            try {
                if ($r.HadOriginal -and (Test-Path -LiteralPath $r.Backup)) { Copy-Item -LiteralPath $r.Backup -Destination $r.Dest -Force }
                elseif (-not $r.HadOriginal -and (Test-Path -LiteralPath $r.Dest)) { Remove-Item -LiteralPath $r.Dest -Force }
            } catch {}
        }
        throw
    }

    foreach ($versionScriptName in @('MENU_DOMLIGHT.ps1','Domlight.ps1')) {
        $versionScriptPath = Join-Path $Root $versionScriptName
        if (Test-Path $versionScriptPath) {
            try {
                $txt = Get-Content $versionScriptPath -Raw
                $txt = [regex]::Replace($txt,'\$AppVersion\s*=\s*["''][^"'']+["'']','$AppVersion = ''' + [string]$manifest.version + '''',1)
                Set-Content -Path $versionScriptPath -Value $txt -Encoding UTF8
            } catch {}
        }
    }

    Set-Content -Path (Join-Path $Root 'VERSION.txt') -Value ('Domlight ' + [string]$manifest.version) -Encoding UTF8
    try { Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}

    Show-Info "Обновление до $($manifest.version) установлено и проверено.`r`nФайлов заменено: $($required.Count)."
    exit 10
}
catch {
    Show-Error ("Не удалось обновить Domlight.`r`n`r`n" + $_.Exception.Message)
    exit 1
}
