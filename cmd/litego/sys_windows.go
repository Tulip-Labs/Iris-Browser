//go:build windows

package main

import (
	"os"
	"os/exec"
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
)

// allowForeground lets the running Lite Go bring its window to the front.
func allowForeground(pid int) {
	if pid > 0 {
		procAllowFG.Call(uintptr(pid))
	}
}

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// setStartup starts Lite Go in the background when Windows starts (not for the
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
		_ = k.SetStringValue("Lite Go", `"`+exe+`" --background`)
	} else {
		_ = k.DeleteValue("Lite Go")
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
