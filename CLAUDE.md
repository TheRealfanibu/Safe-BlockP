# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Windows PowerShell 5.1 scripts that harden the BlockP content blocker (an Electron app at
`C:\Program Files\BlockP`) against its own admin user. [README.md](README.md) is the user guide.
[DESIGN.md](DESIGN.md) has the design history and the empirical constraints on BlockP. Read its
"What BlockP will and will not tolerate" section before proposing any architectural change.

## Tests

No build step. The tests need no admin rights and don't touch the live install:

```powershell
powershell -ExecutionPolicy Bypass -File tests\test-config.ps1
powershell -ExecutionPolicy Bypass -File tests\test-unlock.ps1
powershell -ExecutionPolicy Bypass -File tests\test-peers.ps1
```

Each prints `name ... PASS/FAIL` lines. None of them sets an exit code, so check the output for `FAIL`.
Run all three after any change to `watchdog.ps1`.

How the tests work: they parse `watchdog.ps1` with the PowerShell AST, dot-source only the
functions they name (so the main loop never runs), stub the side effects (`Send-Mail`,
`Send-Notice`, `Start-BlockP`, `Stop-BlockP`, `Start-ScheduledTask`, and others), and work on
scratch files in `%TEMP%\blockp-watchdog-tests`. The script-scope variables those functions
read (`$state`, `$ram`, `$Role`, `$roles`, `$others`, the timing constants) are set up by hand
in each test. So **when you add a function a test needs, or a new script-scope variable, add
it to that test's `Where-Object { $_.Name -in ... }` list or its setup too**.
`test-config.ps1` copies the real `%APPDATA%\BlockP\config.json`, so BlockP must be installed.

Never run `install-blockp-watchdog.ps1` or `uninstall-blockp-watchdog.ps1` to try something out.
Install locks the machine, and removal needs a code emailed to the accountability partner.

## Architecture

- `watchdog.ps1` is the only long-running code. The installer copies it to
  `C:\ProgramData\BlockPWatchdog\` and registers scheduled tasks `BlockPWatchdogA`…`F` (SYSTEM,
  `-Role X -Count N`). Each task fires at boot and every minute, staggered by `60/Count`
  seconds, with `MultipleInstances IgnoreNew`. A `Global\BlockPWatchdog-<Role>` mutex keeps
  each role a singleton.
- **State is loaded into RAM once at startup** (`state.json` = enforced keys + base64 snapshot
  of `config.json`, `smtp.bin` = LocalMachine-DPAPI SMTP creds, and the script's own bytes).
  After that, disk only mirrors RAM: edits to any of these files are reverted. So **editing the
  installed `watchdog.ps1` in place doesn't work**. Changes ship through uninstall (partner
  code) + reinstall.
- Main loop (1 s): heartbeat file `heartbeat-<Role>.txt` (`"<pid> <time>"`) → `Invoke-Unlock`
  (a no-op except on A) → `Confirm-OwnFiles` → `Test-Config` → `Confirm-BlockPRunning` →
  `Confirm-Peers`. Every 5 s it runs `Confirm-WatchdogTask` on its own role and the next role
  in the ring, and the leader also repairs `BlockPStartup` (`Confirm-LauncherTask`). At
  startup it sends a "watchdogs were stopped" notice if every heartbeat is older than
  `60/Count + 10` s.
- **Peers:** a role counts as dead only if its heartbeat is >3 s old *and* its PID is gone
  (`Test-RoleAlive`). The lowest live letter is the leader (`Test-IsLeader`). Only the leader
  sends notices and repairs `BlockPStartup`. `Global\BlockPWatchdogRepair` serialises
  kill/relaunch of BlockP between roles.
- **Unlock protocol (role A only):** the uninstall script writes `unlock\request.json` and
  `unlock\attempt.txt`. A answers through `unlock\status.json` (`code-sent`, `wrong`,
  `accepted`, `done`, …). The code is mailed and only its SHA-256 is kept in RAM. The
  uninstall script has no power of its own. For rebaseline and uninstall, A calls
  `Stop-OtherWatchdogs` (kill + disable in a loop) first, so no peer keeps stale state in RAM.
- BlockP is launched through tasks `BlockPWatchdogLaunch` / `BlockPStartup`, as the interactive
  user with `LogonType Interactive`, `RunLevel Highest`. It *must* be the interactive session
  owner and elevated. Any other identity aborts with `0x80000003` (see DESIGN.md).
- `Register-WatchdogTask` in `watchdog.ps1` and the task loop in `install-blockp-watchdog.ps1`
  build the same task definition. Keep them in sync.
- The volatile (non-enforced) keys list `userId, authData, ratedVal, rateUsDone` is duplicated
  in the installer and `tests\test-config.ps1`.

## Conventions that matter

- **Scripts are ASCII-only.** PS 5.1 reads BOM-less `.ps1` as ANSI. `.gitattributes` forces CRLF
  for `.ps1` and LF for `.md`.
- **Write `config.json` / `state.json` as UTF-8 *without* BOM** (`Write-TextNoBom` /
  `New-Object Text.UTF8Encoding $false`). Electron's `JSON.parse` rejects a BOM. Never use
  `Set-Content -Encoding utf8`.
- Read `config.json` with `.TrimStart([char]0xFEFF)`. Two bad reads in a row are needed before
  a restore, because BlockP may be mid-write.
- BlockP resurrects itself (`preventUninstallMode`), so stopping it takes a kill loop until the
  count stays at zero, never a single `Stop-Process`.
- Resolve the interactive session and user at runtime. Never hardcode a session id.
- `watchdog.ps1` runs with `$ErrorActionPreference = 'SilentlyContinue'` on purpose, so the
  watchdog never dies on an error. The installer and uninstaller use `'Stop'`.
- The user maintains the README and DESIGN.md as dated engineering notes (e.g. "re-checked
  14.09.2026"). When a finding changes, add a dated note rather than silently rewriting
  history.
