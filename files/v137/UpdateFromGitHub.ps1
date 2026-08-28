param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$CurrentVersion
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManifestUrl = 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/latest.json'

function Show-Info([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text, 'Domlight Update', 'OK', 'Information') | Out-Null
}

function Show-Error([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text, 'Domlight Update', 'OK', 'Error') | Out-Null
}

function Get-VersionNumber([string]$Value) {
    if ($Value -match 'v?(\d+)') { return [int]$Matches[1] }
    return 0
}

function Get-GitBlobSha([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $bytes.Length + [char]0))
    $combined = New-Object byte[] ($header.Length + $bytes.Length)
    [Buffer]::BlockCopy($header, 0, $combined, 0, $header.Length)
    [Buffer]::BlockCopy($bytes, 0, $combined, $header.Length, $bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        return (($sha1.ComputeHash($combined) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha1.Dispose()
    }
}

function Test-SafeRelativePath([string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $false }
    if ([IO.Path]::IsPathRooted($Relative)) { return $false }
    $normalized = $Relative.Replace('/', '\')
    if ($normalized -match '(^|\\)\.\.(\\|$)') { return $false }
    if ($normalized -match '(?i)^data(\\|$)') { return $false }
    return $true
}

function Test-FileMatchesManifest($File, [string]$LocalPath) {
    if (-not (Test-Path -LiteralPath $LocalPath)) { return $false }

    if (-not [string]::IsNullOrWhiteSpace([string]$File.gitBlobSha)) {
        $actualBlob = Get-GitBlobSha $LocalPath
        return ($actualBlob -eq ([string]$File.gitBlobSha).ToLowerInvariant())
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$File.sha256)) {
        $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $LocalPath).Hash.ToLowerInvariant()
        return ($actualSha256 -eq ([string]$File.sha256).ToLowerInvariant())
    }

    return $false
}

try {
    $manifest = Invoke-RestMethod -Uri ($ManifestUrl + '?t=' + [DateTime]::UtcNow.Ticks) -Method Get -TimeoutSec 25
    if (-not $manifest.version) { throw 'Invalid update manifest: version is missing.' }
    if (-not $manifest.files) { throw 'Invalid update manifest: files are missing.' }

    $localNumber = Get-VersionNumber $CurrentVersion
    $remoteNumber = Get-VersionNumber ([string]$manifest.version)

    if ($remoteNumber -lt $localNumber) {
        Show-Info ('Installed version is newer than server version: ' + $CurrentVersion)
        exit 0
    }

    $required = @()
    foreach ($file in @($manifest.files)) {
        $relative = [string]$file.path
        if (-not (Test-SafeRelativePath $relative)) { throw ('Unsafe update path: ' + $relative) }
        if ([string]::IsNullOrWhiteSpace([string]$file.url)) { throw ('Missing URL for: ' + $relative) }
        if ([string]::IsNullOrWhiteSpace([string]$file.gitBlobSha) -and [string]::IsNullOrWhiteSpace([string]$file.sha256)) {
            throw ('Missing checksum for: ' + $relative)
        }

        $destination = Join-Path $Root $relative
        if (-not (Test-FileMatchesManifest $file $destination)) {
            $required += $file
        }
    }

    if ($remoteNumber -eq $localNumber -and $required.Count -eq 0) {
        Show-Info ('Version ' + $CurrentVersion + ' is installed and all managed files are verified.')
        exit 0
    }

    if ($remoteNumber -gt $localNumber) {
        $message = 'New version ' + [string]$manifest.version + ' is available.' + "`r`n" +
                   'Files to install: ' + $required.Count + "`r`n`r`n" + 'Install now?'
    }
    else {
        $message = 'Version number already matches, but ' + $required.Count + ' managed file(s) differ.' + "`r`n`r`n" + 'Repair now?'
    }

    $answer = [Windows.Forms.MessageBox]::Show($message, 'Domlight Update', 'YesNo', 'Question')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stageRoot = Join-Path $Root ('data\update_stage\' + $stamp)
    $backupRoot = Join-Path $Root ('data\update_backups\' + $stamp)
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    $stagedItems = @()
    foreach ($file in @($required)) {
        $relative = [string]$file.path
        $stagePath = Join-Path $stageRoot $relative
        $stageDir = Split-Path -Parent $stagePath
        if ($stageDir) { New-Item -ItemType Directory -Force -Path $stageDir | Out-Null }

        Invoke-WebRequest -UseBasicParsing -Uri ([string]$file.url) -OutFile $stagePath -TimeoutSec 40
        if (-not (Test-Path -LiteralPath $stagePath)) { throw ('Download failed: ' + $relative) }
        if (-not (Test-FileMatchesManifest $file $stagePath)) { throw ('Checksum failed: ' + $relative) }

        $stagedItems += [pscustomobject]@{
            File = $file
            StagePath = $stagePath
        }
    }

    $installedItems = @()
    try {
        foreach ($item in @($stagedItems)) {
            $relative = [string]$item.File.path
            $destination = Join-Path $Root $relative
            $destinationDir = Split-Path -Parent $destination
            if ($destinationDir) { New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null }

            $backupPath = Join-Path $backupRoot $relative
            $hadOriginal = Test-Path -LiteralPath $destination
            if ($hadOriginal) {
                $backupDir = Split-Path -Parent $backupPath
                if ($backupDir) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
                Copy-Item -LiteralPath $destination -Destination $backupPath -Force
            }

            Copy-Item -LiteralPath $item.StagePath -Destination $destination -Force
            try { Unblock-File -Path $destination -ErrorAction SilentlyContinue } catch {}

            if (-not (Test-FileMatchesManifest $item.File $destination)) {
                throw ('Post-install verification failed: ' + $relative)
            }

            $installedItems += [pscustomobject]@{
                Destination = $destination
                BackupPath = $backupPath
                HadOriginal = $hadOriginal
            }
        }
    }
    catch {
        for ($i = $installedItems.Count - 1; $i -ge 0; $i--) {
            $installed = $installedItems[$i]
            try {
                if ($installed.HadOriginal -and (Test-Path -LiteralPath $installed.BackupPath)) {
                    Copy-Item -LiteralPath $installed.BackupPath -Destination $installed.Destination -Force
                }
                elseif (-not $installed.HadOriginal -and (Test-Path -LiteralPath $installed.Destination)) {
                    Remove-Item -LiteralPath $installed.Destination -Force
                }
            }
            catch {}
        }
        throw
    }

    Set-Content -Path (Join-Path $Root 'VERSION.txt') -Value ('Domlight ' + [string]$manifest.version) -Encoding UTF8
    try { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}

    Show-Info ('Update installed and verified: ' + [string]$manifest.version + "`r`nFiles changed: " + $required.Count)
    exit 10
}
catch {
    Show-Error ('Update failed.' + "`r`n`r`n" + $_.Exception.Message)
    exit 1
}
