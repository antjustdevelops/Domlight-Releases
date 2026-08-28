$ErrorActionPreference='Stop'

$src='files/v138'
$dst='files/v139'

if(Test-Path $dst){Remove-Item $dst -Recurse -Force}
Copy-Item $src $dst -Recurse -Force

$meterPath=Join-Path $dst 'MeterStatus.ps1'
$text=Get-Content -LiteralPath $meterPath -Raw

$anchor=@'
    foreach($meter in $meters){
'@
$insert=@'
    $meterGrid.Add_CurrentCellDirtyStateChanged({
        if($meterGrid.IsCurrentCellDirty -and $null -ne $meterGrid.CurrentCell -and $meterGrid.CurrentCell.OwningColumn.Name -eq 'Selected'){
            [void]$meterGrid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    foreach($meter in $meters){
'@
if(-not $text.Contains($anchor)){throw 'Meter grid row anchor not found'}
$text=$text.Replace($anchor,$insert)

$oldSave=@'
    $btnSave.Add_Click({
        $meterGrid.EndEdit()
        foreach($row in $meterGrid.Rows){$meterId=[string]$row.Tag;if([string]::IsNullOrWhiteSpace($meterId)){continue};$key=$Account+'|'+$meterId;$script:Drafts[$key]=[pscustomobject]@{Selected=[bool]$row.Cells['Selected'].Value;Value=[string]$row.Cells['NewValue'].Value}}
        Export-MeterDraftStore -Drafts $script:Drafts -Path $DraftsFile
        Build-ObjectRows;$dialog.Close()
    })
'@
$newSave=@'
    $btnSave.Add_Click({
        if($null -ne $meterGrid.CurrentCell -and $meterGrid.IsCurrentCellDirty){
            [void]$meterGrid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
        [void]$meterGrid.EndEdit()
        foreach($row in $meterGrid.Rows){
            $meterId=[string]$row.Tag
            if([string]::IsNullOrWhiteSpace($meterId)){continue}
            $key=$Account+'|'+$meterId
            $selected=$false
            if($null -ne $row.Cells['Selected'].Value){$selected=[bool]$row.Cells['Selected'].Value}
            $value=[string]$row.Cells['NewValue'].Value
            $script:Drafts[$key]=[pscustomobject]@{Selected=$selected;Value=$value}
        }
        Export-MeterDraftStore -Drafts $script:Drafts -Path $DraftsFile
        Build-ObjectRows;$dialog.Close()
    })
'@
if(-not $text.Contains($oldSave)){throw 'Meter save handler contract not found'}
$text=$text.Replace($oldSave,$newSave)

[IO.File]::WriteAllText((Resolve-Path $meterPath),$text,(New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path (Resolve-Path $dst).Path 'VERSION.txt'),'Domlight v139 RELEASE'+[Environment]::NewLine,(New-Object Text.UTF8Encoding($true)))

foreach($ps1 in @(Get-ChildItem -LiteralPath $dst -Filter *.ps1 -File)){
    $tokens=$null
    $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($ps1.FullName,[ref]$tokens,[ref]$parseErrors)
    if(@($parseErrors).Count -gt 0){throw ('Parser error in '+$ps1.Name+': '+$parseErrors[0].Message)}
}

$meterText=Get-Content -LiteralPath $meterPath -Raw
foreach($contract in @('Add_CurrentCellDirtyStateChanged','CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)','meter_drafts.json','Export-MeterDraftStore')){
    if($meterText -notmatch [regex]::Escape($contract)){throw ('Missing checkbox persistence contract: '+$contract)}
}
if($meterText -match '/meter/value'){throw 'Meter submission must remain disabled'}

# Storage regression: checked draft must survive a full save/reload cycle.
. (Join-Path $dst 'MeterDraftStore.ps1')
$testRoot=Join-Path $env:RUNNER_TEMP 'domlight-v139-checkbox-test'
if(Test-Path $testRoot){Remove-Item $testRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $testRoot|Out-Null
$testFile=Join-Path $testRoot 'meter_drafts.json'
$drafts=@{}
$drafts['ACC001|M001']=[pscustomobject]@{Selected=$true;Value='123.45'}
Export-MeterDraftStore -Drafts $drafts -Path $testFile
$loaded=Import-MeterDraftStore -Path $testFile
if(-not $loaded.ContainsKey('ACC001|M001')){throw 'Checked draft reload failed: key missing'}
if(-not [bool]$loaded['ACC001|M001'].Selected){throw 'Checked draft reload failed: checkbox state lost'}
if([string]$loaded['ACC001|M001'].Value -ne '123.45'){throw 'Checked draft reload failed: value mismatch'}

# Build manifest from staged Git blobs so hashes exactly match published content.
git add files/v139
$files=@()
foreach($line in @(git ls-files -s files/v139)){
    $parts=$line -split '\s+',4
    if($parts.Count -lt 4){continue}
    $repoPath=$parts[3]
    $name=$repoPath.Substring('files/v139/'.Length)
    $files += [ordered]@{
        path=$name
        url="https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/v139/$name"
        gitBlobSha=$parts[1]
    }
}
$manifest=[ordered]@{
    version='v139 RELEASE'
    published='2026-08-29'
    notes='Meter draft checkbox persistence fixed: the Передать checkbox is committed immediately when clicked and again before saving; checked drafts survive closing/reopening the meter card, the meters window and Domlight. Existing persistent draft storage is preserved; meter submission remains disabled; all v138 behavior otherwise preserved.'
    files=@($files | Sort-Object path)
}
$manifestJson=$manifest|ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path (Get-Location) 'latest.json'),$manifestJson,(New-Object Text.UTF8Encoding($false)))
git add latest.json
