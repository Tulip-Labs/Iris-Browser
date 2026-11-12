//go:build darwin

package webview

/*
#cgo CFLAGS: -x objective-c -fobjc-arc -mmacosx-version-min=12.0
#cgo LDFLAGS: -framework Cocoa -framework WebKit
#include <stdlib.h>
#include <stdint.h>

void lgStart(uintptr_t parent, const char *dataDir);
void lgSetBlocklist(const char *json);
uintptr_t lgNewView(uintptr_t id, const char *profile, int priv, uintptr_t popup, const char **scripts, int nscripts);
void lgNavigate(uintptr_t v, const char *url);
void lgBack(uintptr_t v);
void lgForward(uintptr_t v);
void lgReload(uintptr_t v);
void lgStop(uintptr_t v);
void lgSetFrame(uintptr_t v, int x, int y, int w, int h);
void lgSetHidden(uintptr_t v, int hidden);
void lgFocus(uintptr_t v);
void lgEval(uintptr_t v, const char *js, uintptr_t cb);
void lgClose(uintptr_t v);
char *lgVersion(void);
double lgSelfMB(void);
*/
import "C"

import (
	"runtime/cgo"
	"strconv"
	"unsafe"
)

// New returns the macOS engine: WKWebView inside the Gio window.
func New() Engine {
	if wkEng == nil {
		wkEng = &wkEngine{}
	}
	return wkEng
}

// Installed is always true: WebKit ships with macOS and updates with it.
func Installed() bool { return true }

// SelfMB is this process's memory.
func SelfMB() float64 { return float64(C.lgSelfMB()) }

func (e *wkEngine) Start(window uintptr, dataDir string, low bool, ready func(error)) {
	e.dataDir, e.low, e.started = dataDir, low, true
	cs := C.CString(dataDir)
	defer C.free(unsafe.Pointer(cs))
	C.lgStart(C.uintptr_t(window), cs)
	e.applyBlocklist()
	ready(nil)
}

func (e *wkEngine) applyBlocklist() {
	e.mu.Lock()
	bl := e.policy.Blocklist
	e.mu.Unlock()
	if bl == nil || !e.started {
		return
	}
	js := C.CString(bl())
	defer C.free(unsafe.Pointer(js))
	C.lgSetBlocklist(js)
}

func (e *wkEngine) SetPolicy(p Policy) {
	e.mu.Lock()
	e.policy = p
	e.mu.Unlock()
	e.applyBlocklist()
}

func (e *wkEngine) MemoryMB() float64 { return 0 }

func (e *wkEngine) Version() string {
	s := C.lgVersion()
	defer C.free(unsafe.Pointer(s))
	return "WebKit " + C.GoString(s)
}

func (e *wkEngine) NewView(o Options, ev Events, done func(View, error)) {
	if o.Popup != nil && o.Popup.impl.id != 0 {
		// WebKit already made the popup's view (see lgGoPopup): adopt it
		if v := wkGet(o.Popup.impl.id); v != nil {
			v.ev = ev
			done(v, nil)
			return
		}
	}
	v := &wkView{ev: ev, private: o.Private}
	id := wkAdd(v)
	e.mu.Lock()
	scripts := e.policy.Scripts
	e.mu.Unlock()
	cs := make([]*C.char, len(scripts)+1)
	for i, s := range scripts {
		cs[i] = C.CString(s)
	}
	defer func() {
		for _, c := range cs[:len(scripts)] {
			C.free(unsafe.Pointer(c))
		}
	}()
	prof := C.CString(o.Profile)
	defer C.free(unsafe.Pointer(prof))
	var popup uintptr
	priv := 0
	if o.Private {
		priv = 1
	}
	v.native = uintptr(C.lgNewView(C.uintptr_t(id), prof, C.int(priv), C.uintptr_t(popup), &cs[0], C.int(len(scripts))))
	if v.native == 0 {
		wkDel(id)
		done(nil, ErrUnavailable)
		return
	}
	done(v, nil)
}

func cstr(s string, f func(*C.char)) {
	c := C.CString(s)
	defer C.free(unsafe.Pointer(c))
	f(c)
}

func (v *wkView) Navigate(u string) {
	cstr(u, func(c *C.char) { C.lgNavigate(C.uintptr_t(v.native), c) })
}
func (v *wkView) Back()    { C.lgBack(C.uintptr_t(v.native)) }
func (v *wkView) Forward() { C.lgForward(C.uintptr_t(v.native)) }
func (v *wkView) Reload()  { C.lgReload(C.uintptr_t(v.native)) }
func (v *wkView) Stop()    { C.lgStop(C.uintptr_t(v.native)) }
func (v *wkView) SetBounds(x, y, w, h int) {
	C.lgSetFrame(C.uintptr_t(v.native), C.int(x), C.int(y), C.int(w), C.int(h))
}
func (v *wkView) SetVisible(on bool) {
	h := 1
	if on {
		h = 0
	}
	C.lgSetHidden(C.uintptr_t(v.native), C.int(h))
}

// Sleep hides the view; WebKit throttles hidden pages by itself.
func (v *wkView) Sleep() { v.SetVisible(false) }
func (v *wkView) Wake()  {}
func (v *wkView) Focus() { C.lgFocus(C.uintptr_t(v.native)) }
func (v *wkView) Eval(js string) {
	cstr(js, func(c *C.char) { C.lgEval(C.uintptr_t(v.native), c, 0) })
}
func (v *wkView) Run(js string, done func(string)) {
	h := cgo.NewHandle(done)
	cstr(js, func(c *C.char) { C.lgEval(C.uintptr_t(v.native), c, C.uintptr_t(h)) })
}
func (v *wkView) SetMuted(on bool) {
	v.Eval(`document.querySelectorAll('video,audio').forEach(m => m.muted = ` + strconv.FormatBool(on) + `)`)
}
func (v *wkView) Close() {
	if v.closed {
		return
	}
	v.closed = true
	C.lgClose(C.uintptr_t(v.native))
	wkDel(v.id)
}

// ---- events from Objective-C ----

//export lgGoURL
func lgGoURL(id C.uintptr_t, u *C.char) {
	if v := wkGet(uintptr(id)); v != nil {
		v.url = C.GoString(u)
		if v.ev.URL != nil {
			v.ev.URL(v.url)
		}
	}
}

//export lgGoTitle
func lgGoTitle(id C.uintptr_t, t *C.char) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Title != nil {
		v.ev.Title(C.GoString(t))
	}
}

//export lgGoLoading
func lgGoLoading(id C.uintptr_t, on C.int, back C.int, fwd C.int) {
	if v := wkGet(uintptr(id)); v != nil {
		if v.ev.Loading != nil {
			v.ev.Loading(on != 0)
		}
		if v.ev.History != nil {
			v.ev.History(back != 0, fwd != 0)
		}
	}
}

//export lgGoDecide
func lgGoDecide(id C.uintptr_t, u *C.char) *C.char {
	v := wkGet(uintptr(id))
	if v == nil || wkEng == nil {
		return nil
	}
	if r := wkEng.decide(v, C.GoString(u)); r != "" {
		return C.CString(r) // freed by the caller
	}
	return nil
}

//export lgGoPopup
func lgGoPopup(id C.uintptr_t, native C.uintptr_t, u *C.char) C.uintptr_t {
	v := wkGet(uintptr(id))
	if v == nil || v.ev.NewTab == nil {
		return 0
	}
	// the new view already exists (WebKit needs it at once): it is handed over
	// to the new tab through its popup
	nv := &wkView{native: uintptr(native), private: v.private}
	nid := wkAdd(nv)
	v.ev.NewTab(C.GoString(u), &Popup{URL: C.GoString(u), impl: popupImpl{native: uintptr(native), id: nid}})
	return C.uintptr_t(nid)
}

//export lgGoFullscreen
func lgGoFullscreen(id C.uintptr_t, on C.int) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Fullscreen != nil {
		v.ev.Fullscreen(on != 0)
	}
}

//export lgGoCrashed
func lgGoCrashed(id C.uintptr_t) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Crashed != nil {
		v.ev.Crashed()
	}
}

//export lgGoKey
func lgGoKey(id C.uintptr_t, ch C.int, vk C.int, cmd, shift, alt C.int) C.int {
	v := wkGet(uintptr(id))
	if v == nil || v.ev.Key == nil {
		return 0
	}
	k := Key{VK: uint32(vk), Ctrl: cmd != 0, Shift: shift != 0, Alt: alt != 0}
	if k.VK == 0 {
		k.VK = vkFromChar(rune(ch))
	}
	if k.VK != 0 && v.ev.Key(k) {
		return 1
	}
	return 0
}

//export lgGoResult
func lgGoResult(cb C.uintptr_t, res *C.char) {
	h := cgo.Handle(cb)
	done := h.Value().(func(string))
	h.Delete()
	done(C.GoString(res))
}
