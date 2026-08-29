Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference='Stop'
$BaseUrl='https://lk.kakdoma.life'
$MeterUrl="$BaseUrl/meter/index"
$Root=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Domlight'
$SessionFile=Join-Path $Root 'data\session.dat'
$ConnectionFile=Join-Path $Root 'data\connection.json'
$OutDir=Join-Path $Root 'diagnostics'
function Unprotect-Text([string]$Text){$bytes=[Convert]::FromBase64String($Text);$dec=[Security.Cryptography.ProtectedData]::Unprotect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[Text.Encoding]::UTF8.GetString($dec)}
function Load-WebSession{if(!(Test-Path -LiteralPath $SessionFile)){throw 'Не найдена сохранённая сессия Domlight.'};$s=New-Object Microsoft.PowerShell.Commands.WebRequestSession;$arr=(Unprotect-Text (Get-Content -LiteralPath $SessionFile -Raw))|ConvertFrom-Json;foreach($x in @($arr)){$c=New-Object Net.Cookie($x.Name,$x.Value,$x.Path,$x.Domain);$s.Cookies.Add($c)};return $s}
function Get-ProxyArgs{$a=@{};if(!(Test-Path $ConnectionFile)){return $a};try{$c=Get-Content $ConnectionFile -Raw|ConvertFrom-Json;if([bool]$c.useProxy -and ![string]::IsNullOrWhiteSpace([string]$c.proxyUrl)){$a.Proxy=[string]$c.proxyUrl;$a.ProxyUseDefaultCredentials=$false;if(![string]::IsNullOrWhiteSpace([string]$c.proxyUser)){$sec=ConvertTo-SecureString ([string]$c.proxyPassword) -AsPlainText -Force;$a.ProxyCredential=New-Object Management.Automation.PSCredential([string]$c.proxyUser,$sec)}}}catch{};return $a}
function Attr([string]$Tag,[string]$Name){$m=[regex]::Match($Tag,'(?is)(?:^|\s)'+[regex]::Escape($Name)+'\s*=\s*["'']([^"'']*)["'']');if($m.Success){return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)};''}
function Mask([string]$Name,[string]$Value){if($Name -match '(?i)csrf|token|auth|cookie|session|password|secret'){if([string]::IsNullOrEmpty($Value)){return ''};return '[MASKED len='+$Value.Length+']'};return $Value}
try{
 New-Item -ItemType Directory -Force -Path $OutDir|Out-Null
 $session=Load-WebSession;$proxy=Get-ProxyArgs
 $r=Invoke-WebRequest -Uri $MeterUrl -WebSession $session -UseBasicParsing -TimeoutSec 40 @proxy -Headers @{'User-Agent'='Mozilla/5.0';'Accept-Language'='ru-RU,ru;q=0.9'}
 $html=[string]$r.Content
 if($html -match '(?i)login|войти' -and $html -notmatch '(?i)meter-input'){throw 'Сессия портала, вероятно, не авторизована.'}
 $lines=New-Object Collections.Generic.List[string]
 $lines.Add('DOMLIGHT METER FORM INSPECTOR — READ ONLY');$lines.Add('Generated: '+(Get-Date).ToString('s'));$lines.Add('GET: '+$MeterUrl);$lines.Add('HTTP: '+[int]$r.StatusCode);$lines.Add('HTML length: '+$html.Length);$lines.Add('NO POST / NO DATA CHANGE');$lines.Add('')
 $forms=[regex]::Matches($html,'(?is)<form\b[^>]*>.*?</form>');$lines.Add('FORMS: '+$forms.Count)
 $i=0;foreach($fm in $forms){$i++;$open=[regex]::Match($fm.Value,'(?is)^<form\b[^>]*>').Value;$lines.Add('');$lines.Add('[FORM '+$i+']');$lines.Add('method='+(Attr $open 'method'));$lines.Add('action='+(Attr $open 'action'));$inputs=[regex]::Matches($fm.Value,'(?is)<(?:input|select|textarea)\b[^>]*>');foreach($im in $inputs){$tag=$im.Value;$name=Attr $tag 'name';$type=Attr $tag 'type';$id=Attr $tag 'id';$value=Mask $name (Attr $tag 'value');$dataId=Attr $tag 'data-id';$unit=Attr $tag 'data-unit';$lines.Add((' field name="{0}" type="{1}" id="{2}" value="{3}" data-id="{4}" data-unit="{5}"' -f $name,$type,$id,$value,$dataId,$unit))}}
 $lines.Add('');$lines.Add('METER INPUTS:');foreach($m in [regex]::Matches($html,'(?is)<input\b[^>]*class=["''][^"'']*meter-input[^"'']*["''][^>]*>')){$tag=$m.Value;$lines.Add((' id={0}; name={1}; value={2}; unit={3}' -f (Attr $tag 'data-id'),(Attr $tag 'name'),(Attr $tag 'value'),(Attr $tag 'data-unit')))}
 $lines.Add('');$lines.Add('POSSIBLE ENDPOINTS / JS:');$seen=@{};foreach($m in [regex]::Matches($html,'(?i)(?:url\s*[:=]\s*["'']([^"'']+)["'']|(?:fetch|ajax)\s*\(\s*["'']([^"'']+)["'']|action=["'']([^"'']+)["''])')){$v=@($m.Groups[1].Value,$m.Groups[2].Value,$m.Groups[3].Value)|?{$_}|Select-Object -First 1;if($v -and !$seen.ContainsKey($v)){$seen[$v]=$true;$lines.Add($v)}}
 $lines.Add('');$lines.Add('SCRIPT REFERENCES:');foreach($m in [regex]::Matches($html,'(?is)<script\b[^>]*src=["'']([^"'']+)["''][^>]*>')){$lines.Add([Net.WebUtility]::HtmlDecode($m.Groups[1].Value))}
 $path=Join-Path $OutDir ('meter_form_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.txt');[IO.File]::WriteAllLines($path,$lines,[Text.UTF8Encoding]::new($true));Start-Process explorer.exe -ArgumentList ('/select,"'+$path+'"');[Windows.Forms.MessageBox]::Show("Диагностика завершена.`r`nНичего на портал не отправлялось.`r`n`r`nОтчёт:`r`n$path",'Domlight Meter Inspector','OK','Information')|Out-Null
}catch{[Windows.Forms.MessageBox]::Show("Диагностика остановлена.`r`nНикакие показания не отправлялись.`r`n`r`n$($_.Exception.Message)",'Domlight Meter Inspector','OK','Error')|Out-Null;exit 1}
