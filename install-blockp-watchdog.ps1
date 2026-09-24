#Requires -RunAsAdministrator
<#
  Installs/repairs the BlockP watchdog (v4).

  BlockP runs as the interactive user, in their own session, under their own
  profile, guarded by a SYSTEM scheduled task that relaunches it within ~5s of
  being killed. This is the only configuration BlockP 2.0.6 actually tolerates.

  WHY (established empirically on 14.09.2026):
    BlockP 2.0.6 aborts with STATUS_BREAKPOINT (0x80000003) whenever it runs as an
    account that is not the interactive session owner. Verified as WinAdmin in
    session 0 and in session 3, with a fresh profile, with and without --disable-gpu,
    with a correctly elevated token and the profile loaded. The same binary run as
    the session owner is stable and blocks correctly. It is a deliberate abort, so
    no launcher work gets around it.

    BlockP.exe is also requireAdministrator, so the session owner must be an admin.
    That is the trade this script makes, and it is a REAL trade:

      you get : blocking that works, and relaunch within ~5s of being killed
      you lose: the guarantee that you cannot dismantle it. As an administrator you
                can unregister BlockPWatchdog and nothing restores it.

    Friction and delay, not a wall - which is what README.md already claims is the
    actual goal. But do not tell yourself it is more than that.

  Run with -RestoreAdmin to actually change group membership. Without that flag
  this only reports what it would do and repairs the tasks.
#>

param(
    [string] $User         = 'Jonas',
    [switch] $RestoreAdmin,
    [switch] $IncludeArbeit
)

$ErrorActionPreference = 'Stop'

$exePath    = 'C:\Program Files\BlockP\BlockP.exe'
$root       = 'C:\ProgramData\BlockPWatchdog'
$scriptPath = Join-Path $root 'watchdog.ps1'
$watchTask  = 'BlockPWatchdog'
$launchTask = 'BlockPWatchdogLaunch'
$startTask  = 'BlockPStartup'

if (-not (Test-Path $exePath)) { throw "BlockP.exe not found at $exePath" }

Write-Host '== Restoring BlockP to a working configuration ==' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- current state
$isAdmin = $false
try {
    $isAdmin = [bool](Get-LocalGroupMember -Group 'Administratoren' -ErrorAction Stop |
                      Where-Object { $_.Name -like "*\$User" })
} catch {
    $isAdmin = [bool](Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*\$User" })
}
Write-Host "$User is currently an administrator: $isAdmin"

if (-not $isAdmin -and -not $RestoreAdmin) {
    Write-Host ''
    Write-Host "$User is a standard user, so BlockP.exe cannot elevate and WILL NOT RUN." -ForegroundColor Yellow
    Write-Host 'Re-run with -RestoreAdmin to put the account back in Administrators.' -ForegroundColor Yellow
    Write-Host 'Repairing the tasks anyway so they are correct once that happens.' -ForegroundColor Yellow
}

# ------------------------------------------------------------ restore admin
if ($RestoreAdmin) {
    $targets = @($User)
    if ($IncludeArbeit) { $targets += 'Arbeit' }
    foreach ($t in $targets) {
        $grp = 'Administratoren'
        if (-not (Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue)) { $grp = 'Administrators' }
        if (Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$t" }) {
            Write-Host "  $t is already in $grp"
        } else {
            Add-LocalGroupMember -Group $grp -Member $t
            Write-Host "  added $t to $grp" -ForegroundColor Green
        }
    }
    Write-Host '  NOTE: sign out and back in for the new token to take effect.' -ForegroundColor Yellow
}

# ------------------------------------------- clear the crash-looping instances
# BlockP resurrects itself (preventUninstallMode), so one kill is never enough.
Write-Host ''
Write-Host 'clearing stale BlockP processes...'
foreach ($t in $watchTask, $startTask, $launchTask) {
    try { Disable-ScheduledTask -TaskName $t -ErrorAction Stop | Out-Null } catch { }
}
$deadline = (Get-Date).AddSeconds(45); $zero = 0; $kills = 0
while ((Get-Date) -lt $deadline) {
    $p = @(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0) { $zero++; if ($zero -ge 6) { break } }
    else { $zero = 0; $kills += $p.Count; $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}
Write-Host "  $kills kills, field clear=$($zero -ge 6)"

# --------------------------------------------------------- watchdog body (v4)
# v4 change from v3: the launch task targets the INTERACTIVE USER, not WinAdmin.
# v3 ran BlockP as WinAdmin "whether logged on or not", which puts it in session 0
# with WinAdmin's profile - where it blocks nothing and aborts on sight.
$body = @'
# Runs as SYSTEM, re-launched every minute by Task Scheduler.
# Polls for ~55s then exits 0. Never loops forever.
$ErrorActionPreference = 'SilentlyContinue'

$exePath    = 'C:\Program Files\BlockP\BlockP.exe'
$launchTask = 'BlockPWatchdogLaunch'
$root       = 'C:\ProgramData\BlockPWatchdog'
$logFile    = Join-Path $root 'watchdog.log'
$beatFile   = Join-Path $root 'heartbeat.txt'
$pollSec    = 5
$runSec     = 55

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
            $keep = Get-Content $logFile -Tail 500
            Set-Content -Path $logFile -Value $keep -Encoding utf8
        }
        Add-Content -Path $logFile -Encoding utf8 -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Get-InteractiveUser {
    $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if (-not $p) { return $null }
    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
    if (-not $o.User) { return $null }
    if ($o.Domain) { return "$($o.Domain)\$($o.User)" }
    return $o.User
}

# The launch task must target whoever is actually logged on, with RunLevel Highest.
# BlockP.exe is requireAdministrator AND aborts (0x80000003) if it is not the
# session owner - so "elevated, as the logged-on user" is the only thing it accepts.
function Confirm-LaunchTask {
    param([string]$User)
    $existing = Get-ScheduledTask -TaskName $launchTask -ErrorAction SilentlyContinue
    $needs = $true
    if ($existing) {
        $userOk = $existing.Principal.UserId -and
                  ($existing.Principal.UserId.Split('\')[-1] -eq $User.Split('\')[-1])
        if ($userOk -and $existing.Principal.RunLevel -eq 'Highest') { $needs = $false }
    }
    if ($needs) {
        try {
            $action    = New-ScheduledTaskAction -Execute $exePath -Argument '--hidden'
            $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $launchTask -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Write-Log "(re)registered $launchTask for $User"
        } catch {
            Write-Log "ERROR registering ${launchTask}: $($_.Exception.Message)"
            return $false
        }
    }
    if ((Get-ScheduledTask -TaskName $launchTask -ErrorAction SilentlyContinue).State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $launchTask | Out-Null
        Write-Log "Re-enabled $launchTask"
    }
    return $true
}

$deadline = (Get-Date).AddSeconds($runSec)

while ((Get-Date) -lt $deadline) {
    try {
        Set-Content -Path $beatFile -Encoding utf8 -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

        $user = Get-InteractiveUser
        if ($user) {
            $running = @(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue)
            if ($running.Count -eq 0) {
                Write-Log "BlockP not running (session: $user) - relaunching"
                if (Confirm-LaunchTask -User $user) {
                    Start-ScheduledTask -TaskName $launchTask
                    Start-Sleep -Seconds 15
                }
            }
        }
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $pollSec
}

exit 0
'@

New-Item -ItemType Directory -Path $root -Force | Out-Null
Set-Content -Path $scriptPath -Value $body -Encoding utf8
Write-Host ''
Write-Host "  wrote $scriptPath (v4 - launches as the interactive user)"

# --------------------------------------------------- repair the launcher tasks
$action    = New-ScheduledTaskAction -Execute $exePath -Argument '--hidden'
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $launchTask -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "  repaired '$launchTask' -> $User / Interactive / Highest"

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
Register-ScheduledTask -TaskName $startTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "  repaired '$startTask'  -> $User / Interactive / Highest / at logon"

# ------------------------------------------------------- re-register watchdog
$wAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
$tBoot   = New-ScheduledTaskTrigger -AtStartup
$tRep    = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
$wPrin   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$wSet    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew `
              -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName $watchTask -Action $wAction -Trigger @($tBoot, $tRep) -Principal $wPrin -Settings $wSet -Force | Out-Null
Enable-ScheduledTask -TaskName $watchTask | Out-Null
Start-ScheduledTask  -TaskName $watchTask
Write-Host "  re-registered + started '$watchTask' (SYSTEM, every 1 min)"

# ------------------------------------------------------------- start BlockP
if ($isAdmin -or $RestoreAdmin) {
    Start-ScheduledTask -TaskName $launchTask
    Start-Sleep -Seconds 8
    $p = @(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue)
    Write-Host ''
    if ($p.Count -gt 0) {
        Write-Host "BlockP is running: $($p.Count) process(es)" -ForegroundColor Green
        Write-Host 'Go test a blocked site.' -ForegroundColor Green
    } else {
        Write-Host 'BlockP did not come up.' -ForegroundColor Yellow
        Write-Host "If you just ran -RestoreAdmin, sign out and back in first - $User's"
        Write-Host 'current token is still a standard-user token until then.'
    }
}

Write-Host ''
Write-Host 'Health check:  Get-Content C:\ProgramData\BlockPWatchdog\heartbeat.txt'
Write-Host 'Log:           C:\ProgramData\BlockPWatchdog\watchdog.log'
