// Package safefile writes small files so that a crash, a full disk or a
// power cut never leaves them half written: the new content goes to a fresh
// temporary file next to the old one, is flushed to the disk, and only then
// takes the old file's place.
package safefile

import (
	"os"
	"path/filepath"
)

// WriteFile replaces path with data. Concurrent writers never share a
// temporary file, so the result is always one writer's whole content.
func WriteFile(path string, data []byte, perm os.FileMode) error {
	dir, base := filepath.Split(path)
	if dir == "" {
		dir = "."
	}
	f, err := os.CreateTemp(dir, "."+base+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	ok := false
	defer func() {
		if !ok {
			f.Close()
			os.Remove(tmp)
		}
	}()
	if err := f.Chmod(perm); err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	ok = true
	// the rename itself reaches the disk with the folder (best effort: not
	// every system can sync a folder)
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}
