# vencord-watchdog

Keeps [Vencord](https://vencord.dev) and [OpenAsar](https://github.com/GooseMod/OpenAsar)
patched into Discord automatically, every time Discord updates.

## The problem

Discord's desktop client auto-updates by dropping a brand new, completely
unpatched `app-X.Y.Z` folder. That silently wipes any Vencord/OpenAsar patch —
you're back to stock Discord until you notice and re-run the installer by
hand.

## What this does

A background watcher detects when Discord has updated (how it detects that is
platform specific, see below), waits for Discord's updater to finish writing,
then:

1. Re-patches **Vencord**, always pulling the latest build first (not just
   reapplying whatever was cached locally).
2. Re-applies **OpenAsar** on top, in that order (Vencord first, then
   OpenAsar, see [why order matters](#why-vencord-before-openasar) below).
3. Closes and reopens Discord around the patch, so the running app actually
   loads the newly patched code.

## Platforms

- **Windows**: done, see [`windows/`](windows/).
- **macOS**: done, see [`macos/`](macos/).

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

## macOS setup

Requirements:
- Discord.app installed under `/Applications` (or `~/Applications`).
- Python 3 (macOS ships `/usr/bin/python3` once Xcode Command Line Tools are
  installed, `xcode-select --install`).
- **App Management permission for Python**, see below. Without this the
  watcher runs and logs cleanly but every patch attempt fails.

No separate Vencord Installer download is needed on macOS: the watcher does
its own patching directly (see [why](#why-macos-patches-itself-instead-of-driving-a-cli)
below), so there's nothing else to install first.

```sh
git clone https://github.com/mliem2k/vencord-watchdog.git
cd vencord-watchdog/macos
./install-watcher.sh                    # defaults to the stable branch
# ./install-watcher.sh --branch canary  # or ptb / canary
```

This registers a `launchd` user agent (`com.mliem2k.vencord-watchdog`) that
runs `watch-discord-update.sh` at login and keeps it alive. It also runs an
initial patch check immediately. No sudo is needed: `/Applications/Discord.app`
is normally owned by the current user.

To remove it:

```sh
./uninstall-watcher.sh
```

Logs land at `~/Library/Logs/VencordWatchdog/watcher.log`.

### Required: grant Python "App Management" permission

macOS's App Management privacy control (introduced to stop one app from
tampering with another's files) blocks renaming or replacing anything
inside `Discord.app` unless the process doing it has an explicit grant.
A background `launchd` agent has no window to show the usual permission
prompt, so without this the watcher just fails every patch attempt with
`Operation not permitted`, logged clearly with this same explanation.

This is not specific to this project: the official
[VencordInstaller.app](https://vencord.dev/download) hits the identical
restriction the first time it patches, it just has a GUI that can prompt
for it. A background watcher can't, so it has to be granted ahead of time:

1. Open **System Settings > Privacy & Security > App Management**
   (or run `open "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"`).
2. macOS does not auto-list a background `launchd` agent's denied attempts
   here the way it sometimes does for other privacy panes, so there is
   usually nothing to just toggle on; click **+** and add the interpreter
   the watcher actually runs (find its real path with
   `/usr/bin/env python3 -c "import sys; print(sys.executable)"`, since
   `/usr/bin/python3` is commonly a shim to something else, e.g. Xcode
   Command Line Tools' copy), then enable it.
3. Restart the watcher: `launchctl kickstart -k gui/$(id -u)/com.mliem2k.vencord-watchdog`
   (or just log out and back in).

Do this once per machine. It does not need repeating after a Discord or
Vencord update.

### Why macOS patches itself instead of driving a CLI

The Windows watcher shells out to `VencordInstallerCli.exe`, and the official
[Vencord Installer](https://github.com/Vencord/Installer) releases a headless
CLI build for Windows and Linux (`VencordInstallerCli.exe` /
`VencordInstallerCli-linux`). It does not release one for macOS, only a GUI
`VencordInstaller.app` with no scriptable/headless mode. Rather than requiring
Go to build an unofficial CLI from source, `vencord_patch.py` ports the
relevant parts of the installer's own patch logic directly (writing the tiny
stub `app.asar`, fetching the latest Vencord build, layering OpenAsar), so
setup only needs Python 3, which is already on any Mac with Xcode Command
Line Tools.

### How update detection differs from Windows

Discord's Windows updater drops a brand new `app-X.Y.Z` folder, leaving the
old one in place, so the Windows watcher polls for a new folder appearing.
Discord's macOS updater replaces `Contents/Resources` of the same
`Discord.app` bundle in place instead, so there's no new folder to watch.
The macOS watcher polls `Contents/Info.plist`'s `CFBundleVersion` for a
change, then waits for `app.asar`'s size to stop changing before patching.

## License

MIT
