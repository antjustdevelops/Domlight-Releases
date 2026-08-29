param(
    [string]$Root = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Domlight'),
    [switch]$AnalyzeOnly,
    [switch]$NoPrompt
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'

function Show-Info([string]$Text) { [Windows.Forms.MessageBox]::Show($Text,'Domlight Recovery','OK','Information') | Out-Null }
function Show-Error([string]$Text) { [Windows.Forms.MessageBox]::Show($Text,'Domlight Recovery','OK','Error') | Out-Null }
function Parse-Ok([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    return (@($errors).Count -eq 0)
}
function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}
function Get-MailingScore([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    try { $text=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return -1 }
    $score=0
    foreach($pattern in @('GmailApi','Recipients','recipients.json','email_history.json','whatsapp_history.json','gmail_token.dat','gmail_client_secret','ABRENTALS','abrentals@ahb.global','Отправить Gmail','WhatsApp','Подготовить PDF','Посмотреть')) {
        if($text.IndexOf($pattern,[StringComparison]::OrdinalIgnoreCase) -ge 0){$score++}
    }
    return $score
}
function Get-BackupStampInfo([IO.FileInfo]$File) {
    $p=$File.Directory
    while($p -and $p.Parent -and $p.Parent.Name -ne 'update_backups'){$p=$p.Parent}
    $stamp=if($p){$p.Name}else{$File.Directory.Name}
    $dt=[datetime]::MinValue
    [void][datetime]::TryParseExact($stamp,'yyyyMMdd_HHmmss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$dt)
    [pscustomobject]@{Stamp=$stamp;StampTime=$dt}
}
function Get-BackupCandidates([string]$FileName) {
    $backupRoot=Join-Path $Root 'data\update_backups'
    if(-not(Test-Path -LiteralPath $backupRoot)){return @()}
    return @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | ForEach-Object {
        $si=Get-BackupStampInfo $_
        [pscustomobject]@{Path=$_.FullName;BackupStamp=$si.Stamp;StampTime=$si.StampTime;LastWrite=$_.LastWriteTime;Size=$_.Length;Sha256=(Get-Sha256 $_.FullName);Score=$(if($FileName -eq 'Mailing.ps1'){Get-MailingScore $_.FullName}else{0});ParseOk=(Parse-Ok $_.FullName)}
    })
}
function Find-BestDependency([string]$FileName,[datetime]$PreferredStamp) {
    $c=@(Get-BackupCandidates $FileName | Where-Object {$_.ParseOk})
    if($PreferredStamp -ne [datetime]::MinValue){
        $near=@($c | Where-Object {$_.StampTime -ne [datetime]::MinValue -and $_.StampTime -le $PreferredStamp} | Sort-Object StampTime -Descending)
        if($near.Count -gt 0){return [string]$near[0].Path}
    }
    $current=Join-Path $Root $FileName
    if((Test-Path -LiteralPath $current) -and (Parse-Ok $current)){return $current}
    $latest=@($c | Sort-Object StampTime -Descending,LastWrite -Descending)
    if($latest.Count -gt 0){return [string]$latest[0].Path}
    return $null
}
function Restore-Safety([string]$SafetyRoot,[hashtable]$HadOriginal) {
    foreach($name in @('Mailing.ps1','GmailApi.ps1','Recipients.ps1')){
        $dest=Join-Path $Root $name; $safe=Join-Path $SafetyRoot $name
        if($HadOriginal[$name]){
            if(Test-Path -LiteralPath $safe){Copy-Item -LiteralPath $safe -Destination $dest -Force}
        } elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}
    }
}

try {
    if(-not(Test-Path -LiteralPath $Root)){throw "Не найдена папка Domlight: $Root"}
    $dataDir=Join-Path $Root 'data'; if(-not(Test-Path -LiteralPath $dataDir)){throw "Не найдена папка данных Domlight: $dataDir"}
    $mailingCandidates=@(Get-BackupCandidates 'Mailing.ps1' | Where-Object {$_.ParseOk -and $_.Score -ge 3} | Sort-Object @{Expression='StampTime';Descending=$false},@{Expression='Score';Descending=$true})
    $reportDir=Join-Path $dataDir 'recovery_reports'; New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'; $reportPath=Join-Path $reportDir ('mailing_recovery_'+$stamp+'.txt')
    $lines=New-Object System.Collections.Generic.List[string]; $lines.Add('DOMLIGHT PRE-V135 MAILING RECOVERY ANALYSIS'); $lines.Add('Root: '+$Root); $lines.Add('Candidates: '+$mailingCandidates.Count)
    foreach($c in $mailingCandidates){$lines.Add(('  stamp={0} score={1} parse={2} size={3} sha={4} path={5}' -f $c.BackupStamp,$c.Score,$c.ParseOk,$c.Size,$c.Sha256,$c.Path))}
    if($mailingCandidates.Count -eq 0){Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8; throw "Не найден parse-valid полноценный Mailing в update_backups. Ничего не изменено.`r`nОтчёт: $reportPath"}

    # The takeover occurred when Mailing first became managed. The backup created by that update contains
    # the locally carried-forward implementation immediately before replacement. Prefer the earliest
    # parse-valid full-feature candidate rather than a later backup of the rewritten managed module.
    $best=$mailingCandidates[0]
    $gmailSource=Find-BestDependency 'GmailApi.ps1' $best.StampTime
    $recipientsSource=Find-BestDependency 'Recipients.ps1' $best.StampTime
    $lines.Add('Selected Mailing: '+$best.Path); $lines.Add('GmailApi source: '+$(if($gmailSource){$gmailSource}else{'NOT FOUND'})); $lines.Add('Recipients source: '+$(if($recipientsSource){$recipientsSource}else{'NOT FOUND'}))
    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8
    if($AnalyzeOnly){Show-Info("Анализ завершён.`r`n$reportPath"); exit 0}
    if(-not $gmailSource){throw "Не найден parse-valid GmailApi.ps1. Ничего не изменено.`r`n$reportPath"}
    if(-not $recipientsSource){throw "Не найден parse-valid Recipients.ps1. Ничего не изменено.`r`n$reportPath"}
    foreach($p in @([string]$best.Path,$gmailSource,$recipientsSource)){if(-not(Parse-Ok $p)){throw "Источник не проходит parser: $p"}}

    if(-not $NoPrompt){
        $answer=[Windows.Forms.MessageBox]::Show("Найдена полноценная pre-v135 рассылка.`r`nBackup: $($best.BackupStamp)`r`n`r`nТекущие файлы будут сохранены; data не изменяется.`r`nВосстановить?",'Domlight Recovery','YesNo','Question')
        if($answer -ne [Windows.Forms.DialogResult]::Yes){exit 0}
    }

    $safetyRoot=Join-Path $dataDir ('recovery_safety\'+$stamp); New-Item -ItemType Directory -Force -Path $safetyRoot | Out-Null
    $had=@{}
    foreach($name in @('Mailing.ps1','GmailApi.ps1','Recipients.ps1')){$p=Join-Path $Root $name;$had[$name]=Test-Path -LiteralPath $p;if($had[$name]){Copy-Item -LiteralPath $p -Destination (Join-Path $safetyRoot $name) -Force}}
    $restoreMap=@{'Mailing.ps1'=[string]$best.Path;'GmailApi.ps1'=$gmailSource;'Recipients.ps1'=$recipientsSource}
    try {
        foreach($name in @('Mailing.ps1','GmailApi.ps1','Recipients.ps1')){Copy-Item -LiteralPath $restoreMap[$name] -Destination (Join-Path $Root $name) -Force}
        foreach($name in @('Mailing.ps1','GmailApi.ps1','Recipients.ps1')){if(-not(Parse-Ok (Join-Path $Root $name))){throw "После восстановления не проходит parser: $name"}}
    } catch {
        Restore-Safety $safetyRoot $had
        throw "Восстановление отменено и автоматически откачено: $($_.Exception.Message)"
    }
    Add-Content -LiteralPath $reportPath -Encoding UTF8 -Value @('RECOVERY SUCCESS','Mailing SHA256: '+(Get-Sha256 (Join-Path $Root 'Mailing.ps1')),'GmailApi SHA256: '+(Get-Sha256 (Join-Path $Root 'GmailApi.ps1')),'Recipients SHA256: '+(Get-Sha256 (Join-Path $Root 'Recipients.ps1')),'Safety backup: '+$safetyRoot,'User data unchanged.')
    Show-Info("Pre-v135 блок рассылки восстановлен атомарно.`r`nSafety backup: $safetyRoot`r`nОтчёт: $reportPath")
}
catch { Show-Error($_.Exception.Message); exit 1 }
