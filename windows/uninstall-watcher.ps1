#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the Vencord Watchdog scheduled task and stops any running watcher.
#>

$taskName = "Vencord Update Watcher"

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'watch-discord-update' } |
    ForEach-Object {
        Write-Host "Stopping running watcher (PID $($_.ProcessId))..."
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task '$taskName'."
} else {
    Write-Host "No such scheduled task found."
}
