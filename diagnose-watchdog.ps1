#Requires -RunAsAdministrator
# Health of the v5 watchdogs (A + B), the launcher tasks, and BlockP itself. Read-only.

$ErrorActionPreference = 'Continue'
$root = 'C:\ProgramData\BlockPWatchdog'

Write-Host '===== HEARTBEATS ====='
foreach ($r in 'A', 'B') {
    $hb = Join-Path $root "heartbeat-$r.txt"
    if (Test-Path $hb) {
        $age = [int] ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds
        $color = if ($age -lt 6) { 'Green' } else { 'Red' }
        Write-Host ("watchdog {0}: heartbeat {1}s old  ({2})" -f $r, $age, (Get-Content $hb)) -ForegroundColor $color
    } else { Write-Host "watchdog ${r}: no heartbeat file" -ForegroundColor Red }
}

Write-Host ''
Write-Host '===== ENFORCED SETTINGS vs config.json ====='
try {
    $state = [IO.File]::ReadAllText((Join-Path $root 'state.json')) | ConvertFrom-Json
    $cfg   = [IO.File]::ReadAllText($state.configPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
    foreach ($p in $state.enforced.PSObject.Properties) {
        $have = $cfg.PSObject.Properties[$p.Name]
        $ok = $have -and ([string] $have.Value -ceq [string] $p.Value)
        $color = if ($ok) { 'Gray' } else { 'Red' }
        Write-Host ("  {0,-28} want {1,-6} have {2}" -f $p.Name, $p.Value, $(if ($have) { $have.Value } else { '(missing)' })) -ForegroundColor $color
    }
    "partner: $($state.partnerEmail)   installed: $($state.installedAt)"
} catch { Write-Host "could not compare: $($_.Exception.Message)" -ForegroundColor Yellow }

foreach ($task in 'BlockPWatchdogA', 'BlockPWatchdogB') {
Write-Host ''
Write-Host "===== TASK $task ====="
$t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if (-not $t) { Write-Host 'TASK DOES NOT EXIST' -ForegroundColor Red; continue }
"State        : $($t.State)"
"Principal    : $($t.Principal.UserId) / $($t.Principal.LogonType) / $($t.Principal.RunLevel)"
"Triggers     : $(($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', ')"
"Arguments    : $($t.Actions[0].Arguments)"

$i = Get-ScheduledTaskInfo -TaskName $task
"LastRunTime  : $($i.LastRunTime)"
"LastResult   : 0x{0:X8} ({0})" -f $i.LastTaskResult
"NextRunTime  : $($i.NextRunTime)"
"ExecutionTimeLimit: $($t.Settings.ExecutionTimeLimit)   MultipleInstances: $($t.Settings.MultipleInstances)"
}

Write-Host ''
Write-Host '===== TASK SCHEDULER EVENTS ====='
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
        "  -> ERROR_ELEVATION_REQUIRED: this task's user has no admin token. BlockP.exe is requireAdministrator, so the interactive user MUST be in Administrators. Add them back to the Administrators group."
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
        Write-Host '     The watchdogs re-point BlockPWatchdogLaunch at the interactive user within 5s.'
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
Write-Host '===== LAST LOG LINES ====='
Get-Content (Join-Path $root 'watchdog.log') -Tail 25 -ErrorAction SilentlyContinue