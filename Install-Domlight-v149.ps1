Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$Repo='https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main'
$ManifestUrl="$Repo/latest.json"
$InstallRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Domlight'
$BackupRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Domlight_Backups'
function GitBlob([string]$Path){$b=[IO.File]::ReadAllBytes($Path);$h=[Text.Encoding]::ASCII.GetBytes(('blob '+$b.Length+[char]0));$x=New-Object byte[] ($h.Length+$b.Length);[Buffer]::BlockCopy($h,0,$x,0,$h.Length);[Buffer]::BlockCopy($b,0,$x,$h.Length,$b.Length);$s=[Security.Cryptography.SHA1]::Create();try{(($s.ComputeHash($x)|%{$_.ToString('x2')})-join '')}finally{$s.Dispose()}}
try{
 $m=Invoke-RestMethod -Uri $ManifestUrl -TimeoutSec 30
 if([string]$m.version -ne 'v149 STABLE'){throw 'Release manifest is not v149 STABLE.'}
 $stage=Join-Path $env:TEMP ('Domlight_v149_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Force -Path $stage|Out-Null
 foreach($f in @($m.files)){$p=Join-Path $stage ([string]$f.path);$d=Split-Path -Parent $p;if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null};Invoke-WebRequest -UseBasicParsing -Uri ([string]$f.url) -OutFile $p -TimeoutSec 45;if((GitBlob $p)-ne ([string]$f.gitBlobSha)){throw ('Checksum failed: '+$f.path)}}
 $stamp=Get-Date -Format 'yyyyMMdd_HHmmss';$backup=Join-Path $BackupRoot ('before_v149_'+$stamp);New-Item -ItemType Directory -Force -Path $BackupRoot|Out-Null
 if(Test-Path $InstallRoot){New-Item -ItemType Directory -Force -Path $backup|Out-Null;Get-ChildItem -LiteralPath $InstallRoot -Force|?{$_.Name -ne 'data'}|%{Copy-Item -LiteralPath $_.FullName -Destination $backup -Recurse -Force}}
 New-Item -ItemType Directory -Force -Path $InstallRoot|Out-Null
 foreach($f in @($m.files)){$src=Join-Path $stage ([string]$f.path);$dst=Join-Path $InstallRoot ([string]$f.path);$d=Split-Path -Parent $dst;if($d){New-Item -ItemType Directory -Force -Path $d|Out-Null};Copy-Item -LiteralPath $src -Destination $dst -Force;if((GitBlob $dst)-ne ([string]$f.gitBlobSha)){throw ('Install verification failed: '+$f.path)}}
 Set-Content -LiteralPath (Join-Path $InstallRoot 'STABLE_BASELINE.lock') -Value ('Domlight v149 STABLE`r`nInstalled '+(Get-Date).ToString('s')) -Encoding UTF8
 $desk=[Environment]::GetFolderPath('Desktop');$lnk=Join-Path $desk 'Domlight v149 STABLE.lnk';$ws=New-Object -ComObject WScript.Shell;$s=$ws.CreateShortcut($lnk);$s.TargetPath="$env:SystemRoot\System32\wscript.exe";$s.Arguments='"'+(Join-Path $InstallRoot 'DomlightLauncher.vbs')+'"';$s.WorkingDirectory=$InstallRoot;$s.Save()
 Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
 [Windows.Forms.MessageBox]::Show('Domlight v149 STABLE установлен и проверен. Данные сохранены.','Domlight','OK','Information')|Out-Null
}catch{[Windows.Forms.MessageBox]::Show("Установка v149 остановлена.`r`n`r`n$($_.Exception.Message)`r`n`r`nСуществующие данные не удалялись.",'Domlight','OK','Error')|Out-Null;exit 1}
