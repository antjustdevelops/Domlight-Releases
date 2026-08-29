param(
    [Parameter(Mandatory=$true)][string]$CandidateDir,
    [string]$ChangeTarget = '',
    [string[]]$AllowedSharedChanges = @()
)

$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$RegistryPath=Join-Path $PSScriptRoot 'PROTECTED_MODULES.json'
if(-not(Test-Path -LiteralPath $RegistryPath)){throw 'Protected module registry is missing.'}
$registry=Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
if([string]::IsNullOrWhiteSpace($ChangeTarget)){throw 'CHANGE_TARGET is mandatory. Refusing unscoped release build.'}
if(-not(Test-Path -LiteralPath $CandidateDir)){throw ('Candidate directory not found: '+$CandidateDir)}

# Global data-boundary guard.
if(Test-Path -LiteralPath (Join-Path $CandidateDir 'data')){throw 'RELEASE BLOCKED: candidate contains data/. User state must never be packaged.'}

# No stable promotion while a known accepted capability is regressed.
$recovery=@($registry.modules | Where-Object { [string]$_.status -eq 'RECOVERY_REQUIRED' })
if($recovery.Count -gt 0){
    $ids=($recovery | ForEach-Object {[string]$_.id}) -join ', '
    throw ('RELEASE BLOCKED: protected capabilities require recovery: '+$ids+'. Candidate may be TEST only.')
}

# Every candidate PowerShell file must parse under Windows PowerShell 5.1-compatible parser.
foreach($ps1 in @(Get-ChildItem -LiteralPath $CandidateDir -Filter *.ps1 -File -Recurse)){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($ps1.FullName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -gt 0){throw ('RELEASE BLOCKED: parser error in '+$ps1.FullName+': '+$errors[0].Message)}
}

# Explicit regression evidence is mandatory for every protected/accepted capability.
$EvidenceDir=Join-Path $CandidateDir 'regression-evidence'
if(-not(Test-Path -LiteralPath $EvidenceDir)){throw 'RELEASE BLOCKED: regression-evidence directory is missing.'}
foreach($m in @($registry.modules)){
    if([string]$m.status -notin @('protected','protected_after_acceptance')){continue}
    $evidence=Join-Path $EvidenceDir (([string]$m.id)+'.PASS')
    if(-not(Test-Path -LiteralPath $evidence)){throw ('RELEASE BLOCKED: no PASS evidence for protected module '+[string]$m.id)}
}

Write-Output ('RELEASE_GATE_OK target='+$ChangeTarget)
