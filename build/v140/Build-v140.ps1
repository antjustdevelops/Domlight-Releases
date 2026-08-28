$ErrorActionPreference = 'Stop'

$src = 'files/v138'
$dst = 'files/v140'

if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
Copy-Item -LiteralPath 'build/v140/MeterGridBehavior.ps1' -Destination (Join-Path $dst 'MeterGridBehavior.ps1') -Force

$meterPath = Join-Path $dst 'MeterStatus.ps1'
$text = Get-Content -LiteralPath $meterPath -Raw

$moduleAnchor = @'
. $DraftStoreModule

$script:AllMeters = @()
'@
$moduleReplacement = @'
. $DraftStoreModule
$GridBehaviorModule = Join-Path $Root 'MeterGridBehavior.ps1'
if (-not (Test-Path -LiteralPath $GridBehaviorModule)) { throw 'Meter grid behavior module is missing.' }
. $GridBehaviorModule

$script:AllMeters = @()
'@
if (-not $text.Contains($moduleAnchor)) { throw 'v138 module anchor not found' }
$text = $text.Replace($moduleAnchor, $moduleReplacement)

$oldSave = @'
    $btnSave.Add_Click({
        $meterGrid.EndEdit()
        foreach($row in $meterGrid.Rows){$meterId=[string]$row.Tag;if([string]::IsNullOrWhiteSpace($meterId)){continue};$key=$Account+'|'+$meterId;$script:Drafts[$key]=[pscustomobject]@{Selected=[bool]$row.Cells['Selected'].Value;Value=[string]$row.Cells['NewValue'].Value}}
        Export-MeterDraftStore -Drafts $script:Drafts -Path $DraftsFile
        Build-ObjectRows;$dialog.Close()
    })
'@
$newSave = @'
    $btnSave.Add_Click({
        Save-MeterDraftsFromGrid -Grid $meterGrid -Account $Account -Drafts $script:Drafts -Path $DraftsFile
        Build-ObjectRows
        $dialog.Close()
    })
'@
if (-not $text.Contains($oldSave)) { throw 'v138 save handler contract not found' }
$text = $text.Replace($oldSave, $newSave)

[IO.File]::WriteAllText((Resolve-Path -LiteralPath $meterPath), $text, (New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path (Resolve-Path -LiteralPath $dst).Path 'VERSION.txt'), 'Domlight v140 RELEASE' + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))

# Structural guards for the exact regression seen in v139.
$meterText = Get-Content -LiteralPath $meterPath -Raw
$buildStart = $meterText.IndexOf('function Build-ObjectRows')
$buildEnd = $meterText.IndexOf('$form=New-Object Windows.Forms.Form', $buildStart)
if ($buildStart -lt 0 -or $buildEnd -le $buildStart) { throw 'Cannot isolate Build-ObjectRows' }
$buildObjectRowsText = $meterText.Substring($buildStart, $buildEnd - $buildStart)
if ($buildObjectRowsText.Contains('$meterGrid')) { throw 'Regression: Build-ObjectRows must not reference meterGrid' }
if ($meterText.Contains('Add_CurrentCellDirtyStateChanged')) { throw 'Regression: inline checkbox event handler is forbidden in MeterStatus' }
$dialogStart = $meterText.IndexOf('function Show-ObjectDialog')
$saveCall = $meterText.IndexOf('Save-MeterDraftsFromGrid', $dialogStart)
if ($dialogStart -lt 0 -or $saveCall -le $dialogStart) { throw 'Canonical save call is not inside Show-ObjectDialog' }
if ($meterText -match '/meter/value') { throw 'Meter submission must remain disabled' }

foreach ($ps1 in @(Get-ChildItem -LiteralPath $dst -Filter *.ps1 -File)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ('Parser error in ' + $ps1.Name + ': ' + $errors[0].Message) }
}

# Offline grid save test. This exercises the same DataGridView cells and persisted store used by the UI.
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $dst 'MeterDraftStore.ps1')
. (Join-Path $dst 'MeterGridBehavior.ps1')
$testRoot = Join-Path $env:RUNNER_TEMP 'domlight-v140-grid-test'
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$testFile = Join-Path $testRoot 'meter_drafts.json'
$grid = New-Object System.Windows.Forms.DataGridView
$grid.AllowUserToAddRows = $false
$selectedColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$selectedColumn.Name = 'Selected'
[void]$grid.Columns.Add($selectedColumn)
$valueColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$valueColumn.Name = 'NewValue'
[void]$grid.Columns.Add($valueColumn)
$rowIndex = $grid.Rows.Add()
$row = $grid.Rows[$rowIndex]
$row.Tag = 'M001'
$row.Cells['Selected'].Value = $true
$row.Cells['NewValue'].Value = '123.45'
$grid.CurrentCell = $row.Cells['Selected']
$grid.NotifyCurrentCellDirty($true)
$drafts = @{}
Save-MeterDraftsFromGrid -Grid $grid -Account 'ACC001' -Drafts $drafts -Path $testFile
$loaded = Import-MeterDraftStore -Path $testFile
if (-not $loaded.ContainsKey('ACC001|M001')) { throw 'Grid persistence test: key missing' }
if (-not [bool]$loaded['ACC001|M001'].Selected) { throw 'Grid persistence test: checkbox lost' }
if ([string]$loaded['ACC001|M001'].Value -ne '123.45') { throw 'Grid persistence test: value lost' }

# Stage first, then use actual staged Git blobs in manifest.
git add files/v140
$files = @()
foreach ($line in @(git ls-files -s files/v140)) {
    $parts = $line -split '\s+', 4
    if ($parts.Count -lt 4) { continue }
    $repoPath = $parts[3]
    $name = $repoPath.Substring('files/v140/'.Length)
    $files += [ordered]@{
        path = $name
        url = "https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/v140/$name"
        gitBlobSha = $parts[1]
    }
}
$manifest = [ordered]@{
    version = 'v140 RELEASE'
    published = '2026-08-29'
    notes = 'Meter UI rebuilt from the last working v138 baseline. Checkbox persistence is handled by a dedicated MeterGridBehavior module at save time; Build-ObjectRows cannot reference the card grid; persistent drafts are preserved; meter submission remains disabled.'
    files = @($files | Sort-Object path)
}
$manifestPath = Join-Path (Get-Location) 'latest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
git add latest.json
