Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$ErrorActionPreference='Stop'
$BaseUrl='https://lk.kakdoma.life'
$ReceiptsUrl="$BaseUrl/receipt/index"
$AccountSetUrl="$BaseUrl/account/set"
$MeterUrl="$BaseUrl/meter/index"
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir=Join-Path $Root 'data'
$SessionFile=Join-Path $DataDir 'session.dat'
$ConnectionFile=Join-Path $DataDir 'connection.json'
$AccountsStateFile=Join-Path $DataDir 'accounts_state.json'
$script:AllMeters=@()
$script:Drafts=@{}
$script:Filter='all'

function Unprotect-Text([string]$Text){$b=[Convert]::FromBase64String($Text);$d=[Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[Text.Encoding]::UTF8.GetString($d)}
function Load-WebSession{
 if(-not(Test-Path -LiteralPath $SessionFile)){throw 'Сохранённая сессия Domlight не найдена.'}
 $s=New-Object Microsoft.PowerShell.Commands.WebRequestSession
 $arr=(Unprotect-Text (Get-Content $SessionFile -Raw))|ConvertFrom-Json
 foreach($x in @($arr)){$c=New-Object System.Net.Cookie($x.Name,$x.Value,$x.Path,$x.Domain);$s.Cookies.Add($c)}
 $s
}
function Get-ProxyArgs{
 $a=@{};if(-not(Test-Path $ConnectionFile)){return $a}
 try{$cfg=Get-Content $ConnectionFile -Raw|ConvertFrom-Json;if(-not[bool]$cfg.useProxy){return $a};if([string]::IsNullOrWhiteSpace([string]$cfg.proxyUrl)){return $a};$a['Proxy']=[string]$cfg.proxyUrl;$a['ProxyUseDefaultCredentials']=$false;if(-not[string]::IsNullOrWhiteSpace([string]$cfg.proxyUser)){$sec=ConvertTo-SecureString ([string]$cfg.proxyPassword) -AsPlainText -Force;$a['ProxyCredential']=New-Object System.Management.Automation.PSCredential ([string]$cfg.proxyUser,$sec)}}catch{};$a
}
function Invoke-Get([string]$Url,$Session){$p=Get-ProxyArgs;Invoke-WebRequest -Uri $Url -WebSession $Session -UseBasicParsing -TimeoutSec 40 @p -Headers @{'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0';'Accept-Language'='ru-RU,ru;q=0.9'}}
function Get-Csrf([string]$Html){
 $m=[regex]::Match($Html,'<meta[^>]+name=["'']csrf-token["''][^>]+content=["'']([^"'']+)["'']','IgnoreCase');if($m.Success){return[Net.WebUtility]::HtmlDecode($m.Groups[1].Value)}
 $m=[regex]::Match($Html,'<input[^>]+name=["'']_csrf-lk["''][^>]+value=["'']([^"'']+)["'']','IgnoreCase');if($m.Success){return[Net.WebUtility]::HtmlDecode($m.Groups[1].Value)}
 throw 'Не найден CSRF-токен Домлайта.'
}
function Parse-Accounts([string]$Html){
 $r=@();$seen=@{};foreach($f in [regex]::Matches($Html,'<form[^>]+action=["'']/account/set["''][\s\S]*?</form>','IgnoreCase')){$am=[regex]::Match($f.Value,'<input[^>]+name=["'']account["''][^>]+value=["'']([^"'']+)["'']','IgnoreCase');$cm=[regex]::Match($f.Value,'<input[^>]+name=["'']company["''][^>]+value=["'']([^"'']+)["'']','IgnoreCase');if($am.Success-and$cm.Success){$a=[Net.WebUtility]::HtmlDecode($am.Groups[1].Value);$c=[Net.WebUtility]::HtmlDecode($cm.Groups[1].Value);$k="$c|$a";if(-not$seen.ContainsKey($k)){$seen[$k]=$true;$r+=[pscustomobject]@{Account=$a;Company=$c}}}};$r
}
function Load-Details{
 $m=@{};if(-not(Test-Path $AccountsStateFile)){return$m};try{$items=Get-Content $AccountsStateFile -Raw|ConvertFrom-Json;foreach($i in @($items)){$a=([string]$i.Account).Trim();if($a){$m[$a]=[pscustomobject]@{Address=([string]$i.Address).Trim();Apartment=([string]$i.Apartment).Trim();Excluded=[bool]$i.Excluded}}}}catch{};$m
}
function Switch-Account($Session,[string]$Company,[string]$Account){
 $html=(Invoke-Get $ReceiptsUrl $Session).Content;$csrf=Get-Csrf $html;$body='_csrf-lk='+[uri]::EscapeDataString($csrf)+'&company='+[uri]::EscapeDataString($Company)+'&account='+[uri]::EscapeDataString($Account);$p=Get-ProxyArgs
 try{Invoke-WebRequest -Uri $AccountSetUrl -Method POST -WebSession $Session -UseBasicParsing -TimeoutSec 40 @p -Headers @{'Referer'=$ReceiptsUrl;'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:154.0) Gecko/20100101 Firefox/154.0'} -ContentType 'application/x-www-form-urlencoded' -Body $body|Out-Null}catch{$code=$null;try{$code=[int]$_.Exception.Response.StatusCode}catch{};if($code-ne302){throw}}
}
function Clean([string]$h){(([Net.WebUtility]::HtmlDecode(($h-replace'<[^>]+>',' ')))-replace'\s+',' ').Trim()}
function Attr([string]$tag,[string]$name){$m=[regex]::Match($tag,'(?is)(?:^|\s)'+[regex]::Escape($name)+'\s*=\s*["'']([^"'']*)["'']');if($m.Success){[Net.WebUtility]::HtmlDecode($m.Groups[1].Value)}else{''}}
function MonthStatus([string]$d){if(-not$d){return'Не передано'};$x=[datetime]::MinValue;if(-not[datetime]::TryParseExact($d,'dd.MM.yyyy',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$x)){return'Дата неизвестна'};$n=Get-Date;if($x.Year-eq$n.Year-and$x.Month-eq$n.Month){'Передано'}else{'Не передано'}}
function Short-Address([string]$a,[string]$apt){
 if(-not$a){if($apt){return'кв. '+$apt};return''};$p=@($a.Split(',')|%{$_.Trim()}|?{$_});$idx=-1;for($i=0;$i-lt$p.Count;$i++){if($p[$i]-match'(?i)(улиц|\bул\.?\b|бульвар|\bб-р\b|проспект|\bпр-т\b|шоссе|переулок|проезд|набережн)'){$idx=$i;break}};if($idx-ge0){return($p[$idx..($p.Count-1)]-join', ')};$keep=@($p|?{$_-notmatch'^\d{6}$'-and$_-notmatch'(?i)^Москва$'-and$_-notmatch'(?i)вн\.тер'-and$_-notmatch'(?i)муниципальн.*округ'});if($keep.Count){$keep-join', '}else{$a}
}
function Parse-Meters([string]$Html,[string]$Account,[string]$Address){
 $s=$Html.IndexOf('id="tab_meter_all"');if($s-lt0){$s=$Html.IndexOf("id='tab_meter_all'")};$e=$Html.IndexOf('id="tab_meter_water"');if($e-lt0){$e=$Html.IndexOf("id='tab_meter_water'")};if($s-ge0-and$e-gt$s){$scope=$Html.Substring($s,$e-$s)}else{$scope=$Html}
 $pat='<div class="card mb-5 p-8">';$pos=New-Object System.Collections.Generic.List[int];$from=0;while($true){$p=$scope.IndexOf($pat,$from,[StringComparison]::OrdinalIgnoreCase);if($p-lt0){break};$pos.Add($p);$from=$p+$pat.Length}
 $r=@();$seen=@{};for($i=0;$i-lt$pos.Count;$i++){$st=$pos[$i];$en=if($i+1-lt$pos.Count){$pos[$i+1]}else{$scope.Length};$card=$scope.Substring($st,$en-$st);$im=[regex]::Match($card,'<input[^>]+class=["''][^"'']*meter-input[^"'']*["''][^>]*>','IgnoreCase');if(-not$im.Success){continue};$tag=$im.Value;$id=Attr $tag 'data-id';if(-not$id-or$seen.ContainsKey($id)){continue};$seen[$id]=$true;$hm=[regex]::Match($card,'(?is)<h2[^>]*>(.*?)</h2>');$head=if($hm.Success){Clean $hm.Groups[1].Value}else{''};$type=$head;$num='';$nm=[regex]::Match($head,'№\s*(.+)$');if($nm.Success){$num=$nm.Groups[1].Value.Trim();$type=$head.Substring(0,$nm.Index).Trim()};$date='';$dm=[regex]::Match($card,'Передавали\s+(\d{2}\.\d{2}\.\d{4})','IgnoreCase');if($dm.Success){$date=$dm.Groups[1].Value};$ver='';$vm=[regex]::Match($card,'title=["'']Поверка:\s*([^"'']*)["'']','IgnoreCase');if($vm.Success){$ver=[Net.WebUtility]::HtmlDecode($vm.Groups[1].Value)};$r+=[pscustomobject]@{Account=$Account;Address=$Address;MeterId=$id;Type=$type;Number=$num;LastValue=(Attr $tag 'value');Unit=(Attr $tag 'data-unit');LastDate=$date;MonthStatus=(MonthStatus $date);Verification=$ver}};$r
}
function Object-Rows{
 $r=@();foreach($g in @($script:AllMeters|Group-Object Account)){$m=@($g.Group);$pending=@($m|?{$_.MonthStatus-ne'Передано'}).Count;$ready=0;foreach($x in $m){$k=$x.Account+'|'+$x.MeterId;if($script:Drafts.ContainsKey($k)-and$script:Drafts[$k].Selected-and$script:Drafts[$k].Value){$ready++}};$r+=[pscustomobject]@{Address=$m[0].Address;Account=$g.Name;MeterCount=$m.Count;PendingCount=$pending;Status=$(if($pending-eq0){'Всё передано'}else{'Нужно передать: '+$pending});Ready=$ready}};$r
}

$form=New-Object Windows.Forms.Form;$form.Text='Счётчики / показания — объекты';$form.StartPosition='CenterScreen';$form.ClientSize=New-Object Drawing.Size(1180,720);$form.MinimumSize=New-Object Drawing.Size(900,520);$form.Font=New-Object Drawing.Font('Segoe UI',10);$form.KeyPreview=$true
$title=New-Object Windows.Forms.Label;$title.Text='Счётчики / показания';$title.Location=New-Object Drawing.Point(20,15);$title.Size=New-Object Drawing.Size(450,34);$title.Font=New-Object Drawing.Font('Segoe UI Semibold',16);$form.Controls.Add($title)
$summary=New-Object Windows.Forms.Label;$summary.Text='Загрузка данных с портала...';$summary.Location=New-Object Drawing.Point(22,51);$summary.Size=New-Object Drawing.Size(1100,25);$summary.ForeColor=[Drawing.Color]::DimGray;$form.Controls.Add($summary)
$searchLabel=New-Object Windows.Forms.Label;$searchLabel.Text='Поиск:';$searchLabel.Location=New-Object Drawing.Point(20,88);$searchLabel.Size=New-Object Drawing.Size(55,24);$form.Controls.Add($searchLabel)
$txt=New-Object Windows.Forms.TextBox;$txt.Location=New-Object Drawing.Point(75,84);$txt.Size=New-Object Drawing.Size(305,28);$form.Controls.Add($txt)
$all=New-Object Windows.Forms.Button;$all.Text='Все';$all.Location=New-Object Drawing.Point(400,82);$all.Size=New-Object Drawing.Size(90,32);$form.Controls.Add($all)
$need=New-Object Windows.Forms.Button;$need.Text='Нужно передать';$need.Location=New-Object Drawing.Point(500,82);$need.Size=New-Object Drawing.Size(140,32);$form.Controls.Add($need)
$done=New-Object Windows.Forms.Button;$done.Text='Передано';$done.Location=New-Object Drawing.Point(650,82);$done.Size=New-Object Drawing.Size(110,32);$form.Controls.Add($done)
$grid=New-Object Windows.Forms.DataGridView;$grid.Location=New-Object Drawing.Point(20,126);$grid.Size=New-Object Drawing.Size(1140,510);$grid.Anchor='Top,Bottom,Left,Right';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.AutoGenerateColumns=$false;$grid.BackgroundColor=[Drawing.Color]::White;$form.Controls.Add($grid)
foreach($s in @(@{N='Address';H='Объект';W=430},@{N='Account';H='Лицевой счёт';W=145},@{N='MeterCount';H='Счётчиков';W=85},@{N='Status';H='Статус месяца';W=165},@{N='Ready';H='Готово к отправке';W=125})){$c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$s.N;$c.DataPropertyName=$s.N;$c.HeaderText=$s.H;$c.Width=$s.W;if($s.N-eq'Address'){$c.AutoSizeMode='Fill';$c.MinimumWidth=330};[void]$grid.Columns.Add($c)}
$open=New-Object Windows.Forms.Button;$open.Text='Открыть объект';$open.Size=New-Object Drawing.Size(160,38);$open.Location=New-Object Drawing.Point(1000,650);$open.Anchor='Bottom,Right';$form.Controls.Add($open)

function Refresh-Grid{$q=$txt.Text.Trim().ToLowerInvariant();$items=@(Object-Rows|?{$ok=switch($script:Filter){'need'{$_.PendingCount-gt0};'done'{$_.PendingCount-eq0};default{$true}};$sq=[string]::IsNullOrWhiteSpace($q)-or$_.Address.ToLowerInvariant().Contains($q)-or$_.Account.ToLowerInvariant().Contains($q);$ok-and$sq});$grid.DataSource=$null;$grid.DataSource=$items}
function Show-Object([string]$Account){
 $meters=@($script:AllMeters|?{$_.Account-eq$Account});if(-not$meters){return};$d=New-Object Windows.Forms.Form;$d.Text='Показания — '+$meters[0].Address;$d.StartPosition='CenterParent';$d.ClientSize=New-Object Drawing.Size(1040,500);$d.MinimumSize=New-Object Drawing.Size(900,430);$d.Font=New-Object Drawing.Font('Segoe UI',10);$d.KeyPreview=$true
 $h=New-Object Windows.Forms.Label;$h.Text=$meters[0].Address;$h.Location=New-Object Drawing.Point(18,15);$h.Size=New-Object Drawing.Size(980,30);$h.Font=New-Object Drawing.Font('Segoe UI Semibold',15);$d.Controls.Add($h)
 $l=New-Object Windows.Forms.Label;$l.Text='Лицевой счёт: '+$Account+'   •   Передача на портал пока отключена';$l.Location=New-Object Drawing.Point(20,48);$l.Size=New-Object Drawing.Size(950,24);$l.ForeColor=[Drawing.Color]::DimGray;$d.Controls.Add($l)
 $g=New-Object Windows.Forms.DataGridView;$g.Location=New-Object Drawing.Point(18,82);$g.Size=New-Object Drawing.Size(1004,340);$g.Anchor='Top,Bottom,Left,Right';$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.RowHeadersVisible=$false;$g.AutoGenerateColumns=$false;$g.SelectionMode='CellSelect';$g.MultiSelect=$false;$d.Controls.Add($g)
 foreach($z in @(@{T='check';N='Selected';H='Передать';W=75},@{T='text';N='Type';H='Счётчик';W=135},@{T='text';N='Number';H='№ прибора';W=135},@{T='text';N='LastValue';H='Последнее';W=90},@{T='text';N='Unit';H='Ед.';W=55},@{T='text';N='LastDate';H='Передавали';W=100},@{T='text';N='MonthStatus';H='Статус';W=105},@{T='text';N='NewValue';H='Новое показание';W=120},@{T='text';N='Verification';H='Поверка';W=120})){if($z.T-eq'check'){$c=New-Object Windows.Forms.DataGridViewCheckBoxColumn}else{$c=New-Object Windows.Forms.DataGridViewTextBoxColumn};$c.Name=$z.N;$c.DataPropertyName=$z.N;$c.HeaderText=$z.H;$c.Width=$z.W;if($z.N-notin@('Selected','NewValue')){$c.ReadOnly=$true};[void]$g.Columns.Add($c)}
 $data=New-Object System.Collections.ArrayList;foreach($m in $meters){$k=$m.Account+'|'+$m.MeterId;$sel=$false;$nv='';if($script:Drafts.ContainsKey($k)){$sel=[bool]$script:Drafts[$k].Selected;$nv=[string]$script:Drafts[$k].Value};[void]$data.Add([pscustomobject]@{MeterId=$m.MeterId;Selected=$sel;Type=$m.Type;Number=$m.Number;LastValue=$m.LastValue;Unit=$m.Unit;LastDate=$m.LastDate;MonthStatus=$m.MonthStatus;NewValue=$nv;Verification=$m.Verification})};$g.DataSource=$data
 $g.Add_CellBeginEdit({param($sender,$e);$r=$sender.Rows[$e.RowIndex];if([string]$r.Cells['MonthStatus'].Value-eq'Передано'-and$sender.Columns[$e.ColumnIndex].Name-in@('Selected','NewValue')){$e.Cancel=$true}})
 $save=New-Object Windows.Forms.Button;$save.Text='Сохранить черновик';$save.Size=New-Object Drawing.Size(170,36);$save.Location=New-Object Drawing.Point(650,440);$save.Anchor='Bottom,Right';$d.Controls.Add($save)
 $close=New-Object Windows.Forms.Button;$close.Text='Закрыть';$close.Size=New-Object Drawing.Size(120,36);$close.Location=New-Object Drawing.Point(835,440);$close.Anchor='Bottom,Right';$d.Controls.Add($close)
 $save.Add_Click({$g.EndEdit();foreach($r in $g.Rows){$obj=$data[$r.Index];$k=$Account+'|'+[string]$obj.MeterId;$script:Drafts[$k]=[pscustomobject]@{Selected=[bool]$r.Cells['Selected'].Value;Value=[string]$r.Cells['NewValue'].Value}};$d.Close()});$close.Add_Click({$d.Close()});$d.Add_KeyDown({if($_.KeyCode-eq[Windows.Forms.Keys]::Escape){$d.Close()}});[void]$d.ShowDialog($form)
}
$all.Add_Click({$script:Filter='all';Refresh-Grid});$need.Add_Click({$script:Filter='need';Refresh-Grid});$done.Add_Click({$script:Filter='done';Refresh-Grid});$txt.Add_TextChanged({Refresh-Grid})
$openSelected={if($grid.SelectedRows.Count-eq0){return};$a=[string]$grid.SelectedRows[0].Cells['Account'].Value;if($a){Show-Object $a;Refresh-Grid}};$open.Add_Click({&$openSelected});$grid.Add_CellDoubleClick({param($sender,$e);if($e.RowIndex-ge0){$sender.Rows[$e.RowIndex].Selected=$true;&$openSelected}})
$form.Add_Shown({try{$session=Load-WebSession;$page=Invoke-Get $ReceiptsUrl $session;$accounts=@(Parse-Accounts([string]$page.Content));if($accounts.Count-eq0){throw'Не удалось получить лицевые счета с портала.'};$details=Load-Details;$meters=New-Object System.Collections.ArrayList;$checked=0;foreach($a in $accounts){if($details.ContainsKey([string]$a.Account)-and[bool]$details[[string]$a.Account].Excluded){continue};$checked++;$summary.Text="Читаю объекты: $checked из $($accounts.Count) — ЛС $($a.Account)";[Windows.Forms.Application]::DoEvents();Switch-Account $session ([string]$a.Company) ([string]$a.Account);$mp=Invoke-Get $MeterUrl $session;$full='';$apt='';if($details.ContainsKey([string]$a.Account)){$full=[string]$details[[string]$a.Account].Address;$apt=[string]$details[[string]$a.Account].Apartment};$short=Short-Address $full $apt;foreach($r in @(Parse-Meters([string]$mp.Content)([string]$a.Account)$short)){[void]$meters.Add($r)}};$script:AllMeters=@($meters);Refresh-Grid;$objects=@(Object-Rows);$n=@($objects|?{$_.PendingCount-gt0}).Count;$ok=@($objects|?{$_.PendingCount-eq0}).Count;$summary.Text="Объектов: $($objects.Count)   •   Нужно передать: $n   •   Передано: $ok   •   Передача на портал пока отключена";$summary.ForeColor=[Drawing.Color]::DarkGreen}catch{$summary.Text='Ошибка: '+$_.Exception.Message;$summary.ForeColor=[Drawing.Color]::DarkRed;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight — счётчики','OK','Error')|Out-Null}})
$form.Add_KeyDown({if($_.KeyCode-eq[Windows.Forms.Keys]::Escape){$form.Close()}})
[void]$form.ShowDialog()
