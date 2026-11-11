# Runs watchdog.ps1's updater-pause functions (extracted via the AST, main loop not started).
# The process list is stubbed; the signature check runs for real against files on this PC.
# powershell -ExecutionPolicy Bypass -File tests\test-update.ps1
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\watchdog.ps1'), [ref] $null, [ref] $null)
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $_.Name -in 'Test-UpdatePause', 'Test-GenuineInstaller' } |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$pollMs = 1000; $installerMaxSec = 300; $installerBudgetSec = 600; $installerGraceSec = 15
$installerSeen = @{}; $sigCache = @{}
$pauseTicks = New-Object 'Collections.Generic.Queue[datetime]'
$lastInstallerAt = [datetime]::MinValue

$script:notices = @(); $script:procs = @()
function Send-Notice { param($Kind, $Text) $script:notices += $Kind }
function Write-Log { param($m) }
function Get-BlockPInstallers { @($script:procs) }
function Proc($procId, $path) { [pscustomobject] @{ ProcessId = [uint32] $procId; ExecutablePath = $path } }
function Check($name, $cond) { '{0,-58} {1}' -f $name, $(if ($cond) { 'PASS' } else { 'FAIL' }) }

$signed = Get-ChildItem "$env:LOCALAPPDATA\blockp-updater" -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $signed) { $signed = 'C:\Program Files\BlockP\BlockP.exe' }   # same signer
$foreign = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"  # signed, by Microsoft

Check 'NovaFocus-signed file is genuine' (Test-GenuineInstaller $signed)
Check 'Microsoft-signed file is not' (-not (Test-GenuineInstaller $foreign))
Check 'missing file is not' (-not (Test-GenuineInstaller 'C:\nope\BlockP-9.9.9-setup.exe'))

Check 'no installer: no pause' (-not (Test-UpdatePause))
$procs = @(Proc 4242 $foreign)
Check 'non-genuine process in the list: no pause' (-not (Test-UpdatePause))

$procs = @(Proc 4242 $signed)
Check 'genuine installer running: pause' (Test-UpdatePause)
Check 'pause sends no notice' ($notices.Count -eq 0)

$procs = @()
Check 'installer just exited: still paused (grace)' (Test-UpdatePause)
$lastInstallerAt = (Get-Date).AddSeconds(-$installerGraceSec - 1)
Check 'after grace: enforcement back' (-not (Test-UpdatePause))

# One run is capped.
$procs = @(Proc 5000 $signed)
[void] (Test-UpdatePause)
$installerSeen['5000'] = (Get-Date).AddSeconds(-$installerMaxSec - 1)
Check 'installer older than 5 min: no pause' (-not (Test-UpdatePause))
Check 'and the partner hears about it' ($notices -contains 'BlockP installer running long')

# Restarting the installer over and over runs into the hourly budget.
$notices = @(); $installerSeen = @{}; $pauseTicks.Clear()
1..$installerBudgetSec | ForEach-Object { $pauseTicks.Enqueue((Get-Date).AddMinutes(-30)) }
$procs = @(Proc 6000 $signed)
Check 'hourly budget used up: no pause' (-not (Test-UpdatePause))
Check 'budget notice sent' ($notices -contains 'BlockP installer pause used up')
$pauseTicks.Clear(); 1..$installerBudgetSec | ForEach-Object { $pauseTicks.Enqueue((Get-Date).AddMinutes(-61)) }
Check 'ticks older than an hour expire: pause again' (Test-UpdatePause)
