//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32       = windows.NewLazySystemDLL("user32.dll")
	procSetFocus = user32.NewProc("SetFocus")
	kernel32     = windows.NewLazySystemDLL("kernel32.dll")
	procMemEx    = kernel32.NewProc("GlobalMemoryStatusEx")
)

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
