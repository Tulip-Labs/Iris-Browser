//go:build linux && webkit && servo

// Package servo is Iris's light engine on Linux: Servo (servo.org), drawing
// articles, Wikipedia, search and docs in Iris's own process, with nothing to
// start. The router (webview/route) gives it the pages it can draw and the
// rest to Chromium. Its frames are drawn in the GTK window like Chromium's
// (servo_linux.c); its requests pass Iris Shields; its cookies are shared
// with Chromium through Iris's own store (core/session).
package servo

/*
#cgo pkg-config: gtk4
#cgo LDFLAGS: -L${SRCDIR}/lib -lirisservo -Wl,-rpath,$ORIGIN
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
void lsvTicks(void);
*/
import "C"

import (
	"bufio"
	"errors"
	"log"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"iris/core/session"
	"iris/webview"
)

// Version is the Servo Iris carries (rust/Cargo.toml).
const Version = "Servo 0.4.0"

// Engine is the Servo engine; one per program.
type Engine struct {
	mu      sync.Mutex
	policy  webview.Policy
	started bool
	// Cookies is the store shared with Chromium (nil: Servo keeps its own).
	Cookies *session.Store
	budget  float64 // MB Iris's own process may use before Servo tabs rest
}

var (
	eng     *Engine
	views   = map[uint64]*view{} // the pages open in Servo, by number
	all     = map[*view]bool{}   // every Servo view, rested ones included
	nextID  uint64
	runs    = map[uint64]func(string){}
	nextRun uint64
)

// New returns the Servo engine.
func New(cookies *session.Store) *Engine {
	if eng == nil {
		eng = &Engine{Cookies: cookies}
	}
	return eng
}

func (e *Engine) Start(window uintptr, dataDir string, low bool, ready func(error)) {
	if C.lsvStart(C.uintptr_t(window)) == 0 {
		ready(errors.New("Servo could not start"))
		return
	}
	e.started = true
	e.budget = budgetMB()
	C.lsvTicks() // the memory check, every 10 seconds (lsvGoTick)
	ready(nil)
}

func (e *Engine) SetPolicy(p webview.Policy) {
	e.mu.Lock()
	e.policy = p
	e.mu.Unlock()
}

func (e *Engine) pol() webview.Policy {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.policy
}

func (e *Engine) MemoryMB() float64 { return 0 } // inside Iris's own process: counted there
func (e *Engine) Version() string   { return Version }

func (e *Engine) NewView(o webview.Options, ev webview.Events, done func(webview.View, error)) {
	if !e.started {
		done(nil, errors.New("Servo is not running"))
		return
	}
	// The page is made in Servo with its first address, not before: a load
	// sent to a page Servo has just made without one was lost (Servo's
	// constellation did not know the page yet: "LoadUrl for unknown browsing
	// context") and the tab stayed on about:blank. Until then it waits like a
	// rested page.
	v := &view{ev: ev, o: o, seen: time.Now(), rested: true}
	all[v] = true
	done(v, nil)
}

// view is one Servo page.
type view struct {
	id     uint64
	ev     webview.Events
	o      webview.Options
	url    string
	shown  bool
	closed bool
	divert func(string) bool
	going  string    // the address Iris itself asked for (not diverted)
	rested bool      // the page was let go to save memory; it comes back when shown
	seen   time.Time // when it was last on screen
	bounds [4]int
}

func (v *view) SetDivert(f func(string) bool) { v.divert = f }

// open makes the page in Servo (under a new number: a rested page's old one
// is gone), at address u ("" for none).
func (v *view) open(u string) bool {
	nextID++
	v.id = nextID
	views[v.id] = v
	ok := true
	cstr(u, func(cu *C.char) { ok = C.lsvOpen(C.uint64_t(v.id), cu) != 0 })
	if !ok {
		delete(views, v.id)
	}
	return ok
}

// rest lets the page go to give its memory back; it opens again at its
// address when it is shown (Iris's tab keeps its place and title).
func (v *view) rest() {
	if v.rested || v.closed {
		return
	}
	v.keep(v.url)
	delete(views, v.id)
	C.lsvClose(C.uint64_t(v.id))
	v.rested = true
}

// revive opens a rested page again where it was.
func (v *view) revive() {
	if !v.rested || v.closed || v.url == "" {
		return // (no address yet: it opens with its first one)
	}
	v.rested = false
	if v.url != "" {
		v.share(v.url)
	}
	if !v.open(v.url) {
		return
	}
	v.going = v.url
	if b := v.bounds; b[2] > 0 {
		C.lsvBounds(C.uint64_t(v.id), C.int(b[0]), C.int(b[1]), C.int(b[2]), C.int(b[3]))
	}
	if v.shown {
		C.lsvShow(C.uint64_t(v.id), 1) // its tab is on screen already
	}
}

func cstr(s string, f func(*C.char)) {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	f(cs)
}

// share gives Servo the cookies Iris has for u.
func (v *view) share(u string) {
	if eng == nil || eng.Cookies == nil {
		return
	}
	for _, c := range eng.Cookies.For("", u) {
		line := c.SetCookie()
		cstr(u, func(cu *C.char) { cstr(line, func(cl *C.char) { C.iris_servo_set_cookie(cu, cl) }) })
	}
}

// keep takes the cookies Servo has for u into Iris's store.
func (v *view) keep(u string) {
	if eng == nil || eng.Cookies == nil || u == "" || !strings.HasPrefix(u, "http") {
		return
	}
	var s *C.char
	cstr(u, func(cu *C.char) { s = C.iris_servo_cookies(cu) })
	if s == nil {
		return
	}
	lines := C.GoString(s)
	C.iris_servo_free(s)
	for _, l := range strings.Split(lines, "\n") {
		if l != "" {
			eng.Cookies.SetFromHeader("", u, l)
		}
	}
}

func (v *view) Navigate(u string) {
	if v.closed {
		return
	}
	if v.rested {
		v.url = u
		v.revive()
		return
	}
	v.going = u
	v.share(u)
	cstr(u, func(cu *C.char) { C.iris_servo_load(C.uint64_t(v.id), cu) })
	C.lsvWake()
}

func (v *view) Back()    { C.iris_servo_back(C.uint64_t(v.id)); C.lsvWake() }
func (v *view) Forward() { C.iris_servo_forward(C.uint64_t(v.id)); C.lsvWake() }
func (v *view) Reload()  { C.iris_servo_reload(C.uint64_t(v.id)); C.lsvWake() }
func (v *view) Stop()    {}

func (v *view) SetBounds(x, y, w, h int) {
	v.bounds = [4]int{x, y, w, h}
	if v.rested {
		return
	}
	C.lsvBounds(C.uint64_t(v.id), C.int(x), C.int(y), C.int(w), C.int(h))
}

func (v *view) SetVisible(on bool) {
	v.shown = on
	v.seen = time.Now()
	if on {
		v.revive()
	}
	if v.rested {
		return // not in Servo (yet, or any more)
	}
	b := 0
	if on {
		b = 1
	}
	C.lsvShow(C.uint64_t(v.id), C.int(b))
}

func (v *view) Sleep()         { v.SetVisible(false) }
func (v *view) Wake()          {}
func (v *view) Focus()         { C.lsvFocus(C.uint64_t(v.id)) }
func (v *view) Eval(js string) { v.Run(js, func(string) {}) }

func (v *view) Run(js string, done func(string)) {
	nextRun++
	runs[nextRun] = done
	tok := nextRun
	cstr(js, func(cj *C.char) { C.iris_servo_eval(C.uint64_t(v.id), cj, C.uint64_t(tok)) })
	C.lsvWake()
}

func (v *view) SetMuted(bool)      {} // no sound in Servo pages here (no media back end)
func (v *view) SetZoom(f float64)  { C.iris_servo_zoom(C.uint64_t(v.id), C.float(f)); C.lsvWake() }
func (v *view) SetBackground(bool) {}

func (v *view) Close() {
	if v.closed {
		return
	}
	if !v.rested {
		v.keep(v.url)
		delete(views, v.id)
		C.lsvClose(C.uint64_t(v.id))
	}
	v.closed = true
	delete(all, v)
}

// ---- keeping Servo small (docs/engines.md) ----
//
// Servo runs in Iris's own process. Every 10 seconds Iris reads its own
// memory (/proc/self) and:
//   - lets go of Servo pages hidden for more than a minute (a tab's page comes
//     back at its address when the tab is shown again);
//   - above the budget (a sixth of the computer's memory, 600 MB at least),
//     lets go of hidden pages at once, the longest hidden first.
// Servo 0.4's embedding API has no call to drop its caches, nor to shut it
// down and start it again in the same process: when no light tab is left,
// its pages are all closed, which frees what they hold; the engine itself
// stays, idle.

const restAfter = time.Minute

// rssMB is this process's resident memory.
func rssMB() float64 {
	b, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) < 2 {
		return 0
	}
	pages, _ := strconv.ParseFloat(f[1], 64)
	return pages * float64(os.Getpagesize()) / (1 << 20)
}

// budgetMB is what Iris's own process may use before hidden Servo pages rest.
func budgetMB() float64 {
	if s := os.Getenv("IRIS_SERVO_BUDGET_MB"); s != "" {
		if v, err := strconv.ParseFloat(s, 64); err == nil && v > 0 {
			return v
		}
	}
	total := 8192.0
	if f, err := os.Open("/proc/meminfo"); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if fs := strings.Fields(sc.Text()); len(fs) >= 2 && fs[0] == "MemTotal:" {
				kb, _ := strconv.ParseFloat(fs[1], 64)
				total = kb / 1024
			}
		}
		f.Close()
	}
	return max(600, total/6)
}

//export lsvGoTick
func lsvGoTick() {
	if eng == nil {
		return
	}
	now := time.Now()
	rss := rssMB()
	var hidden []*view
	shown := 0
	for _, v := range views {
		if v.closed || v.rested {
			continue
		}
		if v.shown {
			shown++
			v.seen = now
			continue
		}
		hidden = append(hidden, v)
	}
	sort.Slice(hidden, func(i, j int) bool { return hidden[i].seen.Before(hidden[j].seen) })
	over := rss > eng.budget
	for _, v := range hidden {
		if over || now.Sub(v.seen) >= restAfter {
			v.rest()
		}
	}
	if os.Getenv("IRIS_GL_DEBUG") != "" {
		rested := 0
		for v := range all {
			if v.rested && !v.closed {
				rested++
			}
		}
		log.Printf("Iris: memory %.0f MB (budget %.0f), Servo pages: %d shown, %d hidden, %d rested", rss, eng.budget, shown, len(hidden), rested)
	}
}

// ---- what Servo reports (servo_linux.c) ----

const (
	evURL     = 1
	evTitle   = 2
	evLoading = 3
	evHistory = 4
	evCrashed = 5
	evNewTab  = 6
	evLoaded  = 8
	evHead    = 9
)

//export lsvGoEvent
func lsvGoEvent(id C.uint64_t, kind C.int, text *C.char, a, b C.int) {
	v := views[uint64(id)]
	if v == nil {
		return
	}
	t := C.GoString(text)
	switch kind {
	case evURL:
		v.url = t
		if v.ev.URL != nil {
			v.ev.URL(t)
		}
	case evTitle:
		if v.ev.Title != nil {
			v.ev.Title(t)
		}
	case evLoading:
		if v.ev.Loading != nil {
			v.ev.Loading(a != 0)
		}
	case evHistory:
		if v.ev.History != nil {
			v.ev.History(a != 0, b != 0)
		}
	case evCrashed:
		log.Println("Iris: Servo stopped on", v.url+":", t)
		if v.ev.Crashed != nil {
			v.ev.Crashed()
		}
	case evNewTab:
		if v.ev.NewTab != nil {
			v.ev.NewTab(t, nil)
		}
	case evLoaded:
		v.keep(v.url)
	case evHead:
		for _, js := range eng.pol().Scripts {
			v.Eval(js)
		}
	}
}

//export lsvGoAllow
func lsvGoAllow(id C.uint64_t, url, page, kind *C.char) C.int {
	if eng == nil {
		return 1
	}
	p := eng.pol()
	k := C.GoString(kind)
	if k == "document" || p.Allow == nil {
		return 1
	}
	pg := C.GoString(page)
	if p.Scan != nil && !p.Scan(pg) {
		return 1 // adaptive shields: a site scanned and found clean
	}
	if p.Allow(C.GoString(url), pg, k) {
		return 1
	}
	if v := views[uint64(id)]; v != nil && v.ev.Blocked != nil {
		v.ev.Blocked(C.GoString(url))
	}
	return 0
}

//export lsvGoNavigate
func lsvGoNavigate(id C.uint64_t, url *C.char) C.int {
	v := views[uint64(id)]
	if v == nil || eng == nil {
		return 1
	}
	u := C.GoString(url)
	asked := u == v.going
	v.going = ""
	p := eng.pol()
	if !asked {
		// a link, a form or a script: a heavy site opens in Chromium
		if v.divert != nil && v.divert(u) {
			return 0
		}
		if p.NewTabFor != nil && v.url != "" && v.ev.NewTab != nil && p.NewTabFor(v.url, u) {
			v.ev.NewTab(u, nil)
			return 0
		}
	}
	if p.Rewrite != nil {
		if c := p.Rewrite(u); c != "" && c != u {
			v.Navigate(c)
			return 0
		}
	}
	stop := p.HTTPSOnly && strings.HasPrefix(strings.ToLower(u), "http://") && (p.AllowInsecure == nil || !p.AllowInsecure(u))
	if !stop && p.Unsafe != nil && !v.o.Sandbox {
		stop = p.Unsafe(u)
	}
	if stop {
		if v.ev.Insecure != nil {
			v.ev.Insecure(u)
		}
		return 0
	}
	v.share(u)
	return 1
}

//export lsvGoResult
func lsvGoResult(token C.uint64_t, json *C.char) {
	done := runs[uint64(token)]
	delete(runs, uint64(token))
	if done != nil {
		done(C.GoString(json))
	}
}

//export lsvGoKey
func lsvGoKey(id C.uint64_t, vk, ctrl, shift, alt C.int) C.int {
	v := views[uint64(id)]
	if v == nil || v.ev.Key == nil {
		return 0
	}
	if v.ev.Key(webview.Key{VK: uint32(vk), Ctrl: ctrl != 0, Shift: shift != 0, Alt: alt != 0}) {
		return 1
	}
	return 0
}

//export lsvGoFocus
func lsvGoFocus(id C.uint64_t) {
	if v := views[uint64(id)]; v != nil && v.ev.Focus != nil {
		v.ev.Focus()
	}
}

var _ webview.Engine = (*Engine)(nil)
