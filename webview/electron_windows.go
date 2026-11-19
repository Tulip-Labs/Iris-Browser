//go:build windows

package webview

// The Electron engine on Windows: the child-window side. The pages live as
// child windows of Iris's window (present_windows.go), the helper is the
// same Electron run as a separate process, speaking over the same Unix
// socket, and the memory readings come from the process APIs. The engine
// itself (engine_electron.go) is shared with Linux; this file is only what
// Windows does differently. Pure Go: no C compiler is needed for this
// engine (the Servo bridge is the only part that needs one).

import (
	"os/exec"
	"unsafe"

	"golang.org/x/sys/windows"

	"iris/webview/winpresent"
)

// elxBinName is the helper's program, next to Iris or on the PATH.
const elxBinName = "electron.exe"

var (
	kernel32dll = windows.NewLazySystemDLL("kernel32.dll")
	psapiDLL    = windows.NewLazySystemDLL("psapi.dll")

	procGetProcessMemoryInfo = psapiDLL.NewProc("GetProcessMemoryInfo")
	procGlobalMemoryStatusEx = kernel32dll.NewProc("GlobalMemoryStatusEx")
	procCreateToolhelp32Snap = kernel32dll.NewProc("CreateToolhelp32Snapshot")
	procProcess32First       = kernel32dll.NewProc("Process32FirstW")
	procProcess32Next        = kernel32dll.NewProc("Process32NextW")
	procOpenProcess          = kernel32dll.NewProc("OpenProcess")
	procCloseHandle          = kernel32dll.NewProc("CloseHandle")
)

const (
	th32csSnapProcess = 0x00000002
	processQueryInfo  = 0x0400
	processVMRead     = 0x0010
)

type processMemoryCounters struct {
	cb                         uint32
	pageFaultCount             uint32
	peakWorkingSetSize         uintptr
	workingSetSize             uintptr
	quotaPeakPagedPoolUsage    uintptr
	quotaPagedPoolUsage        uintptr
	quotaPeakNonPagedPoolUsage uintptr
	quotaNonPagedPoolUsage     uintptr
	pagefileUsage              uintptr
	peakPagefileUsage          uintptr
}

type memoryStatusEx struct {
	dwLength                uint32
	dwMemoryLoad            uint32
	ullTotalPhys            uint64
	ullAvailPhys            uint64
	ullTotalPageFile        uint64
	ullAvailPageFile        uint64
	ullTotalVirtual         uint64
	ullAvailVirtual         uint64
	ullAvailExtendedVirtual uint64
}

type processEntry32 struct {
	dwSize              uint32
	cntUsage            uint32
	th32ProcessID       uint32
	th32DefaultHeapID   uintptr
	th32ModuleID        uint32
	cntThreads          uint32
	th32ParentProcessID uint32
	pcPriClassBase      int32
	dwFlags             uint32
	szExeFile           [260]uint16
}

// elxPlatformAttach is Iris's window: the pages' child windows go in it.
func elxPlatformAttach(window uintptr, dataDir string) {
	_ = dataDir // the helper gets its data folder through IRIS_DATA
	elxPresenter = winpresent.Attach(window)
	elxPresenter.SetInput(winpresent.Electron, elx)
}

var elxPresenter *winpresent.Presenter

// elxPlatformScale is the window's scale now.
func elxPlatformScale() float64 {
	if elxPresenter == nil {
		return 1
	}
	return elxPresenter.Scale()
}

func elxPlatformPlace(id uintptr, x, y, w, h int) {
	if elxPresenter == nil {
		return
	}
	elxPresenter.Place(winpresent.Electron, id, x, y, w, h)
}

func elxPlatformShow(id uintptr, on bool) {
	if elxPresenter == nil {
		return
	}
	elxPresenter.Show(winpresent.Electron, id, on)
}

func elxPlatformDrop(id uintptr) {
	if elxPresenter == nil {
		return
	}
	elxPresenter.Drop(winpresent.Electron, id)
}

func elxPlatformFocus(id uintptr) {
	if elxPresenter == nil {
		return
	}
	elxPresenter.Focus(winpresent.Electron, id)
}

func elxPlatformCursor(id uintptr, name string) {
	if elxPresenter == nil {
		return
	}
	elxPresenter.Cursor(winpresent.Electron, id, name)
}

// elxPlatformPaint takes a part of a page's frame: (x, y, w, h) of a fw × fh
// frame. The presenter keeps the whole frame and draws it.
func elxPlatformPaint(id uintptr, fw, fh, x, y, w, h int, pix []byte) {
	if elxPresenter == nil {
		return
	}
	elxPresenter.Paint(winpresent.Electron, id, fw, fh, x, y, w, h, pix)
}

// elxPlatformOnMain runs f on the window's thread.
func elxPlatformOnMain(f func()) {
	if elxPresenter == nil {
		return
	}
	elxPresenter.RunOnMain(f)
}

// elxPlatformHelperArgs is empty: Electron on Windows needs no ozone flag.
func elxPlatformHelperArgs() []string { return nil }

// elxPlatformStopHelper kills the helper (Windows has no SIGTERM).
func elxPlatformStopHelper(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
}

// ---- input from the window (winpresent, on the window's thread) ----
//
// The presenter reports a page's pointer, wheel and keys to its engine
// through winpresent.PageInput; the Electron engine answers with the shared
// handlers (engine_electron.go).

func (e *elxEngine) Mouse(id uintptr, kind int, x, y float64, button, clicks int, mods uint) {
	elxMouse(id, kind, x, y, button, clicks, mods)
}

func (e *elxEngine) Wheel(id uintptr, x, y, dx, dy float64, precise bool, mods uint) {
	elxWheel(id, x, y, dx, dy, precise, mods)
}

func (e *elxEngine) KeyEv(id uintptr, down bool, code string, mods uint) {
	elxKeyEv(id, down, code, mods)
}

func (e *elxEngine) Char(id uintptr, text string, mods uint) {
	elxChar(id, text, mods)
}

func (e *elxEngine) Nav(id uintptr, fwd bool) { elxNav(id, fwd) }

func (e *elxEngine) Key(id uintptr, ch rune, vk uint32, ctrl, shift, alt bool) bool {
	return elxKey(id, ch, int(vk), ctrl, shift, alt)
}

func (e *elxEngine) Focus(id uintptr) { elxFocus(id) }

// SelfMB is this process's memory (resident set).
func SelfMB() float64 {
	var pmc processMemoryCounters
	pmc.cb = uint32(unsafe.Sizeof(pmc))
	// GetCurrentProcess is the process's own handle (-1)
	r, _, _ := procGetProcessMemoryInfo.Call(^uintptr(0), uintptr(unsafe.Pointer(&pmc)), uintptr(pmc.cb))
	if r == 0 {
		return 0
	}
	return float64(pmc.workingSetSize) / (1 << 20)
}

// totalMemMB is the computer's memory, for the pages' memory limits.
func totalMemMB() int {
	var ms memoryStatusEx
	ms.dwLength = uint32(unsafe.Sizeof(ms))
	r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&ms)))
	if r == 0 {
		return 0
	}
	return int(ms.ullTotalPhys / (1 << 20))
}

// treeRSS is the memory (resident set) of process pid and all its
// descendants, in MB, and how many processes that is.
func treeRSS(pid int) (float64, int) {
	snap, _, _ := procCreateToolhelp32Snap.Call(th32csSnapProcess, 0)
	if snap == 0 || snap == ^uintptr(0) {
		return 0, 0
	}
	defer procCloseHandle.Call(snap)
	parent := map[uint32]uint32{}
	var pe processEntry32
	pe.dwSize = uint32(unsafe.Sizeof(pe))
	r, _, _ := procProcess32First.Call(snap, uintptr(unsafe.Pointer(&pe)))
	for r != 0 {
		parent[pe.th32ProcessID] = pe.th32ParentProcessID
		r, _, _ = procProcess32Next.Call(snap, uintptr(unsafe.Pointer(&pe)))
	}
	in := map[uint32]bool{uint32(pid): true}
	for changed := true; changed; {
		changed = false
		for p, pp := range parent {
			if !in[p] && in[pp] {
				in[p], changed = true, true
			}
		}
	}
	var mb float64
	for p := range in {
		h, _, _ := procOpenProcess.Call(processQueryInfo|processVMRead, 0, uintptr(p))
		if h == 0 {
			continue
		}
		var pmc processMemoryCounters
		pmc.cb = uint32(unsafe.Sizeof(pmc))
		if r, _, _ := procGetProcessMemoryInfo.Call(h, uintptr(unsafe.Pointer(&pmc)), uintptr(pmc.cb)); r != 0 {
			mb += float64(pmc.workingSetSize) / (1 << 20)
		}
		procCloseHandle.Call(h)
	}
	return mb, len(in)
}
