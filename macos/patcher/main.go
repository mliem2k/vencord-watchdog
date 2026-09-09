// Re-patches Vencord + OpenAsar into a Discord.app Resources dir.
//
// Ports the relevant parts of https://github.com/Vencord/Installer
// (patcher.go, app_asar.go, openasar.go, github_downloader.go) directly,
// because Vencord Installer only publishes a headless CLI build for
// Windows and Linux, not macOS: only a GUI app with no scriptable mode.
//
// Compiled to a standalone binary (rather than shipped as a Python
// script) so macOS's App Management privacy grant is easier to set up:
// TCC attributes that permission to whichever binary actually performs
// the file operations, and a plain executable living right in this repo
// is far easier to point System Settings' picker at than a python3
// interpreter buried inside an Xcode Command Line Tools install.
//
// Usage: patcher <path to Discord.app/Contents/Resources>
// Exit codes: 0 = patched successfully, 1 = failed.
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var (
	vencordDistDir string
	patcherPath    string
)

const (
	vencordReleaseURL         = "https://api.github.com/repos/Vendicated/Vencord/releases/latest"
	vencordReleaseFallbackURL = "https://vencord.dev/releases/vencord"
	openAsarDownloadURL       = "https://github.com/GooseMod/OpenAsar/releases/download/nightly/app.asar"
	userAgent                 = "vencord-watchdog-macos (https://github.com/mliem2k/vencord-watchdog)"
)

// Exact filenames only (not a prefix match): a GitHub release asset name
// is attacker-controlled the moment the release feed is compromised, and
// filepath.Join does not strip ".." segments, so a prefix match would let
// a crafted asset name write outside vencordDistDir entirely.
var vencordAssetNames = map[string]bool{
	"patcher.js":   true,
	"preload.js":   true,
	"renderer.js":  true,
	"renderer.css": true,
}

func init() {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		panic("cannot determine home directory: " + err.Error())
	}
	vencordDistDir = filepath.Join(homeDir, "Library", "Application Support", "Vencord", "dist")
	patcherPath = filepath.Join(vencordDistDir, "patcher.js")
}

func logMsg(msg string) {
	fmt.Printf("%s %s\n", time.Now().UTC().Format("2006-01-02T15:04:05Z"), msg)
}

type githubAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

type githubRelease struct {
	Assets []githubAsset `json:"assets"`
}

func httpGet(url string) (*http.Response, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	client := &http.Client{Timeout: 60 * time.Second}
	return client.Do(req)
}

func fetchRelease(url, fallbackURL string) (*githubRelease, error) {
	res, err := httpGet(url)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()

	if res.StatusCode >= 300 {
		if (res.StatusCode == 401 || res.StatusCode == 403 || res.StatusCode == 429) && fallbackURL != "" && url != fallbackURL {
			logMsg(fmt.Sprintf("%s returned %d, trying fallback %s", url, res.StatusCode, fallbackURL))
			return fetchRelease(fallbackURL, "")
		}
		return nil, fmt.Errorf("%s: %s", url, res.Status)
	}

	var release githubRelease
	if err := json.NewDecoder(res.Body).Decode(&release); err != nil {
		return nil, err
	}
	return &release, nil
}

func downloadFile(url, dest string) error {
	res, err := httpGet(url)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		return fmt.Errorf("%s: %s", url, res.Status)
	}
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, res.Body)
	return err
}

type asarEntry struct {
	Size   int32  `json:"size"`
	Offset string `json:"offset"`
}

// writeAppAsar is Vencord Installer's own WriteAppAsar (app_asar.go),
// copied directly rather than reimplemented, so it stays byte-for-byte
// identical to upstream's output by construction (same json.Marshal on
// the same map/struct shapes, not a reimplementation that could drift).
func writeAppAsar(outFile string, patcherPath string) error {
	header := make(map[string]map[string]asarEntry)
	files := make(map[string]asarEntry)
	header["files"] = files

	fileContents := ""

	patcherPathB, _ := json.Marshal(patcherPath)
	indexJsContents := "require(" + string(patcherPathB) + ")"
	indexJsBytes := len([]byte(indexJsContents))
	fileContents += indexJsContents
	files["index.js"] = asarEntry{
		Size:   int32(indexJsBytes),
		Offset: "0",
	}

	packageJson := "{\n\t\"name\": \"discord\",\n\t\"main\": \"index.js\"\n}"
	fileContents += packageJson
	files["package.json"] = asarEntry{
		Size:   int32(len([]byte(packageJson))),
		Offset: strconv.Itoa(indexJsBytes),
	}

	headerBytes, _ := json.Marshal(header)
	headerString := string(headerBytes)
	headerStringSize := uint32(len(headerString))
	dataSize := uint32(4)
	alignedSize := (headerStringSize + dataSize - 1) & ^(dataSize - 1)
	headerSize := alignedSize + 8
	headerObjectSize := alignedSize + dataSize
	diff := alignedSize - headerStringSize
	if diff > 0 {
		headerString += strings.Repeat("0", int(diff))
	}

	f, err := os.Create(outFile)
	if err != nil {
		return fmt.Errorf("failed to create %s: %w", outFile, err)
	}
	defer f.Close()

	for _, n := range []uint32{dataSize, headerSize, headerObjectSize, headerStringSize} {
		if err := binary.Write(f, binary.LittleEndian, int32(n)); err != nil {
			return fmt.Errorf("failed to write asar bytes: %w", err)
		}
	}

	for _, s := range []string{headerString, fileContents} {
		if _, err := f.WriteString(s); err != nil {
			return fmt.Errorf("failed to write asar data: %w", err)
		}
	}

	return nil
}

func installLatestVencordBuilds() error {
	if err := os.MkdirAll(vencordDistDir, 0755); err != nil {
		return err
	}

	// Empty package.json so Node doesn't walk up to a parent package.json
	// with "type": "module" in it (mirrors installLatestBuilds in
	// github_downloader.go). Non-fatal, matching upstream: it only
	// affects Node's module resolution, not whether Vencord's own files
	// download successfully.
	pkgPath := filepath.Join(vencordDistDir, "package.json")
	if err := os.WriteFile(pkgPath, []byte("{}"), 0644); err != nil {
		logMsg(fmt.Sprintf("WARNING: failed to write dist package.json: %v", err))
	}

	logMsg("Fetching latest Vencord release info...")
	release, err := fetchRelease(vencordReleaseURL, vencordReleaseFallbackURL)
	if err != nil {
		return err
	}

	downloaded := 0
	for _, asset := range release.Assets {
		if vencordAssetNames[asset.Name] {
			logMsg(fmt.Sprintf("Downloading %s...", asset.Name))
			if err := downloadFile(asset.BrowserDownloadURL, filepath.Join(vencordDistDir, asset.Name)); err != nil {
				return err
			}
			downloaded++
		}
	}
	if downloaded < len(vencordAssetNames) {
		return fmt.Errorf("couldn't find all required Vencord files (got %d/%d)", downloaded, len(vencordAssetNames))
	}
	return nil
}

func isPatched(resourcesDir string) bool {
	_, err := os.Stat(filepath.Join(resourcesDir, "_app.asar"))
	return err == nil
}

// unpatch mirrors unpatchAppAsar's renamesDone+defer rollback
// (patcher.go): if the second rename fails after the first succeeded,
// undo the first so Discord isn't left with no app.asar at all.
func unpatch(resourcesDir string) error {
	appAsar := filepath.Join(resourcesDir, "app.asar")
	appAsarTmp := filepath.Join(resourcesDir, "app.asar.tmp")
	backupAsar := filepath.Join(resourcesDir, "_app.asar")

	if err := os.Rename(appAsar, appAsarTmp); err != nil {
		return err
	}
	if err := os.Rename(backupAsar, appAsar); err != nil {
		_ = os.Rename(appAsarTmp, appAsar)
		return err
	}
	if err := os.Remove(appAsarTmp); err != nil {
		// Non-fatal, matching upstream: the meaningful state transition
		// already succeeded. The stale tmp file is harmless and gets
		// overwritten by the next unpatch's first rename anyway.
		logMsg(fmt.Sprintf("WARNING: failed to remove %s: %v", appAsarTmp, err))
	}
	return nil
}

// patch mirrors patchAppAsar's rollback: if writing the new stub fails
// after the original app.asar was renamed aside, put the original back
// rather than leaving Discord with no app.asar at all.
func patch(resourcesDir string) error {
	appAsar := filepath.Join(resourcesDir, "app.asar")
	backupAsar := filepath.Join(resourcesDir, "_app.asar")

	if isPatched(resourcesDir) {
		logMsg(fmt.Sprintf("%s is already patched. Unpatching first...", resourcesDir))
		if err := unpatch(resourcesDir); err != nil {
			return err
		}
	}

	if err := os.Rename(appAsar, backupAsar); err != nil {
		return err
	}
	if err := writeAppAsar(appAsar, patcherPath); err != nil {
		_ = os.Rename(backupAsar, appAsar)
		return err
	}
	return nil
}

// findAsarFile mirrors FindAsarFile (openasar.go): prefer _app.asar (the
// layer underneath Vencord's stub) if present, else app.asar itself.
func findAsarFile(resourcesDir string) (string, error) {
	for _, name := range []string{"_app.asar", "app.asar"} {
		p := filepath.Join(resourcesDir, name)
		if info, err := os.Stat(p); err == nil && !info.IsDir() {
			return p, nil
		}
	}
	return "", fmt.Errorf("no asar file found in %s", resourcesDir)
}

func isOpenAsar(resourcesDir string) (bool, error) {
	p, err := findAsarFile(resourcesDir)
	if err != nil {
		return false, err
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return false, err
	}
	return strings.Contains(string(data), "OpenAsar"), nil
}

func installOpenAsar(resourcesDir string) error {
	asarPath, err := findAsarFile(resourcesDir)
	if err != nil {
		return err
	}
	backupPath := filepath.Join(resourcesDir, "app.asar.backup")
	if err := os.Rename(asarPath, backupPath); err != nil {
		return err
	}
	return downloadFile(openAsarDownloadURL, asarPath)
}

// resignApp replaces Discord's now-broken code signature with an ad-hoc
// one. Renaming/rewriting app.asar (and OpenAsar's asar) invalidates
// whatever the app was previously signed with: its CodeResources
// manifest hashes the original file contents, so codesign/Gatekeeper
// afterward reports "a sealed resource is missing or invalid" and macOS
// refuses to launch the app at all ("... is damaged and can't be
// opened"), not merely a bypassable warning. Re-signing ad-hoc (no real
// identity, --sign -) is self-consistent with the new contents, which is
// enough for macOS to launch it normally as long as it isn't
// quarantine-flagged (a locally modified, already-installed app normally
// isn't). This has no upstream Go source to mirror: the reference
// installer has no codesign handling at all, macOS is the one platform
// where modifying the bundle needs it.
func resignApp(resourcesDir string) error {
	appBundle := filepath.Dir(filepath.Dir(resourcesDir))
	cmd := exec.Command("codesign", "--force", "--deep", "--sign", "-", appBundle)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("codesign failed: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// disableKrisp renames aside Discord's Krisp (AI noise suppression)
// native module, discord_krisp.node. Krisp's own native code calls a
// signature check (discord::util::IsSignedBy) during voice engine init
// that expects Discord's real Apple-issued certificate; once the app is
// re-signed ad-hoc (resignApp above), that check finds no matching
// certificate and segfaults instead of failing gracefully, and Electron
// respawns a fresh renderer that hits the identical crash immediately,
// an infinite crash loop that presents as a black, unresponsive window,
// never a visible error. Verified directly: with Krisp's .node file
// moved aside, an otherwise-identically-patched, ad-hoc-signed Discord
// reaches full interactivity normally; with it present, it crash-loops
// every time. This costs Krisp's noise suppression specifically, not
// voice chat itself (a separate module, discord_voice, untouched).
//
// The module lives outside Discord.app entirely, in a version-numbered
// directory under ~/Library/Application Support/discord that Discord's
// own module updater can re-populate independently of any repatch, so
// this has to run every cycle, not just once.
func disableKrisp() error {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	base := filepath.Join(homeDir, "Library", "Application Support", "discord")
	patterns := []string{
		filepath.Join(base, "*", "modules", "discord_krisp", "discord_krisp.node"),
		filepath.Join(base, "app-*", "modules", "discord_krisp-*", "discord_krisp", "discord_krisp.node"),
	}
	disabled := 0
	for _, pattern := range patterns {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			return err
		}
		for _, m := range matches {
			if err := os.Rename(m, m+".disabled"); err != nil {
				return err
			}
			disabled++
		}
	}
	if disabled > 0 {
		logMsg(fmt.Sprintf("Disabled %d Krisp module file(s) to prevent its signature-check crash.", disabled))
	}
	return nil
}

func run(resourcesDir string) error {
	if err := installLatestVencordBuilds(); err != nil {
		return err
	}
	logMsg("Patching Vencord into " + resourcesDir + "...")
	if err := patch(resourcesDir); err != nil {
		return err
	}
	logMsg("Vencord patched.")

	// OpenAsar is skipped by default on macOS: live testing found its own
	// module update check (separate from Discord's or Vencord's) can hit
	// "Host error" against a real pending Discord update and then hang
	// indefinitely retrying, an unresolved bug in OpenAsar itself, not in
	// anything this program does. Vencord alone, patched and re-signed
	// with Krisp disabled, was verified to launch reliably across
	// repeated cycles with no such issue. Opt in with
	// VENCORD_WATCHDOG_ENABLE_OPENASAR=1 once that's fixed or you want to
	// try it anyway.
	if os.Getenv("VENCORD_WATCHDOG_ENABLE_OPENASAR") == "1" {
		openAsarActive, err := isOpenAsar(resourcesDir)
		if err != nil {
			return err
		}
		if openAsarActive {
			// Not an error: this is the expected steady state once
			// OpenAsar is already installed and the watcher re-patches
			// Vencord without an intervening real Discord update wiping
			// it. The upstream CLI's --install-openasar treats this as a
			// hard failure for its one-shot interactive use case; a
			// long-lived watcher just leaves it alone since the desired
			// end state already holds.
			logMsg("OpenAsar already installed, leaving as-is.")
		} else {
			logMsg("Applying OpenAsar...")
			if err := installOpenAsar(resourcesDir); err != nil {
				return err
			}
			logMsg("OpenAsar applied.")
		}
	} else {
		logMsg("Skipping OpenAsar (unresolved hang bug on macOS, see README). Set VENCORD_WATCHDOG_ENABLE_OPENASAR=1 to opt in.")
	}

	logMsg("Re-signing app bundle (ad-hoc) to repair the broken code signature...")
	if err := resignApp(resourcesDir); err != nil {
		return err
	}
	logMsg("Re-signed.")

	if err := disableKrisp(); err != nil {
		return err
	}
	return nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: patcher <Discord.app/Contents/Resources>")
		os.Exit(1)
	}
	if err := run(os.Args[1]); err != nil {
		logMsg(fmt.Sprintf("ERROR: %v", err))
		if errors.Is(err, os.ErrPermission) {
			// macOS's App Management privacy control (Settings > Privacy
			// & Security > App Management) blocks any process without
			// an explicit user-granted exception from renaming or
			// replacing files inside another app's bundle, with no
			// prompt for a background process (there's no UI to show
			// one to). This is not a bug in this program: even the
			// official VencordInstaller.app hits the identical
			// restriction until granted. See the macOS setup section in
			// the project README.
			logMsg("This looks like macOS's App Management permission blocking changes to Discord.app. Open System Settings > Privacy & Security > App Management and enable this program, then restart the watcher.")
		}
		os.Exit(1)
	}
}
