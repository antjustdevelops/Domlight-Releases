param([string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path))
$ErrorActionPreference='Stop'

$required=@(
'AccountState.ps1','AccountStatus.ps1','AutoCheck.ps1','ConfigureAutoCheckTask.ps1','DISABLE_AUTO_CHECK.bat','Domlight.ps1','DomlightLauncher.vbs','ENABLE_AUTO_CHECK.bat','MENU_DOMLIGHT.ps1','MeterStatus.ps1','OrganizeDownloadedAccount.ps1','RunAutoCheckHidden.ps1','SingleWindowLauncher.ps1','UpdateFromGitHub.ps1','DomlightPortal.ps1'
)
$optional=@('Mailing.ps1','ConnectionSettings.ps1','Domlight.ico')
$errors=New-Object System.Collections.ArrayList
$warnings=New-Object System.Collections.ArrayList

foreach($name in $required){if(-not(Test-Path -LiteralPath (Join-Path $Root $name))){[void]$errors.Add('Missing required file: '+$name)}}
foreach($name in $optional){if(-not(Test-Path -LiteralPath (Join-Path $Root $name))){[void]$warnings.Add('Optional/local module not present: '+$name)}}

$data=Join-Path $Root 'data'
if(-not(Test-Path -LiteralPath $data)){[void]$warnings.Add('data directory does not exist yet.')}

$versionFile=Join-Path $Root 'VERSION.txt'
if(Test-Path -LiteralPath $versionFile){
  $version=(Get-Content -LiteralPath $versionFile -Raw).Trim()
  if([string]::IsNullOrWhiteSpace($version)){[void]$errors.Add('VERSION.txt is empty.')}
}else{[void]$warnings.Add('VERSION.txt is missing; updater will create it.')}

$portal=Join-Path $Root 'DomlightPortal.ps1'
if(Test-Path -LiteralPath $portal){
  $portalText=Get-Content -LiteralPath $portal -Raw
  foreach($fn in @('Get-DomlightVersion','Import-DomlightSession','Get-DomlightProxyArgs','Get-DomlightCsrf','Get-DomlightAccountsFromHtml','Test-DomlightAuthenticatedHtml','Set-DomlightAccountContext')){
    if($portalText -notmatch ('function\s+'+[regex]::Escape($fn)+'\b')){[void]$errors.Add('DomlightPortal.ps1 missing function: '+$fn)}
  }
}

$wrapper=Join-Path $Root 'RunAutoCheckHidden.ps1'
if(Test-Path -LiteralPath $wrapper){
  $text=Get-Content -LiteralPath $wrapper -Raw
  if($text -match '\$payload\.status'){[void]$errors.Add('RunAutoCheckHidden.ps1 still reads obsolete payload.status.')}
  if($text -notmatch '\$payload\.Result'){[void]$errors.Add('RunAutoCheckHidden.ps1 does not read payload.Result.')}
}

$domlight=Join-Path $Root 'Domlight.ps1'
if(Test-Path -LiteralPath $domlight){
  $text=Get-Content -LiteralPath $domlight -Raw
  if($text -match '\$AppVersion\s*=\s*"v106 RELEASE"'){[void]$errors.Add('Domlight.ps1 still contains hard-coded v106 version.')}
}

$result=[pscustomobject]@{Ok=($errors.Count-eq0);Errors=@($errors);Warnings=@($warnings)}
$result | ConvertTo-Json -Depth 5
if($errors.Count-gt0){exit 1}else{exit 0}
