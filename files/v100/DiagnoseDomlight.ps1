Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$Out = Join-Path $DataDir 'DOMLIGHT_DIAGNOSTIC.txt'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$s) { $lines.Add($s) }
Add-Line 'DOMLIGHT DIAGNOSTIC'
Add-Line ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('Root: ' + $Root)
Add-Line ''
$names = @('AutoCheck.ps1','RunAutoCheckHidden.ps1','AccountStatus.ps1','Domlight.ps1','MENU_DOMLIGHT.ps1','VERSION.txt')
foreach ($n in $names) {
  $p = Join-Path $Root $n
  if (Test-Path -LiteralPath $p) {
    $f = Get-Item -LiteralPath $p
    Add-Line ($n + ': EXISTS | ' + $f.Length + ' bytes | modified ' + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
  } else { Add-Line ($n + ': MISSING') }
}
Add-Line ''
foreach ($n in @('accounts_state.json','last_check.json','auto_check.log','manual_check_launcher.log','check_done.flag')) {
  $p=Join-Path $DataDir $n
  if (Test-Path -LiteralPath $p) {
    $f=Get-Item -LiteralPath $p
    Add-Line ('data/' + $n + ': EXISTS | ' + $f.Length + ' bytes | modified ' + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    if ($n -like '*.json') {
      try { $null = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; Add-Line ('  JSON: OK') } catch { Add-Line ('  JSON: ERROR | ' + $_.Exception.Message) }
    }
  } else { Add-Line ('data/' + $n + ': MISSING') }
}
Add-Line ''
$receipts=Join-Path $DataDir 'receipts'
if (Test-Path -LiteralPath $receipts) {
  $dirs=@(Get-ChildItem -LiteralPath $receipts -Directory -ErrorAction SilentlyContinue)
  Add-Line ('Receipt folders: ' + $dirs.Count)
  foreach($d in $dirs){ Add-Line ('  ' + $d.Name) }
} else { Add-Line 'Receipt folders: receipts directory MISSING' }
$lines | Set-Content -LiteralPath $Out -Encoding UTF8
[Windows.Forms.MessageBox]::Show(('Diagnostic complete.' + [Environment]::NewLine + 'Report:' + [Environment]::NewLine + $Out),'Domlight diagnostic','OK','Information') | Out-Null
Start-Process notepad.exe -ArgumentList ('"' + $Out + '"')