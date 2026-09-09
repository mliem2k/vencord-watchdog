#!/usr/bin/env python3
"""
Re-patches Vencord + OpenAsar into a Discord.app Resources dir.

Ports the relevant parts of https://github.com/Vencord/Installer (patcher.go,
app_asar.go, openasar.go, github_downloader.go) directly, because Vencord
Installer only publishes a headless CLI build for Windows and Linux
(VencordInstallerCli.exe / VencordInstallerCli-linux) -- there is no
"VencordInstallerCli-darwin" release asset, only the GUI VencordInstaller.app,
which has no headless/scriptable mode. Everything this script does mirrors
that Go source's behavior exactly so a watcher can drive it without a GUI.

Usage: vencord_patch.py <path to Discord.app/Contents/Resources>
Exit codes: 0 = patched successfully, 1 = failed.
"""
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request

VENCORD_DIST_DIR = os.path.join(
    os.path.expanduser("~"), "Library", "Application Support", "Vencord", "dist"
)
PATCHER_PATH = os.path.join(VENCORD_DIST_DIR, "patcher.js")

VENCORD_RELEASE_URL = "https://api.github.com/repos/Vendicated/Vencord/releases/latest"
VENCORD_RELEASE_FALLBACK_URL = "https://vencord.dev/releases/vencord"
OPENASAR_DOWNLOAD_URL = "https://github.com/GooseMod/OpenAsar/releases/download/nightly/app.asar"
USER_AGENT = "vencord-watchdog-macos (https://github.com/mliem2k/vencord-watchdog)"

# Exact filenames only (not a prefix match): a GitHub release asset name is
# attacker-controlled the moment the release feed is compromised, and
# os.path.join does not strip "../" segments, so a prefix match like
# "patcher.js".startswith() would let a crafted name such as
# "patcher.js/../../../../Library/LaunchAgents/x.plist" write outside
# VENCORD_DIST_DIR entirely.
VENCORD_ASSET_NAMES = ("patcher.js", "preload.js", "renderer.js", "renderer.css")


def log(msg):
    # UTC, matching watch-discord-update.sh's write_log, so the two
    # interleave in watcher.log without a confusing timezone mismatch.
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}", flush=True)


def _request(url):
    return urllib.request.Request(url, headers={"User-Agent": USER_AGENT})


def fetch_json(url, fallback_url=None):
    try:
        with urllib.request.urlopen(_request(url), timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if fallback_url and e.code in (401, 403, 429) and url != fallback_url:
            log(f"{url} returned {e.code}, trying fallback {fallback_url}")
            return fetch_json(fallback_url, None)
        raise


def download(url, dest):
    with urllib.request.urlopen(_request(url), timeout=60) as r:
        data = r.read()
    with open(dest, "wb") as f:
        f.write(data)


# Go's json.Marshal always HTML-escapes these five code points in string
# values (its htmlSafeSet), on top of the standard JSON escapes; Python's
# json.dumps has no equivalent, so this closes the gap for a home-directory
# path that happens to contain one of them.
_GO_JSON_HTML_ESCAPES = {
    "<": "\\u003c",
    ">": "\\u003e",
    "&": "\\u0026",
    " ": "\\u2028",
    " ": "\\u2029",
}


def _go_json_string(s):
    encoded = json.dumps(s, ensure_ascii=False)
    for ch, esc in _GO_JSON_HTML_ESCAPES.items():
        encoded = encoded.replace(ch, esc)
    return encoded


def write_app_asar(out_file, patcher_path):
    """Byte-for-byte port of Vencord Installer's WriteAppAsar (app_asar.go):
    an ASAR archive containing just index.js (require()s the real patcher)
    and a minimal package.json."""
    index_js = "require(" + _go_json_string(patcher_path) + ")"
    package_json = '{\n\t"name": "discord",\n\t"main": "index.js"\n}'
    index_bytes = index_js.encode()
    package_bytes = package_json.encode()

    # Key order matters and is NOT interchangeable with sort_keys=True: Go's
    # encoding/json sorts map keys alphabetically (files: "index.js" before
    # "package.json", matched by this dict's insertion order) but serializes
    # STRUCT fields in declaration order (asarEntry has Size before Offset,
    # so "size" then "offset" per entry, not alphabetical). Reordering either
    # dict literal changes the output.
    files = {
        "index.js": {"size": len(index_bytes), "offset": "0"},
        "package.json": {"size": len(package_bytes), "offset": str(len(index_bytes))},
    }
    # separators=(",", ":") matches Go's encoding/json, which never inserts
    # whitespace; not required for a valid asar (headerStringSize below is
    # derived from whatever we actually produce), but keeps output identical
    # to the upstream installer's rather than merely equivalent.
    header_str = json.dumps({"files": files}, separators=(",", ":"))
    header_bytes = header_str.encode()

    data_size = 4
    aligned_size = (len(header_bytes) + data_size - 1) & ~(data_size - 1)
    header_size = aligned_size + 8
    header_object_size = aligned_size + data_size
    pad = aligned_size - len(header_bytes)
    if pad > 0:
        header_str += "0" * pad

    with open(out_file, "wb") as f:
        for n in (data_size, header_size, header_object_size, len(header_bytes)):
            f.write(struct.pack("<i", n))
        f.write(header_str.encode())
        f.write(index_bytes)
        f.write(package_bytes)


def install_latest_vencord_builds():
    os.makedirs(VENCORD_DIST_DIR, exist_ok=True)
    # Empty package.json so Node doesn't walk up to a parent package.json
    # with "type": "module" in it (mirrors installLatestBuilds in
    # github_downloader.go). Upstream treats a failure here as a warning,
    # not fatal, since it only affects Node's module resolution, not
    # whether the actual Vencord files download.
    try:
        with open(os.path.join(VENCORD_DIST_DIR, "package.json"), "w") as f:
            f.write("{}")
    except OSError as e:
        log(f"WARNING: failed to write dist package.json: {e}")

    log("Fetching latest Vencord release info...")
    release = fetch_json(VENCORD_RELEASE_URL, VENCORD_RELEASE_FALLBACK_URL)
    assets = release.get("assets", [])
    downloaded = 0
    for asset in assets:
        name = asset.get("name", "")
        # Deliberately skips the .map/.LEGAL.txt sidecar files upstream's
        # prefix match also happens to pick up (harmless but unneeded for
        # Vencord to actually load); required to keep the match exact.
        if name in VENCORD_ASSET_NAMES:
            log(f"Downloading {name}...")
            download(asset["browser_download_url"], os.path.join(VENCORD_DIST_DIR, name))
            downloaded += 1
    if downloaded < len(VENCORD_ASSET_NAMES):
        raise RuntimeError(
            f"Couldn't find all required Vencord files (got {downloaded}/{len(VENCORD_ASSET_NAMES)})"
        )


def is_patched(resources_dir):
    return os.path.exists(os.path.join(resources_dir, "_app.asar"))


def unpatch(resources_dir):
    """Mirrors unpatchAppAsar's renamesDone+defer rollback (patcher.go): if
    the second rename fails after the first succeeded, undo the first so
    Discord isn't left with no app.asar at all."""
    app_asar = os.path.join(resources_dir, "app.asar")
    app_asar_tmp = os.path.join(resources_dir, "app.asar.tmp")
    backup_asar = os.path.join(resources_dir, "_app.asar")

    os.rename(app_asar, app_asar_tmp)
    try:
        os.rename(backup_asar, app_asar)
    except OSError:
        os.rename(app_asar_tmp, app_asar)
        raise

    try:
        os.remove(app_asar_tmp)
    except OSError as e:
        # Non-fatal, matching upstream: the meaningful state transition
        # already succeeded. The stale tmp file is harmless and gets
        # overwritten by the next unpatch's first rename anyway.
        log(f"WARNING: failed to remove {app_asar_tmp}: {e}")


def patch(resources_dir):
    """Mirrors patchAppAsar's rollback: if writing the new stub fails after
    the original app.asar was renamed aside, put the original back rather
    than leaving Discord with no app.asar at all."""
    app_asar = os.path.join(resources_dir, "app.asar")
    backup_asar = os.path.join(resources_dir, "_app.asar")

    if is_patched(resources_dir):
        log(f"{resources_dir} is already patched. Unpatching first...")
        unpatch(resources_dir)

    os.rename(app_asar, backup_asar)
    try:
        write_app_asar(app_asar, PATCHER_PATH)
    except Exception:
        os.rename(backup_asar, app_asar)
        raise


def find_asar_file(resources_dir):
    """Mirrors FindAsarFile (openasar.go): prefer _app.asar (the layer
    underneath Vencord's stub) if present, else app.asar itself."""
    for name in ("_app.asar", "app.asar"):
        p = os.path.join(resources_dir, name)
        if os.path.isfile(p):
            return p
    raise RuntimeError(f"No asar file found in {resources_dir}")


def is_openasar(resources_dir):
    with open(find_asar_file(resources_dir), "rb") as f:
        return b"OpenAsar" in f.read()


def install_openasar(resources_dir):
    asar_path = find_asar_file(resources_dir)
    backup_path = os.path.join(resources_dir, "app.asar.backup")
    os.rename(asar_path, backup_path)
    download(OPENASAR_DOWNLOAD_URL, asar_path)


def run(resources_dir):
    install_latest_vencord_builds()
    log("Patching Vencord into " + resources_dir + "...")
    patch(resources_dir)
    log("Vencord patched.")

    if is_openasar(resources_dir):
        # Not an error: this is the expected steady state once OpenAsar is
        # already installed and the watcher re-patches Vencord without an
        # intervening real Discord update wiping it. The upstream CLI's
        # `--install-openasar` treats this as a hard failure for its
        # one-shot interactive use case; a long-lived watcher just leaves
        # it alone since the desired end state already holds.
        log("OpenAsar already installed, leaving as-is.")
    else:
        log("Applying OpenAsar...")
        install_openasar(resources_dir)
        log("OpenAsar applied.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: vencord_patch.py <Discord.app/Contents/Resources>", file=sys.stderr)
        sys.exit(1)
    try:
        run(sys.argv[1])
    except PermissionError as e:
        # macOS's App Management privacy control (Settings > Privacy &
        # Security > App Management) blocks any process without an
        # explicit user-granted exception from renaming/replacing files
        # inside another app's bundle, EPERM with no prompt for a
        # background process (there's no UI to show one to). This is not
        # a bug in this script: even the official VencordInstaller.app
        # hits the identical restriction until granted. See the macOS
        # setup section in the project README.
        log(f"ERROR: {e}")
        log(
            "This looks like macOS's App Management permission blocking "
            "changes to Discord.app. Open System Settings > Privacy & "
            "Security > App Management and enable the entry for Python "
            "(or add it manually if none is listed), then restart the "
            "watcher."
        )
        sys.exit(1)
    except Exception as e:
        log(f"ERROR: {e}")
        sys.exit(1)
