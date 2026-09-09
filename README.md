# vencord-watchdog

Keeps [Vencord](https://vencord.dev) and [OpenAsar](https://github.com/GooseMod/OpenAsar)
patched into Discord automatically, every time Discord updates.

## The problem

Discord's desktop client auto-updates by dropping a brand new, completely
unpatched `app-X.Y.Z` folder. That silently wipes any Vencord/OpenAsar patch —
you're back to stock Discord until you notice and re-run the installer by
hand.

## What this does

A background watcher polls for that new folder, waits for Discord's updater to
finish writing to it, then:

1. Re-patches **Vencord**, always pulling the *latest* build first (`--repair`,
   not `--install`, which would just reapply whatever's cached locally).
2. Re-applies **OpenAsar** on top (in that order — Vencord first, then
   OpenAsar — see [why order matters](#why-vencord-before-openasar) below).
3. Closes and reopens Discord around the patch, since a running Discord holds
   a lock on the files being patched.

## Platforms

- **Windows** — done, see [`windows/`](windows/).
- **macOS** — planned, see [`macos/README.md`](macos/README.md).

## Windows setup

Requirements:
- [Vencord Installer](https://vencord.dev/download) run at least once (this
  provides `VencordInstallerCli.exe`, which the watcher drives).
- PowerShell, run as Administrator for install/uninstall.

```powershell
git clone https://github.com/mliem2k/vencord-watchdog.git
cd vencord-watchdog/windows
.\install-watcher.ps1          # defaults to the stable branch
# .\install-watcher.ps1 -Branch canary   # or ptb / canary
```

This registers a scheduled task ("Vencord Update Watcher") that runs
`watch-discord-update.ps1` hidden, at logon, elevated. It also runs an
initial patch check immediately.

To remove it:

```powershell
.\uninstall-watcher.ps1
```

Logs land at `%LOCALAPPDATA%\VencordInstaller\watcher.log`.

### Why the task needs to run elevated

If Discord is ever running with higher privileges than the watcher task, a
non-elevated task can't force-close it to release the file lock, and the
patch silently fails. Installing the task with `-RunLevel Highest` avoids
that regardless of how Discord itself was launched.

### Why Vencord before OpenAsar

Vencord's patch just backs up whatever the current "real" Discord app is and
drops in its own small stub. OpenAsar's installer is the one that's layering-aware:
run after Vencord, it backs up the file *underneath* Vencord's stub and
replaces that with its own lean bundle, leaving Vencord's stub as the active
entry point untouched. Doing it the other way around risks OpenAsar's bundle
ending up as the outer layer instead, relying on its own separate
Vencord-detection logic rather than the clean stub chain.

## License

MIT
