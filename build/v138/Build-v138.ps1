$ErrorActionPreference='Stop'
$src='files/v137'
$dst='files/v138'

if(Test-Path $dst){Remove-Item $dst -Recurse -Force}
Copy-Item $src $dst -Recurse -Force
Copy-Item 'build/v138/MeterDraftStore.ps1' (Join-Path $dst 'MeterDraftStore.ps1') -Force

$meterPath=Join-Path $dst 'MeterStatus.ps1'
$text=Get-Content -LiteralPath $meterPath -Raw

$old=@'
$AccountsStateFile = Join-Path $DataDir 'accounts_state.json'

$script:AllMeters = @()
$script:ObjectRows = @()
$script:CurrentFilter = 'all'
$script:Drafts = @{}
'@
$new=@'
$AccountsStateFile = Join-Path $DataDir 'accounts_state.json'
$DraftsFile = Join-Path $DataDir 'meter_drafts.json'
$DraftStoreModule = Join-Path $Root 'MeterDraftStore.ps1'
if (-not (Test-Path -LiteralPath $DraftStoreModule)) { throw 'Не найден модуль хранения черновиков счётчиков.' }
. $DraftStoreModule

$script:AllMeters = @()
$script:ObjectRows = @()
$script:CurrentFilter = 'all'
$script:Drafts = Import-MeterDraftStore -Path $DraftsFile
'@
if(-not $text.Contains($old)){throw 'MeterStatus header contract not found'}
$text=$text.Replace($old,$new)

$oldSave=@'
        foreach($row in $meterGrid.Rows){$meterId=[string]$row.Tag;if([string]::IsNullOrWhiteSpace($meterId)){continue};$key=$Account+'|'+$meterId;$script:Drafts[$key]=[pscustomobject]@{Selected=[bool]$row.Cells['Selected'].Value;Value=[string]$row.Cells['NewValue'].Value}}
        Build-ObjectRows;$dialog.Close()
'@
$newSave=@'
        foreach($row in $meterGrid.Rows){$meterId=[string]$row.Tag;if([string]::IsNullOrWhiteSpace($meterId)){continue};$key=$Account+'|'+$meterId;$script:Drafts[$key]=[pscustomobject]@{Selected=[bool]$row.Cells['Selected'].Value;Value=[string]$row.Cells['NewValue'].Value}}
        Export-MeterDraftStore -Drafts $script:Drafts -Path $DraftsFile
        Build-ObjectRows;$dialog.Close()
'@
if(-not $text.Contains($oldSave)){throw 'MeterStatus save contract not found'}
$text=$text.Replace($oldSave,$newSave)

$oldLoaded='$script:AllMeters=@($meters);Build-ObjectRows;Set-MainCompactHeight;Refresh-Grid'
$newLoaded='$script:AllMeters=@($meters);[void](Remove-StaleMeterDrafts -Drafts $script:Drafts -Meters $script:AllMeters);Export-MeterDraftStore -Drafts $script:Drafts -Path $DraftsFile;Build-ObjectRows;Set-MainCompactHeight;Refresh-Grid'
if(-not $text.Contains($oldLoaded)){throw 'MeterStatus load contract not found'}
$text=$text.Replace($oldLoaded,$newLoaded)

[IO.File]::WriteAllText((Resolve-Path $meterPath),$text,(New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path (Resolve-Path $dst).Path 'VERSION.txt'),'Domlight v138 RELEASE'+[Environment]::NewLine,(New-Object Text.UTF8Encoding($true)))

foreach($ps1 in @(Get-ChildItem -LiteralPath $dst -Filter *.ps1 -File)){
    $tokens=$null
    $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($ps1.FullName,[ref]$tokens,[ref]$parseErrors)
    if(@($parseErrors).Count -gt 0){throw ('Parser error in '+$ps1.Name+': '+$parseErrors[0].Message)}
}

$meterText=Get-Content -LiteralPath $meterPath -Raw
foreach($contract in @('meter_drafts.json','MeterDraftStore.ps1','Import-MeterDraftStore','Export-MeterDraftStore','Remove-StaleMeterDrafts')){
    if($meterText -notmatch [regex]::Escape($contract)){throw ('Missing meter draft contract: '+$contract)}
}
if($meterText -match '/meter/value'){throw 'Meter submission must remain disabled'}

# Offline persistence smoke test: save -> import -> value survives -> transmitted meter clears.
$testRoot=Join-Path $env:RUNNER_TEMP 'domlight-v138-draft-test'
if(Test-Path $testRoot){Remove-Item $testRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $testRoot|Out-Null
. (Join-Path $dst 'MeterDraftStore.ps1')
$testFile=Join-Path $testRoot 'meter_drafts.json'
$drafts=@{}
$drafts['ACC001|M001']=[pscustomobject]@{Selected=$true;Value='123.45'}
Export-MeterDraftStore -Drafts $drafts -Path $testFile
$loaded=Import-MeterDraftStore -Path $testFile
if(-not $loaded.ContainsKey('ACC001|M001')){throw 'Draft persistence smoke test: key missing'}
if(-not [bool]$loaded['ACC001|M001'].Selected){throw 'Draft persistence smoke test: Selected lost'}
if([string]$loaded['ACC001|M001'].Value -ne '123.45'){throw 'Draft persistence smoke test: Value lost'}
$meters=@([pscustomobject]@{Account='ACC001';MeterId='M001';MonthStatus='Передано'})
[void](Remove-StaleMeterDrafts -Drafts $loaded -Meters $meters)
if($loaded.ContainsKey('ACC001|M001')){throw 'Draft cleanup smoke test failed'}

git add files/v138
$files=@()
$indexLines=@(git ls-files -s files/v138)
foreach($line in $indexLines){
    $parts=$line -split '\s+',4
    if($parts.Count -lt 4){continue}
    $repoPath=$parts[3]
    $name=$repoPath.Substring('files/v138/'.Length)
    $files += [ordered]@{
        path=$name
        url="https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/v138/$name"
        gitBlobSha=$parts[1]
    }
}
$manifest=[ordered]@{
    version='v138 RELEASE'
    published='2026-08-29'
    notes='Persistent meter drafts: saved meter readings are stored in data/meter_drafts.json for the current month and survive closing/reopening the meters window and Domlight; stale or already transmitted meter drafts are removed; portal submission remains disabled; all v137 runtime behavior otherwise preserved.'
    files=@($files | Sort-Object path)
}
$manifestPath=Join-Path (Get-Location) 'latest.json'
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
$manifestBytes=[IO.File]::ReadAllBytes($manifestPath)
if($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF){throw 'latest.json must be UTF-8 without BOM'}
git add latest.json
