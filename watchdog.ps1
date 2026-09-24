<#
  BlockP watchdog v5. Runs as SYSTEM, twice: -Role A and -Role B.

  Each instance is long-lived and, every second:
    - keeps BlockP running as the interactive user
    - enforces the protected keys of BlockP's config.json from a copy held in RAM
    - restores its own files (this script, state.json, smtp.bin) from RAM if touched
    - restarts its peer if the peer's heartbeat goes stale
  and every 5 seconds re-registers / re-enables any task that was removed or altered.

  Role A additionally handles the unlock protocol (uninstall / rebaseline need a code
  that is mailed to the accountability partner) and sends tamper notices.

  Task Scheduler re-triggers both tasks every minute (MultipleInstances IgnoreNew), so
  killing both processes costs at most ~60 seconds, and a named mutex keeps each role
  a singleton.

  ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#>
param(
    [ValidateSet('A', 'B')] [string] $Role = 'A'
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
$launchTask = 'BlockPWatchdogLaunch'
$startTask  = 'BlockPStartup'
$peerRole   = if ($Role -eq 'A') { 'B' } else { 'A' }
$beatFile   = Join-Path $root "heartbeat-$Role.txt"
$peerBeat   = Join-Path $root "heartbeat-$peerRole.txt"

$pollMs          = 1000
$taskCheckSec    = 5
$peerStaleSec    = 6
$peerGraceSec    = 20
$relaunchGapSec  = 20
$noticeGapMin    = 30
$codeValidMin    = 60
$codeAttempts    = 3
$requestGapMin   = 5

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
    # Tamper notices go to the partner. Only A sends, unless A is down, so one event
    # does not produce two mails. Rate-limited per kind, in RAM.
    param([string] $Kind, [string] $Text)
    Write-Log "NOTICE ($Kind): $Text"
    if (-not $state -or $suppressNotice) { return }
    if ($Role -eq 'B' -and (Test-PeerAlive)) { return }
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

function Test-PeerAlive {
    try {
        $age = ((Get-Date) - (Get-Item $peerBeat -ErrorAction Stop).LastWriteTime).TotalSeconds
        return ($age -lt $peerStaleSec)
    } catch { return $false }
}

function Get-WatchdogProcesses {
    param([string] $ForRole)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'BlockPWatchdog\\watchdog\.ps1' -and $_.CommandLine -match "-Role $ForRole" }
}

$peerStartedAt = [datetime]::MinValue

function Confirm-Peer {
    if (Test-PeerAlive) { return }
    if (((Get-Date) - $peerStartedAt).TotalSeconds -lt $peerGraceSec) { return }
    $script:peerStartedAt = Get-Date
    Write-Log "peer $peerRole heartbeat stale - starting it"
    Start-ScheduledTask -TaskName "BlockPWatchdog$peerRole"
}

# ------------------------------------------------------------------- tasks

function Register-WatchdogTask {
    param([string] $ForRole)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Role $ForRole"
    $tBoot  = New-ScheduledTaskTrigger -AtStartup
    $tRep   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
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
          ($t.Actions[0].Arguments -like "*$scriptPath*-Role $ForRole*") -and
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

    # Stop B first: it still holds the old state in RAM and would revert both files.
    Get-WatchdogProcesses -ForRole 'B' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Stop-ScheduledTask -TaskName 'BlockPWatchdogB'

    foreach ($k in $Changes.Keys) { $state.enforced.$k = $Changes[$k] }
    if ($Changes.Contains('accountabilityPartnerEmail')) { $state.partnerEmail = $Changes['accountabilityPartnerEmail'] }
    Write-TextNoBom -Path $statePath -Text ($state | ConvertTo-Json -Depth 32)
    $script:ram.State = Read-Bytes $statePath

    # Now the ordinary enforcement path writes the new values into config.json and
    # restarts BlockP, exactly as it would after tampering - minus the notice.
    $script:suppressNotice = $true
    try { Test-Config } finally { $script:suppressNotice = $false }

    Start-ScheduledTask -TaskName 'BlockPWatchdogB'
    Write-Log "rebaselined:`n$summary"
    return $summary
}

function Invoke-Uninstall {
    Write-Log 'uninstall authorised by partner code - standing down'
    Get-WatchdogProcesses -ForRole 'B' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    foreach ($t in 'BlockPWatchdogB', 'BlockPWatchdogA', 'BlockPWatchdogLaunch') {
        Stop-ScheduledTask -TaskName $t
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
    }
    Get-WatchdogProcesses -ForRole 'B' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
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
        if (-not $req -or $req.action -notin 'uninstall', 'rebaseline') { return }
        $changes = $null
        if ($req.action -eq 'rebaseline') {
            $changes = Get-RequestedChanges $req.set
            if (-not $changes) {
                Write-UnlockStatus $req.requestId 'error' 'Invalid changes: only already-enforced settings, with the same type (true/false stays true/false).'
                return
            }
        }
        $what = if ($changes) { Format-Changes $changes } else { '' }

        if ($pending -and ((Get-Date) - $lastRequest).TotalMinutes -lt $requestGapMin -and
            $pending.Action -eq $req.action -and $pending.What -eq $what) {
            # Same request again: re-use the code already mailed instead of spamming the partner.
            $script:pending.RequestId = $req.requestId
            Write-UnlockStatus $req.requestId 'code-sent' "A code for this exact request was sent less than $requestGapMin minutes ago. Use that one."
            return
        }
        $code = New-Code
        $ask = if ($req.action -eq 'uninstall') { 'REMOVE the BlockP watchdog entirely' } else { "CHANGE these protected BlockP settings:`n`n$what`n" }
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
                Changes = $changes; What = $what
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
        $script:pending = $null
        if ($action -eq 'rebaseline') {
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
$suppressNotice = $false
Write-Log "started (pid $PID)"

# Were both watchdogs down while the machine was up? That only happens when someone
# killed them, so it is worth a mail.
if ($Role -eq 'A' -and $state) {
    try {
        $beats = @($beatFile, $peerBeat) | Where-Object { Test-Path $_ } | ForEach-Object { (Get-Item $_).LastWriteTime }
        $newest = $beats | Sort-Object -Descending | Select-Object -First 1
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($newest -and $newest -gt $boot -and ((Get-Date) - $newest).TotalMinutes -gt 3) {
            $mins = [int] ((Get-Date) - $newest).TotalMinutes
            Send-Notice 'watchdogs were stopped' "Both watchdogs were not running for about $mins minutes (since $($newest.ToString('HH:mm'))) while the PC was on."
        }
    } catch { }
}

$nextTaskCheck = Get-Date

while (-not $standDown) {
    try {
        [IO.File]::WriteAllText($beatFile, "$PID $(Get-Date -Format 's')")

        Invoke-Unlock
        if ($standDown) { break }

        Confirm-OwnFiles
        Test-Config
        Confirm-BlockPRunning
        Confirm-Peer

        if ((Get-Date) -ge $nextTaskCheck) {
            $nextTaskCheck = (Get-Date).AddSeconds($taskCheckSec)
            Confirm-WatchdogTask -ForRole $peerRole
            Confirm-WatchdogTask -ForRole $Role
            if ($state) { [void] (Confirm-LauncherTask -Name $startTask -User $state.user -AtLogon) }
        }
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds $pollMs
}

if ($standDown) {
    Start-Sleep -Seconds 2
    Remove-Item $root -Recurse -Force
}
try { $roleMutex.ReleaseMutex() } catch { }
exit 0
