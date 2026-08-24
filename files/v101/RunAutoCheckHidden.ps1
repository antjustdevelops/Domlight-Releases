$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$AutoCheck = Join-Path $Root 'AutoCheck.ps1'
$DoneFile = Join-Path $DataDir 'check_done.flag'
$LastCheckFile = Join-Path $DataDir 'last_check.json'
$AutoLog = Join-Path $DataDir 'auto_check.log'
$LauncherLog = Join-Path $DataDir 'manual_check_launcher.log'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Log-Line([string]$Text) {
  Add-Content -Path $LauncherLog -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  " + $Text) -Encoding UTF8
}
function Write-Failure([string]$Details) {
  $now=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $lastSuccess=''
  if (Test-Path $LastCheckFile) {
    try {
      $old=Get-Content $LastCheckFile -Raw | ConvertFrom-Json
      if ($old.LastSuccessAt) { $lastSuccess=[string]$old.LastSuccessAt }
    } catch {}
  }
  [pscustomobject]@{
    CheckedAt=$now; AttemptAt=$now; LastSuccessAt=$lastSuccess; Mode='Manual'; Result='Ошибка';
    NewCount=0; NewAccounts=0; InitialArchiveCount=0; AccountsTotal=0; ActiveAccounts=0;
    MissingAccounts=0; InactiveAccounts=0; Details=$Details
  } | ConvertTo-Json | Set-Content -Path $LastCheckFile -Encoding UTF8
}

try {
  Log-Line 'Manual check started.'
  if (-not (Test-Path -LiteralPath $AutoCheck)) { throw 'AutoCheck.ps1 is missing.' }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AutoCheck
  $code=$LASTEXITCODE
  Log-Line ("AutoCheck exit code: $code")
  if ($code -ne 0) {
    $tail=''
    if (Test-Path $AutoLog) {
      try { $tail=((Get-Content $AutoLog -Tail 5) -join ' | ') } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($tail)) { $tail="AutoCheck failed with exit code $code." }
    throw $tail
  }
}
catch {
  $msg=$_.Exception.Message
  Log-Line ('ERROR: ' + $msg)
  Write-Failure $msg
}
finally {
  (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') | Set-Content -Path $DoneFile -Encoding ASCII
}
