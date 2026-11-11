#Requires -RunAsAdministrator
<#
  Swaps the installed watchdog.ps1 for a new version without uninstalling (v6.1 and later).

  Your partner gets one mail with the new file's SHA-256 and an 8-digit code. With the code,
  watchdog A stops the others, writes the new script, and they all restart on it within a
  few seconds. No "killed" or "stopped" alarms are sent for that restart.

  The code is bound to the exact file staged here: A reads it into memory when you make
  the request, so changing the file afterwards changes nothing.

  What this does NOT change: state.json (enforced settings, partner), smtp.bin and the task
  definitions. If a new version needs any of those changed, use uninstall + install.

    .\upgrade-blockp-watchdog.ps1
    .\upgrade-blockp-watchdog.ps1 -Source D:\somewhere\watchdog.ps1
#>
param([string] $Source = (Join-Path $PSScriptRoot 'watchdog.ps1'))

& (Join-Path $PSScriptRoot 'uninstall-blockp-watchdog.ps1') -Upgrade -Source $Source
exit $LASTEXITCODE
