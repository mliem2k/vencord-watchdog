#!/bin/bash
# Installs the Vencord Watchdog launchd user agent.
#
# Registers a LaunchAgent that runs watch-discord-update.sh (from this same
# folder) at login and keeps it alive, then starts it immediately. No sudo
# and no elevation is needed on macOS: unlike Windows, Discord.app is
# normally user-owned and user-writable, so the agent runs as the plain
# logged-in user. Re-run this script any time to reinstall/repair the agent.
#
# Usage: install-watcher.sh [--branch stable|ptb|canary]
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this with sudo. It installs a per-user launchd agent" >&2
    echo "under the logged-in user's own session, not root's." >&2
    exit 1
fi

BRANCH="stable"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)
            if [[ $# -lt 2 ]]; then
                echo "--branch requires a value" >&2
                exit 1
            fi
            BRANCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

case "$BRANCH" in
    stable | ptb | canary) ;;
    *)
        echo "Branch must be one of: stable, ptb, canary" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_SCRIPT="$SCRIPT_DIR/watch-discord-update.sh"
PATCHER_SRC_DIR="$SCRIPT_DIR/patcher"
PATCH_BINARY="$SCRIPT_DIR/vencord-patch-helper"

if [[ ! -f "$WATCH_SCRIPT" ]]; then
    echo "Could not find watch-discord-update.sh next to this installer." >&2
    exit 1
fi
if [[ ! -d "$PATCHER_SRC_DIR" ]]; then
    echo "Could not find the patcher/ source directory next to this installer." >&2
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    echo "Go is required to build the patch helper (compiled once, here, at install time)." >&2
    echo "Install it from https://go.dev/doc/install, then re-run this script." >&2
    exit 1
fi

# Compiled to a standalone binary rather than shipped as a script so
# macOS's App Management privacy grant (see the README) can point at one
# stable, easy-to-find executable instead of a python3/etc interpreter
# path buried inside some other tool's install.
echo "Building the patch helper..."
(cd "$PATCHER_SRC_DIR" && go build -o "$PATCH_BINARY" .)
chmod +x "$WATCH_SCRIPT" "$PATCH_BINARY"

LABEL="com.mliem2k.vencord-watchdog"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/VencordWatchdog"

mkdir -p "$PLIST_DIR" "$LOG_DIR"

if launchctl print "gui/$(id -u)/$LABEL" &>/dev/null; then
    echo "Agent '$LABEL' already loaded, unloading it first..."
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
fi
# Also stop a watcher started by hand outside launchd (e.g. a prior
# `./watch-discord-update.sh &`), or the agent we're about to install would
# run alongside it and both could race patching the same Discord install.
pkill -f "watch-discord-update.sh" 2>/dev/null || true

# XML-escape values that come from the filesystem (a checkout path could in
# principle contain &, <, >, "); $BRANCH is already constrained to a fixed
# allowlist above and $LABEL is a literal, so neither needs this.
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}
WATCH_SCRIPT_XML="$(xml_escape "$WATCH_SCRIPT")"
LOG_DIR_XML="$(xml_escape "$LOG_DIR")"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$WATCH_SCRIPT_XML</string>
		<string>--branch</string>
		<string>$BRANCH</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$LOG_DIR_XML/agent.log</string>
	<key>StandardErrorPath</key>
	<string>$LOG_DIR_XML/agent.log</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Installed launchd agent '$LABEL' (branch: $BRANCH). Starting it now..."
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Done. Logs: $LOG_DIR/watcher.log"
