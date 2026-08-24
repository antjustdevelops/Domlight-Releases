$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = 'Domlight Auto Check'
$Script = Join-Path $Root 'AutoCheck.ps1'
$DataDir = Join-Path $Root 'data'
$MigrationFlag = Join-Path $DataDir 'task_settings_v97.flag'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

try {
    # Create the task if it does not exist. Six-hour cadence is kept for compatibility.
    & schtasks.exe /Query /TN $TaskName *> $null
    if ($LASTEXITCODE -ne 0) {
        & schtasks.exe /Create /TN $TaskName /TR ("powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`"") /SC HOURLY /MO 6 /F *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать задачу автоматической проверки.' }
    }

    # Harden the existing task settings without changing its current trigger schedule.
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $folder = $service.GetFolder('\')
    $task = $folder.GetTask($TaskName)
    # One-time migration: v96 could leave a hidden MessageBox task permanently running.
    if (-not (Test-Path $MigrationFlag) -and $task.State -eq 4) {
        try { $task.Stop(0) } catch {}
        Start-Sleep -Milliseconds 300
    }
    $definition = $task.Definition

    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.Enabled = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.RunOnlyIfNetworkAvailable = $false
    $definition.Settings.ExecutionTimeLimit = 'PT15M'
    $definition.Settings.MultipleInstances = 2  # IgnoreNew

    # Refresh the action path in case Domlight was moved/reinstalled.
    if ($definition.Actions.Count -gt 0) {
        $action = $definition.Actions.Item(1)
        $action.Path = 'powershell.exe'
        $action.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
        $action.WorkingDirectory = $Root
    }

    # 6 = TASK_CREATE_OR_UPDATE, 3 = TASK_LOGON_INTERACTIVE_TOKEN
    [void]$folder.RegisterTaskDefinition($TaskName, $definition, 6, $null, $null, 3, $null)
    (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') | Set-Content -Path $MigrationFlag -Encoding ASCII
    exit 0
}
catch {
    # Configuration failure must not prevent Domlight from starting.
    exit 1
}
