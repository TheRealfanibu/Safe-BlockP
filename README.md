# BlockP Hardening

Makes BlockP (`C:\Program Files\BlockP`) on `JONAS-GAMING-PC` hard to switch off on impulse.

BlockP alone is easy to beat: you are an administrator, so killing it in Task Manager or
editing its settings file takes seconds. With these scripts:

- **BlockP comes back** within ~1–20 seconds of being killed.
- **Its settings are locked.** If anyone changes a protected setting, in BlockP's UI or in
  `config.json`, it is reverted within a second.
- **Your accountability partner hears about tampering.** Changed settings, killed watchdogs,
  and deleted or disabled tasks all trigger an email.
- **The only supported way out goes through your partner.** Removing the protection or
  changing a setting needs an 8-digit code that is emailed to them.

This protection is SYSTEM processes and scheduled tasks. Nothing is installed as a service
or driver. The goal is **friction and a witness**, not an unbreakable wall (see
[Limits](#limits)).

How it works, and what was tried and disproved along the way: [DESIGN.md](DESIGN.md).

## Before you install

1. **BlockP is installed, you are signed in, and it is set up exactly how you want it.**
   The installer takes BlockP's current settings as the baseline it enforces. Turning a
   setting on later (for example `timeDelayMode`) needs a code too.
2. **An accountability partner email is set in BlockP** (or pass `-PartnerEmail`).
3. **A mail account the watchdog can send from.** Read this part carefully:

   Gmail and Outlook keep a copy of every message sent over SMTP in the Sent folder. If
   *you* can log into the sending mailbox, you can read every unlock code there. The
   password is also stored on this PC, and as an admin you could decrypt it.

   So **the sending account should belong to your partner.** Ask them to create a separate
   Gmail address, turn on 2-step verification, create an app password (Google Account →
   Security → 2-Step Verification → App passwords), and type it into the installer
   themselves. Another option is a send-only relay such as SendGrid (user `apikey`, host
   `smtp.sendgrid.net`), which has no mailbox anyone could read.
4. **Your account must be an administrator.** BlockP won't run otherwise. If you're not one,
   use `-RestoreAdmin` and sign out and back in.

## Install

In an **elevated** PowerShell (right-click → Run as administrator), in this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-blockp-watchdog.ps1 -SmtpUser blockp.watchdog.xyz@gmail.com
```

The installer:

- shows every setting it will lock and waits for you to type `YES`,
- asks for the mail password (spaces in a Gmail app password are removed automatically) and
  sends a test mail; if the test fails, it stops without installing anything,
- can optionally email your partner a short message explaining what they signed up for,
- starts 6 watchdogs and checks that they are alive.

Useful options: `-PartnerEmail`, `-SmtpHost` / `-SmtpPort` (default Gmail, 587), `-SmtpFrom`,
`-Count` (number of watchdogs, 2–16, default 6, ~100 MB RAM each).

The installer only runs once. After that, every change goes through the partner code.

## Living with it

- **Don't change protected settings in BlockP's UI.** They are reverted within a second, and
  your partner gets an email. Request the change instead (below).
- **Your partner gets an email** (no more than one per type of event every 30 min) when:
  settings were changed, a watchdog was killed, a watchdog task was deleted, altered or
  disabled, a watchdog file was edited, or all watchdogs had been stopped.
- **BlockP updates itself.** While its signed update installer runs, the watchdogs stop
  restarting BlockP (at most 5 minutes per run, 10 per hour), so the update can finish.
- **A BlockP update** that recreates its startup task is fixed automatically. An update that
  *adds or renames* a setting: the new setting isn't locked until you remove the watchdogs
  (with a code) and install again.

## Changing a setting

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-blockp-watchdog.ps1 -Rebaseline -Set timeDelayMode=true
```

To change several at once: `-Set blockGuestMode=false, accountabilityPartnerEmail=new@example.com`.
You can only change settings that are already locked, and a setting keeps its type (true/false stays
true/false). Your partner's email shows exactly what will change. When you change the partner
address, the code for *that* change still goes to the current partner.

## Removing it

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-blockp-watchdog.ps1
```

BlockP itself stays installed. After you remove the watchdogs, your partner gets an email
saying so.

**How the code works (both for changes and for removal):** the script asks watchdog A for a
code, and A emails it to your partner. Ask them for it and type it in. The code is valid for
60 minutes, three wrong tries lock it, and it is never written to disk. Editing the uninstall
script does nothing: watchdog A does the work.

If mail is broken (for example, the app password was revoked), no code can be sent. There
is no quiet way out then. See [Limits](#limits).

## Upgrading the watchdog

From v6.1 on, a new `watchdog.ps1` goes in without uninstalling:

```powershell
powershell -ExecutionPolicy Bypass -File .\upgrade-blockp-watchdog.ps1
```

Your partner gets one email naming the old and new version with their SHA-256, plus the
code. With the code, the watchdogs restart on the new file within a few seconds, and no
"killed" or "stopped" alarms go out. The code installs only the exact file you staged, so
tell your partner what changed. Copying the file over by hand still doesn't work: the
watchdogs hold their own copy in memory and put it back.

If the new version needs different locked settings, a different partner or mail account, or
different tasks, use remove + install instead. **Going from v6 to v6.1** also needs remove +
install once, because v6 doesn't know about upgrades.

## Is it still working?

Silent failure is the real risk. A blocker that quietly stopped is worse than none, because
you think you're covered. That happened on 13–14.09: BlockP was "running" and blocking
nothing. Check now and then:

```powershell
powershell -ExecutionPolicy Bypass -File .\diagnose-watchdog.ps1
```

This command is read-only. It shows the watchdogs' heartbeats, whether the locked settings
match `config.json`, the state of the tasks, and whether BlockP is actually running in *your*
session and staying up.

What to look for:

- **Heartbeats older than ~4 s**: that watchdog is not running (the others should restart it
  within seconds).
- **BlockP in session 0**: it's running but blocking nothing.
- **BlockP's PIDs change every few seconds**: it is crashing and restarting.
- **`0x80000003` in the Application event log**: BlockP refuses to run under that identity
  (see [DESIGN.md](DESIGN.md#what-blockp-will-and-will-not-tolerate)).

The log is `C:\ProgramData\BlockPWatchdog\watchdog.log`. Every relaunch, repair, email and
unlock request is recorded there with a timestamp. Knowing *when* you try to get around it
tells you more than how often.

## Troubleshooting

- **`Get-ScheduledTask BlockPWatchdogA` shows nothing** as a standard user: the tasks are
  locked down. They aren't missing. Use `diagnose-watchdog.ps1` from an elevated shell.
- **BlockP won't die with `Stop-Process`**: with `preventUninstallMode` on, each instance
  starts a new one before it exits. And while the watchdogs are installed, they restart it anyway.
- **Editing `config.json` by hand** (only after removing the watchdogs): never save it with
  `Set-Content -Encoding utf8` in Windows PowerShell 5.1. That adds a BOM, and BlockP can't
  read the file.

## Limits

You have physical access and an admin account, so this can't be absolute:

- One elevated command that disables every watchdog task *and* kills every watchdog process
  gets past it. Your partner only hears about it if a watchdog ever starts again.
- Killing all watchdogs without disabling the tasks buys about 10 seconds.
- Safe Mode, recovery media, or another device get around it.

What this setup does protect against is the impulse: killing BlockP by hand, flipping a setting,
deleting a task. Each of these is undone within seconds, and your partner finds out.

**The layer that survives all of this:** a filtering DNS resolver (NextDNS or CleanBrowsing) set
on the **router**, with the router's admin password held by your partner. It doesn't depend on
BlockP, survives reinstalling Windows, and covers your phone too. If the PC-side protection
keeps getting weaker, put your effort there instead.
