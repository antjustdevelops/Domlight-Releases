param([Parameter(Mandatory=$true)][string]$Root)
Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference='Stop'
$DomlightFile=Join-Path $Root 'Domlight.ps1'
$DataDir=Join-Path $Root 'data'
$OutFile=Join-Path $DataDir 'meter_discovery_report.txt'
function Abs([string]$h,[string]$from){try{return([Uri]::new([Uri]$from,$h)).AbsoluteUri}catch{return''}}
function Txt([string]$x){if($null-eq$x){return''};(([Net.WebUtility]::HtmlDecode(($x-replace'(?is)<script.*?</script>',' '-replace'(?is)<style.*?</style>',' '-replace'<[^>]+>',' ')))-replace'\s+',' ').Trim()}
function A([string]$attrs,[string]$name){$m=[regex]::Match($attrs,'(?is)(?:^|\s)'+[regex]::Escape($name)+'\s*=\s*["'']([^"'']*)["'']');if($m.Success){return[Net.WebUtility]::HtmlDecode($m.Groups[1].Value)};''}
function R([string]$x){if($null-eq$x){return''};$x=[regex]::Replace($x,'(?i)(csrf|token|authorization|cookie)(\s*[=:]\s*)[^\s&;"'']+','$1$2[REDACTED]');$x=[regex]::Replace($x,'\b\d{10,16}\b','[NUMBER]');$x}
function Add-Snips($lines,[string]$label,[string]$text){
  $hits=[regex]::Matches($text,'(?is).{0,220}(?:/meter/|meter|показан|ajax|\.post\s*\(|fetch\s*\(|XMLHttpRequest|w\d+|Отправить).{0,420}')
  $lines.Add($label)
  if($hits.Count-eq0){$lines.Add('  NONE');return}
  $n=0;foreach($h in $hits){$n++;if($n-gt25){break};$s=(R(($h.Value-replace'\s+',' ').Trim()));$lines.Add(('  [{0}] {1}'-f$n,$s))}
}
try{
 if(-not(Test-Path $DomlightFile)){throw"Domlight.ps1 не найден: $DomlightFile"}
 [Windows.Forms.MessageBox]::Show("Откроется обычный Domlight.`r`nУбедитесь, что статус 'Подключено', затем закройте только это окно.`r`nПосле закрытия будет прочитан JavaScript страницы счётчиков. Ничего отправляться не будет.",'Domlight - диагностика счётчиков','OK','Information')|Out-Null
 . $DomlightFile
 $verify=Invoke-DomlightGet $ReceiptsUrl;if(-not(Is-Authenticated([string]$verify.Content)){throw"Сессия не авторизована."}
 $u="$BaseUrl/meter/index";$r=Invoke-DomlightGet $u;$html=[string]$r.Content;if(-not(Is-Authenticated $html)){throw'Нет авторизации на странице счётчиков.'}
 $lines=New-Object Collections.Generic.List[string]
 $lines.Add('DOMLIGHT METER SUBMIT DISCOVERY - LIVE SESSION - READ ONLY');$lines.Add('Generated: '+(Get-Date -Format'yyyy-MM-dd HH:mm:ss'));$lines.Add('Authenticated session: YES');$lines.Add('URL: '+$u);$lines.Add('No POST/PUT/PATCH/DELETE requests were sent by this discovery stage.');$lines.Add('')
 $lines.Add('VISIBLE METER TEXT:');$lines.Add('  '+(R(Txt $html)));$lines.Add('')
 $lines.Add('INTERACTIVE ELEMENTS:')
 $els=@()
 foreach($m in[regex]::Matches($html,'(?is)<(?<tag>button|a|input)\b(?<attrs>[^>]*)>(?<body>.*?)</(?:button|a)>|<input\b(?<attrs2>[^>]*)>')){
   $tag=$m.Groups['tag'].Value;if([string]::IsNullOrWhiteSpace($tag)){$tag='input';$attrs=$m.Groups['attrs2'].Value}else{$attrs=$m.Groups['attrs'].Value}
   $id=A $attrs'id';$class=A $attrs'class';$onclick=A $attrs'onclick';$href=A $attrs'href';$type=A $attrs'type';$value=A $attrs'value';$text=Txt $m.Groups['body'].Value
   $data=@();foreach($dm in[regex]::Matches($attrs,'(?is)\s(data-[\w-]+)=["'']([^"'']*)["'']')){$data+=($dm.Groups[1].Value+'='+$dm.Groups[2].Value)}
   $all=($tag+' '+$id+' '+$class+' '+$onclick+' '+$href+' '+$type+' '+$value+' '+$text+' '+($data-join' '))
   if($all-match'(?i)meter|показан|отправ|send|submit|value|w\d+|ajax'){$els+=[pscustomobject]@{Tag=$tag;Id=$id;Class=$class;Type=$type;Text=$text;Value=$value;Href=$href;OnClick=$onclick;Data=($data-join'; ')}}
 }
 if($els.Count-eq0){$lines.Add('  NONE')}else{foreach($e in$els){$lines.Add(('  tag={0} id={1} class={2} type={3} text="{4}" value="{5}" href="{6}" onclick="{7}" data="{8}"'-f$e.Tag,$e.Id,$e.Class,$e.Type,(R$e.Text),(R$e.Value),(R$e.Href),(R$e.OnClick),(R$e.Data)))}}
 $lines.Add('')
 Add-Snips $lines 'INLINE SCRIPT / HTML CODE SNIPPETS:' $html
 $lines.Add('');$lines.Add('EXTERNAL JAVASCRIPT:')
 $srcs=@();foreach($sm in[regex]::Matches($html,'(?is)<script\b[^>]*src=["'']([^"'']+)["''][^>]*>')){$src=Abs([Net.WebUtility]::HtmlDecode($sm.Groups[1].Value))$u;if($src){$srcs+=$src}}
 if($srcs.Count-eq0){$lines.Add('  NONE')}else{
   foreach($src in($srcs|Select-Object-Unique)){
     $lines.Add('  SCRIPT: '+(R$src))
     try{if(([Uri]$src).Host-eq([Uri]$BaseUrl).Host){$jr=Invoke-DomlightGet $src;$js=[string]$jr.Content;Add-Snips $lines '    MATCHES:' $js}else{$lines.Add('    skipped external host')}}catch{$lines.Add('    read error: '+$_.Exception.Message)}
   }
 }
 New-Item-ItemType Directory-Force-Path $DataDir|Out-Null;$lines|Set-Content-LiteralPath $OutFile-Encoding UTF8
 [Windows.Forms.MessageBox]::Show("Диагностика JavaScript завершена.`r`nНичего на портал не отправлялось.`r`n`r`nОтчёт:`r`n$OutFile",'Domlight - счётчики','OK','Information')|Out-Null;Start-Process notepad.exe('"'+$OutFile+'"')
}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight - диагностика счётчиков','OK','Error')|Out-Null;exit1}
