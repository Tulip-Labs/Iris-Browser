//go:build windows

package setup

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"iris/webview"
)

const (
	uninstallKey = `Software\Microsoft\Windows\CurrentVersion\Uninstall\LiteGo`
	clientKey    = `Software\Clients\StartMenuInternet\LiteGo`
	progID       = "LiteGoHTML"
	exeName      = "Iris.exe"
	uninstName   = "Uninstall Iris.exe"
)

// installDir is the per-user install folder (no administrator rights needed).
func installDir() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base, _ = os.UserCacheDir()
	}
	return filepath.Join(base, "Programs", "Iris")
}

func installedVersion() string {
	k, err := registry.OpenKey(registry.CURRENT_USER, uninstallKey, registry.QUERY_VALUE)
	if err != nil {
		return ""
	}
	defer k.Close()
	v, _, _ := k.GetStringValue("DisplayVersion")
	return v
}

func engineInstalled() bool { return webview.Installed() }

// installEngine downloads Microsoft's WebView2 bootstrapper and runs it silently.
func installEngine(progress func(float32)) error {
	resp, err := http.Get("https://go.microsoft.com/fwlink/p/?LinkId=2124703")
	if err != nil {
		return fmt.Errorf("could not download the web engine: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("could not download the web engine (HTTP %d)", resp.StatusCode)
	}
	tmp := filepath.Join(os.TempDir(), "MicrosoftEdgeWebview2Setup.exe")
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, resp.Body)
	f.Close()
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	progress(0.5)
	cmd := exec.Command(tmp, "/silent", "/install")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("the web engine installer failed: %w", err)
	}
	if !webview.Installed() {
		return errors.New("the web engine is still missing after its installer ran")
	}
	return nil
}

// quitRunning asks a running Iris (also one waiting in the background) to
// exit, and a running Lite Go (Iris's name until 1.0.19).
func quitRunning() {
	quitIn("Iris")
	quitIn("Lite Go")
}

func quitIn(name string) {
	conf, err := os.UserConfigDir()
	if err != nil {
		return
	}
	b, err := os.ReadFile(filepath.Join(conf, name, "instance.json"))
	if err != nil {
		return
	}
	var f struct {
		Port  int    `json:"port"`
		Token string `json:"token"`
	}
	if json.Unmarshal(b, &f) != nil || f.Port == 0 {
		return
	}
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", f.Port), 300*time.Millisecond)
	if err != nil {
		return
	}
	_ = c.SetDeadline(time.Now().Add(time.Second))
	c.Write([]byte(f.Token + "\n[\"--quit\"]\n"))
	c.Close()
	time.Sleep(600 * time.Millisecond)
}

// copyApp writes the app; a running copy is renamed out of the way first.
func copyApp(dir string, app []byte) error {
	quitRunning()
	removeLiteGo()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	exe := filepath.Join(dir, exeName)
	old := exe + ".old"
	os.Remove(old)
	if _, err := os.Stat(exe); err == nil {
		if err := os.Rename(exe, old); err != nil {
			return fmt.Errorf("close Iris and try again (%v)", err)
		}
	}
	if err := os.WriteFile(exe, app, 0o755); err != nil {
		return err
	}
	// the record Iris checks itself against at every start, and both files
	// read-only so nothing changes them by accident
	sum := sha256.Sum256(app)
	rec := exe + ".sha256"
	_ = os.Chmod(rec, 0o644)
	if os.WriteFile(rec, []byte(hex.EncodeToString(sum[:])+"\n"), 0o644) == nil {
		_ = os.Chmod(rec, 0o444)
	}
	_ = os.Chmod(exe, 0o555)
	os.Remove(old) // fails while the old copy runs; removed next time
	// the setup itself stays as the uninstaller
	self, err := os.Executable()
	if err == nil {
		if b, err := os.ReadFile(self); err == nil && !strings.EqualFold(self, filepath.Join(dir, uninstName)) {
			_ = os.WriteFile(filepath.Join(dir, uninstName), b, 0o755)
		}
	}
	for _, n := range []string{"LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"} {
		if b, err := payload.ReadFile("payload/" + n); err == nil {
			_ = os.WriteFile(filepath.Join(dir, n), b, 0o644)
		}
	}
	return nil
}

func shortcutPaths(desktop bool) []string {
	var out []string
	if p, err := windows.KnownFolderPath(windows.FOLDERID_Programs, 0); err == nil {
		out = append(out, filepath.Join(p, "Iris.lnk"))
	}
	if desktop {
		if p, err := windows.KnownFolderPath(windows.FOLDERID_Desktop, 0); err == nil {
			out = append(out, filepath.Join(p, "Iris.lnk"))
		}
	}
	return out
}

var (
	ole32            = windows.NewLazySystemDLL("ole32.dll")
	procCoCreate     = ole32.NewProc("CoCreateInstance")
	clsidShellLink   = windows.GUID{Data1: 0x00021401, Data4: [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	iidShellLinkW    = windows.GUID{Data1: 0x000214F9, Data4: [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	iidPersistFile   = windows.GUID{Data1: 0x0000010b, Data4: [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	shell32          = windows.NewLazySystemDLL("shell32.dll")
	procNotifyAssocs = shell32.NewProc("SHChangeNotify")
)

func vcall(obj uintptr, slot int, args ...uintptr) uintptr {
	vt := *(*uintptr)(unsafe.Pointer(obj))
	fn := *(*uintptr)(unsafe.Pointer(vt + uintptr(slot)*unsafe.Sizeof(uintptr(0))))
	r, _, _ := syscall.SyscallN(fn, append([]uintptr{obj}, args...)...)
	return r
}

func wstr(s string) uintptr {
	p, _ := windows.UTF16PtrFromString(s)
	return uintptr(unsafe.Pointer(p))
}

// shortcut writes a .lnk with IShellLinkW (COM must be initialized on this thread).
func shortcut(lnk, target, desc string) error {
	var sl uintptr
	if hr, _, _ := procCoCreate.Call(uintptr(unsafe.Pointer(&clsidShellLink)), 0, 1 /*CLSCTX_INPROC_SERVER*/, uintptr(unsafe.Pointer(&iidShellLinkW)), uintptr(unsafe.Pointer(&sl))); hr != 0 || sl == 0 {
		return fmt.Errorf("shortcut: 0x%08x", uint32(hr))
	}
	defer vcall(sl, 2)
	vcall(sl, 20, wstr(target))              // SetPath
	vcall(sl, 7, wstr(desc))                 // SetDescription
	vcall(sl, 9, wstr(filepath.Dir(target))) // SetWorkingDirectory
	vcall(sl, 17, wstr(target), 0)           // SetIconLocation
	var pf uintptr
	if hr := vcall(sl, 0, uintptr(unsafe.Pointer(&iidPersistFile)), uintptr(unsafe.Pointer(&pf))); hr != 0 || pf == 0 {
		return fmt.Errorf("shortcut: 0x%08x", uint32(hr))
	}
	defer vcall(pf, 2)
	_ = os.MkdirAll(filepath.Dir(lnk), 0o755)
	if hr := vcall(pf, 6, wstr(lnk), 1); hr != 0 { // Save
		return fmt.Errorf("shortcut: 0x%08x", uint32(hr))
	}
	return nil
}

func makeShortcuts(dir string, desktop bool) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED)
	defer windows.CoUninitialize()
	exe := filepath.Join(dir, exeName)
	for _, p := range shortcutPaths(desktop) {
		if err := shortcut(p, exe, "Iris, a light and fast browser"); err != nil {
			return err
		}
	}
	return nil
}

// removeLiteGo takes away what Iris left installed under its old name, Lite
// Go (until 1.0.19): its program folder, shortcuts and start-up entry. The
// settings and history move over when Iris first starts; the uninstall
// entry and the browser registration keep their keys and are rewritten.
func removeLiteGo() {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base, _ = os.UserCacheDir()
	}
	if base != "" {
		os.RemoveAll(filepath.Join(base, "Programs", "Lite Go"))
	}
	for _, id := range []*windows.KNOWNFOLDERID{windows.FOLDERID_Programs, windows.FOLDERID_Desktop} {
		if p, err := windows.KnownFolderPath(id, 0); err == nil {
			os.Remove(filepath.Join(p, "Lite Go.lnk"))
		}
	}
	hk := registry.CURRENT_USER
	if rk, err := registry.OpenKey(hk, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE); err == nil {
		rk.DeleteValue("Lite Go")
		rk.Close()
	}
	if rk, err := registry.OpenKey(hk, `Software\RegisteredApplications`, registry.SET_VALUE); err == nil {
		rk.DeleteValue("Lite Go")
		rk.Close()
	}
}

func setString(root registry.Key, path, name, value string) error {
	k, _, err := registry.CreateKey(root, path, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	return k.SetStringValue(name, value)
}

// register adds the uninstall entry and offers Iris as a browser in Windows' default apps.
func register(dir string, size int) error {
	exe := filepath.Join(dir, exeName)
	hk := registry.CURRENT_USER
	k, _, err := registry.CreateKey(hk, uninstallKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	for n, v := range map[string]string{
		"DisplayName":     "Iris",
		"DisplayVersion":  Version,
		"Publisher":       "Tulipan Labs",
		"DisplayIcon":     exe + ",0",
		"InstallLocation": dir,
		"UninstallString": `"` + filepath.Join(dir, uninstName) + `" --uninstall`,
		// winget and other package managers remove it without a window
		"QuietUninstallString": `"` + filepath.Join(dir, uninstName) + `" --uninstall --silent`,
		"InstallDate":     time.Now().Format("20060102"),
	} {
		k.SetStringValue(n, v)
	}
	k.SetDWordValue("NoModify", 1)
	k.SetDWordValue("NoRepair", 1)
	k.SetDWordValue("EstimatedSize", uint32(size/1024))
	k.Close()

	open := `"` + exe + `" "%1"`
	cls := `Software\Classes\` + progID
	for _, e := range [][3]string{
		{cls, "", "Iris web page"},
		{cls + `\DefaultIcon`, "", exe + ",0"},
		{cls + `\shell\open\command`, "", open},
		{clientKey, "", "Iris"},
		{clientKey + `\DefaultIcon`, "", exe + ",0"},
		{clientKey + `\shell\open\command`, "", `"` + exe + `"`},
		{clientKey + `\Capabilities`, "ApplicationName", "Iris"},
		{clientKey + `\Capabilities`, "ApplicationDescription", "A light, fast browser that keeps memory low."},
		{clientKey + `\Capabilities`, "ApplicationIcon", exe + ",0"},
		{clientKey + `\Capabilities\URLAssociations`, "http", progID},
		{clientKey + `\Capabilities\URLAssociations`, "https", progID},
		{clientKey + `\Capabilities\FileAssociations`, ".htm", progID},
		{clientKey + `\Capabilities\FileAssociations`, ".html", progID},
		{`Software\RegisteredApplications`, "Iris", clientKey + `\Capabilities`},
	} {
		if err := setString(hk, e[0], e[1], e[2]); err != nil {
			return err
		}
	}
	// ready in the background from sign-in, so the window opens instantly
	if rk, _, err := registry.CreateKey(hk, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE); err == nil {
		rk.SetStringValue("Iris", `"`+exe+`" --background`)
		rk.Close()
	}
	procNotifyAssocs.Call(0x08000000 /*SHCNE_ASSOCCHANGED*/, 0, 0, 0)
	return nil
}

func deleteTree(root registry.Key, path string) {
	k, err := registry.OpenKey(root, path, registry.ENUMERATE_SUB_KEYS)
	if err == nil {
		names, _ := k.ReadSubKeyNames(-1)
		k.Close()
		for _, n := range names {
			deleteTree(root, path+`\`+n)
		}
	}
	registry.DeleteKey(root, path)
}

// uninstall removes the app, its shortcuts and registry entries; with data, also
// settings, history and site data. The folder holding this running uninstaller is
// removed by a helper a moment after it exits.
func uninstall(data bool) error {
	dir := installDir()
	for _, p := range shortcutPaths(true) {
		os.Remove(p)
	}
	hk := registry.CURRENT_USER
	deleteTree(hk, uninstallKey)
	deleteTree(hk, clientKey)
	deleteTree(hk, `Software\Classes\`+progID)
	if k, err := registry.OpenKey(hk, `Software\RegisteredApplications`, registry.SET_VALUE); err == nil {
		k.DeleteValue("Iris")
		k.Close()
	}
	if rk, err := registry.OpenKey(hk, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE); err == nil {
		rk.DeleteValue("Iris")
		rk.Close()
	}
	quitRunning()
	procNotifyAssocs.Call(0x08000000, 0, 0, 0)
	os.Remove(filepath.Join(dir, exeName) + ".sha256")
	if err := os.Remove(filepath.Join(dir, exeName)); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("close Iris and try again (%v)", err)
	}
	if data {
		if c, err := os.UserConfigDir(); err == nil {
			os.RemoveAll(filepath.Join(c, "Iris"))
		}
		if c, err := os.UserCacheDir(); err == nil {
			os.RemoveAll(filepath.Join(c, "Iris"))
		}
	}
	cmd := exec.Command("cmd.exe", "/c", "ping -n 3 127.0.0.1 >nul & rmdir /s /q \""+dir+"\"")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000 /*CREATE_NO_WINDOW*/}
	return cmd.Start()
}

func launch(dir string) {
	cmd := exec.Command(filepath.Join(dir, exeName))
	cmd.Dir = dir
	_ = cmd.Start()
}

func isWindows() bool { return true }
