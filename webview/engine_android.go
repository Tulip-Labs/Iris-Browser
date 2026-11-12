//go:build android

package webview

/*
#cgo LDFLAGS: -llog
#include <jni.h>
#include <stdlib.h>
#include <stdint.h>

enum { OP_NEW = 1, OP_NAV, OP_BACK, OP_FWD, OP_RELOAD, OP_STOP, OP_BOUNDS, OP_SHOW, OP_FOCUS, OP_EVAL, OP_MUTE, OP_CLOSE, OP_SCRIPT, OP_PROFILE, OP_PRIVATE, OP_BLOCKLIST, OP_SLEEP, OP_WAKE };

int lgaInit(uintptr_t vm, uintptr_t context);
void lgaStart(uintptr_t view, int low);
void lgaOp(int op, int64_t id, int a, int b, int c, int d, const uint16_t *s, int n, int64_t cb);
void lgaToBack(void);
void lgaTrim(void);
void lgaFocusApp(void);
int lgaExitFullscreen(void);
uint16_t *lgaString(JNIEnv *e, jstring s, int *n);
jstring lgaNewString(JNIEnv *e, const uint16_t *s, int n);
uint16_t *lgaVersion(int *n);
*/
import "C"

import (
	"bufio"
	"os"
	"runtime/cgo"
	"strconv"
	"strings"
	"unicode/utf16"
	"unsafe"
)

// The Android engine: the system WebView (Android's own Chromium, updated by
// the system), placed over Lite Go's Gio view. The Java half is
// webview/android/LiteWeb.java.

var (
	jvm, jctx uintptr
	// OnBack is the system back button pressed while a page has the focus;
	// it returns true when Lite Go used it.
	OnBack func() bool
)

// SetJVM gives the engine the app's Java VM and context (from Gio).
func SetJVM(vm, context uintptr) { jvm, jctx = vm, context }

// New returns the Android engine.
func New() Engine {
	if wkEng == nil {
		wkEng = &wkEngine{}
	}
	return wkEng
}

// Installed reports whether the system WebView is there (it is part of Android).
func Installed() bool { return true }

// SelfMB is this process's memory (resident set): Lite Go and, on Android,
// most of the WebView too (its renderer is a separate, sandboxed process).
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

// ToBack sends Lite Go behind the other apps (back pressed on the first page).
func ToBack() { C.lgaToBack() }

// ExitFullscreen leaves a fullscreen video; it reports whether one was showing.
func ExitFullscreen() bool { return C.lgaExitFullscreen() != 0 }

// FocusApp gives the keyboard back to Lite Go's view (from a page).
func FocusApp() { C.lgaFocusApp() }

// Trim lets hidden pages give memory back (the system is short of it).
func Trim() { C.lgaTrim() }

func call(op int, id uintptr, a, b, c, d int, s string, cb uintptr) {
	var p *C.uint16_t
	n := 0
	if s != "" || op == C.OP_NEW || op == C.OP_PROFILE || op == C.OP_NAV || op == C.OP_EVAL || op == C.OP_SCRIPT {
		u := utf16.Encode([]rune(s))
		n = len(u)
		if n == 0 {
			u = []uint16{0}
		}
		p = (*C.uint16_t)(C.malloc(C.size_t(len(u) * 2)))
		copy(unsafe.Slice((*uint16)(unsafe.Pointer(p)), len(u)), u)
		defer C.free(unsafe.Pointer(p))
	}
	C.lgaOp(C.int(op), C.int64_t(id), C.int(a), C.int(b), C.int(c), C.int(d), p, C.int(n), C.int64_t(cb))
}

func goString(env *C.JNIEnv, s C.jstring) string {
	var n C.int
	p := C.lgaString(env, s, &n)
	if p == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(p))
	return string(utf16.Decode(unsafe.Slice((*uint16)(unsafe.Pointer(p)), int(n))))
}

func javaString(env *C.JNIEnv, s string) C.jstring {
	u := utf16.Encode([]rune(s))
	if len(u) == 0 {
		u = []uint16{0}
		return C.lgaNewString(env, (*C.uint16_t)(unsafe.Pointer(&u[0])), 0)
	}
	return C.lgaNewString(env, (*C.uint16_t)(unsafe.Pointer(&u[0])), C.int(len(u)))
}

func (e *wkEngine) Start(window uintptr, dataDir string, low bool, ready func(error)) {
	e.dataDir, e.low = dataDir, low
	if jvm == 0 || C.lgaInit(C.uintptr_t(jvm), C.uintptr_t(jctx)) == 0 {
		ready(ErrUnavailable)
		return
	}
	l := 0
	if low {
		l = 1
	}
	C.lgaStart(C.uintptr_t(window), C.int(l))
	e.started = true
	ready(nil)
}

func (e *wkEngine) SetPolicy(p Policy) {
	e.mu.Lock()
	e.policy = p
	e.mu.Unlock()
}

func (e *wkEngine) MemoryMB() float64 { return 0 }

func (e *wkEngine) Version() string {
	var n C.int
	p := C.lgaVersion(&n)
	if p == nil {
		return "Android System WebView"
	}
	defer C.free(unsafe.Pointer(p))
	return "Android System WebView " + string(utf16.Decode(unsafe.Slice((*uint16)(unsafe.Pointer(p)), int(n))))
}

func (e *wkEngine) NewView(o Options, ev Events, done func(View, error)) {
	if o.Popup != nil && o.Popup.impl.id != 0 {
		if v := wkGet(o.Popup.impl.id); v != nil {
			v.ev = ev
			done(v, nil)
			return
		}
	}
	v := &wkView{ev: ev, private: o.Private}
	id := wkAdd(v)
	v.native = id
	e.mu.Lock()
	scripts := e.policy.Scripts
	e.mu.Unlock()
	for _, s := range scripts {
		call(C.OP_SCRIPT, id, 0, 0, 0, 0, s, 0)
	}
	priv := 0
	if o.Private {
		priv = 1
	}
	call(C.OP_PROFILE, id, priv, 0, 0, 0, o.Profile, 0)
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
func (v *wkView) Sleep()         { v.SetVisible(false); v.op(C.OP_SLEEP, 0, 0, 0, 0, "", 0) }
func (v *wkView) Wake()          { v.op(C.OP_WAKE, 0, 0, 0, 0, "", 0) }
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
func (v *wkView) Close() {
	if v.closed {
		return
	}
	call(C.OP_CLOSE, v.native, 0, 0, 0, 0, "", 0)
	v.closed = true
	wkDel(v.id)
}

// ---- events from LiteWeb (UI thread, except allow) ----

//export Java_org_tulipanlabs_litego_LiteWeb_created
func Java_org_tulipanlabs_litego_LiteWeb_created(env *C.JNIEnv, cls C.jclass, cb C.jlong, ok C.jboolean) {
	h := cgo.Handle(cb)
	f := h.Value().(func())
	h.Delete()
	if ok != 0 {
		f()
	}
}

//export Java_org_tulipanlabs_litego_LiteWeb_url
func Java_org_tulipanlabs_litego_LiteWeb_url(env *C.JNIEnv, cls C.jclass, id C.jlong, u C.jstring) {
	if v := wkGet(uintptr(id)); v != nil {
		v.url = goString(env, u)
		if v.ev.URL != nil {
			v.ev.URL(v.url)
		}
	}
}

//export Java_org_tulipanlabs_litego_LiteWeb_title
func Java_org_tulipanlabs_litego_LiteWeb_title(env *C.JNIEnv, cls C.jclass, id C.jlong, t C.jstring) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Title != nil {
		v.ev.Title(goString(env, t))
	}
}

//export Java_org_tulipanlabs_litego_LiteWeb_loading
func Java_org_tulipanlabs_litego_LiteWeb_loading(env *C.JNIEnv, cls C.jclass, id C.jlong, on, back, fwd C.jboolean) {
	if v := wkGet(uintptr(id)); v != nil {
		if v.ev.Loading != nil {
			v.ev.Loading(on != 0)
		}
		if v.ev.History != nil {
			v.ev.History(back != 0, fwd != 0)
		}
	}
}

//export Java_org_tulipanlabs_litego_LiteWeb_decide
func Java_org_tulipanlabs_litego_LiteWeb_decide(env *C.JNIEnv, cls C.jclass, id C.jlong, u C.jstring) C.jstring {
	v := wkGet(uintptr(id))
	if v == nil || wkEng == nil {
		return 0
	}
	if r := wkEng.decide(v, goString(env, u)); r != "" {
		return javaString(env, r)
	}
	return 0
}

//export Java_org_tulipanlabs_litego_LiteWeb_popup
func Java_org_tulipanlabs_litego_LiteWeb_popup(env *C.JNIEnv, cls C.jclass, id C.jlong, u C.jstring) C.jlong {
	v := wkGet(uintptr(id))
	if v == nil || v.ev.NewTab == nil {
		return 0
	}
	url := goString(env, u)
	nv := &wkView{private: v.private}
	nid := wkAdd(nv)
	nv.native = nid
	v.ev.NewTab(url, &Popup{URL: url, impl: popupImpl{native: nid, id: nid}})
	return C.jlong(nid)
}

//export Java_org_tulipanlabs_litego_LiteWeb_fullscreen
func Java_org_tulipanlabs_litego_LiteWeb_fullscreen(env *C.JNIEnv, cls C.jclass, id C.jlong, on C.jboolean) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Fullscreen != nil {
		v.ev.Fullscreen(on != 0)
	}
}

//export Java_org_tulipanlabs_litego_LiteWeb_crashed
func Java_org_tulipanlabs_litego_LiteWeb_crashed(env *C.JNIEnv, cls C.jclass, id C.jlong) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Crashed != nil {
		v.ev.Crashed()
	}
}

//export Java_org_tulipanlabs_litego_LiteWeb_failed
func Java_org_tulipanlabs_litego_LiteWeb_failed(env *C.JNIEnv, cls C.jclass, id C.jlong, u C.jstring, status C.jint) {
	if v := wkGet(uintptr(id)); v != nil && v.ev.Failed != nil {
		v.ev.Failed(goString(env, u), int(status))
	}
}

//export Java_org_tulipanlabs_litego_LiteWeb_result
func Java_org_tulipanlabs_litego_LiteWeb_result(env *C.JNIEnv, cls C.jclass, cb C.jlong, res C.jstring) {
	h := cgo.Handle(cb)
	f := h.Value().(func(string))
	h.Delete()
	f(goString(env, res))
}

// allow is the shield, asked for every request (on WebView's network thread).
//
//export Java_org_tulipanlabs_litego_LiteWeb_allow
func Java_org_tulipanlabs_litego_LiteWeb_allow(env *C.JNIEnv, cls C.jclass, id C.jlong, u, page, kind C.jstring) C.jboolean {
	if wkEng == nil {
		return 1
	}
	wkEng.mu.Lock()
	allow := wkEng.policy.Allow
	wkEng.mu.Unlock()
	if allow == nil {
		return 1
	}
	url := goString(env, u)
	if allow(url, goString(env, page), goString(env, kind)) {
		return 1
	}
	if v := wkGet(uintptr(id)); v != nil && v.ev.Blocked != nil {
		v.ev.Blocked(url)
	}
	return 0
}

//export Java_org_tulipanlabs_litego_LiteWeb_back
func Java_org_tulipanlabs_litego_LiteWeb_back(env *C.JNIEnv, cls C.jclass) C.jboolean {
	if OnBack != nil && OnBack() {
		return 1
	}
	return 0
}
