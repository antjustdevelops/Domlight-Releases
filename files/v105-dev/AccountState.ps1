$ErrorActionPreference = 'Stop'

function New-DomlightAccountStateItem {
    param(
        [Parameter(Mandatory=$true)][string]$Account,
        [string]$Company = '',
        [string]$Apartment = '',
        [string]$SeenAt = ''
    )
    if ([string]::IsNullOrWhiteSpace($SeenAt)) { $SeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    [pscustomobject]@{
        Account = $Account
        Company = $Company
        Apartment = $Apartment
        Status = 'active'
        MissingSuccessCount = 0
        ManuallyDisabled = $false
        FirstSeenAt = $SeenAt
        LastSeenAt = $SeenAt
    }
}

function Read-DomlightAccountState {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json)
    } catch {
        throw "accounts_state.json cannot be read: $($_.Exception.Message)"
    }
}

function Write-DomlightAccountState {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][object[]]$Items
    )
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = $Path + '.tmp'
    @($Items) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Merge-DomlightAccountSnapshot {
    param(
        [Parameter(Mandatory=$true)][object[]]$Previous,
        [Parameter(Mandatory=$true)][object[]]$PortalAccounts,
        [int]$MissingThreshold = 3,
        [string]$SeenAt = ''
    )
    if ($MissingThreshold -lt 1) { throw 'MissingThreshold must be at least 1.' }
    if ([string]::IsNullOrWhiteSpace($SeenAt)) { $SeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

    $result = @()
    $prevMap = @{}
    foreach ($x in @($Previous)) {
        if ($null -eq $x -or [string]::IsNullOrWhiteSpace([string]$x.Account)) { continue }
        $prevMap[[string]$x.Account] = $x
    }

    $seenMap = @{}
    foreach ($p in @($PortalAccounts)) {
        if ($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Account)) { continue }
        $account = [string]$p.Account
        $seenMap[$account] = $true

        if ($prevMap.ContainsKey($account)) {
            $x = $prevMap[$account]
            if ($p.PSObject.Properties.Name -contains 'Company' -and -not [string]::IsNullOrWhiteSpace([string]$p.Company)) { $x.Company = [string]$p.Company }
            if ($p.PSObject.Properties.Name -contains 'Apartment' -and -not [string]::IsNullOrWhiteSpace([string]$p.Apartment)) { $x.Apartment = [string]$p.Apartment }
            $x.LastSeenAt = $SeenAt
            $x.MissingSuccessCount = 0
            if (-not [bool]$x.ManuallyDisabled) { $x.Status = 'active' }
            $result += $x
        } else {
            $company = if ($p.PSObject.Properties.Name -contains 'Company') { [string]$p.Company } else { '' }
            $apartment = if ($p.PSObject.Properties.Name -contains 'Apartment') { [string]$p.Apartment } else { '' }
            $result += New-DomlightAccountStateItem -Account $account -Company $company -Apartment $apartment -SeenAt $SeenAt
        }
    }

    foreach ($x in @($Previous)) {
        if ($null -eq $x -or [string]::IsNullOrWhiteSpace([string]$x.Account)) { continue }
        $account = [string]$x.Account
        if ($seenMap.ContainsKey($account)) { continue }

        if ([bool]$x.ManuallyDisabled) {
            $x.Status = 'inactive'
            $result += $x
            continue
        }

        $miss = 0
        try { $miss = [int]$x.MissingSuccessCount } catch { $miss = 0 }
        $miss++
        $x.MissingSuccessCount = $miss
        if ($miss -ge $MissingThreshold) { $x.Status = 'inactive' } else { $x.Status = 'missing' }
        $result += $x
    }

    return @($result | Sort-Object Account)
}

function Set-DomlightAccountManualTracking {
    param(
        [Parameter(Mandatory=$true)][object[]]$Items,
        [Parameter(Mandatory=$true)][string]$Account,
        [Parameter(Mandatory=$true)][bool]$Enabled
    )
    $found = $false
    foreach ($x in @($Items)) {
        if ([string]$x.Account -ne $Account) { continue }
        $found = $true
        if ($Enabled) {
            $x.ManuallyDisabled = $false
            $x.MissingSuccessCount = 0
            $x.Status = 'active'
        } else {
            $x.ManuallyDisabled = $true
            $x.Status = 'inactive'
        }
    }
    if (-not $found) { throw "Account not found: $Account" }
    return @($Items)
}

function Get-DomlightAccountStateSummary {
    param([Parameter(Mandatory=$true)][object[]]$Items)
    [pscustomobject]@{
        Total = @($Items).Count
        Active = @($Items | Where-Object { $_.Status -eq 'active' -and -not [bool]$_.ManuallyDisabled }).Count
        Missing = @($Items | Where-Object { $_.Status -eq 'missing' }).Count
        Inactive = @($Items | Where-Object { $_.Status -eq 'inactive' -or [bool]$_.ManuallyDisabled }).Count
    }
}
