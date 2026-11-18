package update

import (
	"os"
	"path/filepath"
	"testing"
)

// A copy installed in the home folder as Lite Go moves to Iris's names.
func TestMigrateUserInstall(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_DATA_HOME", "")
	t.Setenv("XDG_BIN_HOME", "")
	old := filepath.Join(home, ".local", "lib", "lite-go-browser")
	bin := filepath.Join(home, ".local", "bin")
	apps := filepath.Join(home, ".local", "share", "applications")
	os.MkdirAll(old, 0o755)
	os.MkdirAll(bin, 0o755)
	os.MkdirAll(apps, 0o755)
	const id = "io.github.tulip_labs.Iris"
	files := map[string]string{
		"iris": "program", "iris.sha256": "record", "lite-go-browser": "#!/bin/sh", "lite-go-helper": "#!/bin/sh",
		id + ".desktop": "[Desktop Entry]\nName=Iris\nExec=iris %U\n", id + ".png": "icon",
	}
	for n, c := range files {
		os.WriteFile(filepath.Join(old, n), []byte(c), 0o755)
	}
	os.Symlink(filepath.Join(old, "lite-go-browser"), filepath.Join(bin, "lite-go"))
	os.WriteFile(filepath.Join(apps, "lite-go.desktop"), []byte("old"), 0o644)

	migrateUserInstall(filepath.Join(old, "iris"))

	dir := filepath.Join(home, ".local", "lib", "iris-browser")
	if _, err := os.Stat(filepath.Join(dir, "iris")); err != nil {
		t.Fatal("the folder did not move:", err)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("the old folder is still there")
	}
	for _, f := range []string{"lite-go-browser", "lite-go-helper"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
			t.Errorf("%s was kept", f)
		}
	}
	if l, err := os.Readlink(filepath.Join(bin, "iris")); err != nil || l != filepath.Join(dir, "iris") {
		t.Fatalf("iris command: %q %v", l, err)
	}
	if _, err := os.Lstat(filepath.Join(bin, "lite-go")); err == nil {
		t.Error("the lite-go command is still there")
	}
	if _, err := os.Stat(filepath.Join(apps, "lite-go.desktop")); err == nil {
		t.Error("the old menu entry is still there")
	}
	d, err := os.ReadFile(filepath.Join(apps, id+".desktop"))
	if err != nil || string(d) != "[Desktop Entry]\nName=Iris\nExec="+filepath.Join(bin, "iris")+" %U\n" {
		t.Fatalf("menu entry: %q %v", d, err)
	}
	// a second start finds nothing to do
	migrateUserInstall(filepath.Join(dir, "iris"))
	if _, err := os.Stat(filepath.Join(dir, "iris")); err != nil {
		t.Fatal(err)
	}
}
