param(
  [string]$Root=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Domlight'),
  [switch]$Silent
)
$ErrorActionPreference='Stop'
if(-not $Silent){Add-Type -AssemblyName System.Windows.Forms}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

function Info([string]$s){if($Silent){Write-Host $s}else{[Windows.Forms.MessageBox]::Show($s,'Domlight v141 Recovery','OK','Information')|Out-Null}}
function Fail([string]$s){if($Silent){Write-Host ('ERROR: '+$s) -ForegroundColor Red}else{[Windows.Forms.MessageBox]::Show($s,'Domlight v141 Recovery','OK','Error')|Out-Null}}
function BlobSha([string]$p){$b=[IO.File]::ReadAllBytes($p);$h=[Text.Encoding]::ASCII.GetBytes(('blob '+$b.Length+[char]0));$a=New-Object byte[]($h.Length+$b.Length);[Buffer]::BlockCopy($h,0,$a,0,$h.Length);[Buffer]::BlockCopy($b,0,$a,$h.Length,$b.Length);$s=[Security.Cryptography.SHA1]::Create();try{(($s.ComputeHash($a)|ForEach-Object{$_.ToString('x2')})-join'')}finally{$s.Dispose()}}
function ParseOk([string]$p){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);(@($e).Count-eq0)}
function MailScore([string]$p){if(-not(Test-Path $p)){return -1};$t=Get-Content $p -Raw;$n=0;foreach($x in @('Gmail','WhatsApp','Recipients','recipients.json','email_history.json','whatsapp_history.json','gmail_token')){if($t.IndexOf($x,[StringComparison]::OrdinalIgnoreCase)-ge0){$n++}};$n}
function FindBackup([string]$name,[scriptblock]$ok){$r=Join-Path $Root 'data\update_backups';if(-not(Test-Path $r)){return $null};$x=@(Get-ChildItem $r -Recurse -File -Filter $name -ErrorAction SilentlyContinue|Where-Object{&$ok $_.FullName}|Sort-Object FullName);if($x.Count){$x[0].FullName}else{$null}}
function FindCurrentOrBackup([string]$name){$cur=Join-Path $Root $name;if((Test-Path $cur)-and(ParseOk $cur)){return $cur};return FindBackup $name {param($p)(ParseOk $p)}}

$log=$null
try{
 if(-not(Test-Path $Root)){throw "Не найдена рабочая папка Domlight: $Root"}
 $data=Join-Path $Root 'data';if(-not(Test-Path $data)){throw "Не найдена data в $Root"}
 $stamp=Get-Date -Format 'yyyyMMdd_HHmmss';$log=Join-Path $data ('recovery_v141_'+$stamp+'.log');"START v141 recovery $((Get-Date).ToString('s'))"|Set-Content $log -Encoding UTF8
 $stage=Join-Path $data ('recovery_stage\'+$stamp);$safe=Join-Path $data ('recovery_safety\'+$stamp);New-Item -ItemType Directory -Force -Path $stage,$safe|Out-Null
 $pins=@(
  @('AccountState.ps1','v106','0521a6bf852a201df5cf0986650939a52fa34c61'),
  @('AccountStatus.ps1','v109','7013dfd669d61603dc161d15692855bd36060422'),
  @('OrganizeDownloadedAccount.ps1','v109','21b465f17fc0632890195d43b2b0081ad65f81be'),
  @('Domlight.ps1','v106','8745cf88f53f0745b388e8f13783fb771c99c642'),
  @('AutoCheck.ps1','v106','3d059b62d4df75d4ca00a634309dfe4c1ac28ade'),
  @('RunAutoCheckHidden.ps1','v140','69178900f9708cbbbcf26b8687b9c4bd6cab4c48'),
  @('ConfigureAutoCheckTask.ps1','v140','c817ffd32f1fa9b42c4569328f0eb23b2a77a54d'),
  @('ENABLE_AUTO_CHECK.bat','v140','f2758ef04388873745843d11c0f83a699da1fa98'),
  @('DISABLE_AUTO_CHECK.bat','v140','eb6e2ca52d0ff92b505457565940cacca58f98aa'),
  @('MENU_DOMLIGHT.ps1','v140','b1b776d660fdb53ae410dac58eb947c63b9f7b64'),
  @('SingleWindowLauncher.ps1','v140','2b28b54b985e4d9aaa00c8f9666a0d516e9f2a5d'),
  @('DomlightLauncher.vbs','v140','e3a7fd209d09fa7274dfb7abbdebaf932e0834ee'),
  @('MeterStatus.ps1','v140','063611850a8b6ba1a96bab3e7cd792179d73b6e1'),
  @('MeterDraftStore.ps1','v140','422bd3c38bfc0479d768229267337a5ff08548e5'),
  @('MeterGridBehavior.ps1','v140','5ef036f27f8a5fb8a040c758ee36a410516edc99')
 )
 foreach($f in $pins){$name=$f[0];$ver=$f[1];$sha=$f[2];$dst=Join-Path $stage $name;$url="https://raw.githubusercontent.com/antjustdevelops/Domlight-Releases/main/files/$ver/$name";Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dst -TimeoutSec 40;if((BlobSha $dst)-ne$sha){throw "SHA mismatch: $name"};if($name.EndsWith('.ps1')-and -not(ParseOk $dst)){throw "Parser error: $name"};"OK pin $name $ver"|Add-Content $log -Encoding UTF8}

 $oldMail=FindBackup 'Mailing.ps1' {param($p)(ParseOk $p)-and(MailScore $p)-ge3};if(-not$oldMail){throw 'Не найден полноценный pre-v135 Mailing.ps1 в data\update_backups'}
 $oldConn=FindBackup 'ConnectionSettings.ps1' {param($p)if(-not(ParseOk $p)){return $false};$t=Get-Content $p -Raw;($t-match'useProxy'-and$t-match'proxyUrl'-and$t-match'proxyUser'-and$t-match'proxyPassword')};if(-not$oldConn){throw 'Не найден pre-v135 ConnectionSettings.ps1 в data\update_backups'}
 $gmailSource=FindCurrentOrBackup 'GmailApi.ps1';if(-not$gmailSource){throw 'Не найден рабочий GmailApi.ps1 ни в установке, ни в update_backups'}
 $recipientsSource=FindCurrentOrBackup 'Recipients.ps1';if(-not$recipientsSource){throw 'Не найден рабочий Recipients.ps1 ни в установке, ни в update_backups'}
 "Legacy Mailing: $oldMail"|Add-Content $log -Encoding UTF8;"Legacy ConnectionSettings: $oldConn"|Add-Content $log -Encoding UTF8;"GmailApi source: $gmailSource"|Add-Content $log -Encoding UTF8;"Recipients source: $recipientsSource"|Add-Content $log -Encoding UTF8

 $managed=@($pins|ForEach-Object{$_[0]})+@('Mailing.ps1','ConnectionSettings.ps1','GmailApi.ps1','Recipients.ps1','UpdateFromGitHub.ps1','SelfCheck.ps1','VERSION.txt');$had=@{}
 foreach($n in $managed){$src=Join-Path $Root $n;$had[$n]=Test-Path $src;if($had[$n]){Copy-Item $src (Join-Path $safe $n) -Force}}
 try{
  foreach($f in $pins){Copy-Item (Join-Path $stage $f[0]) (Join-Path $Root $f[0]) -Force}
  Copy-Item $oldMail (Join-Path $Root 'Mailing.ps1') -Force
  Copy-Item $oldConn (Join-Path $Root 'ConnectionSettings.ps1') -Force
  Copy-Item $gmailSource (Join-Path $Root 'GmailApi.ps1') -Force
  Copy-Item $recipientsSource (Join-Path $Root 'Recipients.ps1') -Force
  $updateStub="Add-Type -AssemblyName System.Windows.Forms`r`n[Windows.Forms.MessageBox]::Show('Обновление временно отключено в v141 RECOVERY CANDIDATE до завершения регрессионного теста.','Domlight Recovery','OK','Information')|Out-Null`r`n";Set-Content (Join-Path $Root 'UpdateFromGitHub.ps1') -Value $updateStub -Encoding UTF8
  Set-Content (Join-Path $Root 'VERSION.txt') -Value 'Domlight v141 RECOVERY CANDIDATE' -Encoding UTF8
  $self=@(
   '$ErrorActionPreference=''Stop''',
   '$Root=Split-Path -Parent $MyInvocation.MyCommand.Path',
   '$e=@()',
   'foreach($n in @(''AccountState.ps1'',''AccountStatus.ps1'',''OrganizeDownloadedAccount.ps1'',''Domlight.ps1'',''AutoCheck.ps1'',''RunAutoCheckHidden.ps1'',''Mailing.ps1'',''ConnectionSettings.ps1'',''GmailApi.ps1'',''Recipients.ps1'',''MeterStatus.ps1'',''MeterDraftStore.ps1'',''MeterGridBehavior.ps1'')){if(-not(Test-Path(Join-Path $Root $n))){$e+=''Missing ''+$n}}',
   '$m=Get-Content (Join-Path $Root ''MeterStatus.ps1'') -Raw;if($m-match''Invoke-WebRequest[^\r\n]*?/meter/value'' -or $m-match''Invoke-RestMethod[^\r\n]*?/meter/value''){$e+=''Meter send call enabled''}',
   '$v=(Get-Content (Join-Path $Root ''VERSION.txt'') -Raw).Trim();if($v-ne''Domlight v141 RECOVERY CANDIDATE''){$e+=''Wrong version''}',
   '[pscustomobject]@{Ok=($e.Count-eq0);Errors=$e;Version=$v}|ConvertTo-Json -Depth 4',
   'if($e.Count){exit 1}else{exit 0}'
  );Set-Content (Join-Path $Root 'SelfCheck.ps1') -Value $self -Encoding UTF8
  $out=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'SelfCheck.ps1') 2>&1;$out|Add-Content $log -Encoding UTF8;if($LASTEXITCODE-ne0){throw('SelfCheck failed: '+($out-join' '))}
 }catch{
  foreach($n in $managed){$dst=Join-Path $Root $n;$bak=Join-Path $safe $n;if($had[$n]){if(Test-Path $bak){Copy-Item $bak $dst -Force}}elseif(Test-Path $dst){Remove-Item $dst -Force}}
  throw "Установка автоматически откачена: $($_.Exception.Message)"
 }
 Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue;"SUCCESS"|Add-Content $log -Encoding UTF8
 Info("v141 RECOVERY CANDIDATE установлен.`r`nSelfCheck: OK`r`nSafety backup: $safe`r`nLog: $log")
 exit 0
}catch{if($log){"ERROR: $($_.Exception.Message)"|Add-Content $log -Encoding UTF8};Fail($_.Exception.Message);exit 1}
