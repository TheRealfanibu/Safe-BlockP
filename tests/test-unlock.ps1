# Runs watchdog.ps1's functions (extracted via the AST, main loop not started) against
# scratch files in %TEMP%. Side effects (tasks, BlockP, mail) are stubbed. No admin needed.
# powershell -ExecutionPolicy Bypass -File tests\test-unlock.ps1
$ErrorActionPreference = 'Stop'
$scratch = Join-Path $env:TEMP "blockp-watchdog-tests"; New-Item -ItemType Directory $scratch -Force | Out-Null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\watchdog.ps1'), [ref] $null, [ref] $null)
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $_.Name -in 'Invoke-Unlock', 'Write-UnlockStatus', 'New-Code', 'Get-Sha256', 'Write-TextNoBom',
                              'Get-RequestedChanges', 'Format-Changes', 'Invoke-Rebaseline', 'Test-Config', 'Get-ConfigDiff', 'Read-Bytes' } |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$Role = 'A'; $codeValidMin = 60; $codeAttempts = 3; $requestGapMin = 5
$utf8NoBom = New-Object Text.UTF8Encoding $false
$unlockDir = Join-Path $scratch 'unlock'; New-Item -ItemType Directory $unlockDir -Force | Out-Null
$statePath = Join-Path $scratch 'state.json'
$cfgPath   = Join-Path $scratch 'config.json'
[IO.File]::WriteAllText($cfgPath, '{"userId":"u","passProtectionMode":true,"timeDelayMode":false,"accountabilityPartnerEmail":"partner@example.com"}')
$state = '{"user":"Jonas","configPath":"' + ($cfgPath -replace '\\', '\\') + '","partnerEmail":"partner@example.com","enforced":{"passProtectionMode":true,"timeDelayMode":false,"accountabilityPartnerEmail":"partner@example.com"}}' | ConvertFrom-Json
$ram = @{ State = $null }
$pending = $null; $lastRequest = [datetime]::MinValue; $standDown = $false; $suppressNotice = $false; $badReads = 0; $lastGood = $null

$script:mails = @(); $script:did = @(); $script:notices = @()
function Send-Mail { param($To, $Subject, $Body) $script:mails += [pscustomobject] @{ To = $To; Body = $Body }; $true }
function Send-Notice { param($Kind, $Text) if (-not $suppressNotice) { $script:notices += $Kind } }
function Invoke-Uninstall { $script:did += 'uninstall' }
function Get-WatchdogProcesses { param($ForRole) }
function Stop-ScheduledTask { param($TaskName) $script:did += "stop:$TaskName" }
function Start-ScheduledTask { param($TaskName) $script:did += "start:$TaskName" }
function Stop-BlockP { $script:did += 'stopBlockP'; $true }
function Start-BlockP { param([switch] $Force) $script:did += 'startBlockP' }
function Enter-Repair { param($TimeoutMs) $true }
function Exit-Repair { }
function Write-Log { param($m) }

function Status { [IO.File]::ReadAllText("$unlockDir\status.json") | ConvertFrom-Json }
function Req($a, $set) {
    $r = [ordered] @{ action = $a; requestId = 'r1' }; if ($set) { $r.set = $set }
    [IO.File]::WriteAllText("$unlockDir\request.json", ($r | ConvertTo-Json)); Invoke-Unlock
}
function LastCode { [regex]::Match($mails[-1].Body, 'Code: (\d{8})').Groups[1].Value }
function Try-Code($c) { [IO.File]::WriteAllText("$unlockDir\attempt.txt", $c); Invoke-Unlock; Status }
function Check($name, $cond) { '{0,-55} {1}' -f $name, $(if ($cond) { 'PASS' } else { 'FAIL' }) }

# --- uninstall flow
Req 'uninstall'
$code = LastCode
Check 'code mailed to partner' ($mails.Count -eq 1 -and $mails[0].To -eq 'partner@example.com' -and $code)
Check 'status code-sent' ((Status).status -eq 'code-sent')
Check 'code not on disk' (-not (Get-ChildItem $unlockDir -File | Where-Object { (Get-Content $_.FullName -Raw) -match $code }))
Req 'uninstall'
Check 'identical repeat request re-uses code (no 2nd mail)' ($mails.Count -eq 1)
Check 'wrong code -> 2 left' ((Try-Code '00000000').status -eq 'wrong' -and $did.Count -eq 0)
[void] (Try-Code '11111111')
Check 'third wrong code -> locked' ((Try-Code '22222222').status -eq 'locked')
Check 'right code after lockout rejected' ((Try-Code $code).status -eq 'no-request' -and $did.Count -eq 0)
$lastRequest = [datetime]::MinValue
Req 'uninstall'
$s = Try-Code (LastCode)
Check 'right code -> uninstall + done' ($did -contains 'uninstall' -and $s.status -eq 'done' -and $standDown)
Check 'partner told it was removed' ($mails[-1].Body -match 'has been removed')

# --- rebaseline validation
$standDown = $false; $did = @(); $n = $mails.Count
Req 'rebaseline' @{ nonsenseKey = $true }
Check 'unknown key rejected, no mail' ((Status).status -eq 'error' -and $mails.Count -eq $n)
Req 'rebaseline' @{ passProtectionMode = 'no' }
Check 'bool -> string rejected, no mail' ((Status).status -eq 'error' -and $mails.Count -eq $n)
Req 'rebaseline'
Check 'rebaseline without changes rejected' ((Status).status -eq 'error' -and $mails.Count -eq $n)

# --- rebaseline flow
Req 'rebaseline' ([ordered] @{ timeDelayMode = $true; accountabilityPartnerEmail = 'new@example.com' })
Check 'mail shows the requested diff' ($mails[-1].Body -match 'timeDelayMode : False -> True' -and $mails[-1].To -eq 'partner@example.com')
$s = Try-Code (LastCode)
$cfg = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
$st  = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
Check 'status done' ($s.status -eq 'done')
Check 'B stopped before, started after' (($did -join ',') -match '^stop:BlockPWatchdogB,.*start:BlockPWatchdogB$')
Check 'config.json updated, BlockP restarted' ($cfg.timeDelayMode -eq $true -and $cfg.accountabilityPartnerEmail -eq 'new@example.com' -and $did -contains 'startBlockP')
Check 'state.json updated (enforced + partner)' ($st.enforced.timeDelayMode -eq $true -and $st.partnerEmail -eq 'new@example.com')
Check 'RAM copy matches new state.json' ($null -ne $ram.State -and [Convert]::ToBase64String($ram.State) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)))
Check 'confirmation went to the OLD partner' ($mails[-1].To -eq 'partner@example.com' -and $mails[-1].Body -match 'Your code was used')
Check 'no tamper notice for an authorised change' ($notices.Count -eq 0)
$did = @(); Test-Config
Check 'next poll accepts the new values' ($did.Count -eq 0)

Remove-Item $unlockDir, $statePath, $cfgPath -Recurse -Force
