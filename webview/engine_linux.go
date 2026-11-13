//go:build linux && webkit

package webview

/*
#cgo pkg-config: gtk+-3.0 webkit2gtk-4.1
#include <stdlib.h>
#include <stdint.h>

enum { OP_NEW = 1, OP_NAV, OP_BACK, OP_FWD, OP_RELOAD, OP_STOP, OP_BOUNDS, OP_SHOW, OP_FOCUS, OP_EVAL, OP_MUTE, OP_CLOSE, OP_SCRIPT, OP_PROFILE, OP_PRIVATE, OP_BLOCKLIST, OP_ZOOM, OP_DLCANCEL };

void lgxMain(unsigned long parent, const char *dataDir);
void lgxAttach(uintptr_t layout, const char *dataDir);
void lgxCall(int op, uintptr_t id, int a, int b, int c, int d, const char *s, uintptr_t cb);
char *lgxVersion(void);
*/
import "C"

import (
	"bufio"
	"os"
	"runtime"
	"runtime/cgo"
	"strconv"
	"strings"
	"unsafe"
)

// hosted: Lite Go's window is a GTK window, and Start gets its GtkLayout.
var hosted bool

// HostGTK tells the engine that the program's window is made with GTK (on
// the GTK thread): Start then takes that window's GtkLayout, and the pages go
// in it directly, which works on Wayland as well as X11.
func HostGTK() { hosted = true }

// New returns the Linux engine: WebKitGTK views in Lite Go's GTK window (or,
// when hosted by Gio, in GtkPlugs inside its X11 window).
func New() Engine {
	if wkEng == nil {
		wkEng = &wkEngine{}
	}
	return wkEng
}

// Installed reports whether WebKitGTK is present (it is linked in; the program
// does not start without it).
func Installed() bool { return true }

// SelfMB is this process's memory (resident set).
func SelfMB() float64 {
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if fs := strings.Fields(sc.Text()); len(fs) >= 2 && fs[0] == "VmRSS:" {
			kb, _ := strconv.Atoi(fs[1])
			return float64(kb) / 1024
		}
	}
	return 0
}

func call(op int, id uintptr, a, b, c, d int, s string, cb uintptr) {
	var cs *C.char
	if s != "" || op == C.OP_NEW || op == C.OP_PROFILE {
		cs = C.CString(s)
		defer C.free(unsafe.Pointer(cs))
	}
	C.lgxCall(C.int(op), C.uintptr_t(id), C.int(a), C.int(b), C.int(c), C.int(d), cs, C.uintptr_t(cb))
}

func (e *wkEngine) Start(window uintptr, dataDir string, low bool, ready func(error)) {
	e.dataDir, e.low, e.started = dataDir, low, true
	if hosted {
		cs := C.CString(dataDir)
		C.lgxAttach(C.uintptr_t(window), cs)
		C.free(unsafe.Pointer(cs))
		e.applyBlocklist()
		ready(nil)
		return
	}
	started := make(chan struct{})
	go func() {
		// GTK lives on its own thread for the whole program
		runtime.LockOSThread()
		cs := C.CString(dataDir)
		close(started)
		C.lgxMain(C.ulong(window), cs)
	}()
	<-started
	e.applyBlocklist()
	ready(nil)
}

func (e *wkEngine) applyBlocklist() {
	e.mu.Lock()
	bl := e.policy.Blocklist
	e.mu.Unlock()
	if bl != nil && e.started {
		call(C.OP_BLOCKLIST, 0, 0, 0, 0, 0, bl(), 0)
	}
}

func (e *wkEngine) SetPolicy(p Policy) {
	e.mu.Lock()
	e.policy = p
	e.mu.Unlock()
	e.applyBlocklist()
}

func (e *wkEngine) MemoryMB() float64 { return 0 }

func (e *wkEngine) Version() string {
	s := C.lgxVersion()
	defer C.free(unsafe.Pointer(s))
	return "WebKitGTK " + C.GoString(s)
}

func (e *wkEngine) NewView(o Options, ev Events, done func(View, error)) {
	if o.Popup != nil && o.Popup.impl.id != 0 {
		if v := wkGet(o.Popup.impl.id); v != nil {
			v.ev = ev
			done(v, nil)
			return
		}
	}
	v := &wkView{ev: ev, private: o.Private, sandbox: o.Sandbox}
	id := wkAdd(v)
	v.native = id
	e.mu.Lock()
	scripts := e.policy.Scripts
	e.mu.Unlock()
	// the view is made on the GTK thread: its scripts and storage go first
	for _, s := range scripts {
		call(C.OP_SCRIPT, id, 0, 0, 0, 0, s, 0)
	}
	priv := 0
	if o.Private {
		priv = 1
	}
	sandbox := 0
	if o.Sandbox {
		sandbox = 1
	}
	call(C.OP_PROFILE, id, priv, sandbox, 0, 0, o.Profile, 0)
	h := cgo.NewHandle(func() { done(v, nil) })
	call(C.OP_NEW, id, 0, 0, 0, 0, "", uintptr(h))
}

func (v *wkView) op(op int, a, b, c, d int, s string, cb uintptr) {
	if !v.closed {
		call(op, v.native, a, b, c, d, s, cb)
	}
}

func (v *wkView) Navigate(u string)        { v.op(C.OP_NAV, 0, 0, 0, 0, u, 0) }
func (v *wkView) Back()                    { v.op(C.OP_BACK, 0, 0, 0, 0, "", 0) }
func (v *wkView) Forward()                 { v.op(C.OP_FWD, 0, 0, 0, 0, "", 0) }
func (v *wkView) Reload()                  { v.op(C.OP_RELOAD, 0, 0, 0, 0, "", 0) }
func (v *wkView) Stop()                    { v.op(C.OP_STOP, 0, 0, 0, 0, "", 0) }
func (v *wkView) SetBounds(x, y, w, h int) { v.op(C.OP_BOUNDS, x, y, w, h, "", 0) }
func (v *wkView) SetVisible(on bool) {
	s := 0
	if on {
		s = 1
	}
	v.op(C.OP_SHOW, s, 0, 0, 0, "", 0)
}
func (v *wkView) Sleep()         { v.SetVisible(false) }
func (v *wkView) Wake()          {}
func (v *wkView) Focus()         { v.op(C.OP_FOCUS, 0, 0, 0, 0, "", 0) }
func (v *wkView) Eval(js string) { v.op(C.OP_EVAL, 0, 0, 0, 0, js, 0) }
func (v *wkView) Run(js string, done func(string)) {
	if v.closed {
		done("null")
		return
	}
	h := cgo.NewHandle(done)
	v.op(C.OP_EVAL, 0, 0, 0, 0, js, uintptr(h))
}
func (v *wkView) SetMuted(on bool) {
	m := 0
	if on {
		m = 1
	}
	v.op(C.OP_MUTE, m, 0, 0, 0, "", 0)
}
func (v *wkView) SetZoom(f float64) { v.op(C.OP_ZOOM, int(f*100+0.5), 0, 0, 0, "", 0) }

// SetBackground: WebKit lowers a hidden page's memory by itself.
func (v *wkView) SetBackground(bool) {}

func (v *wkView) Close() {
	if v.closed {
		return
	}
	call(C.OP_CLOSE, v.native, 0, 0, 0, 0, "", 0)
	v.closed = true
	wkDel(v.id)
}

// ---- events from the GTK thread ----

//export lgxGoCreated
func lgxGoCreated(cb C.uintptr_t, ok C.int) {
	h := cgo.Handle(cb)
	f := h.Value().(func())
	h.Delete()
	if ok != 0 {
		f()
	}
}

//export lgxGoURL
func lgxGoURL(id C.uintptr_t, u *C.char) {
	if v := wkGet(uintptr(id)); v != nil {
		v.url = C.GoString(u)
		if v.ev.URL != nil {
			v.ev.URL(v.url)
		}
	}
}

//export lgxGoTitle
func lgxGoTitle(id C.uintptr_t, t *C.char) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Title != nil {
		v.ev.Title(C.GoString(t))
	}
}

//export lgxGoLoading
func lgxGoLoading(id C.uintptr_t, on, back, fwd C.int) {
	if v := wkGet(uintptr(id)); v != nil {
		if v.ev.Loading != nil {
			v.ev.Loading(on != 0)
		}
		if v.ev.History != nil {
			v.ev.History(back != 0, fwd != 0)
		}
	}
}

//export lgxGoDecide
func lgxGoDecide(id C.uintptr_t, u *C.char) *C.char {
	v := wkGet(uintptr(id))
	if v == nil || wkEng == nil {
		return nil
	}
	if r := wkEng.decide(v, C.GoString(u)); r != "" {
		return C.CString(r)
	}
	return nil
}

//export lgxGoPopup
func lgxGoPopup(id C.uintptr_t, u *C.char) C.uintptr_t {
	v := wkGet(uintptr(id))
	if v == nil || v.ev.NewTab == nil {
		return 0
	}
	nv := &wkView{private: v.private, sandbox: v.sandbox}
	nid := wkAdd(nv)
	nv.native = nid
	v.ev.NewTab(C.GoString(u), &Popup{URL: C.GoString(u), impl: popupImpl{native: nid, id: nid}})
	return C.uintptr_t(nid)
}

//export lgxGoFullscreen
func lgxGoFullscreen(id C.uintptr_t, on C.int) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Fullscreen != nil {
		v.ev.Fullscreen(on != 0)
	}
}

//export lgxGoCrashed
func lgxGoCrashed(id C.uintptr_t) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Crashed != nil {
		v.ev.Crashed()
	}
}

//export lgxGoAudio
func lgxGoAudio(id C.uintptr_t, on C.int) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Audio != nil {
		v.ev.Audio(on != 0)
	}
}

//export lgxGoKey
func lgxGoKey(id C.uintptr_t, ch C.int, vk C.int, ctrl, shift, alt C.int) C.int {
	v := wkGet(uintptr(id))
	if v == nil || v.ev.Key == nil {
		return 0
	}
	k := Key{VK: uint32(vk), Ctrl: ctrl != 0, Shift: shift != 0, Alt: alt != 0}
	if k.VK == 0 {
		k.VK = vkFromChar(rune(ch))
	}
	if k.VK != 0 && (k.Ctrl || k.Alt || vk != 0) && v.ev.Key(k) {
		return 1
	}
	return 0
}

//export lgxGoFocus
func lgxGoFocus(id C.uintptr_t) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Focus != nil {
		v.ev.Focus()
	}
}

//export lgxGoDownload
func lgxGoDownload(id C.uintptr_t, state C.int, u, path *C.char, total, got C.longlong) {
	if wkEng == nil {
		return
	}
	wkEng.mu.Lock()
	report := wkEng.policy.Download
	wkEng.mu.Unlock()
	if report == nil {
		return
	}
	d := Download{ID: int(id), URL: C.GoString(u), Path: C.GoString(path), Total: int64(total), Received: int64(got), State: DownloadState(state)}
	if d.State == DownloadActive {
		n := uintptr(id)
		d.Cancel = func() { call(C.OP_DLCANCEL, n, 0, 0, 0, 0, "", 0) }
	} else if d.State == DownloadDone && d.Total < 0 {
		d.Total = d.Received
	}
	report(d)
}

//export lgxGoResult
func lgxGoResult(cb C.uintptr_t, res *C.char) {
	h := cgo.Handle(cb)
	done := h.Value().(func(string))
	h.Delete()
	done(C.GoString(res))
}
