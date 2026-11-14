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
	return "io.github.tulip_labs.LiteGo"
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

// replaceFromTar puts the program and its checksum record from the release
// archive in place of exe, each with one rename (a running copy keeps going).
func replaceFromTar(archive, exe string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(zr)
	want := map[string]string{"lite-go": exe, "lite-go.sha256": exe + ".sha256"}
	done := map[string]string{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		dst, ok := want[filepath.Base(h.Name)]
		if !ok || h.Typeflag != tar.TypeReg {
			continue
		}
		tmp := dst + ".new"
		w, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
		if err != nil {
			return err
		}
		if _, err := io.Copy(w, io.LimitReader(tr, 512<<20)); err != nil {
			w.Close()
			os.Remove(tmp)
			return err
		}
		if err := w.Close(); err != nil {
			return err
		}
		done[dst] = tmp
	}
	if len(done) != 2 {
		for _, tmp := range done {
			os.Remove(tmp)
		}
		return errors.New("the release archive is missing lite-go or its record")
	}
	// the record first: if the program rename failed, the old program would
	// be flagged as changed, which is the safe way round
	for _, dst := range []string{exe + ".sha256", exe} {
		if err := os.Rename(done[dst], dst); err != nil {
			return err
		}
	}
	return nil
}

// Restart starts Lite Go again in a moment, once this copy has quit.
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
