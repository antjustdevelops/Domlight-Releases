$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$AutoCheck = Join-Path $Root 'AutoCheck.ps1'
$DoneFile = Join-Path $DataDir 'check_done.flag'
$LauncherLog = Join-Path $DataDir 'auto_check_launcher.log'
$LastCheck = Join-Path $DataDir 'last_check.json'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Log-Line([string]$Text) {
    Add-Content -Path $LauncherLog -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  " + $Text) -Encoding UTF8
}

$exitCode = 1
$p = $null
try {
    Log-Line 'Scheduled wrapper started.'
    if (-not (Test-Path -LiteralPath $AutoCheck)) { throw 'AutoCheck.ps1 is missing.' }

    Remove-Item -LiteralPath $DoneFile -Force -ErrorAction SilentlyContinue
    $startedAt = Get-Date

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AutoCheck`""
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { throw 'Could not start AutoCheck.ps1.' }
    Log-Line ("AutoCheck started. PID=" + $p.Id)

    $deadline = (Get-Date).AddMinutes(15)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        # AutoCheck writes last_check.json at the end. A fresh successful/error result means its work is complete.
        if (Test-Path -LiteralPath $LastCheck) {
            try {
                $info = Get-Item -LiteralPath $LastCheck
                if ($info.LastWriteTime -ge $startedAt.AddSeconds(-1)) {
                    $payload = Get-Content -LiteralPath $LastCheck -Raw | ConvertFrom-Json
                    if ($payload.status -in @('Успешно','Ошибка','Нужен вход')) {
                        Log-Line ('AutoCheck finished work; final status=' + [string]$payload.status)
                        Start-Sleep -Milliseconds 500
                        break
                    }
                }
            } catch {}
        }
    }

    if (-not $p.HasExited) {
        Log-Line 'AutoCheck work is complete but process is still alive; terminating direct child process.'
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(5000) | Out-Null } catch {}
        $exitCode = 0
    } else {
        $exitCode = [int]$p.ExitCode
        Log-Line ("AutoCheck process exited with code: $exitCode")
    }

    if ((Get-Date) -ge $deadline -and -not (Test-Path -LiteralPath $LastCheck)) {
        throw 'AutoCheck timeout.'
    }
}
catch {
    Log-Line ('WRAPPER ERROR: ' + $_.Exception.Message)
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
    $exitCode = 1
}

try {
    (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') | Set-Content -Path $DoneFile -Encoding ASCII
    Log-Line 'Scheduled wrapper finished.'
} catch {}

[Environment]::Exit($exitCode)
