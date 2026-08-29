Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference='Stop'

$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir=Join-Path $Root 'data'
$StateFile=Join-Path $DataDir 'accounts_state.json'
$ReceiptsDir=Join-Path $DataDir 'receipts'
$Module=Join-Path $Root 'AccountState.ps1'
if(-not(Test-Path $Module)){[Windows.Forms.MessageBox]::Show('AccountState.ps1 not found.','Domlight','OK','Error')|Out-Null;exit 1}
. $Module

# Single instance for the Accounts window. A repeated click signals the already-open window.
$mutexName='Local\Domlight_AccountStatus_SingleInstance'
$focusEventName='Local\Domlight_AccountStatus_Focus'
$createdNew=$false
$mutex=New-Object System.Threading.Mutex($true,$mutexName,[ref]$createdNew)
if(-not $createdNew){
    try{
        $existingEvent=[System.Threading.EventWaitHandle]::OpenExisting($focusEventName)
        [void]$existingEvent.Set()
        $existingEvent.Dispose()
    }catch{}
    $mutex.Dispose()
    exit 0
}
$focusEvent=New-Object System.Threading.EventWaitHandle($false,[System.Threading.EventResetMode]::AutoReset,$focusEventName)

function Ensure-State {
    $items=@(Read-DomlightAccountState -Path $StateFile)
    if($items.Count -eq 0){
        $items=@(Get-DomlightArchiveAccounts -ReceiptsDir $ReceiptsDir)
        if($items.Count -gt 0){Write-DomlightAccountState -Path $StateFile -Items $items}
    }
    return @($items)
}
function Status-Text($x){
    if([bool]$x.Excluded){return 'Исключен'}
    if([bool]$x.ManuallyDisabled){return 'Не проверять'}
    switch([string]$x.Status){
        'active'{'Активен'}
        'missing'{'Временно отсутствует'}
        'inactive'{'Неактивен'}
        default{[string]$x.Status}
    }
}

$form=New-Object Windows.Forms.Form
$form.Text='Лицевые счета / статус'
$form.StartPosition='CenterScreen'
$form.ClientSize=New-Object Drawing.Size(1340,420)
$form.MinimumSize=New-Object Drawing.Size(1120,360)
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.FormBorderStyle='Sizable'
$form.MaximizeBox=$true
$form.MinimizeBox=$true
$form.KeyPreview=$true

$label=New-Object Windows.Forms.Label
$label.Text='История квитанций сохраняется. 1-2 пропуска = временно отсутствует, 3+ = неактивен. «Не проверять» временно отключает проверку; «Исключить из Domlight» — отдельное постоянное действие.'
$label.Location=New-Object Drawing.Point(20,15)
$label.Size=New-Object Drawing.Size(1300,42)
$label.Anchor='Top,Left,Right'
$form.Controls.Add($label)

$grid=New-Object Windows.Forms.DataGridView
$grid.Location=New-Object Drawing.Point(20,65)
$grid.Size=New-Object Drawing.Size(1300,230)
$grid.ReadOnly=$true
$grid.AllowUserToAddRows=$false
$grid.AllowUserToDeleteRows=$false
$grid.SelectionMode='FullRowSelect'
$grid.MultiSelect=$false
$grid.AutoGenerateColumns=$false
$grid.RowHeadersVisible=$false
$grid.AutoSizeRowsMode='None'
$grid.RowTemplate.Height=25
$grid.ColumnHeadersHeight=28
$grid.ScrollBars='Both'
$grid.Anchor='Top,Left,Right'
$form.Controls.Add($grid)

foreach($spec in @(
    @('Account','Лицевой счёт',150),
    @('Address','Адрес',650),
    @('StatusText','Статус',195),
    @('MissingSuccessCount','Пропуски',90),
    @('LastSeenAt','Последняя проверка',170)
)){
    $c=New-Object Windows.Forms.DataGridViewTextBoxColumn
    $c.Name=$spec[0]
    $c.DataPropertyName=$spec[0]
    $c.HeaderText=$spec[1]
    $c.Width=[int]$spec[2]
    if($spec[0]-eq 'Address'){
        $c.AutoSizeMode='Fill'
        $c.MinimumWidth=520
        $c.DefaultCellStyle.WrapMode='False'
    }else{$c.AutoSizeMode='None'}
    [void]$grid.Columns.Add($c)
}

$show=New-Object Windows.Forms.CheckBox
$show.Text='Показать исключенные'
$show.Size=New-Object Drawing.Size(230,24)
$form.Controls.Add($show)

$off=New-Object Windows.Forms.Button
$off.Text='Не проверять'
$off.Size=New-Object Drawing.Size(190,42)
$form.Controls.Add($off)

$on=New-Object Windows.Forms.Button
$on.Text='Возобновить проверку'
$on.Size=New-Object Drawing.Size(220,42)
$form.Controls.Add($on)

$exclude=New-Object Windows.Forms.Button
$exclude.Text='Исключить из Domlight'
$exclude.Size=New-Object Drawing.Size(220,42)
$form.Controls.Add($exclude)

$restore=New-Object Windows.Forms.Button
$restore.Text='Восстановить'
$restore.Size=New-Object Drawing.Size(180,42)
$form.Controls.Add($restore)

$close=New-Object Windows.Forms.Button
$close.Text='Закрыть'
$close.Size=New-Object Drawing.Size(160,42)
$form.Controls.Add($close)

$script:VisibleRowCount=0
$script:AutoGridHeight=230

function Layout-Controls {
    $margin=20
    $clientWidth=$form.ClientSize.Width
    $label.Width=[Math]::Max(600,$clientWidth-($margin*2))
    $grid.Width=[Math]::Max(700,$clientWidth-($margin*2))
    $grid.Height=$script:AutoGridHeight

    $show.Location=New-Object Drawing.Point($margin,($grid.Bottom+12))

    $buttons=@($off,$on,$exclude,$restore,$close)
    $gap=12
    $total=0
    foreach($b in $buttons){$total+=$b.Width}
    $total+=$gap*($buttons.Count-1)
    $start=[int][Math]::Floor(($clientWidth-$total)/2)
    if($start -lt $margin){$start=$margin}
    $y=$show.Bottom+14
    $x=$start
    foreach($b in $buttons){
        $b.Location=New-Object Drawing.Point($x,$y)
        $x+=$b.Width+$gap
    }
}

function Set-AutoHeight {
    $working=[Windows.Forms.Screen]::FromControl($form).WorkingArea
    $rowCount=[Math]::Max(1,$script:VisibleRowCount)
    $wantedGrid=$grid.ColumnHeadersHeight+($rowCount*$grid.RowTemplate.Height)+3
    $minGrid=90
    $fixedHeight=65+12+$show.Height+14+$off.Height+18
    $maxClient=[Math]::Max(360,$working.Height-100)
    $maxGrid=[Math]::Max($minGrid,$maxClient-$fixedHeight)
    $script:AutoGridHeight=[Math]::Min([Math]::Max($wantedGrid,$minGrid),$maxGrid)
    $wantedClient=$fixedHeight+$script:AutoGridHeight
    $form.ClientSize=New-Object Drawing.Size($form.ClientSize.Width,$wantedClient)
    Layout-Controls
}

function Refresh-Grid {
    $rows=New-Object System.Collections.ArrayList
    foreach($x in @(Ensure-State)){
        if([bool]$x.Excluded -and -not $show.Checked){continue}
        $m=0
        try{$m=[int]$x.MissingSuccessCount}catch{}
        $address=if(-not [string]::IsNullOrWhiteSpace([string]$x.Address)){
            [string]$x.Address
        }elseif(-not [string]::IsNullOrWhiteSpace([string]$x.Apartment)){
            'кв. '+[string]$x.Apartment
        }else{'—'}
        [void]$rows.Add([pscustomobject]@{
            Account=[string]$x.Account
            Address=$address
            StatusText=(Status-Text $x)
            MissingSuccessCount=$m
            LastSeenAt=[string]$x.LastSeenAt
        })
    }
    $grid.DataSource=$null
    $grid.DataSource=$rows
    $script:VisibleRowCount=$rows.Count
    Set-AutoHeight
}

$off.Add_Click({
    try{
        if($grid.SelectedRows.Count-eq 0){return}
        $a=[string]$grid.SelectedRows[0].Cells['Account'].Value
        $items=@(Ensure-State)
        $i=@($items|Where-Object{[string]$_.Account-eq$a})|Select-Object -First 1
        if($null-eq$i -or [bool]$i.Excluded){return}
        $items=@(Set-DomlightAccountManualTracking -Items $items -Account $a -Enabled $false)
        Write-DomlightAccountState -Path $StateFile -Items $items
        Refresh-Grid
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight','OK','Error')|Out-Null}
})

$on.Add_Click({
    try{
        if($grid.SelectedRows.Count-eq 0){return}
        $a=[string]$grid.SelectedRows[0].Cells['Account'].Value
        $items=@(Ensure-State)
        $i=@($items|Where-Object{[string]$_.Account-eq$a})|Select-Object -First 1
        if($null-eq$i -or [bool]$i.Excluded){return}
        $items=@(Set-DomlightAccountManualTracking -Items $items -Account $a -Enabled $true)
        Write-DomlightAccountState -Path $StateFile -Items $items
        Refresh-Grid
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight','OK','Error')|Out-Null}
})

$exclude.Add_Click({
    try{
        if($grid.SelectedRows.Count-eq 0){return}
        $a=[string]$grid.SelectedRows[0].Cells['Account'].Value
        $items=@(Ensure-State)
        $i=@($items|Where-Object{[string]$_.Account-eq$a})|Select-Object -First 1
        if($null-eq$i -or [bool]$i.Excluded){return}
        $msg="ЛС $a будет постоянно исключён из Domlight.`r`n`r`nУдалить также локальные квитанции этого ЛС?`r`nДа — исключить и удалить архив`r`nНет — исключить, но оставить архив`r`nОтмена — ничего не менять"
        $c=[Windows.Forms.MessageBox]::Show($msg,'Исключить из Domlight',[Windows.Forms.MessageBoxButtons]::YesNoCancel,[Windows.Forms.MessageBoxIcon]::Warning)
        if($c-eq[Windows.Forms.DialogResult]::Cancel){return}
        $items=@(Set-DomlightAccountExcluded -Items $items -Account $a -Excluded $true)
        Write-DomlightAccountState -Path $StateFile -Items $items
        if($c-eq[Windows.Forms.DialogResult]::Yes){
            foreach($f in @(Get-ChildItem -LiteralPath $ReceiptsDir -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name-match('^'+[regex]::Escape($a)+'(?:\s+-|$)')})){
                Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction Stop
            }
        }
        Refresh-Grid
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight','OK','Error')|Out-Null}
})

$restore.Add_Click({
    try{
        if($grid.SelectedRows.Count-eq 0){return}
        $a=[string]$grid.SelectedRows[0].Cells['Account'].Value
        $items=@(Ensure-State)
        $i=@($items|Where-Object{[string]$_.Account-eq$a})|Select-Object -First 1
        if($null-eq$i -or -not [bool]$i.Excluded){
            [Windows.Forms.MessageBox]::Show('Выберите исключённый лицевой счёт.','Domlight','OK','Information')|Out-Null
            return
        }
        $items=@(Set-DomlightAccountExcluded -Items $items -Account $a -Excluded $false)
        Write-DomlightAccountState -Path $StateFile -Items $items
        Refresh-Grid
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight','OK','Error')|Out-Null}
})

$close.Add_Click({$form.Close()})
$show.Add_CheckedChanged({Refresh-Grid})
$form.Add_Resize({Layout-Controls})

$focusTimer=New-Object Windows.Forms.Timer
$focusTimer.Interval=250
$focusTimer.Add_Tick({
    try{
        if($focusEvent.WaitOne(0)){
            if($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized){
                $form.WindowState=[Windows.Forms.FormWindowState]::Normal
            }
            $form.Show()
            $form.TopMost=$true
            $form.BringToFront()
            $form.Activate()
            $form.TopMost=$false
        }
    }catch{}
})
$focusTimer.Start()

try{
    Refresh-Grid
    [void]$form.ShowDialog()
}
finally{
    try{$focusTimer.Stop();$focusTimer.Dispose()}catch{}
    try{$focusEvent.Dispose()}catch{}
    try{$mutex.ReleaseMutex()}catch{}
    try{$mutex.Dispose()}catch{}
}
