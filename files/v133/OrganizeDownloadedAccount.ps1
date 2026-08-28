param(
    [Parameter(Mandatory=$true)][string]$ReceiptsDir,
    [Parameter(Mandatory=$true)][string]$Account
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "PdfEngine.ps1")

function Safe-Part([string]$Text) {
    $v = ([string]$Text).Trim()
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $v = $v.Replace([string]$c, '_') }
    return $v
}

function Normalize-ReceiptText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{ Normal=''; Compact='' } }
    $normal = ($Text -replace '[\u0000-\u001F]+',' ' -replace '\s+',' ').Trim().ToLowerInvariant()
    $compact = ($normal -replace '[^0-9a-zа-яё]+','')
    return [pscustomobject]@{ Normal=$normal; Compact=$compact }
}

function Get-FullAddress([string]$Text, [string]$Apartment = '') {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $flat = ($Text -replace '[\u0000-\u001F]+',' ' -replace '\s+',' ').Trim()
    $patterns = @(
        '(?i)\bадрес(?:\s+(?:помещения|объекта|квартиры|апартамента))?\s*[:\-]\s*(?<addr>.*?)(?=\s+(?:апарт(?:амент)?|кв(?:артира)?)\.?\s*[№#]?\s*[0-9]|\s+(?:лицевой\s+сч[её]т|л\/?с|плательщик|период|общая\s+площадь|итого)\b)',
        '(?i)\bадрес(?:\s+(?:помещения|объекта|квартиры|апартамента))?\s*[:\-]\s*(?<addr>[^;]{8,220})',
        '(?i)\b(?<addr>(?:г\.?\s*)?москва[^;\r\n]{8,220})'
    )
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($flat, $pattern)
        if (-not $m.Success) { continue }
        $addr = ($m.Groups['addr'].Value -replace '\s+',' ').Trim(' ', ',', ';', '.')
        if ($addr.Length -lt 6) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Apartment) -and $addr -notmatch ('(?i)(?:кв(?:артира)?|апарт(?:амент)?)\.?\s*[№#]?\s*' + [regex]::Escape($Apartment))) {
            $addr = $addr + ', кв. ' + $Apartment
        }
        return $addr
    }
    return ''
}

function Get-Apartment([string]$Text) {
    $n = Normalize-ReceiptText $Text
    foreach ($pattern in @(
        '(?i)\bадрес\s*:\s*.*?\bапарт\.?\s*([0-9]+[0-9a-zа-яё-]*)',
        '(?i)\bапарт\.?\s*([0-9]+[0-9a-zа-яё-]*)',
        '(?i)\bапартамент(?:а|ов)?\s*([0-9]+[0-9a-zа-яё-]*)',
        '(?i)\bкв(?:артира)?\.?\s*([0-9]+[0-9a-zа-яё-]*)'
    )) { $m=[regex]::Match($n.Normal,$pattern); if($m.Success){return $m.Groups[1].Value.ToUpperInvariant()} }
    foreach ($pattern in @('апарт(?:амент(?:а|ов)?)?([0-9]+[0-9a-zа-яё-]*)','квартира([0-9]+[0-9a-zа-яё-]*)')) {
        $m=[regex]::Match($n.Compact,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase); if($m.Success){return $m.Groups[1].Value.ToUpperInvariant()}
    }
    return ''
}

$numericFolder = Join-Path $ReceiptsDir $Account
$decorated = @(Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($Account + ' - кв. *') } | Select-Object -First 1)
$apt='';$address='';$sourceFolder=$numericFolder
if($decorated.Count-gt0){
    $sourceFolder=[string]$decorated[0].FullName
    $m=[regex]::Match($decorated[0].Name,' - кв\.\s+(?<apt>.+)$','IgnoreCase');if($m.Success){$apt=$m.Groups['apt'].Value.Trim().ToUpperInvariant()}
    $metaPath=Join-Path $sourceFolder '_account_meta.json'
    if(Test-Path -LiteralPath $metaPath){try{$meta=Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8|ConvertFrom-Json;if(-not[string]::IsNullOrWhiteSpace([string]$meta.Apartment)){$apt=[string]$meta.Apartment};if(-not[string]::IsNullOrWhiteSpace([string]$meta.Address)){$address=[string]$meta.Address}}catch{}}
}
if(-not(Test-Path -LiteralPath $sourceFolder)){exit 0}
$files=@(Get-ChildItem -LiteralPath $sourceFolder -Recurse -Filter *.pdf -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if($files.Count-eq0){exit 0}

# Canonical address recovery: scan the archive until both apartment and full address are known.
if([string]::IsNullOrWhiteSpace($apt)-or[string]::IsNullOrWhiteSpace($address)){
    foreach($f in $files){
        try{
            $txt=Get-PdfTextDirect $f.FullName
            if([string]::IsNullOrWhiteSpace($apt)){$apt=Get-Apartment $txt}
            if([string]::IsNullOrWhiteSpace($address)){$address=Get-FullAddress $txt $apt}
            if(-not[string]::IsNullOrWhiteSpace($apt)-and-not[string]::IsNullOrWhiteSpace($address)){break}
        }catch{}
    }
}
if([string]::IsNullOrWhiteSpace($apt)){exit 0}

$safeApt=Safe-Part $apt;$safeAccount=Safe-Part $Account
$accountFolder=Join-Path $ReceiptsDir ($safeAccount+' - кв. '+$safeApt)
New-Item -ItemType Directory -Force -Path $accountFolder|Out-Null
try{[pscustomobject]@{Account=$Account;Apartment=$apt;Address=$address}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $accountFolder '_account_meta.json') -Encoding UTF8}catch{}

foreach($f in $files){
    $m=[regex]::Match($f.Name,'^(?<y>20\d{2})[_-](?<m>0[1-9]|1[0-2])[_-](?<kind>[12])[_-]');if(-not$m.Success){continue}
    $type=if($m.Groups['kind'].Value-eq'1'){'ЖКХ'}else{'Капремонт'};$year=[int]$m.Groups['y'].Value;$month=[int]$m.Groups['m'].Value
    $typeFolder=Join-Path $accountFolder ($type+' - ЛС '+$safeAccount+' - кв. '+$safeApt);New-Item -ItemType Directory -Force -Path $typeFolder|Out-Null
    $dest=Join-Path $typeFolder ('{0:D4}_{1:D2}_{2}_кв_{3}_ЛС_{4}.pdf' -f $year,$month,$type,$safeApt,$safeAccount)
    if([IO.Path]::GetFullPath($f.FullName)-eq[IO.Path]::GetFullPath($dest)){continue}
    if(Test-Path -LiteralPath $dest){try{$a=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash;$b=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash;if($a-eq$b){Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue;continue}}catch{};$base=[IO.Path]::GetFileNameWithoutExtension($dest);$ext=[IO.Path]::GetExtension($dest);$dir=Split-Path -Parent $dest;$i=2;do{$candidate=Join-Path $dir ($base+'_'+$i+$ext);$i++}while(Test-Path -LiteralPath $candidate);$dest=$candidate}
    Move-Item -LiteralPath $f.FullName -Destination $dest -Force
}
if(Test-Path -LiteralPath $numericFolder){try{if(@(Get-ChildItem -LiteralPath $numericFolder -Force -ErrorAction Stop).Count-eq0){Remove-Item -LiteralPath $numericFolder -Force}}catch{}}
