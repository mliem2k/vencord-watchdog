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

function Test-HasAsar($folder) {
    # Discord's own asar is tiny once Vencord/OpenAsar are applied (Vencord's
    # app.asar shim is ~200 bytes), so this can't check file size -- only that
    # an asar exists at all. A folder with none is a half-written Squirrel
    # update, which must never be patched or launched (see Wait-ForUpdaterIdle).
    if (-not $folder) { return $false }
    $resources = Join-Path $folder.FullName "resources"
    if (-not (Test-Path $resources)) { return $false }
    return [bool](Get-ChildItem -Path $resources -Filter '*.asar' -File -ErrorAction SilentlyContinue)
}

function Get-FallbackGoodFolder($excludeName) {
    # Used when the newest app-* folder fails to patch. Scanned from disk
    # rather than tracked in a variable, since the watcher may have just
    # (re)started and so have no in-memory record of the last good version --
    # but an older, still-intact install folder can still be sitting right
    # there on disk from before the broken update landed.
    Get-ChildItem -Path $discordRoot -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $excludeName } |
        Sort-Object { [version]($_.Name -replace '^app-', '') } -Descending -ErrorAction SilentlyContinue |
        Where-Object { Test-HasAsar $_ } |
        Select-Object -First 1
}

function Wait-ForUpdaterIdle($folder, [int]$timeoutSeconds = 120) {
    # Discord's own Squirrel updater (Update.exe) can still be extracting/
    # copying files into the new app-* folder even after its file count/size
    # briefly looks stable between polls (e.g. paused mid-write). Patching
    # during that window is exactly what once left a version folder with zero
    # asar files -- Discord could then only crash on launch, which dragged
    # Discord's own updater into an endless rollback/re-update loop against
    # this watcher. Require a stable signature AND Update.exe exited AND a
    # real asar already present before touching anything.
    $stableChecks = 0
    $lastSig = $null
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $sig = Get-FolderSignature $folder
        $updaterRunning = [bool](Get-Process -Name "Update" -ErrorAction SilentlyContinue)
        if ($sig -and $sig -eq $lastSig -and -not $updaterRunning -and (Test-HasAsar $folder)) {
            $stableChecks++
        } else {
            $stableChecks = 0
        }
        $lastSig = $sig
        if ($stableChecks -ge 4) { return $true }
    }
    return $false
}

function Invoke-Patch($folder) {
    # The installer CLI's own "kill Discord" step is unreliable (it can miss
    # processes / track a stale PID) and silently no-ops the whole patch if
    # Discord's files are still locked. Force-close it ourselves first.
    #
    # Also close Update.exe (Squirrel's updater): if it's still mid-copy when
    # we patch, our own unpatch/repatch rename of app.asar <-> _app.asar can
    # race it and leave the folder with no asar at all.
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
    }
    $updateProcs = Get-Process -Name "Update" -ErrorAction SilentlyContinue
    if ($updateProcs) {
        Write-Log "Closing Discord's own updater (PIDs: $($updateProcs.Id -join ', ')) before patching..."
        $updateProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    if ($wasRunning -or $updateProcs) { Start-Sleep -Milliseconds 750 }

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

    if (-not (Test-HasAsar $folder)) {
        Write-Log "ERROR: $($folder.Name) has no asar file after patching -- refusing to launch a broken install."
        return $false
    }

    if ($wasRunning) {
        $exe = Join-Path $folder.FullName "Discord.exe"
        if (Test-Path $exe) {
            Write-Log "Relaunching Discord..."
            Start-Process -FilePath $exe
        }
    }
    return $true
}

$lastVersion = $null
Write-Log "Watcher started. Current version: $((Get-LatestAppFolder).Name). Running initial patch check."

while ($true) {
    $current = Get-LatestAppFolder
    if ($current -and $current.Name -ne $lastVersion) {
        Write-Log "Detected version folder: $($current.Name) (was $lastVersion). Waiting for updater to settle..."
        if (-not (Wait-ForUpdaterIdle $current)) {
            Write-Log "WARNING: $($current.Name) never fully settled within the timeout; patching anyway."
        }

        $ok = $false
        for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
            if ($attempt -gt 1) {
                Write-Log "Retrying patch for $($current.Name) (attempt $attempt/3)..."
                Start-Sleep -Seconds 3
            }
            $ok = Invoke-Patch $current
        }

        if ($ok) {
            Write-Log "Repatch complete for version $($current.Name)"
        } else {
            Write-Log "ERROR: Giving up patching $($current.Name) after 3 attempts."
            if (-not (Get-Process -Name "Discord" -ErrorAction SilentlyContinue)) {
                $fallback = Get-FallbackGoodFolder $current.Name
                if ($fallback) {
                    $goodExe = Join-Path $fallback.FullName "Discord.exe"
                    if (Test-Path $goodExe) {
                        Write-Log "Relaunching last known-good version $($fallback.Name) instead."
                        Start-Process -FilePath $goodExe
                    }
                } else {
                    Write-Log "ERROR: No intact fallback version found on disk either. Discord is left closed until this resolves."
                }
            }
        }
        # Record this version as seen either way, and pause before re-checking,
        # so a folder that keeps flapping gets retried on a slow cadence
        # instead of hammering the installer CLI in a tight loop.
        $lastVersion = $current.Name
        Start-Sleep -Seconds 15
    }
    Start-Sleep -Seconds 2
}
