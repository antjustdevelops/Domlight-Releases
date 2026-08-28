$ErrorActionPreference = 'Stop'

function New-DomlightAccountStateItem {
    param([string]$Account,[string]$Company = '',[string]$Apartment = '',[string]$Address = '',[string]$SeenAt = '')
    if ([string]::IsNullOrWhiteSpace($SeenAt)) { $SeenAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    [pscustomobject]@{Account=$Account;Company=$Company;Apartment=$Apartment;Address=$Address;Status='active';MissingSuccessCount=0;ManuallyDisabled=$false;Excluded=$false;ExcludedAt='';FirstSeenAt=$SeenAt;LastSeenAt=$SeenAt}
}
function Read-DomlightAccountState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

        $parsed = $raw | ConvertFrom-Json
        $source = @($parsed)
        if ($source.Count -eq 1 -and $source[0] -is [System.Array]) {
            $source = @($source[0])
        }

        $normalized = @()
        foreach ($x in $source) {
            if ($null -eq $x) { continue }

            $missing = 0
            try {
                $rawMissing = @($x.MissingSuccessCount)
                if ($rawMissing.Count -gt 0 -and $null -ne $rawMissing[0] -and -not [string]::IsNullOrWhiteSpace([string]$rawMissing[0])) {
                    $missing = [Convert]::ToInt32($rawMissing[0])
                }
            } catch { $missing = 0 }

            $manual = $false
            try {
                $rawManual = @($x.ManuallyDisabled)
                if ($rawManual.Count -gt 0) { $manual = [Convert]::ToBoolean($rawManual[0]) }
            } catch { $manual = $false }

            $excluded = $false
            try {
                if ($x.PSObject.Properties.Name -contains 'Excluded') { $excluded = [Convert]::ToBoolean(@($x.Excluded)[0]) }
            } catch { $excluded = $false }

            $normalized += [pscustomobject]@{
                Account = [string]$x.Account
                Company = [string]$x.Company
                Apartment = [string]$x.Apartment
                Address = $(if ($x.PSObject.Properties.Name -contains 'Address') { [string]$x.Address } else { '' })
                Status = [string]$x.Status
                MissingSuccessCount = $missing
                ManuallyDisabled = $manual
                Excluded = $excluded
                ExcludedAt = $(if ($x.PSObject.Properties.Name -contains 'ExcludedAt') { [string]$x.ExcludedAt } else { '' })
                FirstSeenAt = [string]$x.FirstSeenAt
                LastSeenAt = [string]$x.LastSeenAt
            }
        }
        return @($normalized)
    } catch { throw "accounts_state.json cannot be read: $($_.Exception.Message)" }
}
function Write-DomlightAccountState {
    param([string]$Path,[object[]]$Items)
    $dir=Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp=$Path+'.tmp'
    @($Items) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path
}
function Get-DomlightArchiveAccounts {
    param([string]$ReceiptsDir)
    $items=@()
    if (-not (Test-Path -LiteralPath $ReceiptsDir)) { return @() }
    foreach($folder in @(Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue)) {
        $m=[regex]::Match($folder.Name,'^(?<a>\d{9,20})(?:\s+-\s+(?:кв\.|#U043a#U0432\.)\s*(?<apt>.+))?$','IgnoreCase')
        if(-not $m.Success){continue}
        $address = ''
        $metaPath = Join-Path $folder.FullName '_account_meta.json'
        if (Test-Path -LiteralPath $metaPath) {
            try {
                $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($meta.PSObject.Properties.Name -contains 'Address') { $address = [string]$meta.Address }
            } catch {}
        }
        $items += New-DomlightAccountStateItem -Account $m.Groups['a'].Value -Apartment $m.Groups['apt'].Value -Address $address -SeenAt $folder.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
    return @($items)
}
function Merge-DomlightAccountSnapshot {
    param([object[]]$Previous,[object[]]$PortalAccounts,[int]$MissingThreshold=3,[string]$SeenAt='')
    if($MissingThreshold -lt 1){throw 'MissingThreshold must be at least 1.'}
    if([string]::IsNullOrWhiteSpace($SeenAt)){$SeenAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')}
    $prevMap=@{}; foreach($x in @($Previous)){if($x -and $x.Account){$prevMap[[string]$x.Account]=$x}}
    $seen=@{}; $result=@()
    foreach($p in @($PortalAccounts)){
        if(-not $p -or [string]::IsNullOrWhiteSpace([string]$p.Account)){continue}
        $account=[string]$p.Account; $seen[$account]=$true
        if($prevMap.ContainsKey($account)){
            $x=$prevMap[$account]
            if($p.PSObject.Properties.Name -contains 'Company'){$x.Company=[string]$p.Company}
            if($p.PSObject.Properties.Name -contains 'Apartment' -and -not [string]::IsNullOrWhiteSpace([string]$p.Apartment)){$x.Apartment=[string]$p.Apartment}
            if($p.PSObject.Properties.Name -contains 'Address' -and -not [string]::IsNullOrWhiteSpace([string]$p.Address)){$x.Address=[string]$p.Address}
            $x.LastSeenAt=$SeenAt
            if ([bool]$x.Excluded) { $x.Status='excluded'; $result += $x; continue }
            $x.MissingSuccessCount=0
            $x.ManuallyDisabled=$false; $x.Status='active'
            $result += $x
        } else {
            $company=if($p.PSObject.Properties.Name -contains 'Company'){[string]$p.Company}else{''}
            $apartment=if($p.PSObject.Properties.Name -contains 'Apartment'){[string]$p.Apartment}else{''}
            $address=if($p.PSObject.Properties.Name -contains 'Address'){[string]$p.Address}else{''}
            $result += New-DomlightAccountStateItem -Account $account -Company $company -Apartment $apartment -Address $address -SeenAt $SeenAt
        }
    }
    foreach($x in @($Previous)){
        if(-not $x -or [string]::IsNullOrWhiteSpace([string]$x.Account)){continue}
        $account=[string]$x.Account; if($seen.ContainsKey($account)){continue}
        if([bool]$x.Excluded){$x.Status='excluded';$result+=$x;continue}
        $miss=0; try{$miss=[int]$x.MissingSuccessCount}catch{$miss=0}; $miss++
        $x.MissingSuccessCount=$miss
        if($miss -ge $MissingThreshold){$x.Status='inactive'}else{$x.Status='missing'}
        $result += $x
    }
    return @($result | Sort-Object Account -Unique)
}
function Set-DomlightAccountManualTracking {
    param([object[]]$Items,[string]$Account,[bool]$Enabled)
    $found=$false
    foreach($x in @($Items)){
        if([string]$x.Account -ne $Account){continue};$found=$true
        if($Enabled){$x.ManuallyDisabled=$false;$x.MissingSuccessCount=0;$x.Status='active'}else{$x.ManuallyDisabled=$true;$x.Status='inactive'}
    }
    if(-not $found){throw "Account not found: $Account"}
    return @($Items)
}

function Set-DomlightAccountExcluded {
    param([object[]]$Items,[string]$Account,[bool]$Excluded)
    $found=$false
    foreach($x in @($Items)){
        if([string]$x.Account -ne $Account){continue};$found=$true
        if($Excluded){
            $x.Excluded=$true; $x.ExcludedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); $x.Status='excluded'; $x.MissingSuccessCount=0; $x.ManuallyDisabled=$false
        } else {
            $x.Excluded=$false; $x.ExcludedAt=''; $x.Status='active'; $x.MissingSuccessCount=0; $x.ManuallyDisabled=$false
        }
    }
    if(-not $found){throw "Account not found: $Account"}
    return @($Items)
}

function Get-DomlightAccountStateSummary {
    param([object[]]$Items)
    $visible=@($Items|Where-Object{-not [bool]$_.Excluded}); [pscustomobject]@{Total=$visible.Count;Active=@($visible|Where-Object{$_.Status -eq 'active'}).Count;Missing=@($visible|Where-Object{$_.Status -eq 'missing'}).Count;Inactive=@($visible|Where-Object{$_.Status -eq 'inactive'}).Count;Excluded=@($Items|Where-Object{[bool]$_.Excluded}).Count}
}
