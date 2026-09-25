#Requires -RunAsAdministrator
<#
  Installs the BlockP watchdog (v6): -Count SYSTEM watchdogs (A, B, C, ...) that
  guard BlockP, BlockP's settings, and each other. See README.md.

  First install only. Once installed, this script refuses: changing anything
  goes through uninstall-blockp-watchdog.ps1, which needs a code mailed to your
  accountability partner (-Rebaseline to accept new BlockP settings, no switch to
  remove everything).

  What it needs from you:
    - BlockP set up the way you want it protected. Its CURRENT config.json becomes
      the baseline the watchdogs enforce.
    - An SMTP account that can send mail. Read the README section "Mail account"
      first: if YOU can log into that mailbox, you can read the unlock code in
      its Sent folder.

  Example (Gmail with an app password; you are prompted for the password):
    .\install-blockp-watchdog.ps1 -SmtpUser blockp.watchdog.xyz@gmail.com
#>

param(
    [string] $User         = 'Jonas',
    [string] $PartnerEmail,                       # default: accountabilityPartnerEmail from BlockP
    [string] $SmtpHost     = 'smtp.gmail.com',
    [int]    $SmtpPort     = 587,
    [Parameter(Mandatory)] [string] $SmtpUser,
    [string] $SmtpFrom,                           # default: SmtpUser
    [ValidateRange(2, 16)] [int] $Count = 6,      # ~100 MB RAM each
    [switch] $RestoreAdmin,
    [switch] $IncludeArbeit
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$exePath    = 'C:\Program Files\BlockP\BlockP.exe'
$root       = 'C:\ProgramData\BlockPWatchdog'
$scriptPath = Join-Path $root 'watchdog.ps1'
$statePath  = Join-Path $root 'state.json'
$smtpPath   = Join-Path $root 'smtp.bin'
$unlockDir  = Join-Path $root 'unlock'
$launchTask = 'BlockPWatchdogLaunch'
$startTask  = 'BlockPStartup'
$legacyTask = 'BlockPWatchdog'
$volatile   = @('userId', 'authData', 'ratedVal', 'rateUsDone')
$utf8NoBom  = New-Object System.Text.UTF8Encoding $false
if (-not $SmtpFrom) { $SmtpFrom = $SmtpUser }

$source = Join-Path $PSScriptRoot 'watchdog.ps1'
if (-not (Test-Path $exePath)) { throw "BlockP.exe not found at $exePath" }
if (-not (Test-Path $source))  { throw "watchdog.ps1 not found next to this script ($source)" }

Write-Host '== BlockP watchdog v6 install ==' -ForegroundColor Cyan

# ------------------------------------------------------------- already there?
if (Get-ScheduledTask -TaskName 'BlockPWatchdog?' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^BlockPWatchdog[A-P]$' }) {
    Write-Host ''
    Write-Host 'The watchdogs are already installed. Changes go through the partner code:' -ForegroundColor Yellow
    Write-Host '  .\uninstall-blockp-watchdog.ps1 -Rebaseline   # accept current BlockP settings as the new baseline'
    Write-Host '  .\uninstall-blockp-watchdog.ps1               # remove it, then re-run this installer'
    exit 1
}

# ------------------------------------------------------------ admin membership
$adminGroup = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
$isAdmin = [bool](Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$User" })
Write-Host "$User is currently an administrator: $isAdmin"

if ($RestoreAdmin) {
    $targets = @($User)
    if ($IncludeArbeit) { $targets += 'Arbeit' }
    foreach ($t in $targets) {
        if (Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$t" }) {
            Write-Host "  $t is already in $adminGroup"
        } else {
            Add-LocalGroupMember -Group $adminGroup -Member $t
            Write-Host "  added $t to $adminGroup" -ForegroundColor Green
        }
    }
    Write-Host '  NOTE: sign out and back in for the new token to take effect.' -ForegroundColor Yellow
} elseif (-not $isAdmin) {
    Write-Host "$User is a standard user, so BlockP.exe cannot elevate and WILL NOT RUN. Use -RestoreAdmin." -ForegroundColor Yellow
}

# --------------------------------------------------------- baseline from BlockP
$sid = (New-Object Security.Principal.NTAccount $User).Translate([Security.Principal.SecurityIdentifier]).Value
$profilePath = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
if (-not $profilePath) { throw "No profile found for $User ($sid)" }
$configPath = Join-Path $profilePath 'AppData\Roaming\BlockP\config.json'
if (-not (Test-Path $configPath)) { throw "BlockP config not found at $configPath - start BlockP and sign in first" }

$raw = [IO.File]::ReadAllText($configPath, $utf8NoBom)
$cfg = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json

# Every top-level scalar except the ones BlockP legitimately rewrites on its own.
# Later changes go through uninstall-blockp-watchdog.ps1 -Rebaseline -Set key=value.
$enforced = [ordered] @{}
foreach ($p in $cfg.PSObject.Properties) {
    if ($volatile -contains $p.Name) { continue }
    if ($p.Value -isnot [bool] -and $p.Value -isnot [string] -and $p.Value -isnot [int] -and $p.Value -isnot [long]) { continue }
    $enforced[$p.Name] = $p.Value
}

if (-not $PartnerEmail) { $PartnerEmail = $cfg.accountabilityPartnerEmail }
if (-not $PartnerEmail) { throw 'No partner email: pass -PartnerEmail or set one in BlockP first' }

Write-Host ''
Write-Host 'These settings will be enforced (changes are reverted within ~1s):' -ForegroundColor Cyan
foreach ($k in $enforced.Keys) {
    $v = $enforced[$k]
    $color = if ($v -is [bool] -and -not $v -and $k -ne 'timeDelayMode') { 'Yellow' } else { 'Gray' }
    Write-Host ("  {0,-28} = {1}" -f $k, $v) -ForegroundColor $color
}
Write-Host "Not enforced (BlockP rewrites these): $($volatile -join ', ')"
Write-Host "Unlock codes and tamper notices go to: $PartnerEmail"
Write-Host ''
Write-Host 'Anything you want changed later needs a code from that person.' -ForegroundColor Yellow
if ((Read-Host 'Type YES to lock this in') -cne 'YES') { Write-Host 'Aborted.'; exit 1 }

# -------------------------------------------------------------------- SMTP
Write-Host ''
$secure = Read-Host "Password / app password for $SmtpUser" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $smtpPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
# Google displays app passwords as "abcd efgh ijkl mnop"; the spaces are not part of it.
$smtpPass = $smtpPass -replace '\s', ''
if (-not $smtpPass) {
    # .NET's SmtpClient silently skips AUTH with an empty password, and Gmail then
    # answers "5.7.0 Authentication Required" - which looks like a server problem.
    Write-Host 'Empty password (a paste into the hidden prompt can fail silently - try right-click to paste).' -ForegroundColor Red
    exit 1
}
Write-Host "  got a $($smtpPass.Length)-character password"   # Gmail app passwords: 16

function Send-TestMail {
    param([string] $To, [string] $Subject, [string] $Body)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.Mail.SmtpClient($SmtpHost, $SmtpPort)
    $client.EnableSsl   = $true
    $client.Timeout     = 20000
    $client.Credentials = New-Object Net.NetworkCredential($SmtpUser, $smtpPass)
    $msg = New-Object Net.Mail.MailMessage($SmtpFrom, $To, $Subject, $Body)
    try { $client.Send($msg) } finally { $msg.Dispose(); $client.Dispose() }
}

Write-Host "sending a test mail to $SmtpFrom ..."
try {
    Send-TestMail -To $SmtpFrom -Subject 'BlockP watchdog: SMTP test' -Body 'If you can read this, the watchdog can send mail.'
    Write-Host '  sent.' -ForegroundColor Green
} catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($SmtpHost -eq 'smtp.gmail.com') {
        Write-Host '  Gmail needs an APP password (Google Account > Security > 2-Step Verification > App passwords),'
        Write-Host '  not the normal account password, and -SmtpUser must be that account''s full address.'
    }
    Write-Host '  Without working mail there is no way to get an unlock code. Not installing.'
    exit 1
}

if ((Read-Host "Also send $PartnerEmail a short 'you are my accountability partner for this' mail? (y/N)") -eq 'y') {
    try {
        Send-TestMail -To $PartnerEmail -Subject 'BlockP: you are my accountability partner' -Body @"
Hi,

I set up a watchdog on my PC ($env:COMPUTERNAME) that keeps my BlockP blocker running
and its settings locked. If I ever want to remove it or change its settings, it will
mail YOU an 8-digit code, and I need that code from you.

You will also get a mail if it detects that someone tried to tamper with it.

Only give me a code if you agree with what I am asking for.
"@
        Write-Host '  sent.' -ForegroundColor Green
    } catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# ---------------------------------------------------- stop legacy + BlockP
Write-Host ''
if (Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $legacyTask -Confirm:$false
    Write-Host "  removed legacy v4 task '$legacyTask'"
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'BlockPWatchdog\\watchdog\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($t in $startTask, $launchTask) {
    try { Disable-ScheduledTask -TaskName $t -ErrorAction Stop | Out-Null } catch { }
}
Write-Host 'clearing BlockP processes...'
$deadline = (Get-Date).AddSeconds(45); $zero = 0; $kills = 0
while ((Get-Date) -lt $deadline) {
    $p = @(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0) { $zero++; if ($zero -ge 6) { break } }
    else { $zero = 0; $kills += $p.Count; $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}
Write-Host "  $kills kills, field clear=$($zero -ge 6)"

# ------------------------------------------------------------------- files
if (Test-Path $root) { & icacls.exe $root /reset /t /q | Out-Null }
New-Item -ItemType Directory -Path $root -Force | Out-Null
New-Item -ItemType Directory -Path $unlockDir -Force | Out-Null
Get-ChildItem $root -Filter 'heartbeat-*.txt' | Remove-Item -Force   # no false "were stopped" mail

Copy-Item $source $scriptPath -Force

$state = [ordered] @{
    version      = 6
    user         = $User
    configPath   = $configPath
    partnerEmail = $PartnerEmail
    enforced     = $enforced
    volatileKeys = $volatile
    snapshot     = [Convert]::ToBase64String($utf8NoBom.GetBytes($raw))
    installedAt  = (Get-Date).ToString('s')
}
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 32), $utf8NoBom)

# LocalMachine DPAPI: SYSTEM can decrypt it. So can any admin who goes looking -
# this keeps the password out of plain sight, nothing more.
$smtpJson = [ordered] @{ host = $SmtpHost; port = $SmtpPort; user = $SmtpUser; pass = $smtpPass; from = $SmtpFrom } | ConvertTo-Json
$blob = [Security.Cryptography.ProtectedData]::Protect($utf8NoBom.GetBytes($smtpJson), $null, 'LocalMachine')
[IO.File]::WriteAllBytes($smtpPath, $blob)
$smtpPass = $null; $smtpJson = $null

# SYSTEM + Administrators only. Standard users (and a demoted future you) get nothing.
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /q | Out-Null
Write-Host "  wrote $root (watchdog.ps1, state.json, smtp.bin)"

# ------------------------------------------------------------------- tasks
$action = New-ScheduledTaskAction -Execute $exePath -Argument '--hidden'
$prin   = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $launchTask -Action $action -Principal $prin -Settings $set -Force | Out-Null
Register-ScheduledTask -TaskName $startTask -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $User) -Principal $prin -Settings $set -Force | Out-Null
Write-Host "  '$launchTask' and '$startTask' -> $User / Interactive / Highest"

# Same as Register-WatchdogTask in watchdog.ps1. The every-minute triggers are staggered
# by 60/Count seconds, so after a kill-all one of them is back within that time.
$roles = @(0..($Count - 1) | ForEach-Object { [string] [char] (65 + $_) })
$slot  = [int] [math]::Floor(60 / $Count)
for ($i = 0; $i -lt $Count; $i++) {
    $r = $roles[$i]
    $wAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Role $r -Count $Count"
    $tBoot = New-ScheduledTaskTrigger -AtStartup
    $tRep  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddSeconds($i * $slot) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $wPrin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $wSet  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    Register-ScheduledTask -TaskName "BlockPWatchdog$r" -Action $wAction -Trigger @($tBoot, $tRep) -Principal $wPrin -Settings $wSet -Force | Out-Null
    Start-ScheduledTask -TaskName "BlockPWatchdog$r"
    Write-Host ("  registered + started 'BlockPWatchdog$r' (SYSTEM, re-triggered at :{0:D2} every minute)" -f ($i * $slot))
}

# ------------------------------------------------------------------ verify
Start-Sleep -Seconds 10
Write-Host ''
foreach ($r in $roles) {
    $hb = Join-Path $root "heartbeat-$r.txt"
    $age = if (Test-Path $hb) { [int] ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds } else { $null }
    if ($null -ne $age -and $age -lt 6) { Write-Host "watchdog $r alive (heartbeat ${age}s old)" -ForegroundColor Green }
    else { Write-Host "watchdog $r NOT alive - check $root\watchdog.log" -ForegroundColor Red }
}
$p = @(Get-Process -Name 'BlockP' -ErrorAction SilentlyContinue)
if ($p.Count -gt 0) { Write-Host "BlockP running: $($p.Count) process(es). Go test a blocked site." -ForegroundColor Green }
else { Write-Host 'BlockP not up yet - the watchdogs will start it within ~20s. If you just ran -RestoreAdmin, sign out and in first.' -ForegroundColor Yellow }

Write-Host ''
Write-Host 'Health:  .\diagnose-watchdog.ps1'
Write-Host 'Log:     C:\ProgramData\BlockPWatchdog\watchdog.log'
