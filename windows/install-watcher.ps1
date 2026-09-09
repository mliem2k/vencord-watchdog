#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the Vencord Watchdog scheduled task.

.DESCRIPTION
    Registers a scheduled task that runs watch-discord-update.ps1 (from this
    same folder) at logon, hidden, elevated. The elevation matters: if Discord
    is ever running with higher privileges than the task, a non-elevated task
    can't close it to patch. Re-run this script any time to reinstall/repair
    the task.

.PARAMETER Branch
    Discord branch to watch/patch: stable, ptb, or canary. Defaults to stable.
#>
param(
    [ValidateSet("stable", "ptb", "canary")]
    [string]$Branch = "stable"
)

$ErrorActionPreference = "Stop"

$taskName = "Vencord Update Watcher"
$scriptPath = Join-Path $PSScriptRoot "watch-discord-update.ps1"

if (-not (Test-Path $scriptPath)) {
    throw "Could not find watch-discord-update.ps1 next to this installer."
}

$installerCli = "$env:LOCALAPPDATA\VencordInstaller\VencordInstallerCli.exe"
if (-not (Test-Path $installerCli)) {
    throw "VencordInstallerCli.exe not found at $installerCli. Run the official Vencord installer (https://vencord.dev/download) at least once first."
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Branch $Branch"

$trigger = New-ScheduledTaskTrigger -AtLogOn

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "Task '$taskName' already exists, replacing it..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null

Write-Host "Installed scheduled task '$taskName' (branch: $Branch). Starting it now..."
Start-ScheduledTask -TaskName $taskName

Write-Host "Done. Logs: $env:LOCALAPPDATA\VencordInstaller\watcher.log"
