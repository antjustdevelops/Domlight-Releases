param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE 'Downloads\Domlight_v137_CLEAN'),
    [string]$SourceDataRoot = (Join-Path $env:USERPROFILE 'Downloads\Domlight_v106_UPDATE_TEST\data')
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManifestUrl = 'https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/latest.json'

function Show-Info([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text,'Domlight Clean Install','OK','Information') | Out-Null
}
function Show-Error([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text,'Domlight Clean Install','OK','Error') | Out-Null
}
function Get-GitBlobSha([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $bytes.Length + [char]0))
    $combined = New-Object byte[] ($header.Length + $bytes.Length)
    [Buffer]::BlockCopy($header,0,$combined,0,$header.Length)
    [Buffer]::BlockCopy($bytes,0,$combined,$header.Length,$bytes.Length)
    $sha1=[Security.Cryptography.SHA1]::Create()
    try { return (($sha1.ComputeHash($combined) | ForEach-Object {$_.ToString('x2')}) -join '') }
    finally { $sha1.Dispose() }
}
function Test-ManifestFile($File,[string]$Path) {
    if(-not(Test-Path -LiteralPath $Path)){return $false}
    if(-not [string]::IsNullOrWhiteSpace([string]$File.gitBlobSha)){
        return ((Get-GitBlobSha $Path) -eq ([string]$File.gitBlobSha).ToLowerInvariant())
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$File.sha256)){
        return (((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()) -eq ([string]$File.sha256).ToLowerInvariant())
    }
    return $false
}
function Test-SafeRelativePath([string]$Relative) {
    if([string]::IsNullOrWhiteSpace($Relative)){return $false}
    if([IO.Path]::IsPathRooted($Relative)){return $false}
    $n=$Relative.Replace('/','\')
    if($n -match '(^|\\)\.\.(\\|$)'){return $false}
    if($n -match '(?i)^data(\\|$)'){return $false}
    return $true
}

try {
    $manifest=Invoke-RestMethod -Uri ($ManifestUrl+'?t='+[DateTime]::UtcNow.Ticks) -TimeoutSec 30
    if([string]$manifest.version -ne 'v137 RELEASE'){throw ('Expected v137 RELEASE manifest, got: '+[string]$manifest.version)}
    if(-not $manifest.files){throw 'Manifest contains no files.'}

    if(Test-Path -LiteralPath $TargetRoot){
        $TargetRoot = $TargetRoot + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    }

    $stage=Join-Path $env:TEMP ('Domlight_v137_'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    foreach($file in @($manifest.files)){
        $relative=[string]$file.path
        if(-not(Test-SafeRelativePath $relative)){throw ('Unsafe manifest path: '+$relative)}
        $dest=Join-Path $stage $relative
        $dir=Split-Path -Parent $dest
        if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
        Invoke-WebRequest -UseBasicParsing -Uri ([string]$file.url) -OutFile $dest -TimeoutSec 45
        if(-not(Test-ManifestFile $file $dest)){throw ('Checksum failed: '+$relative)}
        try{Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue}catch{}
    }

    foreach($ps1 in @(Get-ChildItem -LiteralPath $stage -Filter *.ps1 -File)){
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($ps1.FullName,[ref]$tokens,[ref]$errors)
        if(@($errors).Count -gt 0){throw ('PowerShell syntax error in '+$ps1.Name+': '+$errors[0].Message)}
    }

    New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
    Get-ChildItem -LiteralPath $stage -Force | Copy-Item -Destination $TargetRoot -Recurse -Force

    if(Test-Path -LiteralPath $SourceDataRoot){
        $targetData=Join-Path $TargetRoot 'data'
        New-Item -ItemType Directory -Force -Path $targetData | Out-Null
        Get-ChildItem -LiteralPath $SourceDataRoot -Force -ErrorAction SilentlyContinue | Copy-Item -Destination $targetData -Recurse -Force
    } else {
        New-Item -ItemType Directory -Force -Path (Join-Path $TargetRoot 'data') | Out-Null
    }

    $selfCheck=Join-Path $TargetRoot 'SelfCheck.ps1'
    if(-not(Test-Path -LiteralPath $selfCheck)){throw 'SelfCheck.ps1 is missing after installation.'}
    $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$selfCheck+'"'),'-Root',('"'+$TargetRoot+'"')) -Wait -PassThru -WindowStyle Hidden
    if($p.ExitCode -ne 0){throw ('Installed copy failed SelfCheck. Exit code: '+$p.ExitCode)}

    try{Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}catch{}

    $launcher=Join-Path $TargetRoot 'DomlightLauncher.vbs'
    if(-not(Test-Path -LiteralPath $launcher)){throw 'DomlightLauncher.vbs is missing after installation.'}
    Show-Info ("v137 CLEAN установлена и проверена.`r`n`r`nПапка:`r`n"+$TargetRoot+"`r`n`r`nСтарая тестовая папка не изменялась.")
    Start-Process wscript.exe -ArgumentList ('"'+$launcher+'"')
}
catch {
    Show-Error ('Установка остановлена. Старая копия не изменялась.'+"`r`n`r`n"+$_.Exception.Message)
    exit 1
}
