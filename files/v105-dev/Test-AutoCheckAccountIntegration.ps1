. "$PSScriptRoot\AccountState.ps1"
$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual,$Expected,[string]$Message){ if($Actual -ne $Expected){ throw "$Message Expected=[$Expected] Actual=[$Actual]" } }
function Snapshot([string[]]$Accounts){ @($Accounts | ForEach-Object { [pscustomobject]@{Account=$_;Company='TEST';Apartment=''} }) }
function Process-Snapshot([object[]]$Previous,[string[]]$Portal,[int]$Threshold=3){
    $state=@(Merge-DomlightAccountSnapshot -Previous $Previous -PortalAccounts (Snapshot $Portal) -MissingThreshold $Threshold)
    $map=@{}; foreach($x in $state){$map[[string]$x.Account]=$x}
    $toCheck=@()
    foreach($p in (Snapshot $Portal)){
        $x=$map[[string]$p.Account]
        if($x -and -not [bool]$x.ManuallyDisabled){$toCheck += [string]$p.Account}
    }
    [pscustomobject]@{State=$state;ToCheck=$toCheck;Summary=(Get-DomlightAccountStateSummary $state)}
}

$all=1..8|ForEach-Object{"20000000$_"}
$gone=$all[7]
$seven=@($all|Where-Object{$_ -ne $gone})

$r=Process-Snapshot -Previous @() -Portal $all
Assert-Equal $r.ToCheck.Count 8 'All 8 portal accounts must be checked.'
Assert-Equal $r.Summary.Active 8 'All 8 must be active.'

$r=Process-Snapshot -Previous $r.State -Portal $seven
Assert-Equal $r.ToCheck.Count 7 'Only 7 present portal accounts can be checked.'
Assert-Equal $r.Summary.Missing 1 'Missing account is retained after first miss.'
Assert-Equal $r.Summary.Total 8 'Known total remains 8.'

$r=Process-Snapshot -Previous $r.State -Portal $seven
Assert-Equal $r.Summary.Missing 1 'Missing account remains missing after second miss.'
$r=Process-Snapshot -Previous $r.State -Portal $seven
Assert-Equal $r.Summary.Inactive 1 'Missing account becomes inactive after third miss.'
Assert-Equal $r.Summary.Total 8 'Inactive account is not deleted.'

$r=Process-Snapshot -Previous $r.State -Portal $all
Assert-Equal $r.ToCheck.Count 8 'Returned account is checked again.'
Assert-Equal $r.Summary.Active 8 'Returned account automatically reactivates.'

$manual=$all[0]
$state=Set-DomlightAccountManualTracking -Items $r.State -Account $manual -Enabled $false
$r=Process-Snapshot -Previous $state -Portal $all
Assert-Equal $r.ToCheck.Count 7 'Manually disabled account must be skipped.'
Assert-Equal $r.Summary.Inactive 1 'Manual disable is represented as inactive.'

Write-Host 'PASS: portal account list controls only current check set'
Write-Host 'PASS: missing account remains in local history/state'
Write-Host 'PASS: 3 successful misses -> inactive'
Write-Host 'PASS: returned account -> active and checked'
Write-Host 'PASS: manual disable -> skip without deletion'
