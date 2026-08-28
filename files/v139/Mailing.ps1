param([switch]$SmokeTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference='Stop'

$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir=Join-Path $Root 'data'
$ReceiptsDir=Join-Path $DataDir 'receipts'
$OutboxDir=Join-Path $DataDir 'outbox'
New-Item -ItemType Directory -Force -Path $ReceiptsDir,$OutboxDir | Out-Null
$script:Rows=@()

function Get-ReceiptRows {
    $rows=New-Object System.Collections.ArrayList
    foreach($f in @(Get-ChildItem -LiteralPath $ReceiptsDir -Recurse -Filter *.pdf -File -ErrorAction SilentlyContinue | Sort-Object FullName)){
        $type='Другое'
        if($f.Name -match '(?i)_ЖКХ_' -or $f.DirectoryName -match '(?i)(^|\\)ЖКХ(?:\s|\-|$)'){$type='ЖКХ'}
        elseif($f.Name -match '(?i)_Капремонт_' -or $f.DirectoryName -match '(?i)(^|\\)Капремонт(?:\s|\-|$)'){$type='Капремонт'}

        $account='';$apartment=''
        $m=[regex]::Match($f.Name,'(?i)_кв_(?<apt>[^_]+)_ЛС_(?<acc>\d+)')
        if($m.Success){
            $apartment=$m.Groups['apt'].Value
            $account=$m.Groups['acc'].Value
        } else {
            $pm=[regex]::Match($f.FullName,'(?i)\\(?<acc>\d{9,20})\s+-\s+кв\.\s*(?<apt>[^\\]+)\\')
            if($pm.Success){$account=$pm.Groups['acc'].Value;$apartment=$pm.Groups['apt'].Value}
        }
        [void]$rows.Add([pscustomobject]@{Type=$type;Account=$account;Apartment=$apartment;Name=$f.Name;FullPath=$f.FullName})
    }
    return @($rows)
}

function Prepare-Outbox([string]$Mode){
    try {
        Get-ChildItem -LiteralPath $OutboxDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $source=@($script:Rows)
        if($Mode -eq 'ЖКХ'){$source=@($source|Where-Object{$_.Type -eq 'ЖКХ'})}
        elseif($Mode -eq 'Капремонт'){$source=@($source|Where-Object{$_.Type -eq 'Капремонт'})}
        foreach($x in $source){
            $dest=Join-Path $OutboxDir $x.Name
            if(Test-Path -LiteralPath $dest){
                $base=[IO.Path]::GetFileNameWithoutExtension($x.Name)
                $ext=[IO.Path]::GetExtension($x.Name)
                $suffix=2
                do{$dest=Join-Path $OutboxDir ($base+'_'+$suffix+$ext);$suffix++}while(Test-Path -LiteralPath $dest)
            }
            Copy-Item -LiteralPath $x.FullPath -Destination $dest -Force
        }
        [Windows.Forms.MessageBox]::Show("Подготовлено файлов: $($source.Count)`r`n`r`n$OutboxDir",'Domlight','OK','Information')|Out-Null
        Start-Process explorer.exe "`"$OutboxDir`""
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight','OK','Error')|Out-Null
    }
}

$form=New-Object Windows.Forms.Form
$form.Text='Рассылка квитанций'
$form.StartPosition='CenterScreen'
$form.ClientSize=[Drawing.Size]::new(1180,650)
$form.MinimumSize=[Drawing.Size]::new(900,500)
$form.Font=[Drawing.Font]::new('Segoe UI',10)

$title=New-Object Windows.Forms.Label;$title.Text='Подготовка квитанций для отправки';$title.Location=[Drawing.Point]::new(20,16);$title.Size=[Drawing.Size]::new(650,34);$title.Font=[Drawing.Font]::new('Segoe UI Semibold',16);$form.Controls.Add($title)
$hint=New-Object Windows.Forms.Label;$hint.Text='Выберите режим. Domlight создаст копии в data\outbox; исходный архив не изменяется.';$hint.Location=[Drawing.Point]::new(22,52);$hint.Size=[Drawing.Size]::new(1100,26);$hint.ForeColor=[Drawing.Color]::DimGray;$form.Controls.Add($hint)

$btnZhkh=New-Object Windows.Forms.Button;$btnZhkh.Text='Подготовить ЖКХ';$btnZhkh.Location=[Drawing.Point]::new(20,88);$btnZhkh.Size=[Drawing.Size]::new(220,42);$form.Controls.Add($btnZhkh)
$btnCap=New-Object Windows.Forms.Button;$btnCap.Text='Подготовить капремонт';$btnCap.Location=[Drawing.Point]::new(250,88);$btnCap.Size=[Drawing.Size]::new(240,42);$form.Controls.Add($btnCap)
$btnAll=New-Object Windows.Forms.Button;$btnAll.Text='Подготовить все квитанции';$btnAll.Location=[Drawing.Point]::new(500,88);$btnAll.Size=[Drawing.Size]::new(250,42);$form.Controls.Add($btnAll)
$btnReset=New-Object Windows.Forms.Button;$btnReset.Text='Сбросить подготовленное';$btnReset.Location=[Drawing.Point]::new(760,88);$btnReset.Size=[Drawing.Size]::new(240,42);$form.Controls.Add($btnReset)
$btnFolder=New-Object Windows.Forms.Button;$btnFolder.Text='Открыть outbox';$btnFolder.Location=[Drawing.Point]::new(1010,88);$btnFolder.Size=[Drawing.Size]::new(145,42);$form.Controls.Add($btnFolder)

$grid=New-Object Windows.Forms.DataGridView
$grid.Location=[Drawing.Point]::new(20,145);$grid.Size=[Drawing.Size]::new(1135,450);$grid.Anchor='Top,Bottom,Left,Right';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoGenerateColumns=$false;$grid.SelectionMode='FullRowSelect';$grid.BackgroundColor=[Drawing.Color]::White;$form.Controls.Add($grid)
foreach($spec in @(@('Type','Тип',120),@('Account','Лицевой счёт',150),@('Apartment','Квартира',100),@('Name','Файл',735))){
    $c=New-Object Windows.Forms.DataGridViewTextBoxColumn
    $c.Name=[string]$spec[0];$c.HeaderText=[string]$spec[1];$c.Width=[int]$spec[2]
    if($spec[0]-eq'Name'){$c.AutoSizeMode='Fill'}
    [void]$grid.Columns.Add($c)
}

$status=New-Object Windows.Forms.Label;$status.Location=[Drawing.Point]::new(20,605);$status.Size=[Drawing.Size]::new(1000,25);$status.Anchor='Bottom,Left,Right';$status.Text='Загрузка архива...';$form.Controls.Add($status)
$btnClose=New-Object Windows.Forms.Button;$btnClose.Text='Закрыть';$btnClose.Location=[Drawing.Point]::new(1030,600);$btnClose.Size=[Drawing.Size]::new(125,36);$btnClose.Anchor='Bottom,Right';$form.Controls.Add($btnClose)

function Set-PrepareButtons([bool]$Enabled){$btnZhkh.Enabled=$Enabled;$btnCap.Enabled=$Enabled;$btnAll.Enabled=$Enabled}
function Load-ArchiveIntoGrid {
    Set-PrepareButtons $false
    $status.Text='Загрузка архива...'
    [Windows.Forms.Application]::DoEvents()
    try {
        $script:Rows=@(Get-ReceiptRows)
        $grid.Rows.Clear()
        foreach($x in $script:Rows){[void]$grid.Rows.Add($x.Type,$x.Account,$x.Apartment,$x.Name)}
        $zhkh=@($script:Rows|Where-Object{$_.Type -eq 'ЖКХ'}).Count
        $cap=@($script:Rows|Where-Object{$_.Type -eq 'Капремонт'}).Count
        $status.Text="В архиве PDF: $($script:Rows.Count)  •  ЖКХ: $zhkh  •  Капремонт: $cap"
        Set-PrepareButtons $true
    } catch {
        $status.Text='Ошибка чтения архива'
        if($SmokeTest){throw}
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight','OK','Error')|Out-Null
    }
}

$btnZhkh.Add_Click({Prepare-Outbox 'ЖКХ'})
$btnCap.Add_Click({Prepare-Outbox 'Капремонт'})
$btnAll.Add_Click({Prepare-Outbox 'Все'})
$btnReset.Add_Click({Get-ChildItem -LiteralPath $OutboxDir -Force -ErrorAction SilentlyContinue|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue;$status.Text='Подготовленные копии удалены. Архив не изменён.'})
$btnFolder.Add_Click({Start-Process explorer.exe "`"$OutboxDir`""})
$btnClose.Add_Click({$form.Close()})
$form.CancelButton=$btnClose
$form.Add_Shown({Load-ArchiveIntoGrid})

if($SmokeTest){
    Load-ArchiveIntoGrid
    $pdfCount=@(Get-ChildItem -LiteralPath $ReceiptsDir -Recurse -Filter *.pdf -File -ErrorAction SilentlyContinue).Count
    if($script:Rows.Count -ne $pdfCount){throw "Mailing row model mismatch: PDF=$pdfCount rows=$($script:Rows.Count)"}
    if($grid.Rows.Count -ne $script:Rows.Count){throw "Mailing grid mismatch: model=$($script:Rows.Count) grid=$($grid.Rows.Count)"}
    Write-Output ('SMOKE_OK Mailing rows='+$grid.Rows.Count)
    $form.Dispose()
    exit 0
}
[void]$form.ShowDialog()
