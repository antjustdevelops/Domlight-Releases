. "$PSScriptRoot\AccountState.ps1"
$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}
function Get-One($Items, [string]$Account) {
    return @($Items | Where-Object { [string]$_.Account -eq $Account })[0]
}
function Snapshot([string[]]$Accounts) {
    return @($Accounts | ForEach-Object { [pscustomobject]@{ Account=$_; Company='TEST'; Apartment=$_ } })
}

$all = 1..8 | ForEach-Object { "10000000$_" }
$missing = $all[7]

# 1. First successful snapshot: eight active accounts.
$state = Merge-DomlightAccountSnapshot -Previous @() -PortalAccounts (Snapshot $all) -MissingThreshold 3 -SeenAt '2026-08-25 10:00:00'
$s = Get-DomlightAccountStateSummary $state
Assert-Equal $s.Total 8 'Initial total.'
Assert-Equal $s.Active 8 'Initial active.'

# 2. One account disappears for one successful portal check.
$seven = @($all | Where-Object { $_ -ne $missing })
$state = Merge-DomlightAccountSnapshot -Previous $state -PortalAccounts (Snapshot $seven) -MissingThreshold 3 -SeenAt '2026-08-25 11:00:00'
$x = Get-One $state $missing
Assert-Equal $x.Status 'missing' 'After first miss status.'
Assert-Equal ([int]$x.MissingSuccessCount) 1 'After first miss counter.'

# 3. Second consecutive successful check without it: still missing.
$state = Merge-DomlightAccountSnapshot -Previous $state -PortalAccounts (Snapshot $seven) -MissingThreshold 3 -SeenAt '2026-08-25 12:00:00'
$x = Get-One $state $missing
Assert-Equal $x.Status 'missing' 'After second miss status.'
Assert-Equal ([int]$x.MissingSuccessCount) 2 'After second miss counter.'

# 4. Third consecutive successful check without it: inactive, but record remains.
$state = Merge-DomlightAccountSnapshot -Previous $state -PortalAccounts (Snapshot $seven) -MissingThreshold 3 -SeenAt '2026-08-25 13:00:00'
$x = Get-One $state $missing
Assert-Equal $x.Status 'inactive' 'After third miss status.'
Assert-Equal ([int]$x.MissingSuccessCount) 3 'After third miss counter.'
Assert-Equal @($state).Count 8 'Inactive account must not be deleted.'

# 5. Account returns on portal: automatic reactivation.
$state = Merge-DomlightAccountSnapshot -Previous $state -PortalAccounts (Snapshot $all) -MissingThreshold 3 -SeenAt '2026-08-25 14:00:00'
$x = Get-One $state $missing
Assert-Equal $x.Status 'active' 'Returned account status.'
Assert-Equal ([int]$x.MissingSuccessCount) 0 'Returned account counter.'

# 6. Manual disable must survive portal presence.
$manual = $all[0]
$state = Set-DomlightAccountManualTracking -Items $state -Account $manual -Enabled $false
$state = Merge-DomlightAccountSnapshot -Previous $state -PortalAccounts (Snapshot $all) -MissingThreshold 3 -SeenAt '2026-08-25 15:00:00'
$x = Get-One $state $manual
Assert-Equal ([bool]$x.ManuallyDisabled) $true 'Manual disabled flag.'
Assert-Equal $x.Status 'inactive' 'Manual disabled status.'

# 7. Manual resume.
$state = Set-DomlightAccountManualTracking -Items $state -Account $manual -Enabled $true
$x = Get-One $state $manual
Assert-Equal ([bool]$x.ManuallyDisabled) $false 'Manual resume flag.'
Assert-Equal $x.Status 'active' 'Manual resume status.'

# 8. Persistence round trip in an isolated temp directory.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('DomlightAccountStateTest_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    $path = Join-Path $temp 'accounts_state.json'
    Write-DomlightAccountState -Path $path -Items $state
    $loaded = Read-DomlightAccountState -Path $path
    Assert-Equal @($loaded).Count 8 'Persistence total.'
    Assert-Equal (Get-One $loaded $missing).Status 'active' 'Persistence returned status.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: 8 -> 7 -> 7 -> 7 -> 8 account lifecycle'
Write-Host 'PASS: inactive account record preserved'
Write-Host 'PASS: manual disable/resume'
Write-Host 'PASS: JSON persistence round trip'
