Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$StateFile = Join-Path $DataDir 'accounts_state.json'
$ReceiptsDir = Join-Path $DataDir 'receipts'

function Load-State {
  $items=@()
  if (Test-Path $StateFile) {
    try { $items=@(Get-Content $StateFile -Raw | ConvertFrom-Json) } catch { $items=@() }
  }
  $known=@{}
  foreach($x in $items){ if($x.Account){ $known[[string]$x.Account]=$true } }
  if (Test-Path $ReceiptsDir) {
    foreach($folder in @(Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue)) {
      $m=[regex]::Match($folder.Name,'^(?<a>\d{9,20})(?:\s+-\s+.*?(?<apt>[0-9A-Za-zА-Яа-яЁё]+))?$')
      if(-not $m.Success){ continue }
      $account=$m.Groups['a'].Value
      if($known.ContainsKey($account)){ continue }
      $items += [pscustomobject]@{Account=$account;Company='';Apartment=$m.Groups['apt'].Value;Status='active';MissingSuccessCount=0;ManuallyDisabled=$false;FirstSeenAt=$folder.CreationTime.ToString('yyyy-MM-dd HH:mm:ss');LastSeenAt=$folder.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')}
      $known[$account]=$true
    }
  }
  if($items.Count -gt 0){ @($items) | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 }
  return @($items)
}
function Save-State([object[]]$items){ @($items) | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 }
function Status-Text([string]$s,[bool]$manual){ if($manual){return 'Do not track'}; switch($s){'active'{return 'Active'}'missing'{return 'Temporarily missing'}'inactive'{return 'Inactive'}default{return $s}} }

$form=New-Object Windows.Forms.Form
$form.Text='Domlight - accounts'
$form.StartPosition='CenterScreen'
$form.Size=New-Object Drawing.Size(780,500)
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$label=New-Object Windows.Forms.Label
$label.Text='Receipt history is preserved when an account is disabled.'
$label.Location=New-Object Drawing.Point(20,15);$label.Size=New-Object Drawing.Size(720,25);$form.Controls.Add($label)
$grid=New-Object Windows.Forms.DataGridView
$grid.Location=New-Object Drawing.Point(20,50);$grid.Size=New-Object Drawing.Size(720,320);$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.AutoGenerateColumns=$false;$form.Controls.Add($grid)
foreach($spec in @(@('Account','Account',170),@('Apartment','Apartment',110),@('StatusText','Status',170),@('MissingSuccessCount','Consecutive',120),@('LastSeenAt','Last seen on portal',170))){$c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$spec[0];$c.DataPropertyName=$spec[0];$c.HeaderText=$spec[1];$c.Width=[int]$spec[2];[void]$grid.Columns.Add($c)}
function Refresh-Grid {
  $rows=New-Object System.Collections.ArrayList
  foreach($x in @(Load-State)){[void]$rows.Add([pscustomobject]@{Account=[string]$x.Account;Apartment=[string]$x.Apartment;StatusText=(Status-Text ([string]$x.Status) ([bool]$x.ManuallyDisabled));MissingSuccessCount=[int]$x.MissingSuccessCount;LastSeenAt=[string]$x.LastSeenAt})}
  $grid.DataSource=$null;$grid.DataSource=$rows
}
$btnDisable=New-Object Windows.Forms.Button;$btnDisable.Text='Stop tracking';$btnDisable.Location=New-Object Drawing.Point(20,390);$btnDisable.Size=New-Object Drawing.Size(220,42);$form.Controls.Add($btnDisable)
$btnDisable.Add_Click({if($grid.SelectedRows.Count -eq 0){return};$account=[string]$grid.SelectedRows[0].Cells['Account'].Value;$state=@(Load-State);$x=$state|Where-Object{[string]$_.Account -eq $account}|Select-Object -First 1;if(-not $x){return};$x.ManuallyDisabled=$true;$x.Status='inactive';Save-State $state;Refresh-Grid})
$btnEnable=New-Object Windows.Forms.Button;$btnEnable.Text='Resume tracking';$btnEnable.Location=New-Object Drawing.Point(260,390);$btnEnable.Size=New-Object Drawing.Size(220,42);$form.Controls.Add($btnEnable)
$btnEnable.Add_Click({if($grid.SelectedRows.Count -eq 0){return};$account=[string]$grid.SelectedRows[0].Cells['Account'].Value;$state=@(Load-State);$x=$state|Where-Object{[string]$_.Account -eq $account}|Select-Object -First 1;if(-not $x){return};$x.ManuallyDisabled=$false;$x.MissingSuccessCount=0;$x.Status='active';Save-State $state;Refresh-Grid})
$btnClose=New-Object Windows.Forms.Button;$btnClose.Text='Close';$btnClose.Location=New-Object Drawing.Point(500,390);$btnClose.Size=New-Object Drawing.Size(240,42);$form.Controls.Add($btnClose);$btnClose.Add_Click({$form.Close()})
Refresh-Grid
[void]$form.ShowDialog()
