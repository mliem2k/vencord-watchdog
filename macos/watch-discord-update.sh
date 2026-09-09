#!/bin/bash
# Watches for Discord (macOS) updates and automatically reapplies Vencord
# and OpenAsar afterward.
#
# Discord's auto-updater on macOS replaces Contents/Resources of the SAME
# Discord.app bundle in place (unlike Windows, which drops a brand new
# versioned "app-X.Y.Z" folder), which wipes any Vencord/OpenAsar patch.
# This script polls Contents/Info.plist's CFBundleVersion for a change,
# waits for app.asar to stop growing (the updater writing to it), then
# re-patches Vencord (always fetching the latest build, mirroring the
# Windows watcher's --repair, never just reapplying a cached copy) and
# OpenAsar on top, via the vencord-patch-helper binary next to this
# script (built from patcher/ by install-watcher.sh).
#
# Unlike Windows, no elevation is needed: /Applications/Discord.app is
# normally owned by the current user and writable without sudo (Discord's
# own updater writes there unprivileged too).
#
# Usage: watch-discord-update.sh [--branch stable|ptb|canary]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_BINARY="$SCRIPT_DIR/vencord-patch-helper"
LOG_DIR="$HOME/Library/Logs/VencordWatchdog"
LOG_FILE="$LOG_DIR/watcher.log"

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
    stable) APP_NAME="Discord.app" ;;
    ptb) APP_NAME="Discord PTB.app" ;;
    canary) APP_NAME="Discord Canary.app" ;;
    *)
        echo "Branch must be one of: stable, ptb, canary" >&2
        exit 1
        ;;
esac

mkdir -p "$LOG_DIR"

if [[ ! -x "$PATCH_BINARY" ]]; then
    echo "Could not find vencord-patch-helper next to this script. Run install-watcher.sh first, which builds it." >&2
    exit 1
fi

write_log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> "$LOG_FILE"
}

# Resolve the Discord.app path the same way Vencord Installer's
# find_discord_darwin.go does: /Applications first, then ~/Applications.
resolve_discord_app() {
    for base in "/Applications" "$HOME/Applications"; do
        if [[ -d "$base/$APP_NAME" ]]; then
            echo "$base/$APP_NAME"
            return 0
        fi
    done
    return 1
}

get_bundle_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist" 2>/dev/null
}

get_asar_size() {
    stat -f "%z" "$1/Contents/Resources/app.asar" 2>/dev/null
}

invoke_patch() {
    local discord_app="$1"
    local resources="$discord_app/Contents/Resources"
    # Matches the main process (Contents/MacOS/Discord) AND every Electron
    # helper/renderer/GPU subprocess (Contents/Frameworks/Discord Helper*
    # .app/Contents/MacOS/...), all of which live under this one path
    # prefix. A lingering helper subprocess (the main process alone doesn't
    # guarantee helpers exit promptly) can still hold app.asar open in a
    # way that makes renaming it fail transiently, so both the kill and the
    # exit-wait below need to cover all of them, not just the main process.
    local proc_pattern="$discord_app/Contents/"

    # macOS allows renaming/replacing a file a running process still has
    # open (no NTFS-style lock), so closing Discord isn't required to
    # WRITE the patch. It's still required for Discord to actually load
    # the newly-patched code, since Electron only reads app.asar at
    # launch, not while running.
    local was_running=0
    if pgrep -f "$proc_pattern" >/dev/null 2>&1; then
        was_running=1
        write_log "Closing running Discord ($discord_app) before patching..."
        pkill -f "$proc_pattern" 2>/dev/null
        # Poll for actual exit instead of a fixed sleep, so a slow-to-quit
        # Discord can't still be running when we call `open` again below
        # and end up with two concurrent instances.
        local waited=0
        while pgrep -f "$proc_pattern" >/dev/null 2>&1 && [[ $waited -lt 10 ]]; do
            sleep 0.5
            waited=$((waited + 1))
        done
    fi

    write_log "Patching $discord_app..."
    # Retry a few times: a just-killed helper subprocess can transiently
    # hold app.asar open for a moment even after pgrep stops seeing it,
    # and Discord's own updater can be touching Resources at the same
    # instant ours runs, both of which surface as a one-off rename failure
    # that clears up within a second or two.
    local attempt status
    for attempt in 1 2 3; do
        "$PATCH_BINARY" "$resources" >> "$LOG_FILE" 2>&1
        status=$?
        [[ $status -eq 0 ]] && break
        if [[ $attempt -lt 3 ]]; then
            write_log "Patch attempt $attempt failed (exit $status), retrying in 2s..."
            sleep 2
        fi
    done
    if [[ $status -ne 0 ]]; then
        write_log "Patch failed after $attempt attempts (exit $status), see above."
    else
        write_log "Patch complete."
    fi

    if [[ $was_running -eq 1 ]]; then
        write_log "Relaunching Discord..."
        open "$discord_app"
    fi
}

DISCORD_APP="$(resolve_discord_app)"
if [[ -z "$DISCORD_APP" ]]; then
    write_log "No $APP_NAME install found under /Applications or ~/Applications. Exiting."
    exit 1
fi

LAST_VERSION="$(get_bundle_version "$DISCORD_APP")"
write_log "Watcher started. Watching $DISCORD_APP (version $LAST_VERSION). Running initial patch check."
invoke_patch "$DISCORD_APP"

while true; do
    sleep 5
    CURRENT_VERSION="$(get_bundle_version "$DISCORD_APP")"
    if [[ -n "$CURRENT_VERSION" && "$CURRENT_VERSION" != "$LAST_VERSION" ]]; then
        write_log "Detected new version: $CURRENT_VERSION (was $LAST_VERSION). Waiting for updater to settle..."
        stable_checks=0
        last_size=""
        deadline=$(($(date +%s) + 120))
        while [[ $(date +%s) -lt $deadline && $stable_checks -lt 4 ]]; do
            sleep 2
            size="$(get_asar_size "$DISCORD_APP")"
            if [[ -n "$size" && "$size" == "$last_size" ]]; then
                stable_checks=$((stable_checks + 1))
            else
                stable_checks=0
            fi
            last_size="$size"
        done
        invoke_patch "$DISCORD_APP"
        LAST_VERSION="$CURRENT_VERSION"
        write_log "Repatch complete for version $LAST_VERSION"
    fi
done
