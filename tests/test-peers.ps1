# Runs watchdog.ps1's peer functions (extracted via the AST, main loop not started) against
# scratch heartbeat files in %TEMP%. Task Scheduler and mail are stubbed. No admin needed.
# powershell -ExecutionPolicy Bypass -File tests\test-peers.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP 'blockp-watchdog-tests\peers'; New-Item -ItemType Directory $root -Force | Out-Null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\watchdog.ps1'), [ref] $null, [ref] $null)
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $_.Name -in 'Test-RoleAlive', 'Test-IsLeader', 'Confirm-Peers', 'Start-OtherWatchdogs' } |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$Count = 6; $Role = 'C'
$roles  = @(0..($Count - 1) | ForEach-Object { [string] [char] (65 + $_) })
$others = @($roles | Where-Object { $_ -ne $Role })
$peerStaleSec = 3; $peerGraceSec = 10
$peerStartedAt = @{}; $seenAlive = @{}; $quietUntil = [datetime]::MinValue

$script:started = @(); $script:notices = @()
function Start-ScheduledTask { param($TaskName) $script:started += $TaskName }
function Enable-ScheduledTask { param($TaskName) }
function Send-Notice { param($Kind, $Text) $script:notices += $Kind }
function Write-Log { param($m) }

$deadPid = 999999   # no such process
function Beat($r, $ageSec, $procId = $deadPid) {
    $f = Join-Path $root "heartbeat-$r.txt"
    [IO.File]::WriteAllText($f, "$procId x")
    (Get-Item $f).LastWriteTime = (Get-Date).AddSeconds(-$ageSec)
}
function Check($name, $cond) { '{0,-58} {1}' -f $name, $(if ($cond) { 'PASS' } else { 'FAIL' }) }

Get-ChildItem $root -Filter 'heartbeat-*.txt' | Remove-Item
foreach ($r in $roles) { Beat $r 0 }

Check 'fresh heartbeat = alive' (Test-RoleAlive 'A')
Beat 'A' 30
Check 'stale heartbeat, process gone = dead' (-not (Test-RoleAlive 'A'))
Beat 'A' 30 $PID
Check 'stale heartbeat, process still there = alive (busy)' (Test-RoleAlive 'A')
Check 'missing heartbeat file = dead' (-not (Test-RoleAlive 'Z'))

foreach ($r in $roles) { Beat $r 0 }
Check 'C is not leader while A is alive' (-not (Test-IsLeader))
Beat 'A' 30; Beat 'B' 30
Check 'C leads once A and B are dead' (Test-IsLeader)

# --- restarts: everyone alive, then two killed
foreach ($r in $roles) { Beat $r 0 }
Confirm-Peers
Check 'all alive: nothing started, no notice' ($started.Count -eq 0 -and $notices.Count -eq 0)
Beat 'A' 30; Beat 'E' 30
Confirm-Peers
Check 'killed A and E are both restarted' (($started -join ',') -eq 'BlockPWatchdogA,BlockPWatchdogE')
Check 'kill produces one notice' (($notices -join ',') -eq 'watchdog killed')
$started = @(); $notices = @()
Confirm-Peers
Check 'still down within grace: not started again' ($started.Count -eq 0)
$peerStartedAt['A'] = (Get-Date).AddSeconds(-60)
Confirm-Peers
Check 'still down after grace: started again, no 2nd notice' (($started -join ',') -eq 'BlockPWatchdogA' -and $notices.Count -eq 0)

# --- after boot: stale heartbeats never seen alive are started, but not reported
$peerStartedAt = @{}; $seenAlive = @{}; $started = @(); $notices = @()
foreach ($r in $roles) { Beat $r 600 }
Confirm-Peers
Check 'boot: all 5 others started' ($started.Count -eq 5)
Check 'boot: no kill notice' ($notices.Count -eq 0)

# --- rebaseline: others stopped on purpose, no notice while they come back
$peerStartedAt = @{}; $seenAlive = @{}; $started = @(); $notices = @()
foreach ($r in $roles) { Beat $r 0 }
Confirm-Peers
Start-OtherWatchdogs
foreach ($r in $others) { Beat $r 30 }
$peerStartedAt = @{}
Confirm-Peers
Check 'after Start-OtherWatchdogs: no kill notice' ($notices.Count -eq 0)

Remove-Item $root -Recurse -Force
