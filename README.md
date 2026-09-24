# BlockP Hardening

Self-imposed restrictions for `C:\Program Files\BlockP`, on `JONAS-GAMING-PC`.

## Why this exists

BlockP is a plain Electron app with **no Windows service and no kernel driver**. It runs as
`Jonas`, and `Jonas` is a local Administrator — so Task Manager kills it with no UAC prompt.
Its built-in uninstall protection can't survive that. These scripts add the missing layers.

> **Read the "What BlockP will and will not tolerate" section before changing anything.**
> The obvious hardening move — demote the daily account and run BlockP as a separate admin —
> was built, tested, and **disproved** on 14.09.2026. Don't rebuild it.

## Scripts

All require an **elevated** PowerShell (right-click → Run as administrator).

Three scripts. Everything else was tried, disproved, and deleted — the reasoning is kept
below so it doesn't get rebuilt.

| Script | What it does |
|---|---|
| `install-blockp-watchdog.ps1` | Installs/repairs everything (v4). Registers the SYSTEM watchdog task, points both launcher tasks at the interactive user (`Interactive` / `RunLevel Highest`), and writes `watchdog.ps1`. `-RestoreAdmin` also returns the account to Administrators, which BlockP requires. Safe to re-run; use it after a BlockP update resets `BlockPStartup`. |
| `uninstall-blockp-watchdog.ps1` | Removes the watchdog task, its processes, and its folder. |
| `diagnose-watchdog.ps1` | Read-only. Task state, exit codes, Task Scheduler events, **whether BlockP is in session 0, whether its PIDs are stable, and whether it is deliberately aborting**. Run this if blocking ever silently stops. |

## Watchdog design — why it is not one long-running loop

v1 was a single infinite loop started once at boot. Killing its process from an elevated Task
Manager left it dead **until the next reboot**, silently — exit code `0x1`, no log entry,
because a hard-terminated process cannot write its own exit. `RestartOnFailure` does not help:
that setting covers a task failing to *start*, not one that was running and got killed.

Since "killed from Task Manager" is the entire threat model, that was the wrong architecture.

**v2 is short-lived on purpose.** Task Scheduler re-runs it every minute; each run polls every
5s for ~55 seconds, then exits 0. Killing a run costs at most 60 seconds of coverage instead of
everything, and no reboot is needed to recover. Verified working: the watchdog detected BlockP
at zero and had it back in 1 second.

**v4** keeps that structure and changes only *who* it launches BlockP as: the detected
interactive user, `LogonType Interactive`, `RunLevel Highest`. It also re-registers the launch
task itself when the principal drifts, rather than only warning about it.

## What BlockP will and will not tolerate

Established empirically on 14.09.2026, after several hours of testing. **This is the important
section.** BlockP.exe 2.0.6 imposes two constraints that together rule out the obvious design:

1. **It requires an elevated token.** Its manifest is `requestedExecutionLevel
   level="requireAdministrator"`. A standard user cannot start it at all.
2. **It must be the interactive session owner.** If it runs as any other account it aborts
   immediately with `STATUS_BREAKPOINT` (`0x80000003`) — a deliberate `__debugbreak()`, at a
   fixed offset, every time. That is anti-tamper, not a crash, and nothing on our side changes it.

### The test matrix

| Identity | Session | Elevated | Result |
|---|---|---|---|
| `Jonas` (session owner), via `RunAsInvoker` shim | yours | no | **stable, blocks correctly** |
| `WinAdmin`, `CreateProcessAsUser`, fresh profile, `--disable-gpu` | 3 | yes | `0x80000003` abort |
| `WinAdmin`, background scheduled task | 0 | yes | `0x80000003` abort |
| SYSTEM, `CreateProcessAsUser` | 3 | yes | dies before creating its profile |

Everything *around* the launch worked: the DPAPI-under-SYSTEM credential store, `LogonUser`
with the elevated linked token, `LoadUserProfile`, `SetTokenInformation(TokenSessionId)`,
`CreateProcessAsUser`. The process gets created in the right session every time. The app
then kills itself. The window-station/desktop-DACL theory was tested and is **not** the cause —
the failure is `0x80000003`, not `0xC0000142`.

### Two dead ends, and why

These were real scripts (`demote-to-standard-user.ps1`, `test-winadmin-session-launch.ps1`,
`test-system-session-launch.ps1`, `reset-winadmin-blockp-profile.ps1`, `verify-relaunch-path.ps1`).
They are deleted. The `WinAdmin` account they created has been removed too. What follows is why.

**Running BlockP as `WinAdmin` (the v3 design).** Satisfies elevation, but violates constraint 2,
so it aborts. When it was registered "run whether user is logged on or not" it also landed in
**session 0**, which has no desktop — even had it run, it could not see or close a browser window
in your session. It also read `C:\Users\WinAdmin\AppData\Roaming\BlockP` instead of yours, so it
was signed out with no blocklist. Symptom: BlockP visibly "running" in Task Manager, blocking
nothing, processes churning every few seconds.

**Running BlockP unelevated as yourself via the `RunAsInvoker` compatibility shim.** This
actually *works* — stable, and it blocks. It was rejected because the config then lived in
`C:\Users\Jonas\AppData\Roaming\BlockP\config.json`, which you own with `FullControl`, with
`passProtectionMode` as a plain JSON boolean in it. Two edits in Notepad and the password
protection is off. Self-defeating, so it was not used.

> **That reason is stale as of 2.0.6 — re-checked 14.09.2026.** There is no `config.json`.
> `%APPDATA%\BlockP` now holds `app.db`, a SQLite file whose only table is `items` (the
> blocklist). No `passProtectionMode` key exists in `app.db`, in `Preferences` (Chromium's own,
> holding a spellcheck dictionary), or in the Local Storage leveldb — that holds only language,
> theme, a sentence-length limit, and the partner email. Password-protection state appears to
> have moved server-side with the account.
>
> **Not proven.** Cookies, IndexedDB and DPAPI were not checked, and the instance inspected was
> the elevated one, so it may simply store this differently. But if it really is server-side,
> the one reason this option was rejected no longer holds — and unelevated-as-yourself is the
> only known configuration that is compatible with a demoted standard account. Re-test before
> trusting it in either direction.

### Therefore

**BlockP requires the daily account to be an administrator.** There is no configuration where
the demotion and working blocking coexist. `demote-to-standard-user.ps1` and BlockP are mutually
exclusive — pick one.

## What you actually get now

- BlockP runs as you, in your session, with your settings, and blocks.
- The SYSTEM watchdog returns it within ~5 seconds of being killed in Task Manager.
- **But you are an administrator**, so you can `Unregister-ScheduledTask -TaskName BlockPWatchdog`
  and nothing restores it.

That is friction against impulse, not a wall. It is worth having — the five-second relaunch
defeats the "just kill it for a second" reflex, which is the actual failure mode. It is not
protection against a deliberate decision to dismantle it, and calling it "hardening" shouldn't
fool you into thinking otherwise.

## The layer that survives all of this

Put a filtering DNS resolver (NextDNS / CleanBrowsing) on the **router**, and lock the router
admin password away with the Windows one.

Nothing discovered on 14.09.2026 weakens this option. It doesn't care about sessions, tokens,
user profiles, or what BlockP's anti-tamper feels like doing; it survives a BlockP update, a
reinstall, and a reset of this PC; and it covers your phone. If the PC-side layer keeps eroding,
this is where to spend effort instead.

## Health check

The watchdog overwrites a heartbeat file every poll. If it is more than ~90 seconds old,
the watchdog is not running:

```powershell
Get-Content C:\ProgramData\BlockPWatchdog\heartbeat.txt   # should be seconds old
Get-Content C:\ProgramData\BlockPWatchdog\watchdog.log -Tail 20
```

Worth checking occasionally. Silent failure is the thing to watch for — a blocker that has
quietly stopped is worse than no blocker, because you think you are covered. That is exactly
what happened on 13–14.09: BlockP was "running" the whole time and blocking nothing.

Two useful cross-checks the heartbeat alone won't give you:

```powershell
# Must be YOUR session id, not 0. Session 0 means it is blocking nothing.
Get-CimInstance Win32_Process -Filter "Name='BlockP.exe'" | Select-Object ProcessId, SessionId

# Deterministic aborts show up here. 0x80000003 means it is refusing to run as this identity.
Get-WinEvent -LogName Application -MaxEvents 50 |
    Where-Object { $_.Message -match 'BlockP' } | Select-Object TimeCreated, Id
```

If the PIDs change every few seconds, it is in a crash/restart loop, not running.

## Gotchas found the hard way

- **BlockP resurrects itself.** With `preventUninstallMode`, each instance spawns a successor
  before dying, so a single `Stop-Process` never clears it. You need a kill loop that runs until
  the count stays at zero. Scripts here do this; ad-hoc commands won't.
- **The watchdog re-enables `BlockPStartup`.** `Disable-ScheduledTask` on it is undone within 60
  seconds. Disable the watchdog *first* when testing.
- **`Get-ScheduledTask -TaskName BlockPWatchdog` returns nothing for a standard user.** The task
  is ACL'd. That is not the task missing — check the heartbeat and the
  `Microsoft-Windows-TaskScheduler/Operational` log instead.
- **Electron's single-instance lock is per user-data dir.** Two instances under the same account
  collide; instances under different accounts do not. A second instance exiting instantly on
  startup usually means the lock, not a crash.
- **Logging out changes your session id.** Anything that hardcodes a session number breaks.
  Resolve it at runtime with `WTSGetActiveConsoleSessionId`.
- **A BlockP update can recreate `BlockPStartup`** and undo the repair. The watchdog logs drift;
  re-run `install-blockp-watchdog.ps1` to fix it.

## Undoing it

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-blockp-watchdog.ps1
```

That is the whole undo. Since the demotion approach is gone, there is no separate admin account
or password to recover — which also means there is nothing here that can lock you out, and
nothing that costs you time on the way back out. Both the strength and the weakness of the
current setup.

## Honest limits

You have physical access to this machine, so none of this is absolute. Safe mode, recovery
media, an offline password reset, or just a different device all defeat it given enough
determination. And since BlockP forces the daily account to stay an administrator, the watchdog
is now removable by you in one command.

The goal is **friction and delay**, which is what actually works against impulse — not an
unbreakable wall. The router layer is the only part of this that a determined five minutes at
the keyboard cannot undo.

## Log

`C:\ProgramData\BlockPWatchdog\watchdog.log` — every relaunch is timestamped there. Worth
reading occasionally; the pattern of *when* you try is more useful information than the count.
