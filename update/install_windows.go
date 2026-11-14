package update

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Detect works out how this copy was installed.
func Detect() Kind {
	exe, err := os.Executable()
	if err != nil {
		return KindPortable
	}
	low := strings.ToLower(exe)
	if strings.Contains(low, `\windowsapps\`) {
		return KindStore
	}
	if _, err := os.Stat(exe + ".sha256"); err != nil {
		return KindDev
	}
	if lad := os.Getenv("LOCALAPPDATA"); lad != "" && strings.HasPrefix(low, strings.ToLower(filepath.Join(lad, "Programs"))) {
		return KindSetup
	}
	return KindPortable
}

// Install starts Lite Go Setup, which closes Lite Go, puts the new version
// in place and opens it again.
func Install(ctx context.Context, k Kind, path string) (Result, error) {
	if k != KindSetup {
		return Result{}, &managedErr{k}
	}
	return Result{}, exec.Command(path).Start()
}

type managedErr struct{ k Kind }

func (e *managedErr) Error() string { return "updates for this copy come from " + e.k.Managed() }

// Restart is done by Lite Go Setup on Windows.
func Restart() error { return nil }
