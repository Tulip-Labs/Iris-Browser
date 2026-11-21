//go:build linux && webkit

// The Linux window: GTK 4 owns it (native on Wayland and on X11), Gio's GPU
// renderer draws our interface into a texture at the screen's exact scale,
// and the pages (WebKitGTK web views, GTK widgets) go over it in the same
// window. See gtk_linux.c.

package main

/*
#cgo pkg-config: gtk4 epoxy
#cgo LDFLAGS: -ldl
#include <stdint.h>
#include <stdlib.h>

void lgwInit(void);
void lgwMain(void);
uintptr_t lgwOpen(int w, int h, int maximized);
void lgwInvalidate(void);
void lgwAfterFrame(void);
void lgwSetClipboard(const char *s);
void lgwPaste(void);
void lgwMinimize(void);
void lgwToggleMaximize(void);
void lgwFullscreen(int on);
void lgwClose(void);
void lgwPresent(void);
void lgwFocus(void);
void lgwSendState(void);
void lgwDo(uintptr_t h);
int lgwWayland(void);
void lgwSetOverlay(int on, double x, double y, double w, double h, double radius);
*/
import "C"

import (
	"fmt"
	"image"
	"log"
	"os"
	"runtime"
	"runtime/cgo"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"gioui.org/gpu"
	"gioui.org/op"

	"iris/shell"
	"iris/ui"
	"iris/webview"
)

func init() {
	// GTK runs on the main thread, which is where main starts
	runtime.LockOSThread()
}

// GDK modifier bits.
const (
	gdkShift   = 1 << 0
	gdkControl = 1 << 2
	gdkAlt     = 1 << 3
	gdkButton1 = 1 << 8
)

func runMain() {
	C.lgwInit()
	C.lgwMain()
}

// onMain runs f on the GTK thread.
func onMain(f func()) { C.lgwDo(C.uintptr_t(cgo.NewHandle(f))) }

//export lgwGoDo
func lgwGoDo(h C.uintptr_t) {
	hd := cgo.Handle(h)
	f := hd.Value().(func())
	hd.Delete()
	f()
}

// win is the open window (one at a time) and glr Gio's renderer in its GL
// area; both are only touched on the GTK thread.
var (
	win *host
	glr gpu.GPU
)

type host struct {
	r     *resident
	a     *shell.App
	eng   webview.Engine
	in    *ui.Input
	ops   op.Ops
	clip  pendingClip
	after []func()
	quit  bool
	exit  bool
	start time.Time

	sf        float64 // the screen's scale (real pixels per GTK unit; 1.25, 1.5 and the like included)
	text      float64 // the desktop's text scale
	motion    bool    // the desktop allows animations
	lastClick time.Time
	lastX     float64
	lastY     float64
	pinch     float64
	calls     []func()
}

func (h *host) Invalidate()             { C.lgwInvalidate() }
func (h *host) Clipboard() ui.Clipboard { return &h.clip }
func (h *host) Minimize()               { h.later(func() { C.lgwMinimize() }) }
func (h *host) ToggleMaximize()         { h.later(func() { C.lgwToggleMaximize() }) }
func (h *host) Close()                  { h.quit = true; h.Invalidate() }
func (h *host) Quit()                   { h.exit = true; h.quit = true; h.Invalidate() }
func (h *host) FocusWindow()            { h.later(func() { C.lgwFocus() }) }
func (h *host) raise()                  { h.later(func() { C.lgwPresent() }) }

func (h *host) SetFullscreen(on bool) {
	h.later(func() {
		if on {
			C.lgwFullscreen(1)
		} else {
			C.lgwFullscreen(0)
		}
	})
}

func (h *host) later(f func()) { h.after = append(h.after, f); h.Invalidate() }

// scale is Gio's pixels per dp: exactly the scale the compositor gives the
// window (niri's 1.25, 1.5 and the like included), nothing on top. The
// desktop's text scale (gtk-xft-dpi) is left out: multiplied in, it made the
// whole interface larger than the screen it was laid out for.
func (h *host) scale() float32 { return float32(h.sf) }

// dp turns a GTK position into our units.
func (h *host) dp(x, y float64) (float32, float32) {
	k := h.sf / float64(h.scale())
	return float32(x * k), float32(y * k)
}

func (r *resident) window(urls []string) {
	onMain(func() { r.makeWindow(urls) })
}

func (r *resident) makeWindow(urls []string) {
	h := &host{r: r, start: time.Now(), sf: 1, text: 1, pinch: 1, motion: true}
	win = h
	// the size the reader left, and maximized unless they chose otherwise
	ws := r.core.Settings.Window
	if ws.W < 480 || ws.H < 420 {
		ws.W, ws.H = 1280, 820
	}
	max := C.int(1)
	if ws.Windowed {
		max = 0
	}
	layout := C.lgwOpen(C.int(ws.W), C.int(ws.H), max)
	h.eng = newEngine(r.conf)
	h.a = shell.New(h, shell.Config{Engine: h.eng, DataDir: r.conf, TotalMB: totalMB(), Version: version, SelfMB: selfMB,
		Core: r.core, Sys: sysHooks(), UpdateKind: installKind()})
	h.in = h.a.In
	h.a.SetMotion(h.motion)
	C.lgwSendState()
	h.eng.SetPolicy(h.a.Policy())
	for _, u := range urls {
		h.a.OpenURL(u)
	}
	r.shown(h.a, h)
	// the pages go in the window's layout, on this (the GTK) thread
	h.eng.Start(uintptr(layout), r.webDir, h.a.LowMemory(), h.a.Started)
	if C.lgwWayland() != 0 {
		log.Println("Iris: native Wayland")
	}
	h.Invalidate()
}

//export lgwGoScale
func lgwGoScale(sf C.double, text C.double, motion C.int) {
	if h := win; h != nil {
		h.sf, h.text, h.motion = max(float64(sf), 0.5), float64(text), motion != 0
		if h.a != nil {
			h.a.SetMotion(h.motion)
		}
	}
}

//export lgwGoRender
func lgwGoRender(w, ht C.int, sf C.double, fbo C.uint) {
	h := win
	if h == nil || h.a == nil || w <= 0 || ht <= 0 {
		return
	}
	h.sf = max(float64(sf), 0.5)
	if glr == nil {
		g, err := newGPU()
		if err != nil {
			log.Println("Iris: no GPU drawing:", err)
			return
		}
		glr = g
	}
	a := h.a
	scale := h.scale()
	a.Scale = scale
	h.in.Now = time.Since(h.start).Seconds()
	h.ops.Reset()
	g := h.r.gfx
	g.Begin(&h.ops, scale)
	a.Frame(g, float32(w)/scale, float32(ht)/scale)
	g.End()
	// what the interface draws over the pages (the right-click menu)
	if o := a.Overlay; o.W > 0 && o.H > 0 {
		C.lgwSetOverlay(1, C.double(o.X), C.double(o.Y), C.double(o.W), C.double(o.H), C.double(a.OverlayRadius))
	} else {
		C.lgwSetOverlay(0, 0, 0, 0, 0, 0)
	}
	if err := glr.Frame(&h.ops, gpu.OpenGLRenderTarget{V: uint(fbo)}, image.Pt(int(w), int(ht))); err != nil {
		log.Println("Iris: drawing:", err)
		glr.Release()
		glr = nil
		h.Invalidate()
	}
	h.calls = append(h.calls, a.TakeWebCalls()...)
	C.lgwAfterFrame()
}

//export lgwGoUnrealize
func lgwGoUnrealize() {
	if glr != nil { // its GL context goes with the window
		glr.Release()
		glr = nil
	}
}

//export lgwGoAfter
func lgwGoAfter() {
	h := win
	if h == nil {
		return
	}
	calls := h.calls
	h.calls = nil
	for _, f := range calls {
		f()
	}
	if h.clip.text != nil {
		cs := C.CString(*h.clip.text)
		C.lgwSetClipboard(cs)
		C.free(unsafe.Pointer(cs))
		h.clip.text = nil
	}
	after := h.after
	h.after = nil
	for _, f := range after {
		f()
	}
	if h.quit {
		h.quit = false
		h.a.Close()
		for _, f := range h.a.TakeWebCalls() {
			f()
		}
		if h.exit {
			h.r.core.Settings.Flush()
			os.Exit(0)
		}
		C.lgwClose()
	}
}

//export lgwGoDestroy
func lgwGoDestroy() {
	h := win
	if h == nil {
		return
	}
	win = nil
	if !h.quit && h.a != nil {
		h.a.Close() // the window was closed by the system
		for _, f := range h.a.TakeWebCalls() {
			f()
		}
	}
	h.r.closed()
}

//export lgwGoClose
func lgwGoClose() {
	if h := win; h != nil && h.a != nil {
		h.Close()
	}
}

//export lgwGoState
func lgwGoState(maximized, fullscreen, w, h C.int) {
	if hst := win; hst != nil && hst.a != nil { // GTK 4 reports the state while the window opens, before the interface exists
		hst.a.Maximized = maximized != 0
		if fullscreen == 0 { // a video's full screen is not how the reader left the window
			hst.r.core.Settings.SetWindow(maximized == 0, int(w), int(h))
		}
		hst.Invalidate()
	}
}

func (h *host) mods(state C.uint) {
	h.in.Ctrl = state&gdkControl != 0
	h.in.Shift = state&gdkShift != 0
	h.in.Alt = state&gdkAlt != 0
}

// inMove reports whether a point is on our title bar (where the window drags).
func (h *host) inMove(x, y float32) bool {
	for _, r := range h.a.MoveAreas {
		if x >= r.X && x < r.X+r.W && y >= r.Y && y < r.Y+r.H {
			return true
		}
	}
	return false
}

// lgwGoButton takes a press or release; it returns 1 when the system should
// move the window, 2 for the system's window menu.
//
//export lgwGoButton
func lgwGoButton(x, y C.double, button C.int, press C.int, state C.uint, touch C.int) C.int {
	h := win
	if h == nil || h.in == nil {
		return 0
	}
	in := h.in
	mx, my := h.dp(float64(x), float64(y))
	in.MX, in.MY = mx, my
	in.Touch = touch != 0
	h.mods(state)
	defer h.Invalidate()
	if press == 0 {
		if in.Down {
			in.Down, in.Released = false, true
		}
		return 0
	}
	now := time.Now()
	dx, dy := float64(x)-h.lastX, float64(y)-h.lastY
	double := now.Sub(h.lastClick) < 450*time.Millisecond && dx*dx+dy*dy < 36
	if button == 1 && h.inMove(mx, my) {
		if double {
			h.lastClick = time.Time{}
			C.lgwToggleMaximize()
			return 0
		}
		h.lastClick, h.lastX, h.lastY = now, float64(x), float64(y)
		return 1
	}
	switch button {
	case 1:
		if double {
			in.DoubleClick = true
		}
		h.lastClick, h.lastX, h.lastY = now, float64(x), float64(y)
		in.Down, in.Pressed, in.PressX, in.PressY = true, true, mx, my
	case 3:
		if h.inMove(mx, my) {
			return 2
		}
		in.RightPressed = true
	case 8: // the mouse's back and forward buttons
		in.Keys = append(in.Keys, ui.KeyPress{Key: ui.KLeft, Alt: true})
	case 9:
		in.Keys = append(in.Keys, ui.KeyPress{Key: ui.KRight, Alt: true})
	}
	return 0
}

//export lgwGoMotion
func lgwGoMotion(x, y C.double, state C.uint, touch C.int) {
	h := win
	if h == nil || h.in == nil {
		return
	}
	h.in.MX, h.in.MY = h.dp(float64(x), float64(y))
	h.in.Touch = touch != 0
	h.mods(state)
	if h.in.Down && state&gdkButton1 == 0 { // the release went elsewhere
		h.in.Down, h.in.Released = false, true
	}
	h.Invalidate()
}

//export lgwGoLeave
func lgwGoLeave() {
	if h := win; h != nil && h.in != nil && !h.in.Down {
		h.in.MX, h.in.MY = -1, -1
		h.Invalidate()
	}
}

//export lgwGoScroll
func lgwGoScroll(dx, dy C.double, smooth C.int, state C.uint, touch C.int) {
	h := win
	if h == nil || h.in == nil {
		return
	}
	h.mods(state)
	// one wheel notch is 1 here; touchpads send fractions of it
	k := 1.0
	if touch != 0 {
		k = 0.75
	}
	h.in.WheelY += float32(-float64(dy) * k)
	h.in.WheelX += float32(-float64(dx) * k)
	h.Invalidate()
}

//export lgwGoPinch
func lgwGoPinch(phase C.int, scale, x, y C.double) {
	h := win
	if h == nil || h.in == nil {
		return
	}
	if phase == 0 {
		h.pinch = 1
	}
	if s := float64(scale); s > 0 && phase == 1 {
		h.in.Pinch *= float32(s / h.pinch)
		h.pinch = s
		h.in.PinchX, h.in.PinchY = h.dp(float64(x), float64(y))
	}
	h.Invalidate()
}

// GDK key values of the keys the interface reacts to.
var gdkKeys = map[uint]ui.Key{
	0xff51: ui.KLeft, 0xff53: ui.KRight, 0xff52: ui.KUp, 0xff54: ui.KDown,
	0xff50: ui.KHome, 0xff57: ui.KEnd, 0xff55: ui.KPageUp, 0xff56: ui.KPageDown,
	0xff08: ui.KBackspace, 0xffff: ui.KDelete, 0xff0d: ui.KEnter, 0xff8d: ui.KEnter,
	0xff09: ui.KTab, 0xfe20: ui.KTab, 0xff1b: ui.KEscape, 0x20: ui.KSpace,
	0xffc2: ui.KF5, 0xffc3: ui.KF6, 0xffc8: ui.KF11, 0xffc9: ui.KF12,
	0x1008ff26: ui.KLeft, 0x1008ff27: ui.KRight, // XF86Back, XF86Forward (with Alt below)
}

// letter and digit shortcuts (with Ctrl)
var gdkChars = map[byte]ui.Key{
	'A': ui.KA, 'C': ui.KC, 'D': ui.KD, 'K': ui.KK, 'L': ui.KL, 'M': ui.KM, 'N': ui.KN, 'R': ui.KR, 'T': ui.KT, 'V': ui.KV,
	'W': ui.KW, 'X': ui.KX, 'Z': ui.KZ, 'Y': ui.KY, 'J': ui.KJ,
	'F': ui.KF, 'P': ui.KP, 'H': ui.KH, 'S': ui.KS, '0': ui.KZero, '+': ui.KPlus, '=': ui.KPlus, '-': ui.KMinus,
	'1': ui.K1, '2': ui.K2, '3': ui.K3, '4': ui.K4, '5': ui.K5, '6': ui.K6, '7': ui.K7, '8': ui.K8, '9': ui.K9, ',': ui.KComma,
}

// lgwGoKey takes a key press; it returns 1 when the interface used it (plain
// typing goes on to the input method instead).
//
//export lgwGoKey
func lgwGoKey(keyval C.uint, state C.uint) C.int {
	h := win
	if h == nil || h.in == nil {
		return 0
	}
	kv := uint(keyval)
	ctrl, shift, alt := state&gdkControl != 0, state&gdkShift != 0, state&gdkAlt != 0
	k, ok := gdkKeys[kv]
	switch {
	case kv == 0x1008ff26 || kv == 0x1008ff27:
		alt = true
	case ok && kv == 0x20 && !ctrl:
		return 0 // a typed space
	case ok:
	case kv < 0x80 && (ctrl || (alt && (kv == 'd' || kv == 'D'))):
		c := byte(kv)
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		if k, ok = gdkChars[c]; !ok {
			return 0
		}
	default:
		return 0
	}
	if ctrl && k == ui.KV {
		C.lgwPaste()
		return 1
	}
	h.in.Keys = append(h.in.Keys, ui.KeyPress{Key: k, Ctrl: ctrl, Shift: shift, Alt: alt})
	h.Invalidate()
	return 1
}

//export lgwGoText
func lgwGoText(s *C.char) {
	if h := win; h != nil && h.in != nil {
		h.in.Typed += C.GoString(s)
		h.Invalidate()
	}
}

//export lgwGoPaste
func lgwGoPaste(s *C.char) {
	if h := win; h != nil && h.in != nil {
		t := C.GoString(s)
		if len(t) > 4<<20 {
			t = t[:4<<20]
		}
		h.in.Paste += t
		h.Invalidate()
	}
}

// newGPU makes Gio's renderer on the GL area's context; Gio panics on a
// context it cannot use, which becomes an error here instead of a crash.
func newGPU() (g gpu.GPU, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("%v", r)
		}
	}()
	return gpu.New(gpu.OpenGL{Shared: true})
}

// selfMB is the memory Iris's own process holds (its resident set).
func selfMB() float64 {
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
