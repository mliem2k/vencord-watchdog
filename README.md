# vencord-watchdog

[![CI](https://github.com/mliem2k/vencord-watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/mliem2k/vencord-watchdog/actions/workflows/ci.yml)

Keeps [Vencord](https://vencord.dev) and [OpenAsar](https://github.com/GooseMod/OpenAsar)
patched into Discord automatically, every time Discord updates.

## Contents

- [The problem](#the-problem)
- [What this does](#what-this-does)
- [Platforms](#platforms)
- [Windows setup](#windows-setup)
- [macOS setup](#macos-setup)
  - [Known issue: OpenAsar can hang on macOS](#known-issue-openasar-can-hang-on-macos)
  - [Required: grant the patch helper "App Management" permission](#required-grant-the-patch-helper-app-management-permission)
- [License](#license)

## The problem

Discord's desktop client auto-updates by dropping a brand new, completely
unpatched `app-X.Y.Z` folder. That silently wipes any Vencord/OpenAsar patch:
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
   Off by default on macOS, see the
   [known issue](#known-issue-openasar-can-hang-on-macos) below.
3. Closes and reopens Discord around the patch, so the running app actually
   loads the newly patched code.

## Platforms

- **Windows**: done, see [`windows/`](windows/).
- **macOS**: done for Vencord; OpenAsar has a known issue and is off by
  default, see [`macos/`](macos/) and the
  [known issue](#known-issue-openasar-can-hang-on-macos) below.

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

### Known issue: OpenAsar can hang on macOS

Live testing found a real bug in OpenAsar itself (not in this project or
in Vencord): its own module update check can hit "Host error" against a
real, pending Discord update and then hang indefinitely retrying,
"checking for updates" forever with no crash and no error, just a stuck
splash screen. Reproduced repeatedly with an unmodified copy of the
official [Vencord Installer](https://github.com/Vencord/Installer)'s own
CLI, so this isn't specific to this project's patcher. Vencord alone,
with no OpenAsar involved, does not have this problem. Until it's
root-caused, `macos/patcher` skips OpenAsar by default (set
`VENCORD_WATCHDOG_ENABLE_OPENASAR=1` to opt in anyway); Vencord itself
was verified to launch reliably across many repeated patch/relaunch
cycles.

Requirements:
- Discord.app installed under `/Applications` (or `~/Applications`).
- [Go](https://go.dev/doc/install), to compile the patch helper once at
  install time.
- **App Management permission for the patch helper**, see below. Without
  this the watcher runs and logs cleanly but every patch attempt fails.

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

### Required: grant the patch helper "App Management" permission

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
   usually nothing to just toggle on; click **+** and add
   `macos/vencord-patch-helper` from wherever you cloned this repo (the
   binary `install-watcher.sh` built), then enable it.
3. Restart the watcher: `launchctl kickstart -k gui/$(id -u)/com.mliem2k.vencord-watchdog`
   (or just log out and back in).

Do this once per machine. It does not need repeating after a Discord or
Vencord update, and it's why the patch logic is a plain compiled
executable rather than a script: TCC attributes this permission to
whatever binary actually performs the file operations, and a script run
through an interpreter means granting it to that interpreter (python3,
wherever it happens to resolve to on your machine) instead of to
anything specific to this project.

### Why the app gets re-signed after every patch

Renaming or rewriting `app.asar` invalidates whatever Discord was already
signed with: its `CodeResources` manifest hashes the original file
contents, so afterward `codesign`/Gatekeeper reports "a sealed resource
is missing or invalid" and macOS refuses to open the app at all
("Discord is damaged and can't be opened"), not merely a bypassable
warning. The patch helper re-signs the app ad-hoc (`codesign --force
--deep --sign -`) as the last step of every patch to fix this
automatically; there is nothing to do here yourself. Worth knowing:
since this changes what Discord looks like to macOS, it can trigger a
one-time Keychain prompt ("Discord wants to use your confidential
information stored in 'discord Safe Storage'") the first time it
happens; click Always Allow so it doesn't ask again. Discord is already
fully logged in and usable regardless of how that prompt is answered.

### Why Krisp (voice noise suppression) gets disabled

A second, sharper consequence of the same re-signing: Discord's Krisp
native module (`discord_krisp.node`, AI noise suppression for voice
chat, a separate feature from voice chat itself) does its own signature
check on startup, and instead of failing gracefully when the app isn't
signed with Discord's real certificate, it segfaults. Electron responds
to that crash by immediately relaunching a fresh renderer, which hits
the identical crash and gets relaunched again, forever: an infinite
crash loop that looks exactly like a plain hang, a black window that
never paints anything, no error dialog. Confirmed directly: an
otherwise-identically-patched, ad-hoc-signed Discord reaches full
interactivity reliably with Krisp's module renamed aside, and crash
loops every single time with it present. `macos/patcher` renames
`discord_krisp.node` (wherever Discord's own module updater has it
installed, a version-numbered path outside Discord.app itself) aside on
every patch cycle, since Discord's updater can silently reinstall a
fresh copy independent of any repatch. This costs Krisp's noise
suppression specifically; voice chat itself (`discord_voice`, a
different module) is untouched. There's no way around this without
Discord's real private signing key, which nobody outside Discord has.

### Why macOS patches itself instead of driving a CLI

The Windows watcher shells out to `VencordInstallerCli.exe`, and the official
[Vencord Installer](https://github.com/Vencord/Installer) releases a headless
CLI build for Windows and Linux (`VencordInstallerCli.exe` /
`VencordInstallerCli-linux`). It does not release one for macOS, only a GUI
`VencordInstaller.app` with no scriptable/headless mode. Rather than
requiring the official installer to already be present, `macos/patcher`
ports the relevant parts of its own patch logic directly (writing the tiny
stub `app.asar`, fetching the latest Vencord build, layering OpenAsar), so
there's nothing else to install first. It's written in Go and compiled to
a standalone binary at install time (see the App Management section above
for why that's a plain compiled executable rather than a script).

### How update detection differs from Windows

Discord's Windows updater drops a brand new `app-X.Y.Z` folder, leaving the
old one in place, so the Windows watcher polls for a new folder appearing.
Discord's macOS updater replaces `Contents/Resources` of the same
`Discord.app` bundle in place instead, so there's no new folder to watch.
The macOS watcher polls `Contents/Info.plist`'s `CFBundleVersion` for a
change, then waits for `app.asar`'s size to stop changing before patching.

## License

MIT
