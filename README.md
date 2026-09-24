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

Everything else was tried, disproved, and deleted — the reasoning is kept below so it doesn't
get rebuilt. Versioned in git; the v4 single-watchdog state is the first commit.

| Script | What it does |
|---|---|
| `watchdog.ps1` | The watchdog body (v5). Copied to `C:\ProgramData\BlockPWatchdog` and run twice by SYSTEM, as `-Role A` and `-Role B`. Not run by hand. |
| `install-blockp-watchdog.ps1` | **First install only.** Takes BlockP's current `config.json` as the baseline to enforce, stores the SMTP login, registers `BlockPWatchdogA`/`B` and both launcher tasks, and removes the old v4 task. Refuses to run once v5 is installed. `-RestoreAdmin` returns the account to Administrators, which BlockP requires. |
| `uninstall-blockp-watchdog.ps1` | Asks watchdog A for an unlock code, which is mailed to the accountability partner. With the code: removes everything. With `-Rebaseline -Set key=value` and the code: changes protected settings. The partner's mail shows exactly what changes. |
| `tests\` | `test-config.ps1`, `test-unlock.ps1`: run the watchdog's own functions against scratch files with side effects stubbed. No admin needed. **Run both before installing a changed `watchdog.ps1`.** |
| `diagnose-watchdog.ps1` | Read-only. Heartbeats, enforced settings compared with `config.json`, task state, Task Scheduler events, **whether BlockP is in session 0, whether its PIDs are stable, and whether it is deliberately aborting**. Run this if blocking ever silently stops. |

## v5 — two watchdogs, settings held in RAM, partner code to remove

v4 had one watchdog, and it protected only the process. v5 adds three things.

**Two watchdogs that guard each other.** `BlockPWatchdogA` and `BlockPWatchdogB` both run as
SYSTEM and poll every second. Each one writes a heartbeat file. If the peer's heartbeat is more
than 6s old, it restarts the peer. Every 5s it re-registers the peer's task (and its own) if
the task was deleted or altered, and re-enables it if it was disabled. It also repairs
`BlockPWatchdogLaunch` and `BlockPStartup`, so a BlockP update that resets `BlockPStartup` no
longer needs a manual re-install. Both tasks also re-trigger every minute
(`MultipleInstances IgnoreNew`), so killing both processes costs at most ~60s. A named mutex per
role stops duplicate copies, and a shared repair mutex keeps A and B from both killing and
relaunching BlockP at the same moment.

Unlike v2–v4, the processes are long-lived on purpose. The "killed → dead until reboot" problem
of v1 is covered by the every-minute trigger, and a process that lives for hours can hold state
in RAM (next point).

**Settings are read once and held in RAM.** At startup, each watchdog reads `state.json`
(the enforced settings plus a full snapshot of `config.json`), `smtp.bin` and its own
`watchdog.ps1` into memory. After that the disk only mirrors memory:

- If `config.json` differs from the RAM copy in an enforced key, the watchdog kills BlockP, so
  BlockP can't write its own in-memory state back on exit. Then it writes the enforced values
  back, relaunches BlockP, and mails the partner. Deleted or corrupted → restored from the last
  good copy in RAM (after two bad reads in a row, so BlockP writing the file mid-poll isn't
  mistaken for tampering).
- If `watchdog.ps1`, `state.json` or `smtp.bin` are edited or deleted, they're rewritten from RAM
  within a second.
- **Enforced:** every top-level scalar in `config.json` (`passProtectionMode`,
  `preventUninstallMode`, `blockPMode`, all `block*Mode`s, `pornBlockMode`, `aiBlockerMode`,
  `timeDelayMode`, `accountabilityPartnerEmail`). **Not enforced:** `userId`, `authData`,
  `ratedVal`, `rateUsDone`, which BlockP rewrites itself. This also works the other way: turning
  a setting *on* in the UI (for example `timeDelayMode`) is reverted too. Use `-Rebaseline`.

**The partner holds the only way out.** `uninstall-blockp-watchdog.ps1` doesn't remove anything
itself. It drops a request into `C:\ProgramData\BlockPWatchdog\unlock\`. Watchdog A generates an
8-digit code, mails it to the partner, and keeps only its SHA-256 hash in RAM; the code is never
written to disk. Three wrong tries and the code is dead; it expires after 60 minutes, and every
new request sends a new mail. With the right code, A itself stops B, unregisters all tasks,
mails the partner that it happened, and deletes its folder. So editing the uninstall script
achieves nothing: it has no power of its own.

The partner is also mailed (rate-limited to one mail per event type per 30 min) when:
- BlockP's settings were changed,
- a watchdog task was deleted, altered or disabled,
- a watchdog file was edited or deleted,
- A starts up and finds that **both** heartbeats went stale for >3 min while the PC was on.
  That can only happen if someone killed both.

### Mail account — read this before installing

The mail that carries the code goes through an SMTP account whose password is stored on this
PC (`smtp.bin`, LocalMachine DPAPI). Two ways that leaks the code to you:

1. **The Sent folder.** Gmail and Outlook save everything sent over SMTP to Sent. If you can log
   into the sender mailbox, you can read every code there.
2. **The stored password.** An admin can decrypt `smtp.bin` (LocalMachine DPAPI protects it only
   from non-admins). A Gmail app password also grants IMAP access, which leads back to point 1.

So: **the sender account should belong to your partner.** Have them create a separate mailbox,
turn on 2FA, create the app password, and type it into the installer themselves. Or use a
transactional relay with a send-only key (e.g. SendGrid SMTP, user `apikey`, host
`smtp.sendgrid.net`), which has no mailbox to read. Point 2 still means a determined you
could send mail as that account, but not read the codes.

## Watchdog design history — why v2–v4 were short-lived

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
>
> **Superseded 25.09.2026: `config.json` is back.** `%APPDATA%\BlockP\config.json` exists
> again, with `passProtectionMode`, `preventUninstallMode`, `blockPMode`, the other
> `block*Mode`s and `accountabilityPartnerEmail` as plain JSON, `FullControl` for `Jonas`. The
> original objection holds again, and it is what v5 is for: the watchdogs revert any edit to
> those keys within a second.
>
> **This reopens the demotion option.** Everything v5 needs runs as SYSTEM, and a standard user
> can't kill, unregister or edit any of it. A standard user *can* edit `config.json`, but v5
> reverts the edit and mails the partner. So "demoted `Jonas` + BlockP unelevated via
> `RunAsInvoker` + v5 watchdogs + admin password held by the partner" is the first design where
> blocking works *and* you can't dismantle it in one command. Not built yet: it needs the launcher
> tasks at `RunLevel Limited` with the shim, and a re-test that 2.0.6 still blocks unelevated.

### Therefore

**BlockP requires the daily account to be an administrator.** There is no configuration where
the demotion and working blocking coexist. `demote-to-standard-user.ps1` and BlockP are mutually
exclusive — pick one.

## What you actually get now

- BlockP runs as you, in your session, with your settings, and blocks.
- Either watchdog returns it within ~1–20 seconds of being killed in Task Manager.
- Edits to BlockP's settings are reverted within a second, and your partner hears about it.
- Killing one watchdog, or deleting or disabling one task, is undone within seconds.
- The supported way out needs your partner's code.
- **But you are still an administrator.** One command that disables both tasks and kills both
  processes, or a Safe Mode boot, still gets past this. What changed from v4: tampering
  that the watchdogs survive, or catch when they restart, **produces a mail to your partner**. Quietly
  dismantling it is much harder now; dismantling it at all is not.

That is still friction, not a wall. The difference from v4 is that the friction now has a
witness.

## The layer that survives all of this

Put a filtering DNS resolver (NextDNS / CleanBrowsing) on the **router**, and lock the router
admin password away with the Windows one.

Nothing discovered on 14.09.2026 weakens this option. It doesn't care about sessions, tokens,
user profiles, or what BlockP's anti-tamper feels like doing; it survives a BlockP update, a
reinstall, and a reset of this PC; and it covers your phone. If the PC-side layer keeps eroding,
this is where to spend effort instead.

## Health check

Each watchdog overwrites its heartbeat file every second. Older than ~6 seconds means that one
is not running (the other should fix that within seconds):

```powershell
Get-ChildItem C:\ProgramData\BlockPWatchdog\heartbeat-*.txt | Select-Object Name, LastWriteTime
Get-Content C:\ProgramData\BlockPWatchdog\watchdog.log -Tail 20
```

Or just run `diagnose-watchdog.ps1`, which also compares the enforced settings to `config.json`.

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
- **The watchdogs re-enable `BlockPStartup`** within 5 seconds, and each other within seconds.
  There is no "disable it for testing" any more short of the partner code. Test changes to
  `watchdog.ps1` with `tests\` before installing.
- **`Get-ScheduledTask -TaskName BlockPWatchdogA` returns nothing for a standard user.** The task
  is ACL'd. That is not the task missing — check the heartbeats and the
  `Microsoft-Windows-TaskScheduler/Operational` log instead.
- **Never write `config.json` with `Set-Content -Encoding utf8`** in Windows PowerShell 5.1: it
  adds a BOM, and Electron's `JSON.parse` rejects it. The watchdog writes UTF-8 without a BOM.
- **The scripts are ASCII-only on purpose.** PowerShell 5.1 reads BOM-less `.ps1` files as ANSI.
- **Electron's single-instance lock is per user-data dir.** Two instances under the same account
  collide; instances under different accounts do not. A second instance exiting instantly on
  startup usually means the lock, not a crash.
- **Logging out changes your session id.** Anything that hardcodes a session number breaks.
  Resolve it at runtime with `WTSGetActiveConsoleSessionId`.
- **A BlockP update can recreate `BlockPStartup`.** v5 repairs it automatically within 5s.
- **A BlockP update that adds or renames a setting** is not enforced until you uninstall (code)
  and install again; `-Rebaseline` only changes keys that are already enforced. One that
  *removes* a setting will have it re-added by the watchdog, which is harmless.

## Changing settings, or undoing it

Don't change a protected setting in BlockP's UI: the watchdogs revert it within a second and
mail your partner. Request it instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-blockp-watchdog.ps1 -Rebaseline -Set timeDelayMode=true
```

Several at once: `-Set blockGuestMode=false, accountabilityPartnerEmail=new@example.com`. Only
keys that are already enforced, with the same type. A new partner email also becomes where
future codes go, but the code for *that* change goes to the current partner.

```powershell
# Remove the watchdogs entirely (BlockP itself stays installed):
powershell -ExecutionPolicy Bypass -File .\uninstall-blockp-watchdog.ps1
```

Both mail your partner a code and wait for you to type it in. With the code, watchdog A writes
the change into `config.json` and restarts BlockP. Changing the watchdog code itself means
removing it and installing again.

If mail ever breaks (app password revoked, account locked), there is no code. The exit then is
the manual one described under "Honest limits". It is loud on purpose.

## Honest limits

You have physical access to this machine, so none of this is absolute. Safe mode, recovery
media, an offline password reset, or just a different device all defeat it given enough
determination. And since BlockP forces the daily account to stay an administrator, one elevated
command that disables both watchdog tasks *and* kills both processes in the same breath still
gets past v5. The next start of watchdog A mails the partner only if A ever starts again.
LocalMachine DPAPI and the ACL on `C:\ProgramData\BlockPWatchdog` do not stop an administrator.
They only stop casual reading.

The demotion design under "What BlockP will and will not tolerate" is what would turn this
into a wall on the PC side.

The goal is **friction and delay**, which is what actually works against impulse — not an
unbreakable wall. The router layer is the only part of this that a determined five minutes at
the keyboard cannot undo.

## Log

`C:\ProgramData\BlockPWatchdog\watchdog.log`: every relaunch, repair, notice and unlock
request is timestamped there, tagged `[A]` or `[B]`. Worth
reading occasionally; the pattern of *when* you try is more useful information than the count.
