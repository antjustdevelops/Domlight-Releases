param(
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(Mandatory=$true)][string]$Key
)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir=Join-Path $Root 'data'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$ErrorLog=Join-Path $DataDir 'window_errors.log'

$bytes=[Text.Encoding]::UTF8.GetBytes(($Root.ToLowerInvariant()+'|'+$Key.ToLowerInvariant()))
$sha=[Security.Cryptography.SHA256]::Create()
try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,24)}finally{$sha.Dispose()}
$mutexName='Local\DomlightWindow_'+$hash
$pidFile=Join-Path $DataDir ('window_'+($Key -replace '[^0-9A-Za-z_-]','_')+'.pid')
$created=$false
$mutex=[Threading.Mutex]::new($true,$mutexName,[ref]$created)

function Activate-Existing {
    try {
        if(Test-Path -LiteralPath $pidFile){
            $oldPid=0
            [void][int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(),[ref]$oldPid)
            if($oldPid-gt0){
                $p=Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                if($p){try{[Microsoft.VisualBasic.Interaction]::AppActivate($oldPid)|Out-Null}catch{}}
            }
        }
    } catch {}
}

if(-not $created){
    Activate-Existing
    try{$mutex.Dispose()}catch{}
    exit 0
}

$filter=$null
try {
    $PID.ToString() | Set-Content -LiteralPath $pidFile -Encoding ASCII

    if(-not('DomlightEscapeFilter' -as [type])){
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Windows.Forms;
public sealed class DomlightEscapeFilter : IMessageFilter {
    public bool PreFilterMessage(ref Message m) {
        const int WM_KEYDOWN = 0x0100;
        if (m.Msg == WM_KEYDOWN && (Keys)m.WParam.ToInt32() == Keys.Escape) {
            Form f = Form.ActiveForm;
            if (f != null && !f.IsDisposed) {
                f.Close();
                return true;
            }
        }
        return false;
    }
}
'@
    }
    $filter=New-Object DomlightEscapeFilter
    [Windows.Forms.Application]::AddMessageFilter($filter)

    if(-not(Test-Path -LiteralPath $Script)){throw "Не найден файл окна: $Script"}
    try {
        & $Script
    } catch {
        $message="Не удалось открыть окно Domlight.`r`n`r`nМодуль: $([IO.Path]::GetFileName($Script))`r`n$($_.Exception.Message)"
        try{Add-Content -LiteralPath $ErrorLog -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'  '+$message.Replace("`r`n",' | '))}catch{}
        [Windows.Forms.MessageBox]::Show($message,'Domlight','OK','Error')|Out-Null
    }
}
finally {
    if($null-ne$filter){try{[Windows.Forms.Application]::RemoveMessageFilter($filter)}catch{}}
    try{Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue}catch{}
    try{$mutex.ReleaseMutex()}catch{}
    try{$mutex.Dispose()}catch{}
}
