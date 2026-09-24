#Requires -RunAsAdministrator
# Removes the BlockP watchdog. Needs admin rights on purpose -
# once you are a standard user, you cannot run this without the admin password.

$ErrorActionPreference = 'Continue'
$root = 'C:\ProgramData\BlockPWatchdog'

foreach ($t in 'BlockPWatchdog', 'BlockPWatchdogLaunch') {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Write-Host "removed scheduled task $t"
    }
}

# Kill any watchdog powershell still looping
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'BlockPWatchdog' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (Test-Path $root) {
    & icacls.exe $root /reset /t /q | Out-Null
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "removed $root"
}

Write-Host 'Watchdog uninstalled.' -ForegroundColor Yellow
