Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference='Stop'

$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir=Join-Path $Root 'data'
$ReceiptsDir=Join-Path $DataDir 'receipts'
$OutboxDir=Join-Path $DataDir 'outbox'
New-Item -ItemType Directory -Force -Path $ReceiptsDir,$OutboxDir | Out-Null

function Get-ReceiptRows {
    $rows=@()
    foreach($f in @(Get-ChildItem -LiteralPath $ReceiptsDir -Recurse -Filter *.pdf -File -ErrorAction SilentlyContinue | Sort-Object FullName)){
        $type='Другое'
        if($f.Name -match '(?i)_ЖКХ_'){$type='ЖКХ'}elseif($f.Name -match '(?i)_Капремонт_'){$type='Капремонт'}
        $account='';$apartment=''
        $m=[regex]::Match($f.Name,'(?i)_кв_(?<apt>[^_]+)_ЛС_(?<acc>\d+)')
        if($m.Success){$apartment=$m.Groups['apt'].Value;$account=$m.Groups['acc'].Value}
        $rows += [pscustomobject]@{Selected=$false;Type=$type;Account=$account;Apartment=$apartment;Name=$f.Name;FullPath=$f.FullName}
    }
    return @($rows)
}

function Prepare-Outbox([string]$Mode){
    Get-ChildItem -LiteralPath $OutboxDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $source=@($script:Rows)
    if($Mode -eq 'ЖКХ'){$source=@($source|Where-Object{$_.Type -eq 'ЖКХ'})}
    elseif($Mode -eq 'Капремонт'){$source=@($source|Where-Object{$_.Type -eq 'Капремонт'})}
    foreach($x in $source){
        $dest=Join-Path $OutboxDir $x.Name
        Copy-Item -LiteralPath $x.FullPath -Destination $dest -Force
    }
    [Windows.Forms.MessageBox]::Show("Подготовлено файлов: $($source.Count)`r`n`r`n$OutboxDir",'Domlight','OK','Information')|Out-Null
    Start-Process explorer.exe "`"$OutboxDir`""
}

$form=New-Object Windows.Forms.Form
$form.Text='Рассылка квитанций'
$form.StartPosition='CenterScreen'
$form.ClientSize=New-Object Drawing.Size(1180,650)
$form.MinimumSize=New-Object Drawing.Size(900,500)
$form.Font=New-Object Drawing.Font('Segoe UI',10)

$title=New-Object Windows.Forms.Label;$title.Text='Подготовка квитанций для отправки';$title.Location=New-Object Drawing.Point(20,16);$title.Size=New-Object Drawing.Size(650,34);$title.Font=New-Object Drawing.Font('Segoe UI Semibold',16);$form.Controls.Add($title)
$hint=New-Object Windows.Forms.Label;$hint.Text='Выберите режим. Domlight создаст копии в data\outbox; исходный архив не изменяется.';$hint.Location=New-Object Drawing.Point(22,52);$hint.Size=New-Object Drawing.Size(1100,26);$hint.ForeColor=[Drawing.Color]::DimGray;$form.Controls.Add($hint)

$btnZhkh=New-Object Windows.Forms.Button;$btnZhkh.Text='Подготовить ЖКХ';$btnZhkh.Location=New-Object Drawing.Point(20,88);$btnZhkh.Size=New-Object Drawing.Size(220,42);$form.Controls.Add($btnZhkh)
$btnCap=New-Object Windows.Forms.Button;$btnCap.Text='Подготовить капремонт';$btnCap.Location=New-Object Drawing.Point(250,88);$btnCap.Size=New-Object Drawing.Size(240,42);$form.Controls.Add($btnCap)
$btnAll=New-Object Windows.Forms.Button;$btnAll.Text='Подготовить все квитанции';$btnAll.Location=New-Object Drawing.Point(500,88);$btnAll.Size=New-Object Drawing.Size(250,42);$form.Controls.Add($btnAll)
$btnReset=New-Object Windows.Forms.Button;$btnReset.Text='Сбросить подготовленное';$btnReset.Location=New-Object Drawing.Point(760,88);$btnReset.Size=New-Object Drawing.Size(240,42);$form.Controls.Add($btnReset)
$btnFolder=New-Object Windows.Forms.Button;$btnFolder.Text='Открыть outbox';$btnFolder.Location=New-Object Drawing.Point(1010,88);$btnFolder.Size=New-Object Drawing.Size(145,42);$form.Controls.Add($btnFolder)

$grid=New-Object Windows.Forms.DataGridView
$grid.Location=New-Object Drawing.Point(20,145);$grid.Size=New-Object Drawing.Size(1135,450);$grid.Anchor='Top,Bottom,Left,Right';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoGenerateColumns=$false;$grid.SelectionMode='FullRowSelect';$form.Controls.Add($grid)
foreach($spec in @(@('Type','Тип',120),@('Account','Лицевой счёт',150),@('Apartment','Квартира',100),@('Name','Файл',735))){$c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$spec[0];$c.DataPropertyName=$spec[0];$c.HeaderText=$spec[1];$c.Width=[int]$spec[2];if($spec[0]-eq'Name'){$c.AutoSizeMode='Fill'};[void]$grid.Columns.Add($c)}

$script:Rows=@(Get-ReceiptRows)
$grid.DataSource=$script:Rows
$status=New-Object Windows.Forms.Label;$status.Location=New-Object Drawing.Point(20,605);$status.Size=New-Object Drawing.Size(1000,25);$status.Anchor='Bottom,Left,Right';$status.Text="В архиве PDF: $($script:Rows.Count)";$form.Controls.Add($status)
$btnClose=New-Object Windows.Forms.Button;$btnClose.Text='Закрыть';$btnClose.Location=New-Object Drawing.Point(1030,600);$btnClose.Size=New-Object Drawing.Size(125,36);$btnClose.Anchor='Bottom,Right';$form.Controls.Add($btnClose)

$btnZhkh.Add_Click({Prepare-Outbox 'ЖКХ'})
$btnCap.Add_Click({Prepare-Outbox 'Капремонт'})
$btnAll.Add_Click({Prepare-Outbox 'Все'})
$btnReset.Add_Click({Get-ChildItem -LiteralPath $OutboxDir -Force -ErrorAction SilentlyContinue|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue;$status.Text='Подготовленные копии удалены. Архив не изменён.'})
$btnFolder.Add_Click({Start-Process explorer.exe "`"$OutboxDir`""})
$btnClose.Add_Click({$form.Close()})
$form.CancelButton=$btnClose
[void]$form.ShowDialog()
