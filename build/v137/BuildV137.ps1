param()

$ErrorActionPreference = 'Stop'

$BuildDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildRoot = Split-Path -Parent $BuildDir
$RepoRoot = Split-Path -Parent $BuildRoot
$OutputDir = Join-Path $RepoRoot 'files\v137'
$ManifestPath = Join-Path $RepoRoot 'latest.json'
$CandidateManifestPath = Join-Path $BuildDir 'latest.v137.json'
$Version = 'v137 RELEASE'

Set-Location $RepoRoot

function Write-Utf8BomFile {
    param([string]$Path,[string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path,$Text,$enc)
}

function Read-Utf8File {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
}

function Get-StagedBlobSha {
    param([string]$RepoRelativePath)
    $spec=':'+($RepoRelativePath.Replace('\','/'))
    $value=& git rev-parse $spec 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$value)) {
        throw ('Cannot resolve staged Git blob: '+$RepoRelativePath)
    }
    return ([string]$value).Trim()
}

function Assert-ParseClean {
    param([string]$Root)
    $allErrors = New-Object System.Collections.ArrayList
    foreach($f in @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)) {
        $tokens=$null
        $parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$parseErrors)
        foreach($e in @($parseErrors)) {
            [void]$allErrors.Add("$($f.Name) line $($e.Extent.StartLineNumber), col $($e.Extent.StartColumnNumber): $($e.Message)")
        }
    }
    if($allErrors.Count -gt 0) {
        $allErrors | ForEach-Object { Write-Host ('PARSER ERROR: '+$_) }
        throw ('Windows PowerShell 5.1 parser found '+$allErrors.Count+' error(s).')
    }
}

function Assert-Utf8Bom {
    param([string]$Root)
    foreach($f in @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)) {
        $bytes=[IO.File]::ReadAllBytes($f.FullName)
        if($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            throw ('PowerShell file is not UTF-8 BOM: '+$f.Name)
        }
    }
}

function Invoke-SmokeTest {
    param([string]$Root,[string]$ScriptName)
    $scriptPath = Join-Path $Root $ScriptName
    $launcherPath = Join-Path $Root 'SingleWindowLauncher.ps1'
    $key='Smoke_'+[IO.Path]::GetFileNameWithoutExtension($ScriptName)+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $stdout = Join-Path $env:TEMP ('domlight_smoke_'+[guid]::NewGuid().ToString('N')+'.out.txt')
    $stderr = Join-Path $env:TEMP ('domlight_smoke_'+[guid]::NewGuid().ToString('N')+'.err.txt')
    try {
        $p = Start-Process powershell.exe -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',$launcherPath,
            '-Script',$scriptPath,'-Key',$key,'-SmokeTest'
        ) -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $outText = if(Test-Path $stdout){Get-Content $stdout -Raw -ErrorAction SilentlyContinue}else{''}
        $errText = if(Test-Path $stderr){Get-Content $stderr -Raw -ErrorAction SilentlyContinue}else{''}
        if($p.ExitCode -ne 0) {
            throw ("Launcher smoke test failed: $ScriptName`r`nExit: $($p.ExitCode)`r`n$outText`r`n$errText")
        }
        if($outText -notmatch 'SMOKE_OK') {
            throw ("Launcher smoke test did not report success: $ScriptName`r`n$outText`r`n$errText")
        }
        Write-Host ('LAUNCHER SMOKE PASS: '+$ScriptName)
    }
    finally {
        Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '=== Domlight v137 structural build ==='

if(-not(Test-Path -LiteralPath $ManifestPath)) { throw 'latest.json not found.' }
$current = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not $current.files) { throw 'Current manifest has no files list.' }

if(Test-Path -LiteralPath $OutputDir) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

foreach($item in @($current.files)) {
    $url=[string]$item.url
    $needle='/antjustdevelops/Domlight-Releases/main/'
    $idx=$url.IndexOf($needle)
    if($idx -lt 0) { throw ('Unsupported manifest URL: '+$url) }
    $repoRelative=$url.Substring($idx+$needle.Length).Replace('/','\')
    $source=Join-Path $RepoRoot $repoRelative
    if(-not(Test-Path -LiteralPath $source)) { throw ('Manifest source missing in repository: '+$repoRelative) }
    $dest=Join-Path $OutputDir ([string]$item.path)
    Copy-Item -LiteralPath $source -Destination $dest -Force
}

foreach($name in @('Mailing.ps1','ConnectionSettings.ps1','SingleWindowLauncher.ps1','SelfCheck.ps1','PROJECT_STRUCTURE.md')) {
    $source=Join-Path $BuildDir $name
    if(-not(Test-Path -LiteralPath $source)) { throw ('Missing v137 build input: '+$name) }
    Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDir $name) -Force
}

$domPath=Join-Path $OutputDir 'Domlight.ps1'
$dom=Read-Utf8File $domPath
$dom=$dom.TrimStart([char[]]@([char]0xFEFF,[char]13,[char]10))
if($dom -notmatch '^param\(\[switch\]\$SmokeTest\)') {
    $dom="param([switch]`$SmokeTest)`r`n`r`n"+$dom
}

$startupPattern='(?s)\r?\ntry \{\r?\n    Add-Type -AssemblyName System\.Web.*?\r?\nRefresh-LastCheck\r?\n\[void\]\$form\.ShowDialog\(\)\s*$'
$startupReplacement=@'

if ($SmokeTest) {
    Write-Output 'SMOKE_OK Domlight'
    $form.Dispose()
    exit 0
}

# No portal request is allowed before the cabinet becomes visible.
try {
    Add-Type -AssemblyName System.Web
    Load-Session
    if (Test-Path -LiteralPath $SessionFile) {
        $lblStatus.Text = "Сессия сохранена"
        $lblStatus.ForeColor = [Drawing.Color]::DarkOrange
        $btnSync.Enabled = $true
        Log "Сохранённая сессия загружена. Соединение будет проверено при обращении к порталу."
    } else {
        Log "Введите телефон и получите SMS."
    }
} catch {
    Log "Старт: $($_.Exception.Message)"
}

Refresh-LastCheck
[void]$form.ShowDialog()
'@
$rx=New-Object Text.RegularExpressions.Regex($startupPattern,[Text.RegularExpressions.RegexOptions]::None)
if(-not $rx.IsMatch($dom)) { throw 'Domlight startup block not found; refusing to build by guess.' }
$dom=$rx.Replace($dom,[Text.RegularExpressions.MatchEvaluator]{param($m)$startupReplacement},1)
Write-Utf8BomFile $domPath $dom

Write-Utf8BomFile (Join-Path $OutputDir 'VERSION.txt') ('Domlight '+$Version+"`r`n")

foreach($f in @(Get-ChildItem -LiteralPath $OutputDir -Filter *.ps1 -File)) {
    $text=Read-Utf8File $f.FullName
    $text=$text.TrimStart([char]0xFEFF)
    Write-Utf8BomFile $f.FullName $text
}

Assert-Utf8Bom $OutputDir
Assert-ParseClean $OutputDir

Write-Host 'Running structural SelfCheck...'
& (Join-Path $OutputDir 'SelfCheck.ps1') -Root $OutputDir
if($LASTEXITCODE -ne 0) { throw 'SelfCheck failed.' }

$smokeRoot=Join-Path $env:TEMP ('domlight_v137_smoke_'+[guid]::NewGuid().ToString('N'))
try {
    Copy-Item -LiteralPath $OutputDir -Destination $smokeRoot -Recurse -Force
    $receiptDir=Join-Path $smokeRoot 'data\receipts\020000000001 - кв. 1\ЖКХ - ЛС 020000000001 - кв. 1'
    New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $receiptDir '2026_08_ЖКХ_кв_1_ЛС_020000000001.pdf'),[byte[]](37,80,68,70,45,49,46,52,10))

    Invoke-SmokeTest $smokeRoot 'ConnectionSettings.ps1'
    Invoke-SmokeTest $smokeRoot 'Mailing.ps1'
    Invoke-SmokeTest $smokeRoot 'Domlight.ps1'
}
finally {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

& git add -- files/v137
if($LASTEXITCODE -ne 0) { throw 'git add files/v137 failed.' }

$manifestFiles=@()
foreach($f in @(Get-ChildItem -LiteralPath $OutputDir -File | Sort-Object Name)) {
    $relative=('files/v137/'+$f.Name)
    $blob=Get-StagedBlobSha $relative
    $manifestFiles += [ordered]@{
        path=$f.Name
        url=('https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/v137/'+$f.Name)
        gitBlobSha=$blob
    }
}

$candidate=[ordered]@{
    version=$Version
    published='2026-08-29'
    notes='Full structural baseline: complete managed snapshot; every PowerShell file normalized to UTF-8 BOM and parsed by Windows PowerShell 5.1; menu child path smoke-tested through SingleWindowLauncher for cabinet, proxy settings and mailing; child startup failures are visible and logged; mailing grid uses explicit rows; data is preserved; meter submission remains disabled.'
    files=$manifestFiles
}
$candidateJson=$candidate | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($CandidateManifestPath,$candidateJson,(New-Object Text.UTF8Encoding($false)))

$actualCount=@(Get-ChildItem -LiteralPath $OutputDir -File).Count
if(@($candidate.files).Count -ne $actualCount) { throw 'Candidate manifest/file count mismatch.' }
foreach($item in @($candidate.files)) {
    $path='files/v137/'+[string]$item.path
    if(-not(Test-Path -LiteralPath (Join-Path $OutputDir ([string]$item.path)))) { throw ('Candidate manifest target missing: '+[string]$item.path) }
    $actualBlob=Get-StagedBlobSha $path
    if($actualBlob -ne [string]$item.gitBlobSha) { throw ('Manifest staged SHA mismatch: '+[string]$item.path) }
}

Write-Host ('BUILD_OK '+$Version+'; files='+$actualCount+'; manifest-sha-source=git-index; smoke-path=launcher')
