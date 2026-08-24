Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$StateFile = Join-Path $DataDir 'accounts_state.json'

function Load-State {
    if (-not (Test-Path $StateFile)) { return @() }
    try { return @(Get-Content $StateFile -Raw | ConvertFrom-Json) } catch { return @() }
}
function Save-State([object[]]$items) {
    @($items) | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}
function Status-Ru([string]$s, [bool]$manual) {
    if ($manual) { return 'Не отслеживать' }
    switch ($s) {
        'active' { return 'Активен' }
        'missing' { return 'Временно отсутствует' }
        'inactive' { return 'Неактивен' }
        default { return $s }
    }
}

$items = @(Load-State)
$form = New-Object Windows.Forms.Form
$form.Text = 'Domlight — лицевые счета'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(760,480)
$form.MinimumSize = New-Object Drawing.Size(760,480)
$form.Font = New-Object Drawing.Font('Segoe UI',10)

$label = New-Object Windows.Forms.Label
$label.Text = 'История квитанций не удаляется при отключении лицевого счёта.'
$label.Location = New-Object Drawing.Point(20,15)
$label.Size = New-Object Drawing.Size(700,25)
$form.Controls.Add($label)

$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(20,50)
$grid.Size = New-Object Drawing.Size(700,300)
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoGenerateColumns = $false
$form.Controls.Add($grid)

foreach ($spec in @(
    @('Account','Лицевой счёт',170),
    @('Apartment','Квартира',110),
    @('StatusRu','Статус',170),
    @('MissingSuccessCount','Пропусков подряд',120),
    @('LastSeenAt','Последний раз на портале',170)
)) {
    $c = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $c.Name=$spec[0]; $c.DataPropertyName=$spec[0]; $c.HeaderText=$spec[1]; $c.Width=[int]$spec[2]
    [void]$grid.Columns.Add($c)
}

function Refresh-Grid {
    $rows = New-Object System.Collections.ArrayList
    foreach ($x in @(Load-State)) {
        [void]$rows.Add([pscustomobject]@{
            Account=[string]$x.Account
            Apartment=[string]$x.Apartment
            StatusRu=(Status-Ru ([string]$x.Status) ([bool]$x.ManuallyDisabled))
            MissingSuccessCount=[int]$x.MissingSuccessCount
            LastSeenAt=[string]$x.LastSeenAt
        })
    }
    $grid.DataSource=$null
    $grid.DataSource=$rows
}

$btnDisable = New-Object Windows.Forms.Button
$btnDisable.Text = 'Больше не отслеживать'
$btnDisable.Location = New-Object Drawing.Point(20,370)
$btnDisable.Size = New-Object Drawing.Size(220,42)
$form.Controls.Add($btnDisable)
$btnDisable.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $account=[string]$grid.SelectedRows[0].Cells['Account'].Value
    $state=@(Load-State)
    $x=$state | Where-Object { [string]$_.Account -eq $account } | Select-Object -First 1
    if (-not $x) { return }
    $answer=[Windows.Forms.MessageBox]::Show("ЛС $account перестанет проверяться автоматически.`r`nАрхив квитанций останется на месте.`r`n`r`nПродолжить?",'Domlight','YesNo','Question')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    $x.ManuallyDisabled=$true
    $x.Status='inactive'
    Save-State $state
    Refresh-Grid
})

$btnEnable = New-Object Windows.Forms.Button
$btnEnable.Text = 'Возобновить отслеживание'
$btnEnable.Location = New-Object Drawing.Point(255,370)
$btnEnable.Size = New-Object Drawing.Size(220,42)
$form.Controls.Add($btnEnable)
$btnEnable.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $account=[string]$grid.SelectedRows[0].Cells['Account'].Value
    $state=@(Load-State)
    $x=$state | Where-Object { [string]$_.Account -eq $account } | Select-Object -First 1
    if (-not $x) { return }
    $x.ManuallyDisabled=$false
    $x.MissingSuccessCount=0
    $x.Status='active'
    Save-State $state
    Refresh-Grid
})

$btnClose = New-Object Windows.Forms.Button
$btnClose.Text = 'Закрыть'
$btnClose.Location = New-Object Drawing.Point(500,370)
$btnClose.Size = New-Object Drawing.Size(220,42)
$form.Controls.Add($btnClose)
$btnClose.Add_Click({$form.Close()})

Refresh-Grid
[void]$form.ShowDialog()
