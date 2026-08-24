$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$restore = Join-Path $Root 'RestoreStable.ps1'
if (-not (Test-Path -LiteralPath $restore)) {
  Add-Type -AssemblyName System.Windows.Forms
  [Windows.Forms.MessageBox]::Show('RestoreStable.ps1 not found. Rollback was not started.','Domlight rollback','OK','Error') | Out-Null
  exit 1
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -Root $Root
exit $LASTEXITCODE
