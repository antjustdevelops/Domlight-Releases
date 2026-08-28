param(
    [string]$Root = (Get-Location).Path
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'

$Files = @(
    [pscustomobject]@{
        Path = 'UpdateFromGitHub.ps1'
        Url = 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/v129/UpdateFromGitHub.ps1'
        GitBlobSha = 'bf435a949d64e7dd45570824e9d7eff716eddb17'
    },
    [pscustomobject]@{
        Path = 'MeterStatus.ps1'
        Url = 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/v129/MeterStatus.ps1'
        GitBlobSha = '78793c1265b30877aea4d778bf0f0f7957c839bd'
    }
)

function Get-GitBlobSha([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $bytes.Length + [char]0))
    $all = New-Object byte[] ($header.Length + $bytes.Length)
    [Buffer]::BlockCopy($header, 0, $all, 0, $header.Length)
    [Buffer]::BlockCopy($bytes, 0, $all, $header.Length, $bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        return (($sha1.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha1.Dispose()
    }
}

try {
    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Папка Domlight не найдена: $Root"
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stageRoot = Join-Path $Root ("data\bootstrap_stage\" + $stamp)
    $backupRoot = Join-Path $Root ("data\bootstrap_backups\" + $stamp)
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    foreach ($file in $Files) {
        $stage = Join-Path $stageRoot $file.Path
        Invoke-WebRequest -Uri $file.Url -OutFile $stage -UseBasicParsing -TimeoutSec 40
        $actual = Get-GitBlobSha $stage
        if ($actual -ne $file.GitBlobSha) {
            throw "Контрольная сумма не совпала: $($file.Path)"
        }
    }

    foreach ($file in $Files) {
        $dest = Join-Path $Root $file.Path
        $stage = Join-Path $stageRoot $file.Path
        $backup = Join-Path $backupRoot $file.Path

        if (Test-Path -LiteralPath $dest) {
            Copy-Item -LiteralPath $dest -Destination $backup -Force
        }

        Copy-Item -LiteralPath $stage -Destination $dest -Force
        try { Unblock-File -Path $dest -ErrorAction SilentlyContinue } catch {}

        $installed = Get-GitBlobSha $dest
        if ($installed -ne $file.GitBlobSha) {
            throw "Проверка после установки не пройдена: $($file.Path)"
        }
    }

    Set-Content -Path (Join-Path $Root 'VERSION.txt') -Value 'Domlight v129 RELEASE' -Encoding UTF8
    try { Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}

    [Windows.Forms.MessageBox]::Show(
        'Bootstrap-восстановление завершено. Updater и MeterStatus установлены и проверены.',
        'Domlight - восстановление',
        'OK',
        'Information'
    ) | Out-Null
}
catch {
    [Windows.Forms.MessageBox]::Show(
        ('Восстановление не выполнено.' + "`r`n`r`n" + $_.Exception.Message),
        'Domlight - восстановление',
        'OK',
        'Error'
    ) | Out-Null
    exit 1
}
