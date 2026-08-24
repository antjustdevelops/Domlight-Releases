$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$AutoCheck = Join-Path $Root 'AutoCheck.ps1'
$DoneFile = Join-Path $DataDir 'check_done.flag'
$LauncherLog = Join-Path $DataDir 'manual_check_launcher.log'

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Log-Line([string]$Text) {
    Add-Content -Path $LauncherLog -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  " + $Text) -Encoding UTF8
}

try {
    Log-Line 'Manual check launcher started.'
    if (-not (Test-Path -LiteralPath $AutoCheck)) {
        throw 'AutoCheck.ps1 not found.'
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AutoCheck
    $code = $LASTEXITCODE
    Log-Line ("AutoCheck finished with exit code " + $code + ".")

    if ($code -ne 0) {
        throw ("AutoCheck failed with exit code " + $code + ".")
    }
}
catch {
    Log-Line ("ERROR: " + $_.Exception.Message)
}
finally {
    (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') | Set-Content -Path $DoneFile -Encoding ASCII
}
