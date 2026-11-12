//go:build !windows

package setup

import (
	"errors"
	"os"
	"path/filepath"
)

var errWindowsOnly = errors.New("this setup installs the Windows app; macOS and Linux come next")

func installDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".local", "share", "Lite Go")
}
func installedVersion() string          { return "" }
func engineInstalled() bool             { return true }
func installEngine(func(float32)) error { return errWindowsOnly }
func copyApp(string, []byte) error      { return errWindowsOnly }
func makeShortcuts(string, bool) error  { return errWindowsOnly }
func register(string, int) error        { return errWindowsOnly }
func uninstall(bool) error              { return errWindowsOnly }
func launch(string)                     {}
func isWindows() bool                   { return false }
