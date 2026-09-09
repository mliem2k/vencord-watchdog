# macOS support (planned)

Not built yet. The Windows watcher works by:

1. Polling `%LOCALAPPDATA%\Discord` for a new `app-*` version folder (Discord's
   updater drops a completely fresh, unpatched one on every update).
2. Waiting for that folder to stop changing size/file count (the updater is
   still writing to it).
3. Re-running `VencordInstallerCli --repair` (fetches the latest Vencord build,
   then patches) followed by `VencordInstallerCli --install-openasar`.
4. Force-closing and relaunching Discord around the patch so file locks don't
   block it.

On macOS, Discord lives at `/Applications/Discord.app` and updates in place
(no versioned folder to watch), so step 1 needs a different signal — likely
an `NSWorkspace`/`FSEvents` watch on the app bundle's `Contents/Resources`, or
just polling `Contents/Info.plist`'s `CFBundleVersion`. The rest (VencordInstallerCli
has macOS builds, and Discord needs to be closed before patching, e.g. via
`pkill Discord`) should map over fairly directly. Would run as a `launchd`
user agent (`~/Library/LaunchAgents`) instead of a Windows scheduled task.

Contributions welcome.
