<#
.SYNOPSIS
    Watches for Discord (Windows) updates and automatically reapplies Vencord
    and OpenAsar afterward.

.DESCRIPTION
    Discord's auto-updater drops a brand new, unpatched "app-X.Y.Z" folder on
    every update, which silently wipes any Vencord/OpenAsar patch. This script
    runs as a long-lived watcher (intended to be launched by install-watcher.ps1
    as a scheduled task) that polls for new app-* folders and, once one shows
    up and stops changing, re-patches Vencord (always pulling the latest build
    via `--repair`, not `--install`, which would just reapply whatever is
    cached) and then OpenAsar.

.PARAMETER Branch
    Discord branch to patch: stable, ptb, or canary. Defaults to stable.
#>
param(
    [ValidateSet("stable", "ptb", "canary")]
    [string]$Branch = "stable"
)

$discordRoot = "$env:LOCALAPPDATA\Discord"
$installerCli = "$env:LOCALAPPDATA\VencordInstaller\VencordInstallerCli.exe"
$logFile = "$env:LOCALAPPDATA\VencordInstaller\watcher.log"

function Write-Log($msg) {
    "$(Get-Date -Format o) $msg" | Out-File -FilePath $logFile -Append -Encoding utf8
}

function Get-LatestAppFolder {
    Get-ChildItem -Path $discordRoot -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Name -replace '^app-', '') } -ErrorAction SilentlyContinue |
        Select-Object -Last 1
}

function Get-FolderSignature($folder) {
    if (-not $folder) { return $null }
    $files = Get-ChildItem -Path $folder.FullName -Recurse -File -ErrorAction SilentlyContinue
    "$($files.Count):$(($files | Measure-Object Length -Sum).Sum)"
}

function Invoke-Patch {
    # The installer CLI's own "kill Discord" step is unreliable (it can miss
    # processes / track a stale PID) and silently no-ops the whole patch if
    # Discord's files are still locked. Force-close it ourselves first.
    #
    # Also: if the watcher task itself isn't running elevated, it may be
    # unable to kill Discord at all if Discord happens to be running with
    # higher privileges than the task. Install the scheduled task with
    # -RunLevel Highest (install-watcher.ps1 does this) to avoid that.
    $wasRunning = $false
    $discordProcs = Get-Process -Name "Discord" -ErrorAction SilentlyContinue
    if ($discordProcs) {
        $wasRunning = $true
        Write-Log "Closing running Discord (PIDs: $($discordProcs.Id -join ', ')) before patching..."
        $discordProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 750
    }

    # -repair (not -install) so this always downloads the latest Vencord
    # build before patching, instead of reapplying whatever is cached locally.
    Write-Log "Fetching latest Vencord build and patching Discord ($Branch)..."
    $out = & $installerCli --repair --branch $Branch 2>&1
    $out | ForEach-Object { Write-Log "  $_" }

    # -install and -install-openasar can't be combined in one call (the CLI's
    # flag handling only runs one action per invocation), so OpenAsar is applied
    # as a second, separate pass after the Vencord patch lands. This is also
    # what always pulls OpenAsar's latest nightly build, since it only
    # downloads when it detects OpenAsar isn't installed yet.
    Write-Log "Applying OpenAsar..."
    $oaOut = & $installerCli --install-openasar --branch $Branch 2>&1
    $oaOut | ForEach-Object { Write-Log "  $_" }

    if ($wasRunning) {
        $exe = Get-ChildItem -Path (Get-LatestAppFolder).FullName -Filter "Discord.exe" -ErrorAction SilentlyContinue
        if ($exe) {
            Write-Log "Relaunching Discord..."
            Start-Process -FilePath $exe.FullName
        }
    }
}

$lastVersion = (Get-LatestAppFolder).Name
Write-Log "Watcher started. Current version: $lastVersion. Running initial patch check."
Invoke-Patch

while ($true) {
    Start-Sleep -Seconds 2
    $current = Get-LatestAppFolder
    if ($current -and $current.Name -ne $lastVersion) {
        Write-Log "Detected new version folder: $($current.Name) (was $lastVersion). Waiting for updater to settle..."
        $stableChecks = 0
        $lastSig = $null
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline -and $stableChecks -lt 4) {
            Start-Sleep -Seconds 2
            $sig = Get-FolderSignature $current
            if ($sig -and $sig -eq $lastSig) { $stableChecks++ } else { $stableChecks = 0 }
            $lastSig = $sig
        }
        Invoke-Patch
        $lastVersion = $current.Name
        Write-Log "Repatch complete for version $lastVersion"
    }
}
