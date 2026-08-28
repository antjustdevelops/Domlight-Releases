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
    Log-Line ('AutoCheck started. PID=' + $p.Id)

    $deadline = (Get-Date).AddMinutes(15)
    $freshResultSeen = $false
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if (Test-Path -LiteralPath $LastCheck) {
            try {
                $info = Get-Item -LiteralPath $LastCheck
                if ($info.LastWriteTime -ge $startedAt.AddSeconds(-1)) {
                    $payload = Get-Content -LiteralPath $LastCheck -Raw | ConvertFrom-Json
                    $result = [string]$payload.Result
                    if ($result -in @('Успешно','Ошибка','Нужен вход')) {
                        $freshResultSeen = $true
                        Log-Line ('AutoCheck finished work; final result=' + $result)
                        Start-Sleep -Milliseconds 500
                        break
                    }
                }
            } catch {}
        }
    }

    if (-not $p.HasExited -and $freshResultSeen) {
        Log-Line 'Final result exists; terminating remaining child process.'
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(5000) | Out-Null } catch {}
        $exitCode = 0
    }
    elseif (-not $p.HasExited) {
        Log-Line 'AutoCheck timeout; terminating child process.'
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(5000) | Out-Null } catch {}
        throw 'AutoCheck timeout.'
    }
    else {
        $exitCode = [int]$p.ExitCode
        Log-Line ('AutoCheck process exited with code: ' + $exitCode)
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
