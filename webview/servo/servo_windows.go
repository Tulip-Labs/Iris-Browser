//go:build windows && servo

package servo

// The Servo engine on Windows: the child-window side. The engine itself
// (servo.go) is shared with Linux; this file is only what Windows does
// differently: the pages live as child windows of Iris's window
// (winpresent), and Servo is driven by a Go goroutine (there is no GLib
// main loop to spin it on, as servo_linux.c does on Linux).

/*
#cgo LDFLAGS: -L${SRCDIR}/lib -lirisservo
#include <stdint.h>
#include <stdlib.h>
#include "irisservo.h"

int lsvStart(uintptr_t view);
int lsvOpen(uint64_t id, const char *url);
void lsvClose(uint64_t id);
void lsvBounds(uint64_t id, int x, int y, int w, int h);
void lsvShow(uint64_t id, int on);
void lsvFocus(uint64_t id);
void lsvWake(void);
*/
import "C"

import (
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"iris/webview/winpresent"
)

var (
	svPresenter *winpresent.Presenter
	svFocusID   uint64 // the Servo page with the keyboard (0: none)
	svFocusMu   sync.Mutex
	spinWake    = make(chan struct{}, 1)
	closeQ      = make(chan uint64, 64)
)

// svPlatformStart attaches the pages' presenter to Iris's window and starts
// the thread that spins Servo.
func svPlatformStart(window uintptr) {
	svPresenter = winpresent.Attach(window)
	svPresenter.SetInput(winpresent.Servo, svInputT{})
	go spinLoop()
}

// svPlatformTicks starts the memory check (lsvGoTick, every 10 seconds).
func svPlatformTicks() {
	go func() {
		for range time.Tick(10 * time.Second) {
			lsvGoTick()
		}
	}()
}

// spinLoop is Servo's event loop on Windows: it spins Servo whenever
// something asks (onWake) and sixteen milliseconds at a time otherwise, so
// pages animate. One goroutine spins, as one GTK thread does on Linux.
func spinLoop() {
	tick := time.NewTicker(16 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-spinWake:
		case <-tick.C:
		case id := <-closeQ:
			C.iris_servo_close(C.uint64_t(id))
			continue
		}
		C.iris_servo_spin()
	}
}

//export lsvGoWake
func lsvGoWake() {
	select {
	case spinWake <- struct{}{}:
	default:
	}
}

// ---- what the C glue calls (servo_windows.c) ----

//export lsvGoFrame
func lsvGoFrame(id C.uint64_t, rgba *C.uint8_t, w, h C.int) {
	if svPresenter == nil || w <= 0 || h <= 0 {
		return
	}
	pix := C.GoBytes(unsafe.Pointer(rgba), w*h*4)
	svPresenter.Paint(winpresent.Servo, uintptr(id), int(w), int(h), 0, 0, int(w), int(h), pix)
}

//export lsvGoScale
func lsvGoScale() C.double {
	if svPresenter == nil {
		return 1
	}
	return C.double(svPresenter.Scale())
}

//export lsvGoPlace
func lsvGoPlace(id C.uint64_t, x, y, w, h C.int) {
	if svPresenter == nil {
		return
	}
	svPresenter.Place(winpresent.Servo, uintptr(id), int(x), int(y), int(w), int(h))
}

//export lsvGoShow
func lsvGoShow(id C.uint64_t, on C.int) {
	if svPresenter == nil {
		return
	}
	svPresenter.Show(winpresent.Servo, uintptr(id), on != 0)
}

//export lsvGoWinFocus
func lsvGoWinFocus(id C.uint64_t) {
	if svPresenter == nil {
		return
	}
	svPresenter.Focus(winpresent.Servo, uintptr(id))
}

//export lsvGoDrop
func lsvGoDrop(id C.uint64_t) {
	svFocusMu.Lock()
	if svFocusID == uint64(id) {
		svFocusID = 0
	}
	svFocusMu.Unlock()
	if svPresenter == nil {
		return
	}
	svPresenter.Drop(winpresent.Servo, uintptr(id))
}

//export lsvGoCursor
func lsvGoCursor(id C.uint64_t, name *C.char) {
	if svPresenter == nil {
		return
	}
	svPresenter.Cursor(winpresent.Servo, uintptr(id), C.GoString(name))
}

//export lsvGoSetFocus
func lsvGoSetFocus(id C.uint64_t) { svFocus(uint64(id)) }

//export lsvGoCloseLater
func lsvGoCloseLater(id C.uint64_t) {
	select {
	case closeQ <- uint64(id):
	default:
	}
}

// svFocus gives the keyboard to a Servo page (and takes it from the last).
func svFocus(id uint64) {
	svFocusMu.Lock()
	if svFocusID == id {
		svFocusMu.Unlock()
		return
	}
	prev := svFocusID
	svFocusID = id
	svFocusMu.Unlock()
	if prev != 0 {
		C.iris_servo_focus(C.uint64_t(prev), 0)
	}
	C.iris_servo_focus(C.uint64_t(id), 1)
	lsvGoFocus(C.uint64_t(id))
}

// ---- input from the window (winpresent, on the window's thread) ----

type svInputT struct{}

var _ winpresent.PageInput = svInputT{}

func svMods(mods uint) C.int {
	// the presenter's modifier bits are Servo's (shift 1, ctrl 2, alt 4,
	// meta 8); the pointer buttons and caps lock are not modifiers here
	return C.int(mods & 0xF)
}

func (svInputT) Mouse(id uintptr, kind int, x, y float64, button, clicks int, mods uint) {
	switch kind {
	case 0:
		C.iris_servo_mouse_move(C.uint64_t(id), C.float(x), C.float(y))
	case 1:
		// Servo's buttons are 1 left, 2 middle, 3 right; the presenter's
		// are 0, 1, 2
		C.iris_servo_mouse_button(C.uint64_t(id), C.float(x), C.float(y), C.int(button+1), 1)
	case 2:
		C.iris_servo_mouse_button(C.uint64_t(id), C.float(x), C.float(y), C.int(button+1), 0)
	default:
		return
	}
	C.lsvWake()
}

func (svInputT) Wheel(id uintptr, x, y, dx, dy float64, precise bool, mods uint) {
	pixels := 0
	if precise {
		pixels = 1
	}
	C.iris_servo_wheel(C.uint64_t(id), C.float(x), C.float(y), C.double(dx), C.double(dy), C.int(pixels))
	C.lsvWake()
}

// svDomKey is the DOM key value of a key the presenter names ("" for keys
// that only type text: their character arrives as Char).
func svDomKey(code string) string {
	switch code {
	case "Left":
		return "ArrowLeft"
	case "Up":
		return "ArrowUp"
	case "Right":
		return "ArrowRight"
	case "Down":
		return "ArrowDown"
	case "Super":
		return "Meta"
	case "Capslock":
		return "CapsLock"
	case "Numlock":
		return "NumLock"
	case "Space":
		return "" // a space arrives as typed text
	}
	if len(code) == 1 {
		return "" // a letter, digit or mark: typed text, not a key
	}
	return code
}

// svKey gives Servo a key press (down 1) or release (down 0).
func svKey(id uint64, key string, down int, mods C.int) {
	cstr(key, func(ck *C.char) {
		cs := C.CString("")
		defer C.free(unsafe.Pointer(cs))
		C.iris_servo_key(C.uint64_t(id), ck, cs, C.int(down), mods, 0)
	})
}

func (svInputT) KeyEv(id uintptr, down bool, code string, mods uint) {
	key := svDomKey(code)
	if key == "" {
		return
	}
	d := 0
	if down {
		d = 1
	}
	svKey(uint64(id), key, d, svMods(mods))
	C.lsvWake()
}

func (svInputT) Char(id uintptr, text string, mods uint) {
	for _, r := range text {
		svKey(uint64(id), string(r), 1, svMods(mods))
		svKey(uint64(id), string(r), 0, svMods(mods))
	}
	C.lsvWake()
}

func (svInputT) Nav(id uintptr, fwd bool) {
	if fwd {
		C.iris_servo_forward(C.uint64_t(id))
	} else {
		C.iris_servo_back(C.uint64_t(id))
	}
	C.lsvWake()
}

func (svInputT) Key(id uintptr, ch rune, vk uint32, ctrl, shift, alt bool) bool {
	// Iris's own shortcuts first (Ctrl+T, Ctrl+L, F5…), as on Linux
	ctrlI, shiftI, altI := 0, 0, 0
	if ctrl {
		ctrlI = 1
	}
	if shift {
		shiftI = 1
	}
	if alt {
		altI = 1
	}
	return lsvGoKey(C.uint64_t(id), C.int(vk), C.int(ctrlI), C.int(shiftI), C.int(altI)) != 0
}

func (svInputT) Focus(id uintptr) { svFocus(uint64(id)) }

// svRssMB is this process's resident memory.
func svRssMB() float64 {
	var pmc processMemoryCounters
	pmc.cb = uint32(unsafe.Sizeof(pmc))
	r, _, _ := procGetProcessMemoryInfo.Call(^uintptr(0), uintptr(unsafe.Pointer(&pmc)), uintptr(pmc.cb))
	if r == 0 {
		return 0
	}
	return float64(pmc.workingSetSize) / (1 << 20)
}

// svTotalMemMB is the computer's memory.
func svTotalMemMB() float64 {
	var ms memoryStatusEx
	ms.dwLength = uint32(unsafe.Sizeof(ms))
	r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&ms)))
	if r == 0 {
		return 8192
	}
	return float64(ms.ullTotalPhys / (1 << 20))
}

var (
	psapiDLL    = windows.NewLazySystemDLL("psapi.dll")
	kernel32dll = windows.NewLazySystemDLL("kernel32.dll")

	procGetProcessMemoryInfo = psapiDLL.NewProc("GetProcessMemoryInfo")
	procGlobalMemoryStatusEx = kernel32dll.NewProc("GlobalMemoryStatusEx")
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
