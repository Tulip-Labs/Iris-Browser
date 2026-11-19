//go:build linux && webkit && electron

package webview

// The Electron engine on Linux: the GTK side. The pages live in Iris's GTK
// window (electron_linux.c), the helper speaks over a Unix socket, and the
// memory readings come from /proc. The engine itself (engine_electron.go)
// is shared with Windows; this file is only what Linux does differently.

/*
#cgo pkg-config: gtk4
#cgo LDFLAGS: -ldl -lm
#include <stdint.h>
#include <stdlib.h>

void lgxAttach(uintptr_t view, const char *dataDir);
double elxScale(void);
void elxPlace(uintptr_t id, int x, int y, int w, int h);
void elxShow(uintptr_t id, int on);
void elxDrop(uintptr_t id);
void elxFocusPage(uintptr_t id);
void elxPaint(uintptr_t id, int fw, int fh, int x, int y, int w, int h, int stride, void *pix);
void elxCursor(uintptr_t id, const char *name);
void elxOnMain(uintptr_t h);
*/
import "C"

import (
	"os"
	"os/exec"
	"runtime/cgo"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// elxBinName is the helper's program, next to Iris or on the PATH.
const elxBinName = "electron"

var hosted bool

// HostGTK tells the engine that Iris's window is made with GTK (always, here).
func HostGTK() { hosted = true }

// elxPlatformAttach is Iris's window: the GTK view the pages are drawn in.
func elxPlatformAttach(window uintptr, dataDir string) {
	cs := C.CString(dataDir)
	C.lgxAttach(C.uintptr_t(window), cs)
	C.free(unsafe.Pointer(cs))
}

// elxPlatformScale is the window's scale now.
func elxPlatformScale() float64 { return float64(C.elxScale()) }

func elxPlatformPlace(id uintptr, x, y, w, h int) {
	C.elxPlace(C.uintptr_t(id), C.int(x), C.int(y), C.int(w), C.int(h))
}

func elxPlatformShow(id uintptr, on bool) {
	s := 0
	if on {
		s = 1
	}
	C.elxShow(C.uintptr_t(id), C.int(s))
}

func elxPlatformDrop(id uintptr) { C.elxDrop(C.uintptr_t(id)) }

func elxPlatformFocus(id uintptr) { C.elxFocusPage(C.uintptr_t(id)) }

func elxPlatformCursor(id uintptr, name string) {
	cs := C.CString(name)
	C.elxCursor(C.uintptr_t(id), cs)
	C.free(unsafe.Pointer(cs))
}

// elxPlatformPaint takes a part of a page's frame: (x, y, w, h) of a fw × fh
// frame. The C side keeps the pixels (and frees them, as it always has).
func elxPlatformPaint(id uintptr, fw, fh, x, y, w, h int, pix []byte) {
	p := C.malloc(C.size_t(len(pix)))
	copy(unsafe.Slice((*byte)(p), len(pix)), pix)
	C.elxPaint(C.uintptr_t(id), C.int(fw), C.int(fh), C.int(x), C.int(y), C.int(w), C.int(h), C.int(w*4), p)
}

// elxPlatformOnMain runs f on GTK's thread.
func elxPlatformOnMain(f func()) { C.elxOnMain(C.uintptr_t(cgo.NewHandle(f))) }

//export elxGoRun
func elxGoRun(h C.uintptr_t) {
	hd := cgo.Handle(h)
	f := hd.Value().(func())
	hd.Delete()
	f()
}

// elxPlatformHelperArgs is how the helper joins the display Iris runs on
// (Wayland first; headless is the last resort).
func elxPlatformHelperArgs() []string {
	switch {
	case os.Getenv("WAYLAND_DISPLAY") != "":
		return []string{"--ozone-platform=wayland"}
	case os.Getenv("DISPLAY") != "":
		return []string{"--ozone-platform=x11"}
	default:
		return []string{"--ozone-platform=headless"}
	}
}

// elxPlatformStopHelper asks the helper to quit, then kills it.
func elxPlatformStopHelper(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	time.AfterFunc(5*time.Second, func() { _ = cmd.Process.Kill() })
}

// ---- input from the window (electron_linux.c, on GTK's thread) ----

//export elxGoMouse
func elxGoMouse(id C.uintptr_t, kind C.int, x, y C.double, button, clicks C.int, mods C.uint) {
	elxMouse(uintptr(id), int(kind), float64(x), float64(y), int(button), int(clicks), uint(mods))
}

//export elxGoWheel
func elxGoWheel(id C.uintptr_t, x, y, dx, dy C.double, precise C.int, mods C.uint) {
	elxWheel(uintptr(id), float64(x), float64(y), float64(dx), float64(dy), precise != 0, uint(mods))
}

//export elxGoKeyEv
func elxGoKeyEv(id C.uintptr_t, down C.int, code *C.char, mods C.uint) {
	elxKeyEv(uintptr(id), down != 0, C.GoString(code), uint(mods))
}

//export elxGoChar
func elxGoChar(id C.uintptr_t, text *C.char, mods C.uint) {
	elxChar(uintptr(id), C.GoString(text), uint(mods))
}

//export elxGoNav
func elxGoNav(id C.uintptr_t, fwd C.int) { elxNav(uintptr(id), fwd != 0) }

//export lgxGoKey
func lgxGoKey(id C.uintptr_t, ch C.int, vk C.int, ctrl, shift, alt C.int) C.int {
	if elxKey(uintptr(id), rune(ch), int(vk), ctrl != 0, shift != 0, alt != 0) {
		return 1
	}
	return 0
}

//export lgxGoFocus
func lgxGoFocus(id C.uintptr_t) { elxFocus(uintptr(id)) }

// SelfMB is this process's memory (resident set).
func SelfMB() float64 {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0
	}
	for _, l := range strings.Split(string(b), "\n") {
		if fs := strings.Fields(l); len(fs) >= 2 && fs[0] == "VmRSS:" {
			kb, _ := strconv.Atoi(fs[1])
			return float64(kb) / 1024
		}
	}
	return 0
}

// totalMemMB is the computer's memory, for the pages' memory limits.
func totalMemMB() int {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	for _, l := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(l, "MemTotal:"); ok {
			kb, _ := strconv.Atoi(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(v), "kB")))
			return kb / 1024
		}
	}
	return 0
}

// treeRSS is the memory (resident set) of process pid and all its
// descendants, in MB, and how many processes that is.
func treeRSS(pid int) (float64, int) {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return 0, 0
	}
	parent := map[int]int{}
	for _, d := range ents {
		p, err := strconv.Atoi(d.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + d.Name() + "/stat")
		if err != nil {
			continue
		}
		// pid (comm) state ppid ...: comm may hold spaces, so after the last ")"
		s := string(b)
		if i := strings.LastIndexByte(s, ')'); i > 0 {
			if f := strings.Fields(s[i+1:]); len(f) > 1 {
				parent[p], _ = strconv.Atoi(f[1])
			}
		}
	}
	in := map[int]bool{pid: true}
	for changed := true; changed; {
		changed = false
		for p, pp := range parent {
			if !in[p] && in[pp] {
				in[p], changed = true, true
			}
		}
	}
	page := float64(os.Getpagesize())
	var mb float64
	for p := range in {
		b, err := os.ReadFile("/proc/" + strconv.Itoa(p) + "/statm")
		if err != nil {
			continue
		}
		if f := strings.Fields(string(b)); len(f) > 1 {
			n, _ := strconv.ParseFloat(f[1], 64)
			mb += n * page / (1 << 20)
		}
	}
	return mb, len(in)
}
