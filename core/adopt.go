package core

import (
	"os"
	"path/filepath"
)

// Iris was called Lite Go until 1.0.19.
const OldName = "Lite Go"

// Adopt moves the folder Lite Go used (old) to Iris's (dir) the first time
// Iris starts; when both exist, Iris's own stays and the old one is left
// alone.
func Adopt(old, dir string) {
	if _, err := os.Stat(dir); err == nil {
		return
	}
	fi, err := os.Lstat(old)
	if err != nil || !fi.IsDir() {
		return
	}
	_ = os.MkdirAll(filepath.Dir(dir), 0o700)
	_ = os.Rename(old, dir)
}
