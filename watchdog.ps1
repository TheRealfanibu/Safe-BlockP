<#
  BlockP watchdog v6.1. Runs as SYSTEM, -Count times: -Role A, B, C, ...

  Each instance is long-lived and, every second:
    - keeps BlockP running as the interactive user
    - enforces the protected keys of BlockP's config.json from a copy held in RAM
    - restores its own files (this script, state.json, smtp.bin) from RAM if touched
    - restarts EVERY other watchdog whose process is gone
  and every 5 seconds re-registers / re-enables its own task and the next role's task.

  While a genuine (NovaFocus-signed) BlockP update installer runs, relaunch and config
  repair pause, capped at 5 min per run and 10 min per hour.

  Role A additionally handles the unlock protocol (uninstall / rebaseline / upgrade need a code
  that is mailed to the accountability partner). Tamper notices are sent by the
  lowest-lettered watchdog that is alive, so one event is one mail.

  Task Scheduler re-triggers every task every minute (MultipleInstances IgnoreNew), and
  the triggers are staggered by 60/Count seconds, so killing all processes at once
  costs at most 60/Count seconds. A named mutex keeps each role a singleton.

  ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#>
param(
    [ValidatePattern('^[A-P]$')] [string] $Role = 'A',
    [ValidateRange(2, 16)] [int] $Count = 2
)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Security

$root       = 'C:\ProgramData\BlockPWatchdog'
$exePath    = 'C:\Program Files\BlockP\BlockP.exe'
$scriptPath = Join-Path $root 'watchdog.ps1'
$statePath  = Join-Path $root 'state.json'
$smtpPath   = Join-Path $root 'smtp.bin'
$logFile    = Join-Path $root 'watchdog.log'
$unlockDir  = Join-Path $root 'unlock'
$upgradeMark = Join-Path $root 'upgraded.txt'
$launchTask = 'BlockPWatchdogLaunch'
$startTask  = 'BlockPStartup'
$roles      = @(0..($Count - 1) | ForEach-Object { [string] [char] (65 + $_) })
$roleIndex  = [array]::IndexOf($roles, $Role)
if ($roleIndex -lt 0) { exit 0 }                     # a role outside the army: not ours
$others     = @($roles | Where-Object { $_ -ne $Role })
$nextRole   = $roles[($roleIndex + 1) % $Count]
$beatFile   = Join-Path $root "heartbeat-$Role.txt"

$pollMs          = 1000
$taskCheckSec    = 5
$peerStaleSec    = 3
$peerGraceSec    = 10
$allDownSec      = 10
$relaunchGapSec  = 20
$noticeGapMin    = 30
$codeValidMin    = 60
$codeAttempts    = 3
$requestGapMin   = 5
$installerMaxSec    = 300   # one BlockP installer run may pause enforcement this long
$installerBudgetSec = 600   # total pause allowed per rolling hour
$installerGraceSec  = 15    # after the installer exits, let it start BlockP itself

# ------------------------------------------------------------------ helpers

function Write-Log {
    param([string] $Message)
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 1MB)) {
            $keep = Get-Content $logFile -Tail 500
            Set-Content -Path $logFile -Value $keep -Encoding utf8
        }
        Add-Content -Path $logFile -Encoding utf8 -Value ('{0}  [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Role, $Message)
    } catch { }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-TextNoBom {
    # BlockP is Electron: JSON.parse chokes on a BOM, so never use Set-Content -Encoding utf8 here.
    param([string] $Path, [string] $Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Read-Bytes {
    param([string] $Path)
    try { return [IO.File]::ReadAllBytes($Path) } catch { return $null }
}

function ConvertTo-B64 {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    return [Convert]::ToBase64String($Bytes)
}

function Get-Sha256 {
    param([string] $Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
    finally { $sha.Dispose() }
}

# ------------------------------------------------------------ singleton mutex
# One process per role. A second copy (e.g. after the task was re-registered while
# the old process kept running) exits immediately instead of doubling up.
$created = $false
$roleMutex = New-Object Threading.Mutex($false, "Global\BlockPWatchdog-$Role", [ref] $created)
$owned = $false
try { $owned = $roleMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

# Serialises anything that kills or relaunches BlockP, so A and B never fight.
$repairMutex = New-Object Threading.Mutex($false, 'Global\BlockPWatchdogRepair')

function Enter-Repair {
    param([int] $TimeoutMs = 30000)
    try { return $repairMutex.WaitOne($TimeoutMs) } catch [Threading.AbandonedMutexException] { return $true }
}
function Exit-Repair { try { $repairMutex.ReleaseMutex() } catch { } }

# ------------------------------------------------------------ load RAM copies
# Everything below is read ONCE. From here on the disk is only a mirror of RAM:
# edits to these files are reverted, not adopted.
$ram = @{
    Script = Read-Bytes $scriptPath
    State  = Read-Bytes $statePath
    Smtp   = Read-Bytes $smtpPath
}
$state = $null
if ($ram.State) {
    try { $state = $utf8NoBom.GetString($ram.State).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $state = $null }
}
if (-not $state) { Write-Log 'WARNING: state.json missing or unreadable - config enforcement and mail are OFF, relaunch still active' }

$lastGood = $null
if ($state -and $state.snapshot) {
    try { $lastGood = $utf8NoBom.GetString([Convert]::FromBase64String($state.snapshot)) } catch { }
}

$smtp = $null
if ($ram.Smtp) {
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($ram.Smtp, $null, 'LocalMachine')
        $smtp  = $utf8NoBom.GetString($plain) | ConvertFrom-Json
    } catch { Write-Log 'WARNING: smtp.bin could not be decrypted - mail is OFF' }
}

# ------------------------------------------------------------------- mail

$lastNotice = @{}

function Send-Mail {
    param([string] $To, [string] $Subject, [string] $Body)
    if (-not $smtp -or -not $To) { return $false }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $client = New-Object Net.Mail.SmtpClient($smtp.host, [int] $smtp.port)
        $client.EnableSsl   = $true
        $client.Timeout     = 20000
        $client.Credentials = New-Object Net.NetworkCredential($smtp.user, $smtp.pass)
        $msg = New-Object Net.Mail.MailMessage($smtp.from, $To, $Subject, $Body)
        $client.Send($msg)
        $msg.Dispose(); $client.Dispose()
        return $true
    } catch {
        Write-Log "ERROR sending mail: $($_.Exception.Message)"
        return $false
    }
}

function Send-Notice {
    # Tamper notices go to the partner. Only the leader sends, so one event does not
    # produce one mail per watchdog. Rate-limited per kind, in RAM.
    param([string] $Kind, [string] $Text)
    Write-Log "NOTICE ($Kind): $Text"
    if (-not $state -or $suppressNotice) { return }
    if (-not (Test-IsLeader)) { return }
    $now = Get-Date
    if ($lastNotice.ContainsKey($Kind) -and ($now - $lastNotice[$Kind]).TotalMinutes -lt $noticeGapMin) { return }
    $lastNotice[$Kind] = $now
    $body = @"
BlockP watchdog on $env:COMPUTERNAME reported:

$Text

Time: $($now.ToString('yyyy-MM-dd HH:mm:ss'))
It has already been reverted. You get this mail because $($state.user) set you up as
accountability partner. No action is needed unless you want to talk about it.
"@
    [void] (Send-Mail -To $state.partnerEmail -Subject "BlockP: $Kind on $env:COMPUTERNAME" -Body $body)
}

# ------------------------------------------------------------------- peer

function Read-SharedText {
    # Read without blocking the owner's next heartbeat write (File.ReadAllText denies
    # writers while it has the file open, which made the owner's write fail).
    param([string] $Path)
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}

function Test-RoleAlive {
    # Alive = fresh heartbeat, or a stale one whose process still exists. The second case
    # is a watchdog busy in a slow repair or a mail, not a killed one.
    # A heartbeat caught mid-write reads as empty. That used to parse as PID 0 (Idle), so
    # a busy peer was reported as killed. Now an unreadable file is read again, and if it
    # never parses the answer is "alive": a missing file is the only proof of death here.
    param([string] $ForRole)
    $f = Join-Path $root "heartbeat-$ForRole.txt"
    for ($try = 0; $try -lt 3; $try++) {
        if ($try) { Start-Sleep -Milliseconds 150 }
        $item = $null
        try { $item = Get-Item -LiteralPath $f -ErrorAction Stop } catch { }
        if (-not $item) {
            if (-not (Test-Path -LiteralPath $f)) { return $false }
            continue
        }
        if (((Get-Date) - $item.LastWriteTime).TotalSeconds -lt $peerStaleSec) { return $true }
        $text = $null
        try { $text = Read-SharedText $f } catch { continue }
        $procId = 0
        if (-not $text -or -not [int]::TryParse(($text -split ' ')[0], [ref] $procId) -or $procId -le 0) { continue }
        return [bool] (Get-Process -Id $procId -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'powershell' })
    }
    return $true
}

function Test-RoleProcess {
    # Ground truth for "is role X running": a watchdog process with that role on its
    # command line. Only asked when the heartbeat already says dead, so it is rare.
    param([string] $ForRole)
    return [bool] (@(Get-WatchdogProcesses) | Where-Object { $_.CommandLine -match "-Role $ForRole(\s|$)" })
}

function Test-IsLeader {
    # The lowest-lettered live watchdog speaks for all of them.
    foreach ($r in $roles) {
        if ($r -eq $Role) { return $true }
        if (Test-RoleAlive $r) { return $false }
    }
    return $true
}

function Get-WatchdogProcesses {
    # Every watchdog process except this one.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'BlockPWatchdog\\watchdog\.ps1' -and $_.ProcessId -ne $PID }
}

$peerStartedAt = @{}     # role -> when this process last started it
$seenAlive     = @{}     # roles seen alive since then; dying after that = killed
$quietUntil    = [datetime]::MinValue

function Confirm-Peers {
    # Every watchdog restarts every other one, so killing them one by one in Task
    # Manager loses against the respawns.
    $killed = @()
    foreach ($r in $others) {
        if (Test-RoleAlive $r) { $seenAlive[$r] = $true; continue }
        if (Test-RoleProcess $r) { $seenAlive[$r] = $true; continue }   # heartbeat lied, process is there
        if ($peerStartedAt.ContainsKey($r) -and ((Get-Date) - $peerStartedAt[$r]).TotalSeconds -lt $peerGraceSec) { continue }
        $peerStartedAt[$r] = Get-Date
        if ($seenAlive[$r]) { $killed += $r; $seenAlive[$r] = $false }
        Write-Log "peer $r is down - starting it"
        Start-ScheduledTask -TaskName "BlockPWatchdog$r"
    }
    if ($killed.Count -and (Get-Date) -gt $quietUntil) {
        Send-Notice 'watchdog killed' "Watchdog process(es) $($killed -join ', ') were killed while running. They have been restarted."
    }
}

function Stop-OtherWatchdogs {
    # For rebaseline and uninstall: the others hold the old state in RAM and would
    # revert the change. Kill and disable in a loop until a pass finds nobody, so a
    # watchdog started by its trigger or by a dying peer cannot slip through.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $p = @(Get-WatchdogProcesses)
        $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        foreach ($r in $others) { Disable-ScheduledTask -TaskName "BlockPWatchdog$r" | Out-Null }
        if ($p.Count -eq 0) { return }
        Start-Sleep -Milliseconds 300
    }
}

function Start-OtherWatchdogs {
    foreach ($r in $others) {
        Enable-ScheduledTask -TaskName "BlockPWatchdog$r" | Out-Null
        Start-ScheduledTask -TaskName "BlockPWatchdog$r"
    }
    # They were stopped on purpose: no "killed" notice while they come back.
    $seenAlive.Clear()
    $script:quietUntil = (Get-Date).AddSeconds(30)
}

# ------------------------------------------------------------------- tasks

function Register-WatchdogTask {
    # Same as the installer: the every-minute trigger is offset by the role's slot, so
    # after a kill-all some watchdog is back within 60/Count seconds.
    param([string] $ForRole)
    $offset = [array]::IndexOf($roles, $ForRole) * [int] [math]::Floor(60 / $Count)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Role $ForRole -Count $Count"
    $tBoot  = New-ScheduledTaskTrigger -AtStartup
    $tRep   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddSeconds($offset) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $prin   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    Register-ScheduledTask -TaskName "BlockPWatchdog$ForRole" -Action $action -Trigger @($tBoot, $tRep) `
        -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
}

function Confirm-WatchdogTask {
    param([string] $ForRole)
    $name = "BlockPWatchdog$ForRole"
    $t = Get-ScheduledTask -TaskName $name
    $ok = $t -and
          ($t.Principal.UserId -match 'SYSTEM') -and
          ($t.Actions.Count -eq 1) -and
          ($t.Actions[0].Arguments -like "*$scriptPath*-Role $ForRole -Count $Count") -and
          ($t.Triggers.Count -ge 2)
    if (-not $ok) {
        try {
            Register-WatchdogTask -ForRole $ForRole
            Send-Notice 'watchdog task removed or altered' "Scheduled task $name was deleted or changed. It has been re-registered."
        } catch { Write-Log "ERROR re-registering ${name}: $($_.Exception.Message)" }
    } elseif ($t.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $name | Out-Null
        Send-Notice 'watchdog task disabled' "Scheduled task $name was disabled. It has been re-enabled."
    }
}

function Confirm-LauncherTask {
    # BlockP.exe is requireAdministrator AND aborts (0x80000003) unless it is the
    # session owner, so "elevated, as the logged-on user" is the only thing it accepts.
    param([string] $Name, [string] $User, [switch] $AtLogon)
    $t = Get-ScheduledTask -TaskName $Name
    $ok = $t -and $t.Principal.UserId -and
          ($t.Principal.UserId.Split('\')[-1] -eq $User.Split('\')[-1]) -and
          ($t.Principal.RunLevel -eq 'Highest') -and
          ($t.Actions.Count -ge 1) -and ($t.Actions[0].Execute -eq $exePath)
    if (-not $ok) {
        try {
            $action = New-ScheduledTaskAction -Execute $exePath -Argument '--hidden'
            $prin   = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
            $set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            if ($AtLogon) {
                $trig = New-ScheduledTaskTrigger -AtLogOn -User $User
                Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trig -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
            } else {
                Register-ScheduledTask -TaskName $Name -Action $action -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
            }
            Write-Log "(re)registered $Name for $User"
        } catch {
            Write-Log "ERROR registering ${Name}: $($_.Exception.Message)"
            return $false
        }
    }
    if ((Get-ScheduledTask -TaskName $Name).State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $Name | Out-Null
        Write-Log "re-enabled $Name"
    }
    return $true
}

# ------------------------------------------------------------------- BlockP

function Get-InteractiveUser {
    $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if (-not $p) { return $null }
    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
    if (-not $o.User) { return $null }
    if ($o.Domain) { return "$($o.Domain)\$($o.User)" }
    return $o.User
}

function Stop-BlockP {
    # preventUninstallMode makes each instance spawn a successor, so kill until the
    # count stays at zero.
    $deadline = (Get-Date).AddSeconds(20); $zero = 0
    while ((Get-Date) -lt $deadline) {
        $p = @(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue)
        if ($p.Count -eq 0) { $zero++; if ($zero -ge 4) { return $true } }
        else { $zero = 0; $p | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$lastLaunch = [datetime]::MinValue

function Start-BlockP {
    param([switch] $Force)
    if (-not $Force -and ((Get-Date) - $lastLaunch).TotalSeconds -lt $relaunchGapSec) { return }
    $user = Get-InteractiveUser
    if (-not $user) { return }
    if (Confirm-LauncherTask -Name $launchTask -User $user) {
        $script:lastLaunch = Get-Date
        Start-ScheduledTask -TaskName $launchTask
        # Callers hold the repair mutex. Keep it until BlockP shows up, or every other
        # watchdog sees zero processes the moment it gets the mutex and launches again.
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue).Count -eq 0) {
            Start-Sleep -Milliseconds 250
        }
    }
}

function Confirm-BlockPRunning {
    if (@(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue).Count -gt 0) { return }
    if (((Get-Date) - $lastLaunch).TotalSeconds -lt $relaunchGapSec) { return }
    if (-not (Enter-Repair -TimeoutMs 0)) { return }   # the other role is mid-repair
    try {
        if (@(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue).Count -eq 0) {
            Write-Log 'BlockP not running - relaunching'
            Start-BlockP
        }
    } finally { Exit-Repair }
}

# ------------------------------------------------------- BlockP's own updater
# electron-updater installs a downloaded update by quitting BlockP and running the setup
# from %LOCALAPPDATA%\blockp-updater. The setup has to close every BlockP.exe and replace
# the files. Relaunching BlockP under it breaks the install, and BlockP retries on its next
# start, which is the restart loop seen after 05.11.2026. So while a genuine BlockP setup
# runs, relaunch and config repair pause. Genuine = in a blockp-updater folder AND validly
# signed by NovaFocus LLC. The pause is capped per run and per hour, so starting the setup
# by hand cannot switch enforcement off for long.

$installerSeen   = @{}                                     # pid -> first seen
$sigCache        = @{}                                     # path|mtime -> genuine?
$pauseTicks      = New-Object 'Collections.Generic.Queue[datetime]'
$lastInstallerAt = [datetime]::MinValue

function Get-BlockPInstallers {
    @(Get-CimInstance Win32_Process -Filter "ExecutablePath LIKE '%blockp-updater%'" |
        Where-Object { $_.ExecutablePath -match '^[A-Za-z]:\\Users\\[^\\]+\\AppData\\Local\\blockp-updater\\' })
}

function Test-GenuineInstaller {
    param([string] $Path)
    if (-not $Path) { return $false }
    $item = $null
    try { $item = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $false }
    $key = "$Path|$($item.LastWriteTimeUtc.Ticks)"
    if (-not $sigCache.ContainsKey($key)) {
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $sigCache[$key] = [bool] ($s -and $s.Status -eq 'Valid' -and $s.SignerCertificate -and
                                  $s.SignerCertificate.Subject -match '(^|, )CN=NovaFocus LLC(,|$)')
    }
    return $sigCache[$key]
}

function Test-UpdatePause {
    # $true = a BlockP update is installing: do not relaunch BlockP or touch config.json.
    $now = Get-Date
    while ($pauseTicks.Count -and ($now - $pauseTicks.Peek()).TotalMinutes -ge 60) { [void] $pauseTicks.Dequeue() }

    $live = @(Get-BlockPInstallers | Where-Object { Test-GenuineInstaller $_.ExecutablePath })
    $livePids = @($live | ForEach-Object { [string] $_.ProcessId })
    foreach ($k in @($installerSeen.Keys)) { if ($livePids -notcontains $k) { $installerSeen.Remove($k) } }

    $inTime = 0
    foreach ($p in $live) {
        $k = [string] $p.ProcessId
        if (-not $installerSeen.ContainsKey($k)) {
            $installerSeen[$k] = $now
            Write-Log "BlockP installer running ($($p.ExecutablePath), pid $k) - pausing relaunch and config repair"
        }
        if (($now - $installerSeen[$k]).TotalSeconds -lt $installerMaxSec) { $inTime++ }
    }

    if ($inTime) {
        if ($pauseTicks.Count * $pollMs / 1000 -ge $installerBudgetSec) {
            Send-Notice 'BlockP installer pause used up' "A BlockP installer has paused the watchdogs for more than $([int] ($installerBudgetSec / 60)) minutes in the last hour. Enforcement has resumed while it is still running."
            return $false
        }
        $pauseTicks.Enqueue($now)
        $script:lastInstallerAt = $now
        return $true
    }
    if ($live.Count) {
        Send-Notice 'BlockP installer running long' "A BlockP installer has been running for more than $([int] ($installerMaxSec / 60)) minutes. Enforcement has resumed."
        return $false
    }
    return (($now - $lastInstallerAt).TotalSeconds -lt $installerGraceSec)
}

# ------------------------------------------------------------- config.json

$badReads = 0

function Get-ConfigDiff {
    param($Cfg)
    $diffs = @()
    foreach ($p in $state.enforced.PSObject.Properties) {
        $want = $p.Value
        $have = $Cfg.PSObject.Properties[$p.Name]
        if (-not $have) { $diffs += "$($p.Name): missing (should be $want)"; continue }
        if ([string] $have.Value -cne [string] $want -or ($have.Value -is [bool]) -ne ($want -is [bool])) {
            $diffs += "$($p.Name): $($have.Value) (should be $want)"
        }
    }
    return , $diffs
}

function Test-Config {
    if (-not $state) { return }
    $path = $state.configPath
    $raw = $null; $cfg = $null
    try { $raw = [IO.File]::ReadAllText($path, $utf8NoBom) } catch { }
    if ($raw) { try { $cfg = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $cfg = $null } }

    if (-not $cfg) {
        # One bad read can be BlockP mid-write. Two in a row is real.
        $script:badReads++
        if ($badReads -lt 2) { return }
        $diffs = @('config.json missing or unreadable')
    } else {
        $script:badReads = 0
        $diffs = Get-ConfigDiff $cfg
        if ($diffs.Count -eq 0) { $script:lastGood = $raw; return }
    }

    if (-not (Enter-Repair)) { return }
    try {
        # Re-check under the lock: the other role may have just fixed it.
        $raw = $null; $cfg = $null
        try { $raw = [IO.File]::ReadAllText($path, $utf8NoBom) } catch { }
        if ($raw) { try { $cfg = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $cfg = $null } }
        if ($cfg -and (Get-ConfigDiff $cfg).Count -eq 0) { return }

        # Kill BlockP first so it cannot write its in-memory (possibly weakened) state
        # back over the repair on exit, and so it re-reads the file on relaunch.
        [void] (Stop-BlockP)

        if ($cfg) {
            foreach ($p in $state.enforced.PSObject.Properties) {
                # Set in place so key order (and the diff BlockP sees) stays the same.
                $have = $cfg.PSObject.Properties[$p.Name]
                if ($have) { $have.Value = $p.Value }
                else { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
            }
            $text = $cfg | ConvertTo-Json -Depth 32
        } elseif ($lastGood) {
            $text = $lastGood
        } else {
            Write-Log 'ERROR: config.json unreadable and no good copy in RAM'
            return
        }
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-TextNoBom -Path $path -Text $text
        $script:badReads = 0
        Send-Notice 'BlockP settings changed' ("BlockP's config.json was changed and has been restored:`n  " + ($diffs -join "`n  "))
        Start-BlockP -Force
    } finally { Exit-Repair }
}

# ------------------------------------------------------------ own files

function Confirm-OwnFiles {
    foreach ($entry in @(
        @{ Name = 'watchdog.ps1'; Path = $scriptPath; Bytes = $ram.Script },
        @{ Name = 'state.json';   Path = $statePath;  Bytes = $ram.State  },
        @{ Name = 'smtp.bin';     Path = $smtpPath;   Bytes = $ram.Smtp   })) {
        if ($null -eq $entry.Bytes) { continue }
        $disk = Read-Bytes $entry.Path
        if ((ConvertTo-B64 $disk) -ne (ConvertTo-B64 $entry.Bytes)) {
            try {
                if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
                [IO.File]::WriteAllBytes($entry.Path, $entry.Bytes)
                Send-Notice 'watchdog files changed' "$($entry.Name) was deleted or edited. It has been restored from memory."
            } catch { Write-Log "ERROR restoring $($entry.Name): $($_.Exception.Message)" }
        }
    }
}

# ------------------------------------------------------------ unlock (role A)
# The code only ever exists in RAM (as a hash) and in the partner's mailbox.

$pending = $null
$lastRequest = [datetime]::MinValue

function Write-UnlockStatus {
    param([string] $RequestId, [string] $Status, [string] $Message)
    $o = [ordered] @{ requestId = $RequestId; status = $Status; message = $Message; updatedAt = (Get-Date).ToString('s') }
    Write-TextNoBom -Path (Join-Path $unlockDir 'status.json') -Text ($o | ConvertTo-Json)
}

function New-Code {
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $b = New-Object byte[] 8; $rng.GetBytes($b); $rng.Dispose()
    return ([BitConverter]::ToUInt64($b, 0) % 100000000).ToString('D8')
}

function Get-RequestedChanges {
    # Validates a rebaseline request: only keys that are already enforced, and only
    # with the same JSON type. Returns an ordered map, or $null if anything is off.
    param($Set)
    if (-not $Set) { return $null }
    $out = [ordered] @{}
    foreach ($p in $Set.PSObject.Properties) {
        $cur = $state.enforced.PSObject.Properties[$p.Name]
        if (-not $cur) { return $null }
        if ($cur.Value -is [bool] -and $p.Value -isnot [bool]) { return $null }
        if ($cur.Value -is [string] -and $p.Value -isnot [string]) { return $null }
        $out[$p.Name] = $p.Value
    }
    if ($out.Count -eq 0) { return $null }
    return $out
}

function Format-Changes {
    param($Changes)
    ($Changes.Keys | ForEach-Object { "  $_ : $($state.enforced.$_) -> $($Changes[$_])" }) -join "`n"
}

function Invoke-Rebaseline {
    param($Changes)
    $summary = Format-Changes $Changes

    # Stop the others first: they still hold the old state in RAM and would revert both files.
    Stop-OtherWatchdogs

    foreach ($k in $Changes.Keys) { $state.enforced.$k = $Changes[$k] }
    if ($Changes.Contains('accountabilityPartnerEmail')) { $state.partnerEmail = $Changes['accountabilityPartnerEmail'] }
    Write-TextNoBom -Path $statePath -Text ($state | ConvertTo-Json -Depth 32)
    $script:ram.State = Read-Bytes $statePath

    # Now the ordinary enforcement path writes the new values into config.json and
    # restarts BlockP, exactly as it would after tampering - minus the notice.
    $script:suppressNotice = $true
    try { Test-Config } finally { $script:suppressNotice = $false }

    Start-OtherWatchdogs
    Write-Log "rebaselined:`n$summary"
    return $summary
}

function Get-BytesSha256 {
    param([byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-UpgradeScript {
    # Reads the staged unlock\upgrade.ps1 into RAM and deletes it, so the code the
    # partner gets can only ever install these exact bytes. Returns @{ Error } on refusal.
    param([string] $WantSha)
    $staged = Join-Path $unlockDir 'upgrade.ps1'
    $bytes = Read-Bytes $staged
    Remove-Item $staged -Force -ErrorAction SilentlyContinue
    if (-not $bytes -or $bytes.Length -lt 100) { return @{ Error = 'unlock\upgrade.ps1 is missing or empty.' } }
    $sha = Get-BytesSha256 $bytes
    if (-not $WantSha -or $sha -ne $WantSha.ToLowerInvariant()) { return @{ Error = 'The staged script does not match the requested SHA-256.' } }
    if ($ram.Script -and $sha -eq (Get-BytesSha256 $ram.Script)) { return @{ Error = 'That is the version already running.' } }
    foreach ($b in $bytes) { if ($b -gt 127) { return @{ Error = 'The new script is not ASCII-only (PowerShell 5.1 would misread it).' } } }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $errs = $null
    [void] [Management.Automation.Language.Parser]::ParseInput($text, [ref] $null, [ref] $errs)
    if ($errs -and $errs.Count) { return @{ Error = "The new script does not parse: $($errs[0].Message)" } }
    $verRx  = 'BlockP watchdog v\d+(\.\d+)*'
    $oldVer = if ($ram.Script) { [regex]::Match([Text.Encoding]::ASCII.GetString($ram.Script), $verRx).Value } else { '' }
    $newVer = [regex]::Match($text, $verRx).Value
    $oldSha = if ($ram.Script) { Get-BytesSha256 $ram.Script } else { '?' }
    $what = "  from: $oldVer  watchdog.ps1 SHA-256 $oldSha`n  to:   $newVer  watchdog.ps1 SHA-256 $sha ($($bytes.Length) bytes)"
    return @{ Bytes = $bytes; Sha = $sha; What = $what }
}

function Invoke-Upgrade {
    # Same shape as rebaseline: stop the others (they hold the old script in RAM and
    # would revert the swap), swap, mark it as authorised, start them on the new script.
    # This process then exits, and the new watchdogs restart role A within seconds.
    param($Upgrade)
    Stop-OtherWatchdogs
    [IO.File]::WriteAllBytes($scriptPath, $Upgrade.Bytes)
    $script:ram.Script = $Upgrade.Bytes
    Write-TextNoBom -Path $upgradeMark -Text "$($Upgrade.Sha) $((Get-Date).ToString('s'))"
    Start-OtherWatchdogs
    Write-Log "upgraded watchdog.ps1 to $($Upgrade.Sha) - restarting on the new version"
}

function Invoke-Uninstall {
    Write-Log 'uninstall authorised by partner code - standing down'
    Stop-OtherWatchdogs
    foreach ($r in $others) { Unregister-ScheduledTask -TaskName "BlockPWatchdog$r" -Confirm:$false }
    Stop-ScheduledTask -TaskName $launchTask
    Unregister-ScheduledTask -TaskName $launchTask -Confirm:$false
    # This process's own task goes last, at the very end of the script: stopping a
    # running task terminates its process, which would cut the clean-up short.
}

function Invoke-Unlock {
    if ($Role -ne 'A' -or -not $state) { return }
    if (-not (Test-Path $unlockDir)) { return }
    $reqFile = Join-Path $unlockDir 'request.json'
    $tryFile = Join-Path $unlockDir 'attempt.txt'

    if (Test-Path $reqFile) {
        $req = $null
        try { $req = [IO.File]::ReadAllText($reqFile) | ConvertFrom-Json } catch { }
        Remove-Item $reqFile -Force
        if (-not $req -or $req.action -notin 'uninstall', 'rebaseline', 'upgrade') { return }
        $changes = $null; $upgrade = $null
        if ($req.action -eq 'rebaseline') {
            $changes = Get-RequestedChanges $req.set
            if (-not $changes) {
                Write-UnlockStatus $req.requestId 'error' 'Invalid changes: only already-enforced settings, with the same type (true/false stays true/false).'
                return
            }
        }
        if ($req.action -eq 'upgrade') {
            $upgrade = Get-UpgradeScript $req.sha256
            if ($upgrade.Error) { Write-UnlockStatus $req.requestId 'error' "Upgrade refused: $($upgrade.Error)"; return }
        }
        $what = if ($changes) { Format-Changes $changes } elseif ($upgrade) { $upgrade.What } else { '' }

        if ($pending -and ((Get-Date) - $lastRequest).TotalMinutes -lt $requestGapMin -and
            $pending.Action -eq $req.action -and $pending.What -eq $what) {
            # Same request again: re-use the code already mailed instead of spamming the partner.
            $script:pending.RequestId = $req.requestId
            Write-UnlockStatus $req.requestId 'code-sent' "A code for this exact request was sent less than $requestGapMin minutes ago. Use that one."
            return
        }
        $code = New-Code
        $ask = switch ($req.action) {
            'uninstall' { 'REMOVE the BlockP watchdog entirely' }
            'upgrade'   { "UPGRADE the BlockP watchdog program to a new version:`n`n$what`n`nThis replaces the program that enforces the protection. Agree only if $($state.user) told you`nwhat changed and why. The code works only for this exact file (the SHA-256 above).`n" }
            default     { "CHANGE these protected BlockP settings:`n`n$what`n" }
        }
        $body = @"
$($state.user) asked to $ask on $env:COMPUTERNAME.

Code: $code

Only pass this code on if you agree. It is valid for $codeValidMin minutes and $codeAttempts attempts.
A new request makes this code invalid and sends you a new one.

Current protected settings:
$(($state.enforced.PSObject.Properties | ForEach-Object { "  $($_.Name) = $($_.Value)" }) -join "`n")
"@
        if (Send-Mail -To $state.partnerEmail -Subject "BlockP: unlock code requested ($($req.action))" -Body $body) {
            $script:pending = @{
                Action = $req.action; RequestId = $req.requestId; Hash = (Get-Sha256 $code)
                Expires = (Get-Date).AddMinutes($codeValidMin); Left = $codeAttempts
                Changes = $changes; Upgrade = $upgrade; What = $what
            }
            $script:lastRequest = Get-Date
            Write-Log "unlock requested ($($req.action)) - code mailed to partner"
            Write-UnlockStatus $req.requestId 'code-sent' 'Code sent to your accountability partner.'
        } else {
            Write-UnlockStatus $req.requestId 'error' 'Could not send the mail. See watchdog.log.'
        }
        $code = $null
        return
    }

    if (Test-Path $tryFile) {
        $try = ''
        try { $try = ([IO.File]::ReadAllText($tryFile)).Trim() } catch { }
        Remove-Item $tryFile -Force
        if (-not $pending) { Write-UnlockStatus '' 'no-request' 'No code has been requested.'; return }
        $rid = $pending.RequestId
        if ((Get-Date) -gt $pending.Expires) {
            $script:pending = $null
            Write-UnlockStatus $rid 'expired' 'The code expired. Request a new one.'
            return
        }
        if ((Get-Sha256 $try) -ne $pending.Hash) {
            $script:pending.Left--
            if ($pending.Left -le 0) {
                $script:pending = $null
                Write-Log 'unlock: wrong code, attempts exhausted'
                Write-UnlockStatus $rid 'locked' 'Wrong code. No attempts left - request a new code.'
            } else {
                Write-UnlockStatus $rid 'wrong' "Wrong code. $($pending.Left) attempt(s) left."
            }
            return
        }

        $action = $pending.Action
        $changes = $pending.Changes
        $upgrade = $pending.Upgrade
        $script:pending = $null
        if ($action -eq 'upgrade') {
            try {
                Invoke-Upgrade $upgrade
                [void] (Send-Mail -To $state.partnerEmail -Subject 'BlockP: watchdog upgraded' -Body "Your code was used. The BlockP watchdog on ${env:COMPUTERNAME} now runs the new version:`n`n$($upgrade.What)")
                Write-UnlockStatus $rid 'done' "Upgraded:`n$($upgrade.What)`nThe watchdogs restart on the new version within a few seconds."
                $script:restartSelf = $true
            } catch {
                Write-Log "ERROR upgrading: $($_.Exception.Message)"
                Start-OtherWatchdogs   # never leave the others disabled
                Write-UnlockStatus $rid 'error' "Upgrade failed: $($_.Exception.Message)"
            }
        } elseif ($action -eq 'rebaseline') {
            try {
                $notify = $state.partnerEmail   # before a possible partner change
                $summary = Invoke-Rebaseline $changes
                [void] (Send-Mail -To $notify -Subject 'BlockP: protected settings changed' -Body "Your code was used. Changed on ${env:COMPUTERNAME}:`n`n$summary")
                Write-UnlockStatus $rid 'done' "Changed:`n$summary"
            } catch {
                Write-Log "ERROR rebaselining: $($_.Exception.Message)"
                Write-UnlockStatus $rid 'error' "Rebaseline failed: $($_.Exception.Message)"
            }
        } else {
            Write-UnlockStatus $rid 'accepted' 'Code accepted. Removing the watchdog...'
            [void] (Send-Mail -To $state.partnerEmail -Subject 'BlockP: watchdog removed' -Body "Your code was used. The BlockP watchdog on $env:COMPUTERNAME has been removed. BlockP itself is still installed.")
            Invoke-Uninstall
            Write-UnlockStatus $rid 'done' 'Watchdog removed.'
            $script:standDown = $true
        }
    }
}

# ------------------------------------------------------------------- start

$standDown = $false
$restartSelf = $false
$suppressNotice = $false
Write-Log "started (pid $PID)"

# Started by an authorised upgrade? Then the old role A exiting right after is expected,
# not a kill. The mark names this script's hash, so it only quiets the new version.
try {
    $mark = ([IO.File]::ReadAllText($upgradeMark)).Trim().Split(' ')
    if ($ram.Script -and $mark[0] -eq (Get-BytesSha256 $ram.Script) -and
        ((Get-Date) - [datetime]::Parse($mark[1])).TotalSeconds -lt 120) {
        $quietUntil = (Get-Date).AddSeconds(60)
        Write-Log 'started by an upgrade - no kill notices for 60s'
    }
} catch { }

# Were ALL watchdogs down while the machine was up? The staggered triggers bring one
# back within 60/Count seconds, so a longer gap means someone killed them all (and
# probably disabled the tasks). Whoever starts first reports it.
if ($state -and (Get-Date) -gt $quietUntil) {
    try {
        $beats = $roles | ForEach-Object { Join-Path $root "heartbeat-$_.txt" } | Where-Object { Test-Path $_ } | ForEach-Object { (Get-Item $_).LastWriteTime }
        $newest = $beats | Sort-Object -Descending | Select-Object -First 1
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $gap = if ($newest) { ((Get-Date) - $newest).TotalSeconds } else { 0 }
        if ($newest -gt $boot -and $gap -gt ([math]::Floor(60 / $Count) + $allDownSec)) {
            Send-Notice 'watchdogs were stopped' "All $Count watchdogs were not running for about $([int] $gap) seconds (since $($newest.ToString('HH:mm:ss'))) while the PC was on."
        }
    } catch { }
}

$nextTaskCheck = Get-Date

while (-not $standDown) {
    try {
        # Own try: a failed heartbeat write must not skip the rest of this tick.
        try { [IO.File]::WriteAllText($beatFile, "$PID $(Get-Date -Format 's')") } catch { }

        Invoke-Unlock
        if ($standDown -or $restartSelf) { break }

        Confirm-OwnFiles
        if (-not (Test-UpdatePause)) {
            Test-Config
            Confirm-BlockPRunning
        }
        Confirm-Peers

        if ((Get-Date) -ge $nextTaskCheck) {
            # Own task + the next one round the ring: every task has two guardians,
            # without every watchdog querying every task.
            $nextTaskCheck = (Get-Date).AddSeconds($taskCheckSec)
            Confirm-WatchdogTask -ForRole $Role
            Confirm-WatchdogTask -ForRole $nextRole
            if ($state -and (Test-IsLeader)) { [void] (Confirm-LauncherTask -Name $startTask -User $state.user -AtLogon) }
        }
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds $pollMs
}

try { $roleMutex.ReleaseMutex() } catch { }
if ($standDown) {
    Start-Sleep -Seconds 2
    Remove-Item $root -Recurse -Force
    Unregister-ScheduledTask -TaskName "BlockPWatchdog$Role" -Confirm:$false
}
exit 0
