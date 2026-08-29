$ErrorActionPreference = 'Stop'

function Get-MeterDraftPeriod {
    return (Get-Date).ToString('yyyy-MM')
}

function Import-MeterDraftStore {
    param([Parameter(Mandatory=$true)][string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    try {
        $payload = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $period = [string]$payload.period
        if ($period -ne (Get-MeterDraftPeriod)) { return $result }
        foreach ($item in @($payload.drafts)) {
            $account = ([string]$item.account).Trim(); $meterId = ([string]$item.meterId).Trim()
            if ([string]::IsNullOrWhiteSpace($account) -or [string]::IsNullOrWhiteSpace($meterId)) { continue }
            $selected = [bool]$item.selected; $value = [string]$item.value
            if (-not $selected -and [string]::IsNullOrWhiteSpace($value)) { continue }
            $key = $account + '|' + $meterId
            $result[$key] = [pscustomobject]@{ Selected = $selected; Value = $value }
        }
    } catch { return @{} }
    return $result
}

function Export-MeterDraftStore {
    param([Parameter(Mandatory=$true)][hashtable]$Drafts,[Parameter(Mandatory=$true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $items = @()
    foreach ($key in @($Drafts.Keys | Sort-Object)) {
        $draft = $Drafts[$key]; if ($null -eq $draft) { continue }
        $parts = [string]$key -split '\|', 2; if ($parts.Count -ne 2) { continue }
        $account = $parts[0]; $meterId = $parts[1]; $selected = [bool]$draft.Selected; $value = [string]$draft.Value
        if (-not $selected -and [string]::IsNullOrWhiteSpace($value)) { continue }
        $items += [pscustomobject]@{ account=$account; meterId=$meterId; selected=$selected; value=$value }
    }
    $payload = [ordered]@{ schemaVersion=1; period=(Get-MeterDraftPeriod); savedAt=(Get-Date).ToString('o'); drafts=@($items) }
    $json = $payload | ConvertTo-Json -Depth 6
    $tempPath = $Path + '.tmp'; Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8; Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Remove-StaleMeterDrafts {
    param([Parameter(Mandatory=$true)][hashtable]$Drafts,[Parameter(Mandatory=$true)][array]$Meters)
    $valid = @{}
    foreach ($meter in @($Meters)) {
        $account=[string]$meter.Account; $meterId=[string]$meter.MeterId
        if ([string]::IsNullOrWhiteSpace($account) -or [string]::IsNullOrWhiteSpace($meterId)) { continue }
        $key=$account+'|'+$meterId; $valid[$key]=([string]$meter.MonthStatus -ne 'Передано')
    }
    $changed=$false
    foreach ($key in @($Drafts.Keys)) {
        if (-not $valid.ContainsKey([string]$key) -or -not [bool]$valid[[string]$key]) { [void]$Drafts.Remove([string]$key); $changed=$true }
    }
    return $changed
}
