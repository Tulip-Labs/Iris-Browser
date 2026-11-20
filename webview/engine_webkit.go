//go:build linux && webkit

// The WebKitGTK engine: Iris's main page engine on Linux (docs/engines.md).
// Pages are WebKitWebViews, real GTK widgets placed over Iris's interface
// (webkit_linux.c). The router (webview/route) gives the heavy sites to
// Electron; the cookies of both go through Iris's shared store
// (core/session), so a sign-in in one is a sign-in in the other.

package webview

/*
#cgo pkg-config: webkitgtk-6.0 gtk4 libsoup-3.0
#cgo LDFLAGS: -lm
#include <stdint.h>
#include <stdlib.h>

void lwkStart(uintptr_t view, const char *dir);
int lwkSandboxWorks(void);
int lwkJar(const char *name, int memory, int bridged);
void lwkReadJar(int idx);
void lwkSetCookie(int idx, const char *name, const char *value, const char *domain, int hostOnly, const char *path,
                  long long expires, int secure, int httpOnly, const char *sameSite, int removed);
void lwkSetRules(const char *json, int n, const char *id);
void lwkSetScripts(char **list, int n);
void lwkStrict(int on);
int lwkOpen(uintptr_t id, int jar, int sandbox, uintptr_t popup);
void lwkNavigate(uintptr_t id, const char *u);
void lwkBack(uintptr_t id);
void lwkForward(uintptr_t id);
void lwkReload(uintptr_t id);
void lwkStop(uintptr_t id);
void lwkMute(uintptr_t id, int on);
void lwkZoom(uintptr_t id, double f);
void lwkBounds(uintptr_t id, int x, int y, int w, int h);
void lwkShow(uintptr_t id, int on);
void lwkFocus(uintptr_t id);
void lwkRun(uintptr_t id, const char *js, uintptr_t token);
void lwkClose(uintptr_t id);
void lwkDrop(uintptr_t popup);
void lwkCancelDownload(uintptr_t n);
void lwkOnMain(uintptr_t h);
char *lwkVersion(void);
long lwkMemoryKB(void);
*/
import "C"

import (
	"errors"
	"hash/fnv"
	"os"
	"runtime/cgo"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"iris/core/session"
)

// KitEngine is the WebKitGTK engine; one per program.
type KitEngine struct {
	mu      sync.Mutex
	policy  Policy
	started bool
	cookies *session.Store
	jars    map[string]int
	names   map[int]string
	seen    map[int]map[string]session.Cookie
	rules   string // the shield's rules last compiled
	scripts string
	version string
}

type kitView struct {
	id     uintptr
	e      *KitEngine
	ev     Events
	o      Options
	jar    int
	url    string
	closed bool
	divert func(string) bool
}

var (
	kit      *KitEngine
	kitViews = map[uintptr]*kitView{}
	kitNext  uintptr
	kitRuns  = map[uintptr]func(string){}
	kitRunN  uintptr
)

// NewWebKit returns the WebKitGTK engine. cookies is the store shared with
// Electron (nil: WebKit keeps its own cookies only).
func NewWebKit(cookies *session.Store) *KitEngine {
	if kit == nil {
		kit = &KitEngine{cookies: cookies, jars: map[string]int{}, names: map[int]string{}, seen: map[int]map[string]session.Cookie{}}
		if cookies != nil {
			// cookies from the other engine come here on any thread: WebKit
			// takes them on GTK's
			cookies.Watch("webkit", func(c session.Cookie, removed bool) {
				kitOnMain(func() { kit.give(c, removed) })
			})
		}
	}
	return kit
}

func kitOnMain(f func()) { C.lwkOnMain(C.uintptr_t(cgo.NewHandle(f))) }

//export lwkGoRun
func lwkGoRun(h C.uintptr_t) {
	hh := cgo.Handle(h)
	f := hh.Value().(func())
	hh.Delete()
	f()
}

func cstr(s string, f func(*C.char)) {
	c := C.CString(s)
	defer C.free(unsafe.Pointer(c))
	f(c)
}

func (e *KitEngine) Start(window uintptr, dataDir string, low bool, ready func(error)) {
	if window == 0 {
		ready(errors.New("WebKit has no window"))
		return
	}
	// IRIS_NO_SANDBOX=1 is the reader's own choice to run pages without
	// their sandbox (as for Electron); otherwise a system where WebKit's
	// sandbox cannot run gets no WebKit: Electron draws every page there
	if os.Getenv("IRIS_NO_SANDBOX") != "" {
		os.Setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1")
	} else if C.lwkSandboxWorks() == 0 {
		ready(errors.New("WebKit's page sandbox (bubblewrap) cannot run on this system"))
		return
	}
	cstr(dataDir, func(d *C.char) { C.lwkStart(C.uintptr_t(window), d) })
	v := C.lwkVersion()
	e.version = "WebKitGTK " + C.GoString(v)
	C.free(unsafe.Pointer(v))
	e.started = true
	e.apply()
	ready(nil)
}

func (e *KitEngine) Version() string   { return e.version }
func (e *KitEngine) MemoryMB() float64 { return float64(C.lwkMemoryKB()) / 1024 }

func (e *KitEngine) SetPolicy(p Policy) {
	e.mu.Lock()
	e.policy = p
	e.mu.Unlock()
	if e.started {
		e.apply()
	}
}

func (e *KitEngine) pol() Policy {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.policy
}

// apply hands the policy's scripts and shield to WebKit (on GTK's thread).
func (e *KitEngine) apply() {
	p := e.pol()
	C.lwkStrict(b2i(p.Strict))
	if js := strings.Join(p.Scripts, "\x00"); js != e.scripts {
		e.scripts = js
		cs := make([]*C.char, len(p.Scripts))
		for i, s := range p.Scripts {
			cs[i] = C.CString(s)
		}
		if len(cs) > 0 {
			C.lwkSetScripts(&cs[0], C.int(len(cs)))
		} else {
			C.lwkSetScripts(nil, 0)
		}
		for _, c := range cs {
			C.free(unsafe.Pointer(c))
		}
	}
	e.RefreshRules()
}

// RefreshRules compiles the shield's rules again when they changed (new
// filter lists, a site's shield turned off). It runs on GTK's thread.
func (e *KitEngine) RefreshRules() {
	rules := e.pol().ContentRules
	if rules == nil || !e.started {
		return
	}
	go func() {
		js := string(rules()) // building the list takes a moment: not on GTK's thread
		kitOnMain(func() {
			if js == e.rules {
				return
			}
			e.rules = js
			h := fnv.New64a()
			h.Write([]byte(js))
			id := "iris-shields-" + strconv.FormatUint(h.Sum64(), 36)
			cstr(js, func(c *C.char) { cstr(id, func(ci *C.char) { C.lwkSetRules(c, C.int(len(js)), ci) }) })
		})
	}()
}

//export lwkGoFilterReady
func lwkGoFilterReady(ok C.int) {}

func b2i(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

// jar is the index of WebKit's session for options o, made (and filled
// from the shared store) the first time.
func (e *KitEngine) jar(o Options) int {
	name := session.JarFor(o.Profile, o.Private, o.Sandbox)
	if i, ok := e.jars[name]; ok {
		return i
	}
	bridged := e.cookies != nil && !o.Sandbox
	var i C.int
	cstr(name, func(c *C.char) { i = C.lwkJar(c, b2i(session.Memory(name)), b2i(bridged)) })
	e.jars[name], e.names[int(i)] = int(i), name
	if bridged {
		for _, c := range e.cookies.Jar(name) {
			e.give(c, false)
		}
		C.lwkReadJar(i)
	}
	return int(i)
}

// give hands a cookie from the shared store to WebKit's session of its jar.
func (e *KitEngine) give(c session.Cookie, removed bool) {
	i, ok := e.jars[c.Jar]
	if !ok {
		return // no WebKit page uses that jar yet; it is filled when one does
	}
	if s := e.seen[i]; s != nil {
		// what WebKit will report back is already known: no echo
		if removed {
			delete(s, c.Key())
		} else {
			s[c.Key()] = c
		}
	}
	n, v, d, p, ss := C.CString(c.Name), C.CString(c.Value), C.CString(c.Domain), C.CString(c.Path), C.CString(c.SameSite)
	C.lwkSetCookie(C.int(i), n, v, d, b2i(c.HostOnly), p, C.longlong(c.Expires), b2i(c.Secure), b2i(c.HTTPOnly), ss, b2i(removed))
	for _, s := range []*C.char{n, v, d, p, ss} {
		C.free(unsafe.Pointer(s))
	}
}

//export lwkGoCookies
func lwkGoCookies(idx C.int, lines *C.char) {
	e := kit
	if e == nil || e.cookies == nil {
		return
	}
	jar := e.names[int(idx)]
	var cur []session.Cookie
	for _, ln := range strings.Split(C.GoString(lines), "\n") {
		f := strings.Split(ln, "\t")
		if len(f) != 9 {
			continue
		}
		exp, _ := strconv.ParseInt(f[5], 10, 64)
		ss := f[8]
		if ss == "None" {
			ss = ""
		}
		cur = append(cur, session.Cookie{Jar: jar, Name: f[0], Value: f[1], Domain: strings.ToLower(f[2]), HostOnly: f[3] == "1",
			Path: f[4], Expires: exp, Secure: f[6] == "1", HTTPOnly: f[7] == "1", SameSite: ss})
	}
	e.seen[int(idx)] = e.cookies.Diff("webkit", e.seen[int(idx)], cur)
}

func (e *KitEngine) NewView(o Options, ev Events, done func(View, error)) {
	if !e.started {
		done(nil, errors.New("WebKit is not running"))
		return
	}
	kitNext++
	v := &kitView{id: kitNext, e: e, ev: ev, o: o, jar: e.jar(o)}
	var popup C.uintptr_t
	if o.Popup != nil {
		popup = C.uintptr_t(o.Popup.impl.kit)
		o.Popup.impl.kit = 0
	}
	if C.lwkOpen(C.uintptr_t(v.id), C.int(v.jar), b2i(o.Sandbox), popup) == 0 {
		if popup != 0 {
			C.lwkDrop(popup)
		}
		done(nil, errors.New("WebKit could not make the page"))
		return
	}
	kitViews[v.id] = v
	done(v, nil)
}

// SetDivert is the router's question before each navigation of the page's
// own: true moves the tab to Electron (webview/route).
func (v *kitView) SetDivert(f func(string) bool) { v.divert = f }

func (v *kitView) Navigate(u string) {
	if v.closed {
		return
	}
	cstr(u, func(c *C.char) { C.lwkNavigate(C.uintptr_t(v.id), c) })
}
func (v *kitView) Back()    { C.lwkBack(C.uintptr_t(v.id)) }
func (v *kitView) Forward() { C.lwkForward(C.uintptr_t(v.id)) }
func (v *kitView) Reload()  { C.lwkReload(C.uintptr_t(v.id)) }
func (v *kitView) Stop()    { C.lwkStop(C.uintptr_t(v.id)) }
func (v *kitView) SetBounds(x, y, w, h int) {
	C.lwkBounds(C.uintptr_t(v.id), C.int(x), C.int(y), C.int(w), C.int(h))
}
func (v *kitView) SetVisible(on bool) { C.lwkShow(C.uintptr_t(v.id), b2i(on)) }
func (v *kitView) Sleep()             { v.SetVisible(false) }
func (v *kitView) Wake()              {}
func (v *kitView) Focus()             { C.lwkFocus(C.uintptr_t(v.id)) }
func (v *kitView) Eval(js string)     { cstr(js, func(c *C.char) { C.lwkRun(C.uintptr_t(v.id), c, 0) }) }
func (v *kitView) SetMuted(on bool)   { C.lwkMute(C.uintptr_t(v.id), b2i(on)) }
func (v *kitView) SetZoom(f float64)  { C.lwkZoom(C.uintptr_t(v.id), C.double(f)) }
func (v *kitView) SetBackground(bool) {} // WebKit stops drawing a hidden page by itself

func (v *kitView) Run(js string, done func(string)) {
	kitRunN++
	kitRuns[kitRunN] = done
	n := kitRunN
	cstr(js, func(c *C.char) { C.lwkRun(C.uintptr_t(v.id), c, C.uintptr_t(n)) })
}

//export lwkGoResult
func lwkGoResult(token C.uintptr_t, js *C.char) {
	if f := kitRuns[uintptr(token)]; f != nil {
		delete(kitRuns, uintptr(token))
		f(C.GoString(js))
	}
}

func (v *kitView) Close() {
	if v.closed {
		return
	}
	v.closed = true
	delete(kitViews, v.id)
	C.lwkClose(C.uintptr_t(v.id))
}

func kitGet(id C.uintptr_t) *kitView { return kitViews[uintptr(id)] }

//export lwkGoURL
func lwkGoURL(id C.uintptr_t, u *C.char) {
	if v := kitGet(id); v != nil {
		v.url = C.GoString(u)
		if v.ev.URL != nil && v.url != "" {
			v.ev.URL(v.url)
		}
	}
}

//export lwkGoTitle
func lwkGoTitle(id C.uintptr_t, t *C.char) {
	if v := kitGet(id); v != nil && v.ev.Title != nil {
		v.ev.Title(C.GoString(t))
	}
}

//export lwkGoLoading
func lwkGoLoading(id C.uintptr_t, on, back, fwd C.int) {
	v := kitGet(id)
	if v == nil {
		return
	}
	if v.ev.Loading != nil {
		v.ev.Loading(on != 0)
	}
	if v.ev.History != nil {
		v.ev.History(back != 0, fwd != 0)
	}
}

// lwkGoDecide is asked before every navigation of a page: 1 stops it
// (Iris opened it elsewhere, rewrote it, or stopped it).
//
//export lwkGoDecide
func lwkGoDecide(id C.uintptr_t, cu *C.char, newWindow, userLink, middle C.int) C.int {
	v := kitGet(id)
	if v == nil {
		return 0
	}
	u := C.GoString(cu)
	p := v.e.pol()
	if newWindow != 0 || middle != 0 {
		if newWindow != 0 && userLink == 0 {
			return 0 // a script's window.open: a pop-up of this page (onCreate)
		}
		if v.ev.NewTab != nil {
			v.ev.NewTab(u, nil)
		}
		return 1
	}
	if p.Rewrite != nil {
		if c := p.Rewrite(u); c != "" && c != u {
			v.Navigate(c)
			return 1
		}
	}
	if userLink != 0 && v.ev.NewTab != nil && p.NewTabFor != nil && v.url != "" && p.NewTabFor(v.url, u) {
		v.ev.NewTab(u, nil) // a link to another website: a new tab beside this one
		return 1
	}
	if !v.o.Sandbox {
		stop := p.HTTPSOnly && strings.HasPrefix(strings.ToLower(u), "http://") && (p.AllowInsecure == nil || !p.AllowInsecure(u))
		if !stop && p.Unsafe != nil {
			stop = p.Unsafe(u)
		}
		if stop {
			if v.ev.Insecure != nil {
				v.ev.Insecure(u)
			}
			return 1
		}
	}
	if v.divert != nil && v.divert(u) {
		return 1 // the router moves the tab to Electron, which opens u
	}
	return 0
}

//export lwkGoNewWindow
func lwkGoNewWindow(id C.uintptr_t, cu *C.char, popup C.uintptr_t) {
	v := kitGet(id)
	if v == nil || v.ev.NewTab == nil {
		C.lwkDrop(popup)
		return
	}
	u := C.GoString(cu)
	v.ev.NewTab(u, &Popup{URL: u, impl: popupImpl{kit: uintptr(popup)}})
}

//export lwkGoFullscreen
func lwkGoFullscreen(id C.uintptr_t, on C.int) {
	if v := kitGet(id); v != nil && v.ev.Fullscreen != nil {
		v.ev.Fullscreen(on != 0)
	}
}

//export lwkGoCrashed
func lwkGoCrashed(id C.uintptr_t) {
	if v := kitGet(id); v != nil && v.ev.Crashed != nil {
		v.ev.Crashed()
	}
}

//export lwkGoFailed
func lwkGoFailed(id C.uintptr_t, u *C.char, code C.int) {
	if v := kitGet(id); v != nil && v.ev.Failed != nil {
		v.ev.Failed(C.GoString(u), int(code))
	}
}

//export lwkGoAudio
func lwkGoAudio(id C.uintptr_t, on C.int) {
	if v := kitGet(id); v != nil && v.ev.Audio != nil {
		v.ev.Audio(on != 0)
	}
}

//export lwkGoKey
func lwkGoKey(id C.uintptr_t, ch, vk, ctrl, shift, alt C.int) C.int {
	v := kitGet(id)
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

//export lwkGoFocus
func lwkGoFocus(id C.uintptr_t) {
	if v := kitGet(id); v != nil && v.ev.Focus != nil {
		v.ev.Focus()
	}
}

//export lwkGoDownload
func lwkGoDownload(n, id C.uintptr_t, state C.int, u, path *C.char, total, got C.longlong) {
	e := kit
	if e == nil {
		return
	}
	p := e.pol()
	if p.Download == nil {
		return
	}
	d := Download{ID: 1_000_000 + int(n), URL: C.GoString(u), Path: C.GoString(path), Total: int64(total), Received: int64(got),
		State: DownloadState(state)}
	if v := kitGet(id); v != nil {
		d.View = v
	}
	nn := n
	d.Cancel = func() { C.lwkCancelDownload(nn) }
	p.Download(d)
}
