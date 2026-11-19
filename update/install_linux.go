package update

import (
	"context"
	"fmt"
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

// Install is not done by Iris on Linux.
func Install(_ context.Context, k Kind, _ string) (Result, error) {
	return Result{}, fmt.Errorf("updates for this copy come from %s", k.Managed())
}

// Restart is not needed on Linux (Iris never installs an update itself).
func Restart() error { return nil }
