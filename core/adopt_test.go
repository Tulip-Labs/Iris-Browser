package core

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAdopt(t *testing.T) {
	base := t.TempDir()
	old, dir := filepath.Join(base, OldName), filepath.Join(base, "Iris")
	os.MkdirAll(old, 0o700)
	os.WriteFile(filepath.Join(old, "settings.json"), []byte("{}"), 0o600)
	Adopt(old, dir)
	if _, err := os.Stat(filepath.Join(dir, "settings.json")); err != nil {
		t.Fatal("settings did not move:", err)
	}
	// Iris's own folder wins once it exists
	os.MkdirAll(old, 0o700)
	os.WriteFile(filepath.Join(old, "settings.json"), []byte("old"), 0o600)
	Adopt(old, dir)
	if b, _ := os.ReadFile(filepath.Join(dir, "settings.json")); string(b) != "{}" {
		t.Fatalf("Iris's settings were replaced: %q", b)
	}
}
