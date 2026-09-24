# Runs watchdog.ps1's functions (extracted via the AST, main loop not started) against
# scratch files in %TEMP%. Side effects (tasks, BlockP, mail) are stubbed. No admin needed.
# powershell -ExecutionPolicy Bypass -File tests\test-config.ps1
$ErrorActionPreference = 'Stop'
$scratch = Join-Path $env:TEMP "blockp-watchdog-tests"; New-Item -ItemType Directory $scratch -Force | Out-Null
$wd = (Join-Path $PSScriptRoot '..\watchdog.ps1')

# Pull the function definitions out of watchdog.ps1 without running its main loop.
$ast = [Management.Automation.Language.Parser]::ParseFile($wd, [ref] $null, [ref] $null)
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $_.Name -in 'Get-ConfigDiff', 'Test-Config', 'Write-TextNoBom' } |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

# Stubs for the side-effecting parts.
$script:events = @()
function Stop-BlockP { $script:events += 'stop'; $true }
function Start-BlockP { param([switch] $Force) $script:events += 'start' }
function Send-Notice { param($Kind, $Text) $script:events += "notice:$Kind" }
function Enter-Repair { param($TimeoutMs) $true }
function Exit-Repair { }
function Write-Log { param($m) }

$utf8NoBom = New-Object Text.UTF8Encoding $false
$cfgPath = Join-Path $scratch 'config.json'
Copy-Item "$env:APPDATA\BlockP\config.json" $cfgPath -Force
$orig = [IO.File]::ReadAllText($cfgPath)
$origObj = $orig | ConvertFrom-Json

# Build state exactly like the installer does.
$volatile = @('userId', 'authData', 'ratedVal', 'rateUsDone')
$enforced = [ordered] @{}
foreach ($p in $origObj.PSObject.Properties) {
    if ($volatile -contains $p.Name) { continue }
    if ($p.Value -isnot [bool] -and $p.Value -isnot [string] -and $p.Value -isnot [int] -and $p.Value -isnot [long]) { continue }
    $enforced[$p.Name] = $p.Value
}
$stateText = [ordered] @{ configPath = $cfgPath; enforced = $enforced; volatileKeys = $volatile } | ConvertTo-Json -Depth 32
$state = $stateText | ConvertFrom-Json      # round-trip, as the watchdog loads it
$lastGood = $orig
$badReads = 0

function Check($name, $cond) { '{0,-58} {1}' -f $name, $(if ($cond) { 'PASS' } else { 'FAIL' }) }
function Same-Json($a, $b) { ($a | ConvertTo-Json -Depth 32 -Compress) -eq ($b | ConvertTo-Json -Depth 32 -Compress) }

"enforced keys: $($enforced.Keys -join ', ')"

# 1. untouched file -> nothing happens
$events = @(); Test-Config
Check '1 clean config: no action' ($events.Count -eq 0)

# 2. flip passProtectionMode, change partner email
$bad = $orig -replace '"passProtectionMode":\s*true', '"passProtectionMode": false' -replace '"accountabilityPartnerEmail":\s*"[^"]*"', '"accountabilityPartnerEmail": "me@example.com"'
[IO.File]::WriteAllText($cfgPath, $bad)
$events = @(); Test-Config
$fixedRaw = [IO.File]::ReadAllBytes($cfgPath)
$fixed = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
Check '2 tamper detected: stop, notice, start' (($events -join ',') -eq 'stop,notice:BlockP settings changed,start')
Check '2 passProtectionMode restored to True (bool)' ($fixed.passProtectionMode -is [bool] -and $fixed.passProtectionMode)
Check '2 partner email restored' ($fixed.accountabilityPartnerEmail -eq $origObj.accountabilityPartnerEmail)
Check '2 authData deep-equal to original' (Same-Json $fixed.authData $origObj.authData)
Check '2 whole object equal to original' (Same-Json $fixed $origObj)
Check '2 no BOM written' (-not ($fixedRaw[0] -eq 0xEF -and $fixedRaw[1] -eq 0xBB))
$events = @(); Test-Config
Check '2 repaired file is accepted on next poll' ($events.Count -eq 0)

# 3. deleted file -> 1st poll tolerates, 2nd restores from lastGood
Remove-Item $cfgPath
$events = @(); Test-Config
Check '3 first missing read tolerated (mid-write guard)' ($events.Count -eq 0)
Test-Config
Check '3 second read restores file' ((Test-Path $cfgPath) -and (Same-Json ([IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json) $origObj))

# 4. volatile key change (BlockP refreshing its token) -> no action
$o = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
$o.ratedVal = 4
[IO.File]::WriteAllText($cfgPath, ($o | ConvertTo-Json -Depth 32))
$events = @(); Test-Config
Check '4 volatile key change ignored' ($events.Count -eq 0)

# 5. bool replaced by the string "true" is still tampering
$o.passProtectionMode = 'true'
[IO.File]::WriteAllText($cfgPath, ($o | ConvertTo-Json -Depth 32))
$events = @(); Test-Config
Check '5 string "true" instead of bool is caught' ($events -contains 'stop')

# 6. key removed entirely
$o = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
$o.PSObject.Properties.Remove('blockPMode')
[IO.File]::WriteAllText($cfgPath, ($o | ConvertTo-Json -Depth 32))
$events = @(); Test-Config
Check '6 removed key is re-added' ((([IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json).blockPMode) -eq $true)

Remove-Item $cfgPath
