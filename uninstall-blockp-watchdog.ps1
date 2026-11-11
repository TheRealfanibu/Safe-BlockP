#Requires -RunAsAdministrator
<#
  Removes the BlockP watchdogs (v5/v6), or with -Rebaseline changes protected settings.
  Either way it needs a code that watchdog A mails to your accountability partner.
  The code is never written to disk: A keeps only its hash in memory.

  This script does not remove or change anything itself. It asks watchdog A, and A
  does it after checking the code. Editing this script therefore gets you nothing.

    .\uninstall-blockp-watchdog.ps1
    .\uninstall-blockp-watchdog.ps1 -Rebaseline -Set timeDelayMode=true
    .\uninstall-blockp-watchdog.ps1 -Rebaseline -Set blockGuestMode=false, accountabilityPartnerEmail=new@example.com
    .\uninstall-blockp-watchdog.ps1 -Upgrade [-Source .\watchdog.ps1]   (or upgrade-blockp-watchdog.ps1)

  -Upgrade swaps the running watchdog.ps1 for a new version in place (v6.1 and later). The
  partner's mail names the new file's SHA-256, and the code installs only that file.
#>

param(
    [switch]   $Rebaseline,
    [string[]] $Set,
    [switch]   $Upgrade,
    [string]   $Source = (Join-Path $PSScriptRoot 'watchdog.ps1')
)

$ErrorActionPreference = 'Stop'
$root      = 'C:\ProgramData\BlockPWatchdog'
$unlockDir = Join-Path $root 'unlock'
$status    = Join-Path $unlockDir 'status.json'

# ------------------------------------------------------------ legacy v4 path
if (-not (Get-ScheduledTask -TaskName 'BlockPWatchdogA' -ErrorAction SilentlyContinue)) {
    if (Get-ScheduledTask -TaskName 'BlockPWatchdog' -ErrorAction SilentlyContinue) {
        Write-Host 'Only the old v4 watchdog is installed - removing it (no code needed for v4).'
        foreach ($t in 'BlockPWatchdog', 'BlockPWatchdogLaunch') {
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        }
        if (Test-Path $root) { & icacls.exe $root /reset /t /q | Out-Null; Remove-Item $root -Recurse -Force }
        Write-Host 'Done.'
    } else {
        Write-Host 'No watchdog installed.'
    }
    exit 0
}

if (-not (Test-Path $unlockDir)) { throw "$unlockDir missing - is watchdog A running? Check watchdog.log" }

function Read-Status {
    try { return [IO.File]::ReadAllText($status) | ConvertFrom-Json } catch { return $null }
}

function Wait-Status {
    # Waits for A to answer this request with a status other than the one we last saw.
    param([string] $RequestId, [string] $Since, [int] $TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path $root)) { return [pscustomobject] @{ status = 'gone' } }
        $s = Read-Status
        if ($s -and $s.requestId -eq $RequestId -and $s.updatedAt -ne $Since) { return $s }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

if ($Rebaseline -and $Upgrade) { throw 'Use -Rebaseline or -Upgrade, not both.' }
$action = if ($Rebaseline) { 'rebaseline' } elseif ($Upgrade) { 'upgrade' } else { 'uninstall' }
$request = [ordered] @{ action = $action; requestId = [guid]::NewGuid().ToString() }

if ($Upgrade) {
    # Check here what watchdog A checks too, so a broken file fails fast and costs no mail.
    $Source = (Resolve-Path $Source).Path
    $bytes = [IO.File]::ReadAllBytes($Source)
    if ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1) { throw "$Source is not ASCII-only." }
    $errs = $null
    [void] [Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::ASCII.GetString($bytes), [ref] $null, [ref] $errs)
    if ($errs) { throw "$Source does not parse: $($errs[0].Message)" }
    $request.sha256 = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllBytes((Join-Path $unlockDir 'upgrade.ps1'), $bytes)
    Write-Host "Requesting an upgrade to $Source" -ForegroundColor Cyan
    Write-Host "  SHA-256 $($request.sha256)"
}

if ($Rebaseline) {
    if (-not $Set) { throw 'Say what to change, e.g. -Set timeDelayMode=true' }
    $changes = [ordered] @{}
    foreach ($s in $Set) {
        $k, $v = $s -split '=', 2
        if (-not $k -or $null -eq $v) { throw "Expected key=value, got '$s'" }
        $changes[$k.Trim()] = switch -Regex ($v.Trim()) {
            '^(?i)true$'  { $true; break }
            '^(?i)false$' { $false; break }
            default       { $v.Trim() }
        }
    }
    Write-Host 'Requesting this change:' -ForegroundColor Cyan
    $changes.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) -> $($_.Value)" }
    $request.set = $changes
} elseif ($Set) {
    throw '-Set only makes sense with -Rebaseline'
}
$rid = $request.requestId
$last = (Read-Status).updatedAt

Write-Host "Requesting an unlock code ($action)..." -ForegroundColor Cyan
[IO.File]::WriteAllText((Join-Path $unlockDir 'request.json'), ($request | ConvertTo-Json -Depth 5))

$s = Wait-Status -RequestId $rid -Since $last -TimeoutSec 90
if (-not $s) {
    Write-Host 'Watchdog A did not answer within 90s. Is it running? See watchdog.log.' -ForegroundColor Red
    if ($Upgrade) {
        Remove-Item (Join-Path $unlockDir 'upgrade.ps1') -Force -ErrorAction SilentlyContinue
        Write-Host 'A watchdog older than v6.1 ignores upgrade requests. Use uninstall + install once.' -ForegroundColor Yellow
    }
    exit 1
}
if ($s.status -ne 'code-sent') { Write-Host $s.message -ForegroundColor Red; exit 1 }
Write-Host $s.message -ForegroundColor Green
Write-Host 'Ask your partner for the 8-digit code. It is valid for 60 minutes.'

while ($true) {
    $code = (Read-Host 'Code (empty to cancel)').Trim()
    if (-not $code) { Write-Host 'Cancelled. The code stays valid until it expires.'; exit 1 }
    $last = (Read-Status).updatedAt
    [IO.File]::WriteAllText((Join-Path $unlockDir 'attempt.txt'), $code)
    $s = Wait-Status -RequestId $rid -Since $last -TimeoutSec 60
    if (-not $s) { Write-Host 'No answer from watchdog A.' -ForegroundColor Red; exit 1 }

    switch ($s.status) {
        'wrong'    { Write-Host $s.message -ForegroundColor Yellow; continue }
        'accepted' {
            Write-Host $s.message -ForegroundColor Green
            $s = Wait-Status -RequestId $rid -Since $s.updatedAt -TimeoutSec 60
            if ($s -and $s.status -in 'done', 'gone') { Write-Host 'Watchdog removed. BlockP itself is still installed.' -ForegroundColor Green }
            else { Write-Host 'Removal did not confirm - check with diagnose-watchdog.ps1.' -ForegroundColor Yellow }
            exit 0
        }
        'done'     { Write-Host $s.message -ForegroundColor Green; exit 0 }
        'gone'     { Write-Host 'Watchdog removed.' -ForegroundColor Green; exit 0 }
        default    { Write-Host $s.message -ForegroundColor Red; exit 1 }
    }
}
