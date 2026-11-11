# Runs watchdog.ps1's functions (extracted via the AST, main loop not started) against
# scratch files in %TEMP%. Side effects (tasks, BlockP, mail) are stubbed. No admin needed.
# powershell -ExecutionPolicy Bypass -File tests\test-unlock.ps1
$ErrorActionPreference = 'Stop'
$scratch = Join-Path $env:TEMP "blockp-watchdog-tests"; New-Item -ItemType Directory $scratch -Force | Out-Null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\watchdog.ps1'), [ref] $null, [ref] $null)
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $_.Name -in 'Invoke-Unlock', 'Write-UnlockStatus', 'New-Code', 'Get-Sha256', 'Write-TextNoBom',
                              'Get-RequestedChanges', 'Format-Changes', 'Invoke-Rebaseline', 'Test-Config', 'Get-ConfigDiff', 'Read-Bytes',
                              'Get-BytesSha256', 'Get-UpgradeScript', 'Invoke-Upgrade' } |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$Role = 'A'; $codeValidMin = 60; $codeAttempts = 3; $requestGapMin = 5
$utf8NoBom = New-Object Text.UTF8Encoding $false
$unlockDir = Join-Path $scratch 'unlock'; New-Item -ItemType Directory $unlockDir -Force | Out-Null
$statePath = Join-Path $scratch 'state.json'
$cfgPath   = Join-Path $scratch 'config.json'
[IO.File]::WriteAllText($cfgPath, '{"userId":"u","passProtectionMode":true,"timeDelayMode":false,"accountabilityPartnerEmail":"partner@example.com"}')
$state = '{"user":"Jonas","configPath":"' + ($cfgPath -replace '\\', '\\') + '","partnerEmail":"partner@example.com","enforced":{"passProtectionMode":true,"timeDelayMode":false,"accountabilityPartnerEmail":"partner@example.com"}}' | ConvertFrom-Json
$scriptPath  = Join-Path $scratch 'watchdog.ps1'
$upgradeMark = Join-Path $scratch 'upgraded.txt'
$oldScript = [Text.Encoding]::ASCII.GetBytes("<# BlockP watchdog v6.1. old #>`r`n" + ('# padding' * 20) + "`r`n'old'")
[IO.File]::WriteAllBytes($scriptPath, $oldScript)
$ram = @{ State = $null; Script = $oldScript }
$pending = $null; $lastRequest = [datetime]::MinValue; $standDown = $false; $restartSelf = $false; $suppressNotice = $false; $badReads = 0; $lastGood = $null

$script:mails = @(); $script:did = @(); $script:notices = @()
function Send-Mail { param($To, $Subject, $Body) $script:mails += [pscustomobject] @{ To = $To; Subject = $Subject; Body = $Body }; $true }
function Send-Notice { param($Kind, $Text) if (-not $suppressNotice) { $script:notices += $Kind } }
function Invoke-Uninstall { $script:did += 'uninstall' }
function Stop-OtherWatchdogs { $script:did += 'stopOthers' }
function Start-OtherWatchdogs { $script:did += 'startOthers' }
function Stop-BlockP { $script:did += 'stopBlockP'; $true }
function Start-BlockP { param([switch] $Force) $script:did += 'startBlockP' }
function Enter-Repair { param($TimeoutMs) $true }
function Exit-Repair { }
function Write-Log { param($m) }

function Status { [IO.File]::ReadAllText("$unlockDir\status.json") | ConvertFrom-Json }
function Req($a, $set, $sha) {
    $r = [ordered] @{ action = $a; requestId = 'r1' }; if ($set) { $r.set = $set }; if ($sha) { $r.sha256 = $sha }
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
Check 'others stopped before, started after' (($did -join ',') -match '^stopOthers,.*startOthers$')
Check 'config.json updated, BlockP restarted' ($cfg.timeDelayMode -eq $true -and $cfg.accountabilityPartnerEmail -eq 'new@example.com' -and $did -contains 'startBlockP')
Check 'state.json updated (enforced + partner)' ($st.enforced.timeDelayMode -eq $true -and $st.partnerEmail -eq 'new@example.com')
Check 'RAM copy matches new state.json' ($null -ne $ram.State -and [Convert]::ToBase64String($ram.State) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)))
Check 'confirmation went to the OLD partner' ($mails[-1].To -eq 'partner@example.com' -and $mails[-1].Body -match 'Your code was used')
Check 'no tamper notice for an authorised change' ($notices.Count -eq 0)
$did = @(); Test-Config
Check 'next poll accepts the new values' ($did.Count -eq 0)

# --- upgrade validation: every refusal costs no mail
$did = @(); $n = $mails.Count
function Stage([string] $text) {
    $b = [Text.Encoding]::ASCII.GetBytes($text); [IO.File]::WriteAllBytes("$unlockDir\upgrade.ps1", $b)
    (Get-FileHash "$unlockDir\upgrade.ps1" -Algorithm SHA256).Hash.ToLowerInvariant()
}
$newText = "<# BlockP watchdog v6.2. new #>`r`n" + ('# padding' * 20) + "`r`n'new'"
$sha = Stage $newText
Req 'upgrade' $null ('0' * 64)
Check 'upgrade: wrong SHA-256 refused, no mail' ((Status).status -eq 'error' -and $mails.Count -eq $n)
Check 'upgrade: staged file removed after a request' (-not (Test-Path "$unlockDir\upgrade.ps1"))
$bad = Stage ("<# BlockP watchdog v6.2 #>`r`n" + ('# padding' * 20) + "`r`nfunction {")
Req 'upgrade' $null $bad
Check 'upgrade: script that does not parse refused' ((Status).status -eq 'error' -and (Status).message -match 'parse' -and $mails.Count -eq $n)
$same = Stage ([Text.Encoding]::ASCII.GetString($oldScript))
Req 'upgrade' $null $same
Check 'upgrade: same version refused' ((Status).status -eq 'error' -and $mails.Count -eq $n)
Req 'upgrade' $null $sha
Check 'upgrade: missing staged file refused' ((Status).status -eq 'error' -and $mails.Count -eq $n)

# --- upgrade flow
$sha = Stage $newText
Req 'upgrade' $null $sha
Check 'upgrade: mail names both versions and the new SHA-256' ($mails[-1].Body -match 'UPGRADE' -and $mails[-1].Body -match $sha -and $mails[-1].Body -match 'v6\.1' -and $mails[-1].Body -match 'v6\.2')
# Swapping the staged file after the request changes nothing: the bytes are already in RAM.
[void] (Stage "'evil'")
$s = Try-Code (LastCode)
Check 'upgrade: status done' ($s.status -eq 'done')
Check 'upgrade: the requested bytes were installed, not the swap' ((Get-FileHash $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sha)
Check 'upgrade: RAM copy follows (no self-revert)' ([Convert]::ToBase64String($ram.Script) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($scriptPath)))
Check 'upgrade: others stopped, then started' (($did -join ',') -eq 'stopOthers,startOthers')
Check 'upgrade: mark written with the new hash' ((Get-Content $upgradeMark -Raw) -match "^$sha ")
Check 'upgrade: this process restarts itself, no stand-down' ($restartSelf -and -not $standDown)
Check 'upgrade: partner told it happened' ($mails[-1].Subject -eq 'BlockP: watchdog upgraded' -and $mails[-1].To -eq $state.partnerEmail)
Check 'upgrade: no tamper notice' ($notices.Count -eq 0)

Remove-Item $unlockDir, $statePath, $cfgPath, $scriptPath, $upgradeMark -Recurse -Force
