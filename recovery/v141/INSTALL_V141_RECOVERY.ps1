param(
    [string]$Root=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Domlight')
)
Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

function Msg([string]$Text,[string]$Icon='Information'){[Windows.Forms.MessageBox]::Show($Text,'Domlight v141 Recovery','OK',$Icon)|Out-Null}
function GitBlobSha([string]$Path){
    $bytes=[IO.File]::ReadAllBytes($Path);$head=[Text.Encoding]::ASCII.GetBytes(('blob '+$bytes.Length+[char]0));$all=New-Object byte[] ($head.Length+$bytes.Length);[Buffer]::BlockCopy($head,0,$all,0,$head.Length);[Buffer]::BlockCopy($bytes,0,$all,$head.Length,$bytes.Length);$h=[Security.Cryptography.SHA1]::Create();try{return (($h.ComputeHash($all)|ForEach-Object{$_.ToString('x2')})-join '')}finally{$h.Dispose()}
}
function ParseOk([string]$Path){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e);return(@($e).Count-eq0)}
function FullMailScore([string]$Path){if(-not(Test-Path $Path)){return -1};try{$t=Get-Content $Path -Raw}catch{return -1};$n=0;foreach($s in @('Gmail','WhatsApp','Recipients','recipients.json','email_history.json','whatsapp_history.json','gmail_token')){if($t.IndexOf($s,[StringComparison]::OrdinalIgnoreCase)-ge0){$n++}};return $n}
function BackupFiles([string]$Dir,[string[]]$Names){New-Item -ItemType Directory -Force -Path $Dir|Out-Null;foreach($n in $Names){$p=Join-Path $Root $n;if(Test-Path $p){$d=Join-Path $Dir $n;$dd=Split-Path -Parent $d;if($dd){New-Item -ItemType Directory -Force -Path $dd|Out-Null};Copy-Item $p $d -Force}}}
function RestoreBackup([string]$Dir,[hashtable]$Had,[string[]]$Names){foreach($n in $Names){$dst=Join-Path $Root $n;$src=Join-Path $Dir $n;if($Had[$n]){if(Test-Path $src){Copy-Item $src $dst -Force}}elseif(Test-Path $dst){Remove-Item $dst -Force}}}
function FindEarliestBackup([string]$Name,[scriptblock]$Filter){$br=Join-Path $Root 'data\update_backups';if(-not(Test-Path $br)){return $null};$a=@(Get-ChildItem $br -Recurse -File -Filter $Name -ErrorAction SilentlyContinue|Where-Object{&$Filter $_.FullName}|Sort-Object FullName);if($a.Count){return $a[0].FullName};return $null}

try{
 if(-not(Test-Path $Root)){throw "Не найдена установленная папка Domlight: $Root"}
 $data=Join-Path $Root 'data';if(-not(Test-Path $data)){throw 'Не найдена data. Recovery остановлен.'}
 $stamp=Get-Date -Format 'yyyyMMdd_HHmmss';$stage=Join-Path $data ('recovery_stage\'+$stamp);$safe=Join-Path $data ('recovery_safety\'+$stamp);New-Item -ItemType Directory -Force -Path $stage|Out-Null

 # Exact accepted/candidate pins. No PdfEngine and no v135+ Mailing/ConnectionSettings are installed.
 $files=@(
  @{n='AccountState.ps1';v='v106';sha='0521a6bf852a201df5cf0986650939a52fa34c61'},
  @{n='AccountStatus.ps1';v='v109';sha='7013dfd669d61603dc161d15692855bd36060422'},
  @{n='OrganizeDownloadedAccount.ps1';v='v109';sha='21b465f17fc0632890195d43b2b0081ad65f81be'},
  @{n='Domlight.ps1';v='v106';sha='8745cf88f53f0745b388e8f13783fb771c99c642'},
  @{n='AutoCheck.ps1';v='v106';sha='3d059b62d4df75d4ca00a634309dfe4c1ac28ade'},
  @{n='RunAutoCheckHidden.ps1';v='v140';sha='69178900f9708cbbbcf26b8687b9c4bd6cab4c48'},
  @{n='ConfigureAutoCheckTask.ps1';v='v140';sha='c817ffd32f1fa9b42c4569328f0eb23b2a77a54d'},
  @{n='ENABLE_AUTO_CHECK.bat';v='v140';sha='f2758ef04388873745843d11c0f83a699da1fa98'},
  @{n='DISABLE_AUTO_CHECK.bat';v='v140';sha='eb6e2ca52d0ff92b505457565940cacca58f98aa'},
  @{n='MENU_DOMLIGHT.ps1';v='v140';sha='b1b776d660fdb53ae410dac58eb947c63b9f7b64'},
  @{n='SingleWindowLauncher.ps1';v='v140';sha='2b28b54b985e4d9aaa00c8f9666a0d516e9f2a5d'},
  @{n='DomlightLauncher.vbs';v='v140';sha='e3a7fd209d09fa7274dfb7abbdebaf932e0834ee'},
  @{n='MeterStatus.ps1';v='v140';sha='063611850a8b6ba1a96bab3e7cd792179d73b6e1'},
  @{n='MeterDraftStore.ps1';v='v140';sha='422bd3c38bfc0479d768229267337a5ff08548e5'},
  @{n='MeterGridBehavior.ps1';v='v140';sha='5ef036f27f8a5fb8a040c758ee36a410516edc99'}
 )
 foreach($f in $files){$u='https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/'+$f.v+'/'+$f.n;$p=Join-Path $stage $f.n;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $p -TimeoutSec 40;if((GitBlobSha $p)-ne$f.sha){throw('SHA mismatch: '+$f.n)};if($f.n.EndsWith('.ps1')-and -not(ParseOk $p)){throw('Parser error: '+$f.n)}}

 # Recover the exact locally carried-forward modules from the first updater takeover backup.
 $oldMail=FindEarliestBackup 'Mailing.ps1' {param($p)(ParseOk $p)-and(FullMailScore $p)-ge3}
 if(-not$oldMail){throw 'Не найден полноценный pre-v135 Mailing.ps1 в data\update_backups. Ничего не установлено.'}
 $oldConn=FindEarliestBackup 'ConnectionSettings.ps1' {param($p)if(-not(ParseOk $p)){return $false};$t=Get-Content $p -Raw;return($t-match'useProxy'-and$t-match'proxyUrl'-and$t-match'proxyUser'-and$t-match'proxyPassword')}
 if(-not$oldConn){throw 'Не найден pre-v135 ConnectionSettings.ps1 в data\update_backups. Ничего не установлено.'}
 foreach($n in @('GmailApi.ps1','Recipients.ps1')){$p=Join-Path $Root $n;if(-not(Test-Path $p)){throw("Не найден сохранённый рабочий $n. Ничего не установлено.")};if(-not(ParseOk $p)){throw("Parser error в сохранённом $n")}}

 $names=@($files|ForEach-Object{$_.n})+@('Mailing.ps1','ConnectionSettings.ps1','GmailApi.ps1','Recipients.ps1','UpdateFromGitHub.ps1','SelfCheck.ps1','VERSION.txt')
 $had=@{};foreach($n in $names){$had[$n]=Test-Path(Join-Path $Root $n)};BackupFiles $safe $names
 try{
  foreach($f in $files){Copy-Item (Join-Path $stage $f.n) (Join-Path $Root $f.n) -Force}
  Copy-Item $oldMail (Join-Path $Root 'Mailing.ps1') -Force;Copy-Item $oldConn (Join-Path $Root 'ConnectionSettings.ps1') -Force
  # Updates are intentionally blocked while this candidate is under regression test.
  @" 
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.MessageBox]::Show('Обновление временно отключено в v141 RECOVERY CANDIDATE до завершения полного регрессионного теста.','Domlight Recovery','OK','Information')|Out-Null
"@|Set-Content (Join-Path $Root 'UpdateFromGitHub.ps1') -Encoding UTF8
  'Domlight v141 RECOVERY CANDIDATE'|Set-Content (Join-Path $Root 'VERSION.txt') -Encoding UTF8
  # Candidate self-check uses exact pins and checks recovered local blocks.
  $sc=@'
$ErrorActionPreference='Stop';$Root=Split-Path -Parent $MyInvocation.MyCommand.Path;$errs=@()
function B($p){$x=[IO.File]::ReadAllBytes($p);$h=[Text.Encoding]::ASCII.GetBytes(('blob '+$x.Length+[char]0));$a=New-Object byte[]($h.Length+$x.Length);[Buffer]::BlockCopy($h,0,$a,0,$h.Length);[Buffer]::BlockCopy($x,0,$a,$h.Length,$x.Length);$s=[Security.Cryptography.SHA1]::Create();try{(($s.ComputeHash($a)|%{$_.ToString('x2')})-join'')}finally{$s.Dispose()}}
$pins=@{'AccountState.ps1'='0521a6bf852a201df5cf0986650939a52fa34c61';'AccountStatus.ps1'='7013dfd669d61603dc161d15692855bd36060422';'OrganizeDownloadedAccount.ps1'='21b465f17fc0632890195d43b2b0081ad65f81be';'Domlight.ps1'='8745cf88f53f0745b388e8f13783fb771c99c642';'AutoCheck.ps1'='3d059b62d4df75d4ca00a634309dfe4c1ac28ade';'RunAutoCheckHidden.ps1'='69178900f9708cbbbcf26b8687b9c4bd6cab4c48';'MeterStatus.ps1'='063611850a8b6ba1a96bab3e7cd792179d73b6e1';'MeterDraftStore.ps1'='422bd3c38bfc0479d768229267337a5ff08548e5';'MeterGridBehavior.ps1'='5ef036f27f8a5fb8a040c758ee36a410516edc99'}
foreach($k in $pins.Keys){$p=Join-Path $Root $k;if(-not(Test-Path $p)){$errs+='Missing '+$k}elseif((B $p)-ne$pins[$k]){$errs+='Pin mismatch '+$k}}
foreach($n in @('Mailing.ps1','ConnectionSettings.ps1','GmailApi.ps1','Recipients.ps1')){if(-not(Test-Path(Join-Path $Root $n))){$errs+='Missing '+$n}}
$t=Get-Content (Join-Path $Root 'Mailing.ps1') -Raw;if($t-notmatch'(?i)Gmail|WhatsApp|Recipients'){$errs+='Mailing is not full legacy stack'}
$m=Get-Content (Join-Path $Root 'MeterStatus.ps1') -Raw;if($m-match'/meter/value'){$errs+='Meter send unexpectedly enabled'}
$v=(Get-Content (Join-Path $Root 'VERSION.txt') -Raw).Trim();if($v-ne'Domlight v141 RECOVERY CANDIDATE'){$errs+='Wrong version '+$v}
[pscustomobject]@{Ok=($errs.Count-eq0);Errors=$errs;Version=$v}|ConvertTo-Json -Depth 4;if($errs.Count){exit 1}else{exit 0}
'@
  $sc|Set-Content (Join-Path $Root 'SelfCheck.ps1') -Encoding UTF8
  $out=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'SelfCheck.ps1') 2>&1;$code=$LASTEXITCODE;$out|Set-Content (Join-Path $data ('recovery_selfcheck_'+$stamp+'.txt')) -Encoding UTF8;if($code-ne0){throw('SelfCheck failed: '+($out-join' '))}
 }catch{RestoreBackup $safe $had $names;throw('Установка автоматически откачена: '+$_.Exception.Message)}
 Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
 Msg("v141 RECOVERY CANDIDATE установлен.`r`n`r`nТекущая установка сохранена в:`r`n$safe`r`n`r`nОбычное обновление заблокировано до окончания теста.`r`nSelfCheck: OK")
}catch{Msg $_.Exception.Message 'Error';exit 1}
