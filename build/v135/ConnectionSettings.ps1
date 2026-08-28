Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference='Stop'

$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir=Join-Path $Root 'data'
$ConfigFile=Join-Path $DataDir 'connection.json'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Read-ConnectionConfig {
    $cfg=[ordered]@{useProxy=$false;proxyUrl='';proxyUser='';proxyPassword=''}
    if(Test-Path -LiteralPath $ConfigFile){
        try{
            $x=Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if($x.PSObject.Properties.Name -contains 'useProxy'){$cfg.useProxy=[bool]$x.useProxy}
            if($x.PSObject.Properties.Name -contains 'proxyUrl'){$cfg.proxyUrl=[string]$x.proxyUrl}
            if($x.PSObject.Properties.Name -contains 'proxyUser'){$cfg.proxyUser=[string]$x.proxyUser}
            if($x.PSObject.Properties.Name -contains 'proxyPassword'){$cfg.proxyPassword=[string]$x.proxyPassword}
        }catch{}
    }
    return [pscustomobject]$cfg
}

function Write-ConnectionConfig($cfg){
    $tmp=$ConfigFile+'.tmp'
    [ordered]@{useProxy=[bool]$cfg.useProxy;proxyUrl=[string]$cfg.proxyUrl;proxyUser=[string]$cfg.proxyUser;proxyPassword=[string]$cfg.proxyPassword} |
        ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $ConfigFile -Force
}

$form=New-Object Windows.Forms.Form
$form.Text='Domlight — прокси / шлюз'
$form.StartPosition='CenterScreen'
$form.ClientSize=New-Object Drawing.Size(620,300)
$form.MinimumSize=New-Object Drawing.Size(640,340)
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.FormBorderStyle='FixedDialog'
$form.MaximizeBox=$false

$chk=New-Object Windows.Forms.CheckBox;$chk.Text='Использовать прокси';$chk.Location=New-Object Drawing.Point(24,22);$chk.Size=New-Object Drawing.Size(220,28);$form.Controls.Add($chk)
function Add-Field([string]$label,[int]$y,[bool]$password=$false){
    $l=New-Object Windows.Forms.Label;$l.Text=$label;$l.Location=New-Object Drawing.Point(24,$y);$l.Size=New-Object Drawing.Size(145,25);$form.Controls.Add($l)
    $t=New-Object Windows.Forms.TextBox;$t.Location=New-Object Drawing.Point(170,$y-2);$t.Size=New-Object Drawing.Size(420,28);$t.UseSystemPasswordChar=$password;$form.Controls.Add($t);return $t
}
$txtUrl=Add-Field 'URL прокси' 72
$txtUser=Add-Field 'Пользователь' 116
$txtPass=Add-Field 'Пароль' 160 $true
$hint=New-Object Windows.Forms.Label;$hint.Text='Пример: http://127.0.0.1:8080  или  http://host:port';$hint.Location=New-Object Drawing.Point(170,194);$hint.Size=New-Object Drawing.Size(420,24);$hint.ForeColor=[Drawing.Color]::DimGray;$form.Controls.Add($hint)
$btnSave=New-Object Windows.Forms.Button;$btnSave.Text='Сохранить';$btnSave.Location=New-Object Drawing.Point(324,236);$btnSave.Size=New-Object Drawing.Size(125,38);$form.Controls.Add($btnSave)
$btnCancel=New-Object Windows.Forms.Button;$btnCancel.Text='Отмена';$btnCancel.Location=New-Object Drawing.Point(465,236);$btnCancel.Size=New-Object Drawing.Size(125,38);$form.Controls.Add($btnCancel)

$cfg=Read-ConnectionConfig;$chk.Checked=[bool]$cfg.useProxy;$txtUrl.Text=[string]$cfg.proxyUrl;$txtUser.Text=[string]$cfg.proxyUser;$txtPass.Text=[string]$cfg.proxyPassword
$toggle={$enabled=[bool]$chk.Checked;$txtUrl.Enabled=$enabled;$txtUser.Enabled=$enabled;$txtPass.Enabled=$enabled}
$chk.Add_CheckedChanged($toggle);&$toggle
$btnSave.Add_Click({
    try{
        $url=$txtUrl.Text.Trim()
        if($chk.Checked -and [string]::IsNullOrWhiteSpace($url)){throw 'Укажите URL прокси или отключите прокси.'}
        if($chk.Checked){$uri=$null;if(-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri)){throw 'Некорректный URL прокси.'};if($uri.Scheme -notin @('http','https')){throw 'Поддерживается прокси http:// или https://.'}}
        Write-ConnectionConfig ([pscustomobject]@{useProxy=[bool]$chk.Checked;proxyUrl=$url;proxyUser=$txtUser.Text.Trim();proxyPassword=$txtPass.Text})
        $form.DialogResult=[Windows.Forms.DialogResult]::OK;$form.Close()
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Domlight','OK','Error')|Out-Null}
})
$btnCancel.Add_Click({$form.DialogResult=[Windows.Forms.DialogResult]::Cancel;$form.Close()})
$form.AcceptButton=$btnSave;$form.CancelButton=$btnCancel
[void]$form.ShowDialog()
