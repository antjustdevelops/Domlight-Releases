param([string]$Root=(Split-Path -Parent $MyInvocation.MyCommand.Path))
$ErrorActionPreference='Stop'
$required=@(
'AccountState.ps1','AccountStatus.ps1','AutoCheck.ps1','ConfigureAutoCheckTask.ps1','DISABLE_AUTO_CHECK.bat','Domlight.ps1','DomlightLauncher.vbs','ENABLE_AUTO_CHECK.bat','MENU_DOMLIGHT.ps1','MeterStatus.ps1','OrganizeDownloadedAccount.ps1','RunAutoCheckHidden.ps1','SingleWindowLauncher.ps1','UpdateFromGitHub.ps1','DomlightPortal.ps1','Mailing.ps1','ConnectionSettings.ps1','PdfEngine.ps1'
)
$errors=New-Object System.Collections.ArrayList
foreach($name in $required){if(-not(Test-Path -LiteralPath (Join-Path $Root $name))){[void]$errors.Add('Missing required file: '+$name)}}
foreach($f in @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -ErrorAction SilentlyContinue)){
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$parseErrors)
    foreach($e in @($parseErrors)){[void]$errors.Add("Parser error in $($f.Name): $($e.Message)")}
    $text=Get-Content -LiteralPath $f.FullName -Raw
    if($text -match '(?m)^\s*\\\$[A-Za-z_]'){[void]$errors.Add("Invalid backslash before PowerShell variable in $($f.Name)")}
}
$known=@{};foreach($f in @(Get-ChildItem -LiteralPath $Root -File)){$known[$f.Name.ToLowerInvariant()]=$true}
foreach($f in @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)){
    $text=Get-Content -LiteralPath $f.FullName -Raw
    $matches=[regex]::Matches($text,'(?i)["''](?<name>[A-Za-z0-9_\-]+\.(?:ps1|bat|vbs))["'']')
    foreach($m in $matches){$n=$m.Groups['name'].Value;if(-not $known.ContainsKey($n.ToLowerInvariant())){[void]$errors.Add("$($f.Name) references missing file: $n")}}
}
$menu=Join-Path $Root 'MENU_DOMLIGHT.ps1'
if(Test-Path $menu){$t=Get-Content $menu -Raw;foreach($n in @('Domlight.ps1','AccountStatus.ps1','MeterStatus.ps1','Mailing.ps1','ConnectionSettings.ps1','SingleWindowLauncher.ps1','UpdateFromGitHub.ps1')){if($t -notmatch [regex]::Escape($n)){[void]$errors.Add('Menu contract missing: '+$n)}}}
$organizer=Join-Path $Root 'OrganizeDownloadedAccount.ps1'
if(Test-Path $organizer){if((Get-Content $organizer -Raw)-notmatch 'PdfEngine\.ps1'){[void]$errors.Add('Organizer no longer declares PdfEngine dependency.')}}
$meter=Join-Path $Root 'MeterStatus.ps1'
if(Test-Path $meter){$t=Get-Content $meter -Raw;if($t -match '/meter/value'){[void]$errors.Add('Meter submission must remain disabled.')}}
$result=[pscustomobject]@{Ok=($errors.Count-eq0);Errors=@($errors);RequiredCount=$required.Count}
$result|ConvertTo-Json -Depth 5
if($errors.Count-gt0){exit 1}else{exit 0}
