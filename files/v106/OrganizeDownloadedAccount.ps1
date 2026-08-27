param(
    [Parameter(Mandatory=$true)][string]$ReceiptsDir,
    [Parameter(Mandatory=$true)][string]$Account
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "PdfEngine.ps1")

function Safe-Part([string]$Text) {
    $v = ([string]$Text).Trim()
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
        $v = $v.Replace([string]$c, '_')
    }
    return $v
}

function Normalize-ReceiptText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ Normal=''; Compact='' }
    }
    $normal = ($Text -replace '[\u0000-\u001F]+',' ' -replace '\s+',' ').Trim().ToLowerInvariant()
    $compact = ($normal -replace '[^0-9a-zа-яё]+','')
    return [pscustomobject]@{ Normal=$normal; Compact=$compact }
}


function Get-FullAddress([string]$Text, [string]$Apartment = '') {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $flat = ($Text -replace '[\u0000-\u001F]+',' ' -replace '\s+',' ').Trim()
    $patterns = @(
        '(?i)\bадрес(?:\s+(?:помещения|объекта|квартиры|апартамента))?\s*[:\-]\s*(?<addr>.*?)(?=\s+(?:апарт(?:амент)?|кв(?:артира)?)\.?\s*[№#]?\s*[0-9]|\s+(?:лицевой\s+сч[её]т|л\/?с|плательщик|период|общая\s+площадь|итого)\b)',
        '(?i)\bадрес(?:\s+(?:помещения|объекта|квартиры|апартамента))?\s*[:\-]\s*(?<addr>[^;]{8,160})'
    )
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($flat, $pattern)
        if ($m.Success) {
            $addr = ($m.Groups['addr'].Value -replace '\s+',' ').Trim(' ', ',', ';', '.')
            if ($addr.Length -lt 6) { continue }
            if (-not [string]::IsNullOrWhiteSpace($Apartment) -and $addr -notmatch ('(?i)(?:кв(?:артира)?|апарт(?:амент)?)\.?\s*[№#]?\s*' + [regex]::Escape($Apartment))) {
                $addr = $addr + ', кв. ' + $Apartment
            }
            return $addr
        }
    }
    return ''
}

function Get-Apartment([string]$Text) {
    $n = Normalize-ReceiptText $Text
    $normal = $n.Normal
    $compact = $n.Compact

    foreach ($pattern in @(
        '(?i)\bадрес\s*:\s*.*?\bапарт\.?\s*([0-9]+[0-9a-zа-яё-]*)',
        '(?i)\bапарт\.?\s*([0-9]+[0-9a-zа-яё-]*)',
        '(?i)\bапартамент(?:а|ов)?\s*([0-9]+[0-9a-zа-яё-]*)',
        '(?i)\bкв(?:артира)?\.?\s*([0-9]+[0-9a-zа-яё-]*)'
    )) {
        $m = [regex]::Match($normal, $pattern)
        if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    }

    foreach ($pattern in @(
        'апарт(?:амент(?:а|ов)?)?([0-9]+[0-9a-zа-яё-]*)',
        'квартира([0-9]+[0-9a-zа-яё-]*)'
    )) {
        $m = [regex]::Match($compact, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    }

    return ''
}

$numericFolder = Join-Path $ReceiptsDir $Account

# If account folder is already decorated, use it and recover apartment from its name.
$decorated = @(
    Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like ($Account + ' - кв. *') } |
    Select-Object -First 1
)

$apt = ''
$address = ''
$sourceFolder = $numericFolder
if ($decorated.Count -gt 0) {
    $sourceFolder = [string]$decorated[0].FullName
    $m = [regex]::Match($decorated[0].Name, ' - кв\.\s+(?<apt>.+)$', 'IgnoreCase')
    if ($m.Success) { $apt = $m.Groups['apt'].Value.Trim().ToUpperInvariant() }
}

if (-not (Test-Path -LiteralPath $sourceFolder)) { exit 0 }

$files = @(Get-ChildItem -LiteralPath $sourceFolder -Recurse -Filter *.pdf -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { exit 0 }

# Read only a few PDFs until apartment and full address are known.
if ([string]::IsNullOrWhiteSpace($apt) -or [string]::IsNullOrWhiteSpace($address)) {
    foreach ($f in @($files | Select-Object -First 6)) {
        try {
            $txt = Get-PdfTextDirect $f.FullName
            if ([string]::IsNullOrWhiteSpace($apt)) { $apt = Get-Apartment $txt }
            if ([string]::IsNullOrWhiteSpace($address)) { $address = Get-FullAddress $txt $apt }
            if (-not [string]::IsNullOrWhiteSpace($apt) -and -not [string]::IsNullOrWhiteSpace($address)) { break }
        } catch {}
    }
}

if ([string]::IsNullOrWhiteSpace($apt)) {
    # Do not guess. Leave files in numeric account folder.
    exit 0
}

$safeApt = Safe-Part $apt
$safeAccount = Safe-Part $Account
$accountFolder = Join-Path $ReceiptsDir ($safeAccount + ' - кв. ' + $safeApt)
New-Item -ItemType Directory -Force -Path $accountFolder | Out-Null

# Persist account metadata next to the receipt archive. This keeps the UI independent
# of folder naming and lets the state layer reuse the address on future runs.
try {
    $metaPath = Join-Path $accountFolder '_account_meta.json'
    [pscustomobject]@{ Account=$Account; Apartment=$apt; Address=$address } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metaPath -Encoding UTF8
} catch {}

foreach ($f in $files) {
    $name = $f.Name
    $m = [regex]::Match($name, '^(?<y>20\d{2})[_-](?<m>0[1-9]|1[0-2])[_-](?<kind>[12])[_-]')
    if (-not $m.Success) {
        # Leave unusual files untouched; mailing can ignore them.
        continue
    }

    $type = if ($m.Groups['kind'].Value -eq '1') { 'ЖКХ' } else { 'Капремонт' }
    $year = [int]$m.Groups['y'].Value
    $month = [int]$m.Groups['m'].Value

    $typeFolder = Join-Path $accountFolder ($type + ' - ЛС ' + $safeAccount + ' - кв. ' + $safeApt)
    New-Item -ItemType Directory -Force -Path $typeFolder | Out-Null

    $newName = ('{0:D4}_{1:D2}_{2}_кв_{3}_ЛС_{4}.pdf' -f $year,$month,$type,$safeApt,$safeAccount)
    $dest = Join-Path $typeFolder $newName

    if ([IO.Path]::GetFullPath($f.FullName) -eq [IO.Path]::GetFullPath($dest)) { continue }

    if (Test-Path -LiteralPath $dest) {
        try {
            $a = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $b = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
            if ($a -eq $b) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                continue
            }
        } catch {}

        $base = [IO.Path]::GetFileNameWithoutExtension($dest)
        $ext = [IO.Path]::GetExtension($dest)
        $dir = Split-Path -Parent $dest
        $i = 2
        do {
            $candidate = Join-Path $dir ($base + '_' + $i + $ext)
            $i++
        } while (Test-Path -LiteralPath $candidate)
        $dest = $candidate
    }

    Move-Item -LiteralPath $f.FullName -Destination $dest -Force
}

# Remove old numeric account folder only if fully empty after moves.
if (Test-Path -LiteralPath $numericFolder) {
    try {
        if (@(Get-ChildItem -LiteralPath $numericFolder -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $numericFolder -Force
        }
    } catch {}
}
