param([string]$Root)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
if([string]::IsNullOrWhiteSpace($Root)){ $Root=Split-Path -Parent $MyInvocation.MyCommand.Path }
$DataDir=Join-Path $Root 'data'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$backup=Join-Path $DataDir ('rollback_backups\'+$stamp)
$temp=Join-Path $env:TEMP ('DomlightStableRollback_'+[guid]::NewGuid().ToString('N'))
$zip=Join-Path $temp 'Domlight_Setup.zip'
$unpack=Join-Path $temp 'unpack'
New-Item -ItemType Directory -Force -Path $backup,$unpack | Out-Null

function Copy-TreeExceptData([string]$Source,[string]$Destination){
  Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction Stop | ForEach-Object {
    $rel=$_.FullName.Substring($Source.Length).TrimStart('\','/')
    if($rel -match '^(?i)data[\\/]'){ return }
    $dest=Join-Path $Destination $rel
    $dir=Split-Path -Parent $dest
    if($dir){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
  }
}

try {
  # Back up current program files only. The data folder is intentionally excluded.
  Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    if($_.FullName.StartsWith($DataDir,[StringComparison]::OrdinalIgnoreCase)){ return }
    $rel=$_.FullName.Substring($Root.Length).TrimStart('\','/')
    $dest=Join-Path $backup $rel
    $dir=Split-Path -Parent $dest
    if($dir){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
  }

  $url='https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/3fda3f0530e406ee0c8dbecd450cd8f2ca4bb12e/Domlight_Setup.zip'
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip -TimeoutSec 60
  Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force

  $menu=Get-ChildItem -LiteralPath $unpack -Recurse -Filter 'MENU_DOMLIGHT.ps1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $menu){ throw 'Stable setup package does not contain MENU_DOMLIGHT.ps1.' }
  $sourceRoot=$menu.Directory.FullName

  # Restore stable program files. Never copy any data folder from the package.
  Copy-TreeExceptData -Source $sourceRoot -Destination $Root

  # Remove only the temporary v97+ helper files that are known not to belong to the stable base.
  foreach($name in @('AccountStatus.ps1','RunAutoCheckHidden.ps1','DiagnoseDomlight.ps1')){
    $p=Join-Path $Root $name
    if(Test-Path $p){ Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
  }

  Set-Content -LiteralPath (Join-Path $DataDir 'rollback_completed.txt') -Value ("Restored stable pre-v97 program files at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'). Backup: $backup") -Encoding UTF8

  [Windows.Forms.MessageBox]::Show("Stable Domlight program files were restored.\r\n\r\nYour data and receipt archive were not changed.\r\nA backup of the replaced program files was saved in data\\rollback_backups.",'Domlight rollback','OK','Information') | Out-Null

  $launcher=Join-Path $Root 'DomlightLauncher.vbs'
  $menuPath=Join-Path $Root 'MENU_DOMLIGHT.ps1'
  if(Test-Path $launcher){ Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList ('"'+$launcher+'"') }
  elseif(Test-Path $menuPath){ Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$menuPath+'"')) -WindowStyle Hidden }
  exit 0
}
catch {
  [Windows.Forms.MessageBox]::Show("Rollback was not completed.\r\n\r\n"+$_.Exception.Message+"\r\n\r\nNo data folder was modified.",'Domlight rollback','OK','Error') | Out-Null
  exit 1
}
finally {
  try{ Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }catch{}
}
