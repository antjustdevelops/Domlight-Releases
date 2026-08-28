param([string]$Root=(Split-Path -Parent $MyInvocation.MyCommand.Path))
$ErrorActionPreference='Stop'

$required=@(
'AccountState.ps1','AccountStatus.ps1','AutoCheck.ps1','ConfigureAutoCheckTask.ps1','ConnectionSettings.ps1',
'DISABLE_AUTO_CHECK.bat','Domlight.ps1','DomlightLauncher.vbs','DomlightPortal.ps1','ENABLE_AUTO_CHECK.bat',
'Mailing.ps1','MENU_DOMLIGHT.ps1','MeterStatus.ps1','OrganizeDownloadedAccount.ps1','PdfEngine.ps1',
'RunAutoCheckHidden.ps1','SingleWindowLauncher.ps1','UpdateFromGitHub.ps1','PROJECT_STRUCTURE.md','VERSION.txt'
)
$errors=New-Object System.Collections.ArrayList
$warnings=New-Object System.Collections.ArrayList

foreach($name in $required){if(-not(Test-Path -LiteralPath (Join-Path $Root $name))){[void]$errors.Add('Missing required file: '+$name)}}

foreach($f in @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -ErrorAction SilentlyContinue)){
    $bytes=[IO.File]::ReadAllBytes($f.FullName)
    if($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF){[void]$errors.Add('PowerShell file is not UTF-8 BOM: '+$f.Name)}
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$parseErrors)
    foreach($e in @($parseErrors)){[void]$errors.Add("Parser error in $($f.Name) line $($e.Extent.StartLineNumber): $($e.Message)")}
}

$known=@{}
foreach($f in @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue)){$known[$f.Name.ToLowerInvariant()]=$true}
foreach($f in @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -ErrorAction SilentlyContinue)){
    $text=Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    foreach($m in [regex]::Matches($text,'(?i)["''](?<name>[A-Za-z0-9_\-]+\.(?:ps1|bat|vbs))["'']')){
        $n=$m.Groups['name'].Value
        if(-not $known.ContainsKey($n.ToLowerInvariant())){[void]$errors.Add("$($f.Name) references missing file: $n")}
    }
}

$menu=Join-Path $Root 'MENU_DOMLIGHT.ps1'
if(Test-Path -LiteralPath $menu){
    $t=Get-Content -LiteralPath $menu -Raw -Encoding UTF8
    foreach($n in @('Domlight.ps1','ConnectionSettings.ps1','Mailing.ps1','MeterStatus.ps1','AccountStatus.ps1','SingleWindowLauncher.ps1','UpdateFromGitHub.ps1')){
        if($t -notmatch [regex]::Escape($n)){[void]$errors.Add('Menu contract missing: '+$n)}
    }
}

$launcher=Join-Path $Root 'SingleWindowLauncher.ps1'
if(Test-Path -LiteralPath $launcher){
    $t=Get-Content -LiteralPath $launcher -Raw -Encoding UTF8
    if($t -notmatch 'window_errors\.log'){[void]$errors.Add('Launcher has no persistent startup error log.')}
    if($t -notmatch '(?s)catch\s*\{.*MessageBox'){[void]$errors.Add('Launcher still hides child startup errors.')}
}

$mail=Join-Path $Root 'Mailing.ps1'
if(Test-Path -LiteralPath $mail){
    $t=Get-Content -LiteralPath $mail -Raw -Encoding UTF8
    if($t -match '\$grid\.DataSource\s*='){[void]$errors.Add('Mailing must populate DataGridView rows explicitly, not via DataSource.')}
    if($t -notmatch '\$grid\.Rows\.Add'){[void]$errors.Add('Mailing has no explicit grid row population.')}
    if($t -notmatch 'param\(\[switch\]\$SmokeTest\)'){[void]$errors.Add('Mailing has no smoke-test entry point.')}
}

$settings=Join-Path $Root 'ConnectionSettings.ps1'
if(Test-Path -LiteralPath $settings){
    $t=Get-Content -LiteralPath $settings -Raw -Encoding UTF8
    if($t -notmatch 'param\(\[switch\]\$SmokeTest\)'){[void]$errors.Add('ConnectionSettings has no smoke-test entry point.')}
}

$domlight=Join-Path $Root 'Domlight.ps1'
if(Test-Path -LiteralPath $domlight){
    $t=Get-Content -LiteralPath $domlight -Raw -Encoding UTF8
    if($t -notmatch 'param\(\[switch\]\$SmokeTest\)'){[void]$errors.Add('Domlight has no smoke-test entry point.')}
    if($t -match '# PRE-SHOW NETWORK CHECK'){[void]$errors.Add('Domlight still performs the old pre-show portal check.')}
}

$wrapper=Join-Path $Root 'RunAutoCheckHidden.ps1'
if(Test-Path -LiteralPath $wrapper){
    $t=Get-Content -LiteralPath $wrapper -Raw -Encoding UTF8
    if($t -match '\$payload\.status'){[void]$errors.Add('RunAutoCheckHidden still reads obsolete payload.status.')}
    if($t -notmatch '\$payload\.Result'){[void]$errors.Add('RunAutoCheckHidden does not read payload.Result.')}
}

$organizer=Join-Path $Root 'OrganizeDownloadedAccount.ps1'
if(Test-Path -LiteralPath $organizer){if((Get-Content -LiteralPath $organizer -Raw -Encoding UTF8)-notmatch 'PdfEngine\.ps1'){[void]$errors.Add('Organizer no longer declares PdfEngine dependency.')}}

$meter=Join-Path $Root 'MeterStatus.ps1'
if(Test-Path -LiteralPath $meter){$t=Get-Content -LiteralPath $meter -Raw -Encoding UTF8;if($t -match '/meter/value'){[void]$errors.Add('Meter submission must remain disabled.')}}

$versionFile=Join-Path $Root 'VERSION.txt'
if(Test-Path -LiteralPath $versionFile){$v=(Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim();if($v -ne 'Domlight v137 RELEASE'){[void]$errors.Add('Unexpected VERSION.txt value: '+$v)}}

$result=[pscustomobject]@{Ok=($errors.Count-eq0);Errors=@($errors|Sort-Object -Unique);Warnings=@($warnings);RequiredCount=$required.Count}
$result|ConvertTo-Json -Depth 6
if($errors.Count-gt0){exit 1}else{exit 0}
