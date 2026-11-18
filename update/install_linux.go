package update

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

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

// Detect works out how this copy was installed. The .deb, .rpm and AUR
// packages leave a file named install-kind beside the program.
func Detect() Kind {
	if os.Getenv("FLATPAK_ID") != "" || exists("/.flatpak-info") {
		if o := flatpakHost("info", "--show-origin", flatpakID()); o != "" && !strings.HasSuffix(o, "-origin") {
			return KindFlathub // installed from a remote (Flathub or another): it updates it
		}
		return KindFlatpak
	}
	exe := self()
	if strings.HasPrefix(exe, "/nix/store/") {
		return KindNix
	}
	if b, err := os.ReadFile(filepath.Join(filepath.Dir(exe), "install-kind")); err == nil {
		switch strings.TrimSpace(string(b)) {
		case "deb":
			return KindDeb
		case "rpm":
			if exists("/run/ostree-booted") {
				return KindOSTree
			}
			return KindRPM
		case "arch":
			return KindArch
		}
	}
	if !exists(exe + ".sha256") {
		return KindDev // built with go build, not by the build script
	}
	if syscall.Access(filepath.Dir(exe), 2) == nil { // W_OK
		return KindUser
	}
	return KindPortable
}

func flatpakID() string {
	if id := os.Getenv("FLATPAK_ID"); id != "" {
		return id
	}
	return "io.github.tulip_labs.Iris"
}

// flatpakHost runs flatpak outside the sandbox (the app may talk to the
// Flatpak service) and returns its trimmed output.
func flatpakHost(args ...string) string {
	out, err := exec.Command("flatpak-spawn", append([]string{"--host", "flatpak"}, args...)...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func flatpakUser() bool {
	b, _ := os.ReadFile("/.flatpak-info")
	return !strings.Contains(string(b), "app-path=/var/lib/flatpak")
}

// Install installs the downloaded file. Packages ask for the password once
// (pkexec); the home-folder copy replaces itself.
func Install(ctx context.Context, k Kind, path string) (Result, error) {
	switch k {
	case KindUser:
		return Result{Restart: true}, replaceFromTar(path, self())
	case KindDeb:
		if _, err := exec.LookPath("apt-get"); err == nil {
			return Result{Restart: true}, run(ctx, "pkexec", "apt-get", "install", "-y", "--allow-downgrades", path)
		}
		return Result{Restart: true}, run(ctx, "pkexec", "dpkg", "-i", path)
	case KindRPM:
		if _, err := exec.LookPath("dnf"); err == nil {
			return Result{Restart: true}, run(ctx, "pkexec", "dnf", "install", "-y", path)
		}
		if _, err := exec.LookPath("zypper"); err == nil {
			return Result{Restart: true}, run(ctx, "pkexec", "zypper", "--non-interactive", "install", "--allow-unsigned-rpm", path)
		}
		return Result{Restart: true}, run(ctx, "pkexec", "rpm", "-U", "--force", path)
	case KindFlatpak:
		where := "--system"
		if flatpakUser() {
			where = "--user"
		}
		return Result{Restart: true}, run(ctx, "flatpak-spawn", "--host", "flatpak", "install", where, "-y", "--noninteractive", "--reinstall", "--bundle", path)
	}
	return Result{}, fmt.Errorf("updates for this copy come from %s", k.Managed())
}

func run(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if i := strings.LastIndexByte(msg, '\n'); i >= 0 {
			msg = msg[i+1:]
		}
		if ee := (*exec.ExitError)(nil); errors.As(err, &ee) && (ee.ExitCode() == 126 || ee.ExitCode() == 127) && name == "pkexec" {
			return errors.New("the password was not given")
		}
		if msg != "" {
			return fmt.Errorf("%s: %s", filepath.Base(name), msg)
		}
		return err
	}
	return nil
}

// replaceFromTar replaces the folder the program is in (the program,
// Chromium beside it, the checksum record) with the release archive's
// folder: it is unpacked next to it, then put in place with two renames (a
// running copy keeps the files it has open).
func replaceFromTar(archive, exe string) error {
	dir := filepath.Dir(exe)
	if _, err := os.Stat(filepath.Join(dir, "libcef.so")); err != nil {
		return errors.New("this copy is not in its own folder; install the new version with its install.sh")
	}
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tmp, old := dir+".new", dir+".old"
	os.RemoveAll(tmp)
	os.RemoveAll(old)
	if err := os.Mkdir(tmp, 0o755); err != nil {
		return err
	}
	fail := func(err error) error { os.RemoveAll(tmp); return err }
	tr := tar.NewReader(zr)
	seen := map[string]bool{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fail(err)
		}
		// Iris-linux-x86_64/<path>: the first part is the archive's folder
		name := filepath.ToSlash(filepath.Clean(h.Name))
		i := strings.IndexByte(name, '/')
		if i < 0 {
			continue
		}
		rel := name[i+1:]
		if rel == "" || strings.HasPrefix(rel, "../") || rel == ".." || filepath.IsAbs(rel) || rel == "install.sh" {
			continue
		}
		dst := filepath.Join(tmp, filepath.FromSlash(rel))
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(dst, 0o755); err != nil {
				return fail(err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return fail(err)
			}
			mode := os.FileMode(0o644)
			if h.Mode&0o111 != 0 {
				mode = 0o755
			}
			w, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
			if err != nil {
				return fail(err)
			}
			_, err = io.Copy(w, io.LimitReader(tr, 2<<30))
			if cerr := w.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				return fail(err)
			}
			seen[rel] = true
		}
	}
	for _, need := range []string{"iris", "iris.sha256", "libcef.so", "iris-helper"} {
		if !seen[need] {
			return fail(errors.New("the release archive is missing " + need))
		}
	}
	if err := os.Rename(dir, old); err != nil {
		return fail(err)
	}
	if err := os.Rename(tmp, dir); err != nil {
		os.Rename(old, dir)
		return fail(err)
	}
	os.RemoveAll(old)
	if home, err := os.UserHomeDir(); err == nil {
		refreshUserEntry(dir, home)
	}
	return nil
}

// MigrateUserInstall brings a copy in the home folder to Iris's names: the
// folder installed as Lite Go (~/.local/lib/lite-go-browser) becomes
// ~/.local/lib/iris-browser, the command iris and the menu entry point at it,
// and the old command, entry, icon and compatibility files go. It is cheap
// when there is nothing to do, and safe to run at every start.
func MigrateUserInstall() { migrateUserInstall(self()) }

func migrateUserInstall(exe string) {
	dir := filepath.Dir(exe)
	home, err := os.UserHomeDir()
	if err != nil || !strings.HasPrefix(dir, home+string(os.PathSeparator)) {
		return
	}
	if filepath.Base(dir) == "lite-go-browser" {
		to := filepath.Join(filepath.Dir(dir), "iris-browser")
		if _, err := os.Stat(to); os.IsNotExist(err) && os.Rename(dir, to) == nil {
			dir = to // this running copy keeps going from the new place
		}
	}
	for _, f := range []string{"lite-go-browser", "lite-go-browser.sha256", "lite-go-helper", "lite-go", "lite-go.desktop", "lite-go.png"} {
		os.Remove(filepath.Join(dir, f))
	}
	refreshUserEntry(dir, home)
}

// refreshUserEntry puts the command, the menu entry and the icon in place for
// a copy in the home folder (the name and icon change between versions).
func refreshUserEntry(dir, home string) {
	const id = "io.github.tulip_labs.Iris"
	share := os.Getenv("XDG_DATA_HOME")
	if share == "" {
		share = filepath.Join(home, ".local", "share")
	}
	bin := os.Getenv("XDG_BIN_HOME")
	if bin == "" {
		bin = filepath.Join(home, ".local", "bin")
	}
	if _, err := os.Stat(filepath.Join(dir, "iris")); err != nil {
		return
	}
	cmd := filepath.Join(bin, "iris")
	if t, err := os.Readlink(cmd); err != nil || t != filepath.Join(dir, "iris") {
		os.MkdirAll(bin, 0o755)
		os.Remove(cmd)
		os.Symlink(filepath.Join(dir, "iris"), cmd)
	}
	if d, err := os.ReadFile(filepath.Join(dir, id+".desktop")); err == nil {
		d = []byte(strings.ReplaceAll(string(d), "\nExec=iris", "\nExec="+cmd))
		entry := filepath.Join(share, "applications", id+".desktop")
		if old, err := os.ReadFile(entry); err != nil || string(old) != string(d) {
			os.MkdirAll(filepath.Dir(entry), 0o755)
			os.WriteFile(entry, d, 0o644)
		}
	}
	if ic, err := os.ReadFile(filepath.Join(dir, id+".png")); err == nil {
		icon := filepath.Join(share, "icons", "hicolor", "256x256", "apps", id+".png")
		if old, err := os.ReadFile(icon); err != nil || len(old) != len(ic) {
			os.MkdirAll(filepath.Dir(icon), 0o755)
			os.WriteFile(icon, ic, 0o644)
		}
	}
	// what Lite Go put there
	if t, err := os.Readlink(filepath.Join(bin, "lite-go")); err == nil && strings.Contains(t, "lite-go") {
		os.Remove(filepath.Join(bin, "lite-go"))
	}
	os.Remove(filepath.Join(share, "applications", "lite-go.desktop"))
	os.Remove(filepath.Join(share, "icons", "hicolor", "256x256", "apps", "lite-go.png"))
}

// Restart starts Iris again in a moment, once this copy has quit.
func Restart() error {
	var argv []string
	if os.Getenv("FLATPAK_ID") != "" {
		argv = []string{"flatpak-spawn", "--host", "flatpak", "run", flatpakID()}
	} else {
		argv = []string{self()}
	}
	cmd := exec.Command("sh", append([]string{"-c", `sleep 2; exec "$@"`, "sh"}, argv...)...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd.Start()
}
