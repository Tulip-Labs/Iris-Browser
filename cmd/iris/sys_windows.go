//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows/registry"

	"golang.org/x/sys/windows"
)

var (
	user32       = windows.NewLazySystemDLL("user32.dll")
	procSetFocus = user32.NewProc("SetFocus")
	kernel32     = windows.NewLazySystemDLL("kernel32.dll")
	procMemEx    = kernel32.NewProc("GlobalMemoryStatusEx")
	procAllowFG  = user32.NewProc("AllowSetForegroundWindow")
	comdlg32     = windows.NewLazySystemDLL("comdlg32.dll")
	procOpenFile = comdlg32.NewProc("GetOpenFileNameW")
)

// OPENFILENAMEW
type openFileName struct {
	structSize    uint32
	owner         uintptr
	instance      uintptr
	filter        *uint16
	customFilter  *uint16
	maxCustFilter uint32
	filterIndex   uint32
	file          *uint16
	maxFile       uint32
	fileTitle     *uint16
	maxFileTitle  uint32
	initialDir    *uint16
	title         *uint16
	flags         uint32
	fileOffset    uint16
	fileExtension uint16
	defExt        *uint16
	custData      uintptr
	hook          uintptr
	templateName  *uint16
	reserved      unsafe.Pointer
	dwReserved    uint32
	flagsEx       uint32
}

// pickFiles shows Windows' "Open" box and returns the files chosen. It
// waits for the reader, on a thread of its own.
func pickFiles() []string {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	buf := make([]uint16, 32768)
	title, _ := windows.UTF16PtrFromString("Send to the phone")
	o := openFileName{file: &buf[0], maxFile: uint32(len(buf)), title: title,
		// explorer style, several files, existing ones only, keep the working folder
		flags: 0x80000 | 0x200 | 0x1000 | 0x800 | 0x8 | 0x4}
	o.structSize = uint32(unsafe.Sizeof(o))
	if r, _, _ := procOpenFile.Call(uintptr(unsafe.Pointer(&o))); r == 0 {
		return nil
	}
	// one file: its full path; several: the folder, then each name, each ended by a zero
	var parts []string
	for i := 0; i < len(buf); {
		j := i
		for j < len(buf) && buf[j] != 0 {
			j++
		}
		if j == i {
			break
		}
		parts = append(parts, windows.UTF16ToString(buf[i:j]))
		i = j + 1
	}
	if len(parts) <= 1 {
		return parts
	}
	out := make([]string, 0, len(parts)-1)
	for _, name := range parts[1:] {
		out = append(out, filepath.Join(parts[0], name))
	}
	return out
}

// allowForeground lets the running Iris bring its window to the front.
func allowForeground(pid int) {
	if pid > 0 {
		procAllowFG.Call(uintptr(pid))
	}
}

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// setStartup starts Iris in the background when Windows starts (not for the
// Store package, whose startup Windows manages).
func setStartup(on bool) {
	exe, err := os.Executable()
	if err != nil || strings.Contains(strings.ToLower(exe), `\windowsapps\`) {
		return
	}
	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return
	}
	defer k.Close()
	if on {
		_ = k.SetStringValue("Iris", `"`+exe+`" --background`)
	} else {
		_ = k.DeleteValue("Iris")
	}
}

// focusWindow gives the keyboard back to the interface (from the page). Window thread only.
func focusWindow(hwnd uintptr) {
	if hwnd != 0 {
		procSetFocus.Call(hwnd)
	}
}

type memoryStatusEx struct {
	length, memoryLoad                  uint32
	totalPhys, availPhys                uint64
	totalPageFile, availPageFile        uint64
	totalVirtual, availVirtual, extVirt uint64
}

// totalMB is the installed memory, for the tab sleep plan.
func totalMB() int {
	var m memoryStatusEx
	m.length = uint32(unsafe.Sizeof(m))
	if r, _, _ := procMemEx.Call(uintptr(unsafe.Pointer(&m))); r == 0 {
		return 0
	}
	return int(m.totalPhys >> 20)
}

// freeMB is the memory still free, for the resource balancer.
func freeMB() int {
	var m memoryStatusEx
	m.length = uint32(unsafe.Sizeof(m))
	if r, _, _ := procMemEx.Call(uintptr(unsafe.Pointer(&m))); r == 0 {
		return 0
	}
	return int(m.availPhys >> 20)
}

// openPath opens a file with its program.
func openPath(p string) {
	verb, _ := windows.UTF16PtrFromString("open")
	file, err := windows.UTF16PtrFromString(p)
	if err != nil {
		return
	}
	_ = windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL)
}

// revealPath shows a file selected in its folder.
func revealPath(p string) {
	cmd := exec.Command("explorer.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `explorer.exe /select,"` + p + `"`}
	_ = cmd.Start()
}

// packaged: installed as a Windows package (MSIX), whose files Windows protects.
func packaged(exe string) bool {
	return strings.Contains(strings.ToLower(exe), `\windowsapps\`)
}
