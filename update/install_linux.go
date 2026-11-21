package update

import (
	"os"
	"path/filepath"
	"strings"
)

// On Linux Iris comes as a Flatpak, a Snap or through Nix, and each of them
// updates it: Iris never replaces itself.

// Detect works out how this copy was installed.
func Detect() Kind {
	if os.Getenv("FLATPAK_ID") != "" || exists("/.flatpak-info") {
		return KindFlatpak
	}
	if os.Getenv("SNAP") != "" && os.Getenv("SNAP_NAME") != "" {
		return KindSnap
	}
	if strings.HasPrefix(self(), "/nix/store/") {
		return KindNix
	}
	return KindDev
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func self() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return exe
}
