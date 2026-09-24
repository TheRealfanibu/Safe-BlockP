#Requires -RunAsAdministrator
# Why did the BlockPWatchdog task stop? Read-only diagnostic.

$ErrorActionPreference = 'Continue'
$task = 'BlockPWatchdog'

Write-Host '===== TASK STATE ====='
$t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if (-not $t) { Write-Host 'TASK DOES NOT EXIST'; return }
"State        : $($t.State)"
"Principal    : $($t.Principal.UserId) / $($t.Principal.LogonType) / $($t.Principal.RunLevel)"
"Triggers     : $(($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', ')"

$i = Get-ScheduledTaskInfo -TaskName $task
"LastRunTime  : $($i.LastRunTime)"
"LastResult   : 0x{0:X8} ({0})" -f $i.LastTaskResult
"NumberOfMissedRuns: $($i.NumberOfMissedRuns)"
"NextRunTime  : $($i.NextRunTime)"

Write-Host ''
Write-Host '===== SETTINGS THAT CAN KILL A LONG-RUNNING TASK ====='
$s = $t.Settings
"ExecutionTimeLimit      : $($s.ExecutionTimeLimit)"
"MultipleInstances       : $($s.MultipleInstances)"
"DisallowStartIfOnBatteries: $($s.DisallowStartIfOnBatteries)"
"StopIfGoingOnBatteries  : $($s.StopIfGoingOnBatteries)"
"IdleSettings.StopOnIdleEnd: $($s.IdleSettings.StopOnIdleEnd)"
"RestartCount            : $($s.RestartCount)"
"RestartInterval         : $($s.RestartInterval)"
"AllowHardTerminate      : $($s.AllowHardTerminate)"

Write-Host ''
Write-Host '===== TASK SCHEDULER EVENTS FOR THIS TASK ====='
try {
    Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 400 -ErrorAction Stop |
        Where-Object { $_.Message -match 'BlockPWatchdog' } |
        Select-Object -First 25 TimeCreated, Id, LevelDisplayName, Message |
        Format-List | Out-String -Width 160
} catch {
    Write-Host "could not read TaskScheduler log: $($_.Exception.Message)"
    Write-Host "(enable it: wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true)"
}

Write-Host ''
Write-Host '===== LAUNCHER TASKS (actually start BlockP.exe) ====='
foreach ($lt in 'BlockPWatchdogLaunch', 'BlockPStartup') {
    $lTask = Get-ScheduledTask -TaskName $lt -ErrorAction SilentlyContinue
    if (-not $lTask) { "$lt : DOES NOT EXIST"; continue }
    $li = Get-ScheduledTaskInfo -TaskName $lt
    "$lt : State=$($lTask.State) User=$($lTask.Principal.UserId) RunLevel=$($lTask.Principal.RunLevel) LastResult=0x{0:X8}" -f $li.LastTaskResult
    if ($li.LastTaskResult -eq 2147943140) {
        "  -> ERROR_ELEVATION_REQUIRED: this task's user has no admin token. BlockP.exe is requireAdministrator, so the interactive user MUST be in Administrators. Add them back, or re-run install-blockp-watchdog.ps1 -RestoreAdmin."
    }
}

Write-Host ''
Write-Host '===== IS BLOCKP ACTUALLY BLOCKING? ====='
# The failure mode that cost hours on 14.09.2026: BlockP "running" in Task Manager
# the whole time, in session 0, blocking nothing. Process count alone proves nothing.
$procs = @(Get-CimInstance Win32_Process -Filter "Name='BlockP.exe'")
if ($procs.Count -eq 0) {
    Write-Host 'NOT RUNNING' -ForegroundColor Red
} else {
    $sessions = ($procs.SessionId | Sort-Object -Unique)
    "processes : $($procs.Count)   session(s): $($sessions -join ', ')"
    if ($sessions -contains 0) {
        Write-Host '  -> SESSION 0: that copy has no desktop and blocks NOTHING.' -ForegroundColor Red
        Write-Host '     A launcher task set to "run whether user is logged on or not" causes this.'
        Write-Host '     Re-run install-blockp-watchdog.ps1 to point it at the interactive user.'
    }
    # A stable PID set is the difference between "running" and "crash-looping".
    Start-Sleep -Seconds 4
    $after = @(Get-CimInstance Win32_Process -Filter "Name='BlockP.exe'")
    $same  = (($procs.ProcessId | Sort-Object) -join ',') -eq (($after.ProcessId | Sort-Object) -join ',')
    if ($same) { Write-Host '  PIDs stable over 4s - genuinely running.' -ForegroundColor Green }
    else       { Write-Host '  PIDs CHANGED over 4s - it is crash-looping, not running.' -ForegroundColor Red }
}

Write-Host ''
Write-Host '===== DELIBERATE ABORTS (0x80000003) ====='
# BlockP int-3s itself if it is not running as the interactive session owner.
try {
    $crashes = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'; StartTime=(Get-Date).AddHours(-24)} -ErrorAction Stop |
               Where-Object { $_.Message -match 'BlockP' }
    if ($crashes) {
        "BlockP aborts in the last 24h: $($crashes.Count)  (newest: $($crashes[0].TimeCreated))"
        Write-Host '  -> It is refusing to run as this identity. It must run as the logged-on user.' -ForegroundColor Yellow
    } else { Write-Host 'none in the last 24h.' -ForegroundColor Green }
} catch { Write-Host 'no matching events.' }

Write-Host ''
Write-Host '===== RAW TASK XML ====='
Export-ScheduledTask -TaskName $task
