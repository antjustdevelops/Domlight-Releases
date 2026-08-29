param(
    [string]$Root = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Domlight'),
    [switch]$AnalyzeOnly
)

Add-Type -AssemblyName System.Windows.Forms
$ErrorActionPreference = 'Stop'

function Show-Info([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text,'Domlight Recovery','OK','Information') | Out-Null
}
function Show-Error([string]$Text) {
    [Windows.Forms.MessageBox]::Show($Text,'Domlight Recovery','OK','Error') | Out-Null
}
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
    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return -1 }
    $score=0
    foreach($pattern in @(
        'GmailApi','Recipients','recipients.json','email_history.json','whatsapp_history.json',
        'gmail_token.dat','gmail_client_secret','ABRENTALS','abrentals@ahb.global',
        'Отправить Gmail','WhatsApp','Подготовить PDF','Посмотреть'
    )) {
        if($text.IndexOf($pattern,[StringComparison]::OrdinalIgnoreCase) -ge 0){$score++}
    }
    return $score
}
function Get-BackupCandidates([string]$FileName) {
    $backupRoot = Join-Path $Root 'data\update_backups'
    if(-not(Test-Path -LiteralPath $backupRoot)){return @()}
    return @(
        Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Path=$_.FullName
                BackupStamp=$_.Directory.Name
                LastWrite=$_.LastWriteTime
                Size=$_.Length
                Sha256=(Get-Sha256 $_.FullName)
                Score=$(if($FileName -eq 'Mailing.ps1'){Get-MailingScore $_.FullName}else{0})
                ParseOk=(Parse-Ok $_.FullName)
            }
        }
    )
}
function Find-BestDependency([string]$FileName) {
    $current = Join-Path $Root $FileName
    if((Test-Path -LiteralPath $current) -and (Parse-Ok $current)){return $current}
    $candidates=@(Get-BackupCandidates $FileName | Where-Object {$_.ParseOk} | Sort-Object LastWrite -Descending)
    if($candidates.Count -gt 0){return [string]$candidates[0].Path}
    return $null
}

try {
    if(-not(Test-Path -LiteralPath $Root)){throw "Не найдена папка Domlight: $Root"}
    $dataDir=Join-Path $Root 'data'
    if(-not(Test-Path -LiteralPath $dataDir)){throw "Не найдена папка данных Domlight: $dataDir"}

    $mailingCandidates=@(Get-BackupCandidates 'Mailing.ps1' | Where-Object {$_.ParseOk -and $_.Score -ge 3} | Sort-Object @{Expression='Score';Descending=$true},@{Expression='LastWrite';Descending=$false})
    $currentMailing=Join-Path $Root 'Mailing.ps1'
    $currentScore=$(if(Test-Path -LiteralPath $currentMailing){Get-MailingScore $currentMailing}else{-1})

    $reportDir=Join-Path $dataDir 'recovery_reports'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportPath=Join-Path $reportDir ('mailing_recovery_'+$stamp+'.txt')
    $lines=New-Object System.Collections.Generic.List[string]
    $lines.Add('DOMLIGHT MAILING RECOVERY ANALYSIS')
    $lines.Add('Root: '+$Root)
    $lines.Add('Current Mailing score: '+$currentScore)
    $lines.Add('Current Mailing SHA256: '+$(if(Test-Path $currentMailing){Get-Sha256 $currentMailing}else{'missing'}))
    $lines.Add('Backup candidates: '+$mailingCandidates.Count)
    foreach($c in $mailingCandidates){$lines.Add(('  score={0} parse={1} size={2} date={3} sha={4} path={5}' -f $c.Score,$c.ParseOk,$c.Size,$c.LastWrite,$c.Sha256,$c.Path))}

    $gmailSource=Find-BestDependency 'GmailApi.ps1'
    $recipientsSource=Find-BestDependency 'Recipients.ps1'
    $lines.Add('GmailApi source: '+$(if($gmailSource){$gmailSource}else{'NOT FOUND'}))
    $lines.Add('Recipients source: '+$(if($recipientsSource){$recipientsSource}else{'NOT FOUND'}))
    Set-Content -LiteralPath $reportPath -Value $lines -Encoding UTF8

    if($AnalyzeOnly){Show-Info("Анализ завершён.`r`n`r`nОтчёт:`r`n$reportPath"); exit 0}
    if($mailingCandidates.Count -eq 0){throw "В update_backups не найден полноценный старый Mailing.ps1. Ничего не изменено.`r`n`r`nОтчёт: $reportPath"}
    if(-not $gmailSource){throw "Не найден рабочий GmailApi.ps1. Ничего не изменено.`r`n`r`nОтчёт: $reportPath"}
    if(-not $recipientsSource){throw "Не найден рабочий Recipients.ps1. Ничего не изменено.`r`n`r`nОтчёт: $reportPath"}

    $best=$mailingCandidates[0]
    $question = "Найдена старая полноценная рассылка.`r`n`r`n"+
                "Backup: $($best.BackupStamp)`r`n"+
                "Признаков старой функции: $($best.Score)`r`n"+
                "Размер: $($best.Size) bytes`r`n`r`n"+
                "Текущий блок будет сначала сохранён в safety backup.`r`n"+
                "Папка data, PDF, recipients.json, Gmail token и история НЕ изменяются.`r`n`r`n"+
                "Восстановить старый блок рассылки?"
    $answer=[Windows.Forms.MessageBox]::Show($question,'Domlight Recovery','YesNo','Question')
    if($answer -ne [Windows.Forms.DialogResult]::Yes){exit 0}

    $safetyRoot=Join-Path $dataDir ('recovery_safety\'+$stamp)
    New-Item -ItemType Directory -Force -Path $safetyRoot | Out-Null
    foreach($name in @('Mailing.ps1','GmailApi.ps1','Recipients.ps1')){
        $p=Join-Path $Root $name
        if(Test-Path -LiteralPath $p){Copy-Item -LiteralPath $p -Destination (Join-Path $safetyRoot $name) -Force}
    }

    $restoreMap=@{
        'Mailing.ps1'=[string]$best.Path
        'GmailApi.ps1'=[string]$gmailSource
        'Recipients.ps1'=[string]$recipientsSource
    }
    foreach($name in @('Mailing.ps1','GmailApi.ps1','Recipients.ps1')){
        $source=$restoreMap[$name]
        if(-not(Parse-Ok $source)){throw "Синтаксическая проверка не пройдена: $source"}
        Copy-Item -LiteralPath $source -Destination (Join-Path $Root $name) -Force
    }

    foreach($name in @('Mailing.ps1','GmailApi.ps1','Recipients.ps1')){
        $dest=Join-Path $Root $name
        if(-not(Parse-Ok $dest)){throw "После восстановления не проходит parser: $dest"}
    }

    $result=@(
        'RECOVERY SUCCESS',
        'Restored Mailing: '+[string]$best.Path,
        'Mailing SHA256: '+(Get-Sha256 (Join-Path $Root 'Mailing.ps1')),
        'GmailApi SHA256: '+(Get-Sha256 (Join-Path $Root 'GmailApi.ps1')),
        'Recipients SHA256: '+(Get-Sha256 (Join-Path $Root 'Recipients.ps1')),
        'Safety backup: '+$safetyRoot,
        'User data was not modified.'
    )
    Add-Content -LiteralPath $reportPath -Value $result -Encoding UTF8
    Show-Info("Старый блок рассылки восстановлен из локальных backup'ов.`r`n`r`nSafety backup:`r`n$safetyRoot`r`n`r`nТеперь запустите Domlight и проверьте «Рассылка квитанций».`r`n`r`nОтчёт:`r`n$reportPath")
}
catch {
    Show-Error($_.Exception.Message)
    exit 1
}
