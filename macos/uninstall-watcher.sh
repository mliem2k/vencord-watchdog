#!/bin/bash
# Removes the Vencord Watchdog launchd user agent and stops any running watcher.
set -u

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this with sudo. The agent is installed per-user, not as root." >&2
    exit 1
fi

LABEL="com.mliem2k.vencord-watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "gui/$(id -u)/$LABEL" &>/dev/null; then
    if launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
        echo "Stopped and unloaded agent '$LABEL'."
    else
        echo "Failed to unload agent '$LABEL', it may still be running." >&2
    fi
else
    echo "Agent '$LABEL' is not loaded."
    # Fall back to killing a bare watcher process started outside launchd.
    pkill -f "watch-discord-update.sh" 2>/dev/null && echo "Stopped a running watcher process."
fi

if [[ -f "$PLIST_PATH" ]]; then
    rm -f "$PLIST_PATH"
    echo "Removed $PLIST_PATH."
else
    echo "No launchd agent plist found."
fi
