# BlockP Hardening: design notes

Why the watchdog looks the way it does, and what was tried and disproved along the way.
The user guide is [README.md](README.md). **Read "What BlockP will and will not tolerate"
before changing the architecture.** The obvious hardening move (demote the daily account and
run BlockP as a separate admin) was built, tested and **disproved** on 14.09.2026. Don't
rebuild it.

## Why this exists

BlockP is a plain Electron app with **no Windows service and no kernel driver**. It runs as
`Jonas`, and `Jonas` is a local Administrator, so Task Manager kills it with no UAC prompt.
Its built-in uninstall protection can't survive that. These scripts add the missing layers.

## v6.1 — BlockP's updater, false kill alarms, in-place upgrade (11.11.2026)

**Restart loop after sign-in.** Symptom: after a sign-in BlockP kept restarting, showing its
blocking screen, until a sign-out and sign-in. First suspected: a BlockP update rewriting
`config.json` and the watchdogs reverting it. **Disproved:** `watchdog.log` (30.10–11.11) has
no `BlockP settings changed` entry at all, and `config.json` was last written 20.10. The
watchdogs only kill BlockP in a config repair, so they never killed it. They only relaunched it
after it exited by itself. (The watchdogs also don't snapshot the config at start; they
enforce the install-time `state.json`, and sign-out doesn't restart them.)

What the PC showed instead: BlockP 2.0.12 installed (16.10) and **2.1.3 downloaded on 05.11 and
never installed** (`%LOCALAPPDATA%\blockp-updater\pending\`). BlockP uses electron-updater
(NSIS): to install, it quits BlockP and runs the setup, which has to close every `BlockP.exe`
and replace the files. A watchdog sees zero BlockP processes and relaunches the old exe within
a second, which breaks the install, and BlockP tries again on its next start. This is the
leading explanation, **not proven**: the log can't show what ran during a loop, and why a
sign-out ends it is still open.

Fix: while a **genuine** BlockP setup runs, the watchdogs skip relaunch and config repair
(`Test-UpdatePause`). "Genuine" = an exe under some user's `AppData\Local\blockp-updater\`
**and** a valid Authenticode signature with `CN=NovaFocus LLC` (2.1.3's setup, the cached
`installer.exe` and `BlockP.exe` are all signed that way). After the setup exits, 15 s of grace
lets it start BlockP itself. Running the genuine setup by hand still only gets 5 min per run and
10 min per rolling hour; past that, enforcement resumes and the partner is mailed. The signed
`Uninstall BlockP.exe` in Program Files does **not** pause anything.

Side note: `LastBootUpTime` was 16.10 on 11.11. With Fast Startup, "shut down" doesn't restart
the watchdogs, so they can run for weeks on one RAM copy.

**False "watchdog killed" alarms.** The log showed one or two of these an hour, with no matching
restart. Cause: a peer reads the PID only when the heartbeat is >3 s old (owner busy in a slow
step). If it catches the file while the owner rewrites it, `ReadAllText` returns `''`, `[int]''`
is `0`, PID 0 is `Idle`, not `powershell`, so the peer counts as killed. The reader also held
the file without write sharing, which is where the `heartbeat-X.txt ... von einem anderen Prozess
verwendet` errors came from. Now: reads share write access, an unreadable or unparsable
heartbeat is read again and otherwise counts as alive, and before reporting a death `Confirm-Peers`
looks for a watchdog process with `-Role X` on its command line. Only a missing file or a
missing process counts as dead.

**In-place upgrade.** `upgrade-blockp-watchdog.ps1` (= `uninstall-blockp-watchdog.ps1 -Upgrade`)
stages the new `watchdog.ps1` in `unlock\` and asks A for an `upgrade` code. A reads the staged
bytes into RAM at request time, checks they are ASCII, parse, differ from the running version
and match the requested SHA-256, and mails the partner both versions with their SHA-256. With the
code it stops the others, writes the new script, updates its RAM copy, writes `upgraded.txt`
(new hash + time) and starts the others; then A exits and they restart A. New watchdogs that
find a mark matching their own hash and <2 min old skip kill notices for 60 s, and the
"all were stopped" check. No code-free upgrade on purpose: whatever is installed is trusted, so a
code-free upgrade is a code-free uninstall. It doesn't touch `state.json`, `smtp.bin` or the
task definitions. Changes to those still need uninstall + install. v6 itself doesn't know
`upgrade`, so getting to v6.1 takes one uninstall + install.

## v6 — an army instead of a pair

With two watchdogs it was easy to kill both in Task Manager before either noticed, and after
that the every-minute trigger meant up to 60s without protection. v6 runs `-Count` watchdogs
(default 6, `A`–`F`), each identical to a v5 watchdog, with three changes:

- **Everyone guards everyone.** Every second, each watchdog checks every other one and starts
  any that is gone. A peer counts as gone only if its heartbeat is >3s old **and** the PID in its
  heartbeat no longer exists, so one that is merely busy (a 20s config repair, a slow mail) is
  left alone. A killed watchdog is back in ~3–5s, with a new PID, so clicking through them one at
  a time in Task Manager loses the race.
- **Staggered triggers.** Task *k* re-triggers every minute at second `k × 60/Count` (A at :00,
  B at :10, … F at :50). After a kill-all, the next watchdog starts within `60/Count` seconds —
  10s at the default — and it brings the rest back.
- **One voice.** The lowest-lettered live watchdog sends the notices and repairs
  `BlockPStartup`, so six watchdogs don't mean six mails. A new notice, **"watchdog killed"**, goes
  out when a watchdog that was seen running disappears. The "all were stopped" notice now fires
  after a gap of `60/Count + 10` seconds instead of 3 minutes.

Each watchdog checks its own task and the next one round the ring (A→B→…→F→A) every 5s, so
every task has two guardians. Whoever holds the repair mutex while relaunching BlockP keeps it
until BlockP is up, so the other five don't launch it again. Rebaseline and uninstall (role A)
now kill *and disable* the others in a loop until none are left, so a trigger can't bring one
back with the old state in RAM halfway through.

Cost: ~100 MB private memory per watchdog, so ~600 MB at the default. `diagnose-watchdog.ps1`
prints the total.

**Upgrading from v5** is a normal remove + install: `uninstall-blockp-watchdog.ps1` (partner
code), then `install-blockp-watchdog.ps1`. v5 holds its own script in RAM and would revert an
in-place swap.

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

(Conclusion from 14.09.2026. It holds for BlockP running **elevated**. The note above from
25.09.2026 describes the one untested way around it: BlockP unelevated via `RunAsInvoker`,
with the watchdogs guarding `config.json`.)


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
- **BlockP's own updater needs BlockP gone while it installs.** Relaunching under it broke the
  2.1.3 install for a week (05.–11.11.2026). v6.1 pauses for signed setups (see above).
- **`[int]''` is `0` in PowerShell, and PID 0 exists (`Idle`).** Never parse a PID from a file
  that might be mid-write without `[int]::TryParse` and a check for `> 0`.
- **A BlockP update that adds or renames a setting** is not enforced until you uninstall (code)
  and install again; `-Rebaseline` only changes keys that are already enforced. One that
  *removes* a setting will have it re-added by the watchdog, which is harmless.

