//go:build linux && webkit

// The Linux engine on Electron. Electron runs in a helper process
// (webview/electron/helper/main.js) that Iris starts when the first page opens
// and that quits by itself a while after the last one closes. Iris speaks to
// it over a Unix socket:
//
//	each message: length (4 bytes, little endian), kind (1 byte), payload
//	kind 0: one JSON object
//	kind 1: a frame: header length (4 bytes), JSON header, then the pixels
//
// Pages are drawn off screen by Electron at the window's scale; their frames
// come here and go to electron_linux.c, which draws them in Iris's window.
// Electron has H.264, H.265 and AAC, so every video
// plays.

package webview

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
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/cgo"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"iris/core/session"
)

const engineName = "Electron "

var hosted bool

// HostGTK tells the engine that Iris's window is made with GTK (always, here).
func HostGTK() { hosted = true }

// New returns the Linux engine on Electron.
func New() Engine {
	if wkEng == nil {
		wkEng = &wkEngine{}
	}
	return elx
}

// Installed reports whether Electron and the helper are where Iris looks.
func Installed() bool { _, _, err := helperPaths(); return err == nil }

func init() { SleepFreesMemory = false }

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

// SetColorScheme makes the pages light or dark (prefers-color-scheme).
func SetColorScheme(dark bool) {
	elx.mu.Lock()
	elx.dark = &dark
	elx.mu.Unlock()
	elx.send(msg{"t": "scheme", "dark": dark})
}

type msg map[string]any

// the engine: one helper at a time

type elxEngine struct {
	mu      sync.Mutex
	wmu     sync.Mutex // writes to the socket
	conn    net.Conn
	cmd     *exec.Cmd
	queue   [][]byte // messages waiting for the helper to connect
	running bool
	dataDir string
	low     bool
	scale   float64 // the scale the running helper draws at
	version string
	memMB   float64
	seq     int
	replies map[int]func(json.RawMessage)
	views   map[uintptr]*elxView
	pending map[uintptr]bool // popups Electron opened, waiting for Iris's view
	dark    *bool
	// the memory watch
	watching   bool
	procs      int       // the helper's processes at the last reading
	overSince  time.Time // over the budget since (zero: not over)
	restartAt  time.Time // the last restart for memory
	restarting bool      // the helper is being restarted (not a crash)
	afterMB    float64   // the memory a minute after that restart
	// the cookie bridge (core/session): the shared store, and the jars the
	// running helper already has from it
	cookies *session.Store
	jars    map[string]bool
}

type elxView struct {
	v          *wkView
	x, y, w, h int // in the window, real pixels
	shown      bool
	opened     bool // the running helper has it
	audio      bool // it plays sound
	url        string
	opts       Options
	pid        int // the helper's popup it shows (0: none)
}

var elx = &elxEngine{replies: map[int]func(json.RawMessage){}, views: map[uintptr]*elxView{}, pending: map[uintptr]bool{}}

func (e *elxEngine) Start(window uintptr, dataDir string, low bool, ready func(error)) {
	e.mu.Lock()
	e.dataDir, e.low = dataDir, low
	e.mu.Unlock()
	wkEng.mu.Lock()
	wkEng.dataDir, wkEng.low, wkEng.started = dataDir, low, true
	wkEng.mu.Unlock()
	cs := C.CString(dataDir)
	C.lgxAttach(C.uintptr_t(window), cs)
	C.free(unsafe.Pointer(cs))
	e.mu.Lock()
	if !e.watching {
		e.watching = true
		go e.watch()
	}
	e.mu.Unlock()
	ready(nil)
}

func (e *elxEngine) SetPolicy(p Policy) {
	wkEng.mu.Lock()
	wkEng.policy = p
	wkEng.mu.Unlock()
	e.send(msg{"t": "scripts", "list": p.Scripts})
}

func (e *elxEngine) MemoryMB() float64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.memMB
}

func (e *elxEngine) Version() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.version == "" {
		return engineName
	}
	return engineName + e.version
}

// helperPaths finds Electron and Iris's helper app: next to the program
// (electron/, with the helper as its app in electron/resources/app), or where IRIS_ELECTRON and
// IRIS_ELECTRON_APP say, or Electron on the PATH (Nix, Flatpak's base).
func helperPaths() (bin, app string, err error) {
	exe, _ := os.Executable()
	dir := filepath.Dir(exe)
	bin = os.Getenv("IRIS_ELECTRON")
	if bin == "" {
		if p := filepath.Join(dir, "electron", "electron"); fileExists(p) {
			bin = p
		} else if p, e := exec.LookPath("electron"); e == nil {
			bin = p
		}
	}
	app = os.Getenv("IRIS_ELECTRON_APP")
	// Iris's own Electron carries the helper as its app (resources/app): it
	// starts with no folder to load. (Opening a folder is the job of Electron's
	// default_app.asar, which Iris's Electron leaves out.)
	if app == "" && bin != "" && fileExists(filepath.Join(filepath.Dir(bin), "resources", "app", "main.js")) {
		return bin, "", nil
	}
	if app == "" {
		for _, p := range []string{filepath.Join(dir, "electron-helper"), filepath.Join(dir, "..", "share", "iris-browser", "electron-helper")} {
			if fileExists(filepath.Join(p, "main.js")) {
				app = p
				break
			}
		}
	}
	if bin == "" || app == "" {
		return "", "", errors.New("Electron or Iris's helper is missing")
	}
	return bin, app, nil
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// ensure starts the helper if it is not running; messages sent meanwhile wait.
// It runs on the window's thread (it reads the window's scale).
func (e *elxEngine) ensure() {
	e.mu.Lock()
	if e.running {
		e.mu.Unlock()
		return
	}
	e.running = true
	e.scale = float64(C.elxScale())
	if s := os.Getenv("IRIS_SCALE"); s != "" {
		if f, err := strconv.ParseFloat(s, 64); err == nil && f >= 0.5 && f <= 8 {
			e.scale = f
		}
	}
	dataDir, low, scale := e.dataDir, e.low, e.scale
	e.mu.Unlock()
	go e.run(dataDir, low, scale)
}

func (e *elxEngine) run(dataDir string, low bool, scale float64) {
	fail := func(err error) {
		fmt.Fprintln(os.Stderr, "Iris: the page engine could not start:", err)
		e.helperGone()
	}
	bin, app, err := helperPaths()
	if err != nil {
		fail(err)
		return
	}
	rt := os.Getenv("XDG_RUNTIME_DIR")
	if rt == "" {
		rt = os.TempDir()
	}
	sock := filepath.Join(rt, fmt.Sprintf("iris-electron-%d-%d.sock", os.Getpid(), time.Now().UnixNano()%1e6))
	_ = os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		fail(err)
		return
	}
	defer os.Remove(sock)
	_ = os.Chmod(sock, 0o600)
	data := filepath.Join(dataDir, "electron")
	_ = os.MkdirAll(data, 0o700)
	// Electron draws no window of its own (every page is offscreen), but it
	// still joins a display: the one Iris runs on. Left to itself it tries X11,
	// and on a Wayland-only desktop (niri, sway, a Flatpak without X) it found
	// no X server and quit at once. Wayland also lets it share frames on the
	// graphics chip; headless is the last resort.
	var args []string
	switch {
	case os.Getenv("WAYLAND_DISPLAY") != "":
		args = append(args, "--ozone-platform=wayland")
	case os.Getenv("DISPLAY") != "":
		args = append(args, "--ozone-platform=x11")
	default:
		args = append(args, "--ozone-platform=headless")
	}
	if app != "" {
		args = append(args, app)
	}
	if os.Getenv("IRIS_NO_SANDBOX") != "" {
		args = append([]string{"--no-sandbox"}, args...)
	}
	cmd := exec.Command(bin, args...)
	lowS := "0"
	if low {
		lowS = "1"
	}
	cmd.Env = append(os.Environ(), "IRIS_SOCK="+sock, "IRIS_DATA="+data, "IRIS_SCALE="+strconv.FormatFloat(scale, 'f', 4, 64),
		"IRIS_MEM="+strconv.Itoa(totalMemMB()), "IRIS_LOW="+lowS, "ELECTRON_NO_ATTACH_CONSOLE=1")
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Start(); err != nil {
		ln.Close()
		fail(err)
		return
	}
	e.mu.Lock()
	e.cmd = cmd
	e.mu.Unlock()
	go func() {
		err := cmd.Wait()
		if err != nil || os.Getenv("IRIS_GL_DEBUG") != "" {
			fmt.Fprintln(os.Stderr, "Iris: the page engine ended:", cmd.ProcessState)
		}
	}()
	type acc struct {
		c   net.Conn
		err error
	}
	ch := make(chan acc, 1)
	go func() { c, err := ln.Accept(); ch <- acc{c, err} }()
	var c net.Conn
	select {
	case a := <-ch:
		c, err = a.c, a.err
	case <-time.After(30 * time.Second):
		err = errors.New("Electron did not answer")
	}
	ln.Close()
	if err != nil {
		_ = cmd.Process.Kill()
		fail(err)
		return
	}
	e.wmu.Lock()
	e.mu.Lock()
	e.conn = c
	q := e.queue
	e.queue = nil
	e.mu.Unlock()
	for _, b := range q {
		if _, err := c.Write(b); err != nil {
			break
		}
	}
	e.wmu.Unlock()
	e.read(c)
	e.helperGone()
}

// helperGone: the helper quit (idle) or died. Pages still open report a
// crash; the next page starts a new helper, and a reload brings each back.
func (e *elxEngine) helperGone() {
	e.mu.Lock()
	e.running = false
	if e.conn != nil {
		e.conn.Close()
	}
	e.conn = nil
	e.queue = nil
	e.jars = nil // a new helper gets every jar again
	open := make([]*elxView, 0, len(e.views))
	for _, ev := range e.views {
		open = append(open, ev)
		ev.opened = false
	}
	for n, f := range e.replies {
		delete(e.replies, n)
		go f(json.RawMessage("null"))
	}
	restart := e.restarting
	e.restarting = false
	e.mu.Unlock()
	if restart {
		// a restart for memory: the tabs in front come back at once, from
		// their last address; the others when they are next shown
		onMain(func() {
			e.ensure()
			for _, ev := range open {
				if ev.shown && !ev.v.closed {
					e.reopen(ev.v)
				}
			}
		})
		return
	}
	for _, ev := range open {
		if ev.v.ev.Crashed != nil && !ev.v.closed {
			ev.v.ev.Crashed()
		}
	}
}

func frameOf(kind byte, payload []byte) []byte {
	b := make([]byte, 5+len(payload))
	binary.LittleEndian.PutUint32(b, uint32(1+len(payload)))
	b[4] = kind
	copy(b[5:], payload)
	return b
}

// send queues or writes one message; safe from any thread.
func (e *elxEngine) send(m msg) {
	p, err := json.Marshal(m)
	if err != nil {
		return
	}
	b := frameOf(0, p)
	e.wmu.Lock()
	defer e.wmu.Unlock()
	e.mu.Lock()
	c := e.conn
	if c == nil {
		if e.running {
			e.queue = append(e.queue, b)
		}
		e.mu.Unlock()
		return
	}
	e.mu.Unlock()
	_ = c.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, _ = c.Write(b)
}

// onMain runs f on the window's thread.
func onMain(f func()) { C.elxOnMain(C.uintptr_t(cgo.NewHandle(f))) }

//export elxGoRun
func elxGoRun(h C.uintptr_t) {
	hd := cgo.Handle(h)
	f := hd.Value().(func())
	hd.Delete()
	f()
}

// ask sends m with a reply number; done gets the reply (null if the helper
// went away), on the window's thread.
func (e *elxEngine) ask(m msg, done func(json.RawMessage)) {
	e.mu.Lock()
	e.seq++
	n := e.seq
	e.replies[n] = func(r json.RawMessage) { onMain(func() { done(r) }) }
	e.mu.Unlock()
	m["n"] = n
	e.send(m)
}

// read handles the helper's messages until the socket closes.
func (e *elxEngine) read(c net.Conn) {
	r := bufio.NewReaderSize(c, 1<<20)
	var hdr [5]byte
	for {
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			return
		}
		n := int(binary.LittleEndian.Uint32(hdr[:4])) - 1
		if n < 0 || n > 512<<20 {
			return
		}
		switch hdr[4] {
		case 0:
			p := make([]byte, n)
			if _, err := io.ReadFull(r, p); err != nil {
				return
			}
			e.handle(p)
		case 1:
			if err := e.frame(r, n); err != nil {
				return
			}
		default:
			if _, err := r.Discard(n); err != nil {
				return
			}
		}
	}
}

func (e *elxEngine) frame(r *bufio.Reader, n int) error {
	var lb [4]byte
	if _, err := io.ReadFull(r, lb[:]); err != nil {
		return err
	}
	hl := int(binary.LittleEndian.Uint32(lb[:]))
	if hl <= 0 || hl > n-4 {
		return errors.New("bad frame")
	}
	hb := make([]byte, hl)
	if _, err := io.ReadFull(r, hb); err != nil {
		return err
	}
	var h struct {
		ID         uintptr `json:"id"`
		FW         int     `json:"fw"`
		FH         int     `json:"fh"`
		X, Y, W, H int
	}
	_ = json.Unmarshal(hb, &h)
	np := n - 4 - hl
	if np <= 0 {
		return nil
	}
	pix := C.malloc(C.size_t(np))
	if _, err := io.ReadFull(r, unsafe.Slice((*byte)(pix), np)); err != nil {
		C.free(pix)
		return err
	}
	if h.W <= 0 || h.H <= 0 || h.W*h.H*4 > np || h.FW <= 0 || h.FH <= 0 {
		C.free(pix)
		return nil
	}
	C.elxPaint(C.uintptr_t(h.ID), C.int(h.FW), C.int(h.FH), C.int(h.X), C.int(h.Y), C.int(h.W), C.int(h.H), C.int(h.W*4), pix)
	return nil
}

// in is a message from the helper (fields used by one kind or another).
type in struct {
	T       string          `json:"t"`
	ID      uintptr         `json:"id"`
	N       int             `json:"n"`
	URL     string          `json:"url"`
	Title   string          `json:"title"`
	On      bool            `json:"on"`
	Back    bool            `json:"back"`
	Fwd     bool            `json:"fwd"`
	Name    string          `json:"name"`
	Type    string          `json:"type"`
	Page    string          `json:"page"`
	Main    bool            `json:"main"`
	Code    int             `json:"code"`
	PID     int             `json:"pid"`
	X       float64         `json:"x"`
	Y       float64         `json:"y"`
	Items   []menuItemIn    `json:"items"`
	Path    string          `json:"path"`
	Total   int64           `json:"total"`
	Got     int64           `json:"got"`
	State   int             `json:"state"`
	MB      float64         `json:"mb"`
	R       json.RawMessage `json:"r"`
	Version string          `json:"version"`
	Jar     *string         `json:"jar"`
	C       *elxCookie      `json:"c"`
	Rm      bool            `json:"rm"`
}

// elxCookie is a cookie as the helper and Iris pass it.
type elxCookie struct {
	Name     string `json:"name"`
	Value    string `json:"value"`
	Domain   string `json:"domain"`
	HostOnly bool   `json:"hostOnly"`
	Path     string `json:"path"`
	Expires  int64  `json:"expires"`
	Secure   bool   `json:"secure"`
	HTTPOnly bool   `json:"httpOnly"`
	SameSite string `json:"sameSite"`
}

func cookieOf(jar string, c *elxCookie) session.Cookie {
	return session.Cookie{Jar: jar, Name: c.Name, Value: c.Value, Domain: strings.ToLower(c.Domain), HostOnly: c.HostOnly, Path: c.Path,
		Expires: c.Expires, Secure: c.Secure, HTTPOnly: c.HTTPOnly, SameSite: c.SameSite}
}

func elxCookieOf(c session.Cookie) elxCookie {
	return elxCookie{Name: c.Name, Value: c.Value, Domain: c.Domain, HostOnly: c.HostOnly, Path: c.Path, Expires: c.Expires,
		Secure: c.Secure, HTTPOnly: c.HTTPOnly, SameSite: c.SameSite}
}

// jarMsg names a jar the way the helper's sessions are named.
func jarMsg(jar string) msg {
	m := msg{"t": "cookies"}
	switch {
	case jar == "private":
		m["private"] = true
	case strings.HasPrefix(jar, "c-"):
		m["profile"] = jar[2:]
	}
	return m
}

// SetCookies joins Electron to the cookie bridge: what its pages set goes to
// the shared store, and what the other engine sets comes here.
func SetCookies(s *session.Store) {
	elx.mu.Lock()
	elx.cookies = s
	elx.mu.Unlock()
	s.Watch("electron", func(c session.Cookie, removed bool) {
		elx.mu.Lock()
		has := elx.jars[c.Jar] && elx.running
		elx.mu.Unlock()
		if !has {
			return // the helper gets the whole jar when a page first needs it
		}
		m := jarMsg(c.Jar)
		if removed {
			m["del"] = []elxCookie{elxCookieOf(c)}
		} else {
			m["set"] = []elxCookie{elxCookieOf(c)}
		}
		elx.send(m)
	})
}

// fillJar gives the running helper a jar's cookies before its first page.
func (e *elxEngine) fillJar(o Options) {
	if o.Sandbox {
		return
	}
	jar := session.JarFor(o.Profile, o.Private, false)
	e.mu.Lock()
	s := e.cookies
	if s == nil || e.jars[jar] {
		e.mu.Unlock()
		return
	}
	if e.jars == nil {
		e.jars = map[string]bool{}
	}
	e.jars[jar] = true
	e.mu.Unlock()
	cs := s.Jar(jar)
	set := make([]elxCookie, len(cs))
	for i, c := range cs {
		set[i] = elxCookieOf(c)
	}
	m := jarMsg(jar)
	m["set"] = set
	e.send(m)
}

type menuItemIn struct {
	C int    `json:"c"`
	L string `json:"l"`
	E bool   `json:"e"`
}

func (e *elxEngine) view(id uintptr) (*wkView, *elxView) {
	v := wkGet(id)
	e.mu.Lock()
	ev := e.views[id]
	e.mu.Unlock()
	return v, ev
}

func (e *elxEngine) handle(p []byte) {
	var m in
	if err := json.Unmarshal(p, &m); err != nil {
		return
	}
	switch m.T {
	case "cookie":
		e.mu.Lock()
		s := e.cookies
		e.mu.Unlock()
		if s != nil && m.Jar != nil && m.C != nil {
			s.Report("electron", cookieOf(*m.Jar, m.C), m.Rm)
		}
	case "hello":
		e.mu.Lock()
		e.version = m.Version
		dark := e.dark
		e.mu.Unlock()
		wkEng.mu.Lock()
		scripts := wkEng.policy.Scripts
		wkEng.mu.Unlock()
		e.send(msg{"t": "scripts", "list": scripts})
		if dark != nil {
			e.send(msg{"t": "scheme", "dark": *dark})
		}
	case "reply":
		e.mu.Lock()
		f := e.replies[m.N]
		delete(e.replies, m.N)
		e.mu.Unlock()
		if f != nil {
			f(m.R)
		}
	case "url":
		if v, ev := e.view(m.ID); v != nil {
			v.url = m.URL
			if ev != nil {
				e.mu.Lock()
				ev.url = m.URL
				e.mu.Unlock()
			}
			if v.ev.URL != nil {
				v.ev.URL(m.URL)
			}
		}
	case "title":
		if v, _ := e.view(m.ID); v != nil && v.ev.Title != nil {
			v.ev.Title(m.Title)
		}
	case "loading":
		if v, _ := e.view(m.ID); v != nil {
			if v.ev.Loading != nil {
				v.ev.Loading(m.On)
			}
			if v.ev.History != nil {
				v.ev.History(m.Back, m.Fwd)
			}
		}
	case "failed":
		if v, _ := e.view(m.ID); v != nil && v.ev.Failed != nil {
			v.ev.Failed(m.URL, m.Code)
		}
	case "crashed":
		if v, _ := e.view(m.ID); v != nil && v.ev.Crashed != nil {
			v.ev.Crashed()
		}
	case "audio":
		v, ev := e.view(m.ID)
		if ev != nil {
			e.mu.Lock()
			ev.audio = m.On
			e.mu.Unlock()
		}
		if v != nil && v.ev.Audio != nil {
			v.ev.Audio(m.On)
		}
	case "full":
		if v, _ := e.view(m.ID); v != nil && v.ev.Fullscreen != nil {
			v.ev.Fullscreen(m.On)
		}
	case "cursor":
		cs := C.CString(m.Name)
		C.elxCursor(C.uintptr_t(m.ID), cs)
		C.free(unsafe.Pointer(cs))
	case "req":
		act, to := e.decideRequest(m)
		e.send(msg{"t": "reqr", "n": m.N, "a": act, "u": to})
	case "nav":
		// a click to another site, held by the helper: a new tab, or on here
		v, _ := e.view(m.ID)
		if v == nil {
			return
		}
		wkEng.mu.Lock()
		nt := wkEng.policy.NewTabFor
		wkEng.mu.Unlock()
		if v.ev.NewTab != nil && nt != nil && v.url != "" && nt(v.url, m.URL) {
			v.ev.NewTab(m.URL, nil)
			return
		}
		e.send(msg{"t": "nav", "id": m.ID, "url": m.URL})
	case "newtab":
		if v, _ := e.view(m.ID); v != nil && v.ev.NewTab != nil {
			v.ev.NewTab(m.URL, nil)
		}
	case "popup":
		v, _ := e.view(m.ID)
		if v == nil || v.ev.NewTab == nil {
			e.send(msg{"t": "unpop", "pid": m.PID})
			return
		}
		nv := &wkView{private: v.private, sandbox: v.sandbox}
		nid := wkAdd(nv)
		nv.native = nid
		e.mu.Lock()
		e.views[nid] = &elxView{v: nv, pid: m.PID, opts: Options{Private: v.private, Sandbox: v.sandbox}}
		e.pending[nid] = true
		e.mu.Unlock()
		e.send(msg{"t": "bind", "pid": m.PID, "id": nid})
		v.ev.NewTab(m.URL, &Popup{URL: m.URL, impl: popupImpl{native: nid, id: nid}})
	case "menu":
		e.menu(m)
	case "dl":
		e.download(m)
	case "focus":
		if v, _ := e.view(m.ID); v != nil && v.ev.Focus != nil {
			v.ev.Focus()
		}
	}
}

// decideRequest answers the helper's question about a request: "" to let it
// go, "cancel", or "redirect" to address to.
func (e *elxEngine) decideRequest(m in) (string, string) {
	v := wkGet(m.ID)
	if v == nil || wkEng == nil {
		return "", ""
	}
	if m.Main {
		switch r := wkEng.decide(v, m.URL); r {
		case "":
			return "", ""
		case "-":
			return "cancel", ""
		default:
			return "redirect", r
		}
	}
	if v.sandbox {
		return "", ""
	}
	wkEng.mu.Lock()
	p := wkEng.policy
	wkEng.mu.Unlock()
	if p.Allow == nil || (p.Scan != nil && !p.Scan(m.Page)) {
		return "", ""
	}
	if p.Allow(m.URL, m.Page, kindOf(m.Type)) {
		return "", ""
	}
	if v.ev.Blocked != nil {
		v.ev.Blocked(m.URL)
	}
	return "cancel", ""
}

// kindOf turns Electron's resource types into the shield's kinds.
func kindOf(t string) string {
	switch t {
	case "script":
		return "script"
	case "image":
		return "image"
	case "media":
		return "media"
	case "xhr":
		return "xmlhttprequest"
	case "ping", "cspReport":
		return "ping"
	}
	return "other"
}

func (e *elxEngine) menu(m in) {
	v, ev := e.view(m.ID)
	if v == nil || v.ev.Menu == nil || len(m.Items) == 0 {
		e.send(msg{"t": "menuc", "id": m.ID, "c": -1})
		return
	}
	e.mu.Lock()
	s := e.scale
	bx, by := 0, 0
	if ev != nil {
		bx, by = ev.x, ev.y
	}
	e.mu.Unlock()
	if s <= 0 {
		s = 1
	}
	// the click's place in the page is in screen pixels (pages are drawn at
	// scale 1, zoomed): back to the window's units
	mm := &Menu{X: float32((float64(bx) + m.X) / s), Y: float32((float64(by) + m.Y) / s)}
	for _, it := range m.Items {
		if it.C == 0 {
			mm.Items = append(mm.Items, MenuItem{Sep: true})
			continue
		}
		mm.Items = append(mm.Items, MenuItem{Cmd: it.C, Label: it.L, Enabled: it.E})
	}
	id := m.ID
	var once sync.Once
	mm.Choose = func(cmd int) {
		once.Do(func() { e.send(msg{"t": "menuc", "id": id, "c": cmd}) })
	}
	v.ev.Menu(mm)
}

func (e *elxEngine) download(m in) {
	wkEng.mu.Lock()
	report := wkEng.policy.Download
	wkEng.mu.Unlock()
	if report == nil {
		return
	}
	d := Download{ID: m.N, URL: m.URL, Path: m.Path, Total: m.Total, Received: m.Got, State: DownloadState(m.State)}
	if v := wkGet(m.ID); v != nil && !v.closed {
		d.View = v
	}
	n := m.N
	switch d.State {
	case DownloadActive:
		d.Cancel = func() { e.send(msg{"t": "dl", "n": n, "do": "cancel"}) }
		d.Pause = func() { e.send(msg{"t": "dl", "n": n, "do": "pause"}) }
	case DownloadPaused:
		d.Cancel = func() { e.send(msg{"t": "dl", "n": n, "do": "cancel"}) }
		d.Resume = func() { e.send(msg{"t": "dl", "n": n, "do": "resume"}) }
	case DownloadDone:
		if d.Total < 0 {
			d.Total = d.Received
		}
	}
	report(d)
}

// ---- views ----

func (e *elxEngine) NewView(o Options, evs Events, done func(View, error)) {
	if _, _, err := helperPaths(); err != nil {
		done(nil, ErrUnavailable)
		return
	}
	e.ensure()
	if o.Popup != nil && o.Popup.impl.id != 0 {
		if v := wkGet(o.Popup.impl.id); v != nil {
			v.ev = evs
			e.mu.Lock()
			delete(e.pending, v.id)
			ev := e.views[v.id]
			if ev != nil {
				ev.opened = true
			}
			e.mu.Unlock()
			done(v, nil)
			return
		}
	}
	v := &wkView{ev: evs, private: o.Private, sandbox: o.Sandbox}
	id := wkAdd(v)
	v.native = id
	e.mu.Lock()
	e.views[id] = &elxView{v: v, opts: o, opened: true}
	e.mu.Unlock()
	e.fillJar(o)
	e.send(msg{"t": "open", "id": id, "profile": o.Profile, "private": o.Private, "sandbox": o.Sandbox})
	done(v, nil)
}

// reopen opens a page again in a new helper (the last one quit or died).
func (e *elxEngine) reopen(v *wkView) {
	e.mu.Lock()
	ev := e.views[v.id]
	if ev == nil || ev.opened {
		e.mu.Unlock()
		return
	}
	ev.opened = true
	o, url, x, y, w, h, shown := ev.opts, ev.url, ev.x, ev.y, ev.w, ev.h, ev.shown
	e.mu.Unlock()
	e.fillJar(o)
	e.send(msg{"t": "open", "id": v.id, "profile": o.Profile, "private": o.Private, "sandbox": o.Sandbox})
	e.bounds(v.id, x, y, w, h)
	if shown {
		e.send(msg{"t": "show", "id": v.id, "on": true})
	}
	if url != "" {
		e.send(msg{"t": "nav", "id": v.id, "url": url})
	}
}

// bounds sizes a page in screen pixels (w, h): the helper draws it at scale
// 1 and zooms it by the window's scale, read now (GTK's first guess at a
// window's scale is often corrected a frame later).
func (e *elxEngine) bounds(id uintptr, x, y, w, h int) {
	s := float64(C.elxScale())
	if s < 0.5 || s > 8 {
		s = 1
	}
	if v := os.Getenv("IRIS_SCALE"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0.5 && f <= 8 {
			s = f
		}
	}
	e.mu.Lock()
	changed := math.Abs(s-e.scale) > 1e-4
	e.scale = s
	e.mu.Unlock()
	if changed {
		e.send(msg{"t": "scale", "s": s})
	}
	if w > 0 && h > 0 {
		e.send(msg{"t": "bounds", "id": id, "w": w, "h": h})
	}
}

// wakes are the operations that bring back a page the helper does not have
// (it quit, or restarted for memory); the others wait for it.
var wakes = map[string]bool{"nav": true, "reload": true, "back": true, "fwd": true, "show": true}

// do sends a page operation, starting a helper (and reopening the page) when needed.
func (e *elxEngine) do(v *wkView, m msg) {
	if v.closed {
		return
	}
	t, _ := m["t"].(string)
	e.mu.Lock()
	ev := e.views[v.id]
	asleep := ev != nil && !ev.opened && !ev.shown
	e.mu.Unlock()
	if asleep && !wakes[t] {
		return
	}
	e.ensure()
	e.reopen(v)
	m["id"] = v.id
	e.send(m)
}

func (v *wkView) Navigate(u string) {
	elx.mu.Lock()
	if ev := elx.views[v.id]; ev != nil {
		ev.url = u
	}
	elx.mu.Unlock()
	elx.do(v, msg{"t": "nav", "url": u})
}
func (v *wkView) Back()    { elx.do(v, msg{"t": "back"}) }
func (v *wkView) Forward() { elx.do(v, msg{"t": "fwd"}) }
func (v *wkView) Reload()  { elx.do(v, msg{"t": "reload"}) }
func (v *wkView) Stop()    { elx.do(v, msg{"t": "stop"}) }

func (v *wkView) SetBounds(x, y, w, h int) {
	if v.closed {
		return
	}
	elx.mu.Lock()
	ev := elx.views[v.id]
	same := ev != nil && ev.x == x && ev.y == y && ev.w == w && ev.h == h
	if ev != nil {
		ev.x, ev.y, ev.w, ev.h = x, y, w, h
	}
	elx.mu.Unlock()
	if same {
		return
	}
	C.elxPlace(C.uintptr_t(v.id), C.int(x), C.int(y), C.int(w), C.int(h))
	elx.mu.Lock()
	live := ev != nil && (ev.opened || ev.shown)
	elx.mu.Unlock()
	if !live {
		return // it gets its size when it comes back
	}
	elx.ensure()
	elx.reopen(v)
	elx.bounds(v.id, x, y, w, h)
}

func (v *wkView) SetVisible(on bool) {
	if v.closed {
		return
	}
	elx.mu.Lock()
	ev := elx.views[v.id]
	same := ev != nil && ev.shown == on
	if ev != nil {
		ev.shown = on
	}
	elx.mu.Unlock()
	if same {
		return
	}
	s := 0
	if on {
		s = 1
	}
	C.elxShow(C.uintptr_t(v.id), C.int(s))
	elx.do(v, msg{"t": "show", "on": on})
}

func (v *wkView) Sleep()             { v.SetVisible(false) }
func (v *wkView) Wake()              {}
func (v *wkView) SetBackground(bool) {}
func (v *wkView) Focus() {
	if v.closed {
		return
	}
	C.elxFocusPage(C.uintptr_t(v.id))
	elx.do(v, msg{"t": "focus"})
}
func (v *wkView) Eval(js string) { elx.do(v, msg{"t": "eval", "js": js}) }
func (v *wkView) Run(js string, done func(string)) {
	if v.closed {
		done("null")
		return
	}
	elx.mu.Lock()
	ev := elx.views[v.id]
	asleep := ev != nil && !ev.opened && !ev.shown
	elx.mu.Unlock()
	if asleep {
		done("null")
		return
	}
	elx.ensure()
	elx.reopen(v)
	elx.ask(msg{"t": "eval", "id": v.id, "js": js}, func(r json.RawMessage) {
		if len(r) == 0 {
			r = json.RawMessage("null")
		}
		done(string(r))
	})
}
func (v *wkView) SetMuted(on bool)  { elx.do(v, msg{"t": "mute", "on": on}) }
func (v *wkView) SetZoom(f float64) { elx.do(v, msg{"t": "zoom", "f": f}) }

func (v *wkView) Close() {
	if v.closed {
		return
	}
	v.closed = true
	elx.send(msg{"t": "close", "id": v.id})
	elx.mu.Lock()
	delete(elx.views, v.id)
	delete(elx.pending, v.id)
	elx.mu.Unlock()
	C.elxDrop(C.uintptr_t(v.id))
	wkDel(v.id)
}

// ---- input from the window (electron_linux.c, on GTK's thread) ----

func modList(m C.uint) []string {
	var l []string
	for _, b := range []struct {
		bit  C.uint
		name string
	}{{1, "shift"}, {2, "control"}, {4, "alt"}, {8, "meta"}, {16, "leftButtonDown"}, {32, "middleButtonDown"}, {64, "rightButtonDown"}, {128, "capsLock"}} {
		if m&b.bit != 0 {
			l = append(l, b.name)
		}
	}
	return l
}

//export elxGoMouse
func elxGoMouse(id C.uintptr_t, kind C.int, x, y C.double, button, clicks C.int, mods C.uint) {
	t := [...]string{"mouseMove", "mouseDown", "mouseUp", "mouseLeave"}[kind&3]
	b := [...]string{"left", "middle", "right"}[button%3]
	elx.send(msg{"t": "in", "id": uintptr(id), "e": msg{"type": t, "x": int(math.Floor(float64(x))), "y": int(math.Floor(float64(y))), "button": b,
		"clickCount": int(clicks), "modifiers": modList(mods)}})
}

//export elxGoWheel
func elxGoWheel(id C.uintptr_t, x, y, dx, dy C.double, precise C.int, mods C.uint) {
	elx.send(msg{"t": "in", "id": uintptr(id), "e": msg{"type": "mouseWheel", "x": int(math.Floor(float64(x))), "y": int(math.Floor(float64(y))),
		"deltaX": float64(dx), "deltaY": float64(dy), "hasPreciseScrollingDeltas": precise != 0, "canScroll": true, "modifiers": modList(mods)}})
}

//export elxGoKeyEv
func elxGoKeyEv(id C.uintptr_t, down C.int, code *C.char, mods C.uint) {
	t := "keyUp"
	if down != 0 {
		t = "keyDown"
	}
	elx.send(msg{"t": "in", "id": uintptr(id), "e": msg{"type": t, "keyCode": C.GoString(code), "modifiers": modList(mods)}})
}

//export elxGoChar
func elxGoChar(id C.uintptr_t, text *C.char, mods C.uint) {
	for _, r := range C.GoString(text) {
		elx.send(msg{"t": "in", "id": uintptr(id), "e": msg{"type": "char", "keyCode": string(r), "modifiers": modList(mods)}})
	}
}

//export elxGoNav
func elxGoNav(id C.uintptr_t, fwd C.int) {
	if v := wkGet(uintptr(id)); v != nil {
		if fwd != 0 {
			v.Forward()
		} else {
			v.Back()
		}
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
	if v := wkGet(uintptr(id)); v != nil {
		elx.send(msg{"t": "focus", "id": v.id})
		if v.ev.Focus != nil {
			v.ev.Focus()
		}
	}
}

// ---- extensions (normal tabs: the default container) ----

// extCall asks the helper about extensions (on the window's thread, which
// starts the helper when it is not running).
func (e *elxEngine) extCall(m msg, done func(json.RawMessage)) {
	e.ensure()
	e.ask(m, done)
}

type extIn struct {
	ID, Name, Version string
	Enabled           bool
	Err               string
}

func (e *elxEngine) AddExtension(dir string, done func(Extension, error)) {
	e.extCall(msg{"t": "ext", "do": "add", "dir": dir}, func(r json.RawMessage) {
		var x extIn
		if json.Unmarshal(r, &x) != nil || x.ID == "" {
			if x.Err == "" {
				x.Err = "the extension could not be loaded"
			}
			done(Extension{}, errors.New(x.Err))
			return
		}
		done(Extension{ID: x.ID, Name: x.Name, Enabled: x.Enabled}, nil)
	})
}

func (e *elxEngine) Extensions(done func([]Extension, error)) {
	e.extCall(msg{"t": "ext", "do": "list"}, func(r json.RawMessage) {
		var l []extIn
		if err := json.Unmarshal(r, &l); err != nil {
			done(nil, err)
			return
		}
		out := make([]Extension, 0, len(l))
		for _, x := range l {
			out = append(out, Extension{ID: x.ID, Name: x.Name, Enabled: x.Enabled})
		}
		done(out, nil)
	})
}

func (e *elxEngine) RemoveExtension(id string, done func(error)) {
	e.extCall(msg{"t": "ext", "do": "remove", "ext": id}, func(json.RawMessage) { done(nil) })
}

func (e *elxEngine) EnableExtension(id string, on bool, done func(error)) {
	e.extCall(msg{"t": "ext", "do": "enable", "ext": id, "on": on}, func(json.RawMessage) { done(nil) })
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

// ---- the memory watch ----
//
// One helper serves every page and extension (never one per tab), and it
// quits two minutes after nothing needs it. While it runs, Iris reads the
// memory of all its processes from /proc every few seconds: that is
// MemoryMB, which Iris's balancer compares with the memory setting's budget
// to rest background tabs, the one used longest ago first (never the tab in
// front, tabs playing sound or video, YouTube, or a tab downloading). When
// the helper stays over the budget with no background page left to rest, it
// is restarted, and the tabs come back from their last address: the tab in
// front at once, the others when shown.

const (
	overFor      = 20 * time.Second // over the budget this long before a restart
	restartEvery = 2 * time.Minute  // at most one restart in this time
)

func (e *elxEngine) watch() {
	for range time.Tick(3 * time.Second) {
		e.checkMemory()
	}
}

// budgetMB is the helper's memory budget: the memory setting's, or
// IRIS_ENGINE_BUDGET_MB, or a quarter of the computer's memory.
func (e *elxEngine) budgetMB() float64 {
	if s := os.Getenv("IRIS_ENGINE_BUDGET_MB"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 {
			return float64(n)
		}
	}
	wkEng.mu.Lock()
	b := wkEng.policy.MemoryBudgetMB
	wkEng.mu.Unlock()
	if b > 0 {
		return float64(b)
	}
	if t := totalMemMB(); t > 0 {
		return float64(t) / 4
	}
	return 2048
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

func youTube(u string) bool {
	h := u
	if i := strings.Index(h, "://"); i >= 0 {
		h = h[i+3:]
	}
	if i := strings.IndexAny(h, "/?#"); i >= 0 {
		h = h[:i]
	}
	h = strings.TrimPrefix(h, "www.")
	return h == "youtube.com" || strings.HasSuffix(h, ".youtube.com") || h == "youtu.be"
}

func (e *elxEngine) checkMemory() {
	e.mu.Lock()
	cmd, running := e.cmd, e.running && e.conn != nil
	e.mu.Unlock()
	if !running || cmd == nil || cmd.Process == nil {
		e.mu.Lock()
		e.memMB, e.procs = 0, 0
		e.mu.Unlock()
		return
	}
	mb, n := treeRSS(cmd.Process.Pid)
	budget := e.budgetMB()
	now := time.Now()
	e.mu.Lock()
	e.memMB, e.procs = mb, n
	// what the pages are doing: the balancer has work left while a
	// background page it may rest still holds memory
	restable := 0
	type st struct {
		id    uintptr
		state string
		url   string
	}
	var tabs []st
	for id, ev := range e.views {
		state := "rested"
		switch {
		case ev.opened && ev.shown:
			state = "shown"
		case ev.opened:
			state = "hidden"
			if !ev.audio && !youTube(ev.url) {
				restable++
			}
		}
		if ev.audio {
			state += "+audio"
		}
		tabs = append(tabs, st{id, state, ev.url})
	}
	if budget > 0 && mb > budget {
		if e.overSince.IsZero() {
			e.overSince = now
		}
	} else {
		e.overSince = time.Time{}
	}
	if !e.restartAt.IsZero() && e.afterMB == 0 && now.Sub(e.restartAt) > time.Minute {
		e.afterMB = mb
	}
	// a restart helps when memory grew since the last one (a leak, a heavy
	// page left behind); right after one that did not help, it waits
	grown := e.afterMB == 0 || mb > e.afterMB*1.5
	restart := !e.overSince.IsZero() && now.Sub(e.overSince) >= overFor && restable == 0 && !e.restarting &&
		(e.restartAt.IsZero() || now.Sub(e.restartAt) >= restartEvery && grown)
	if restart {
		e.restarting, e.restartAt, e.afterMB, e.overSince = true, now, 0, time.Time{}
	}
	e.mu.Unlock()
	if os.Getenv("IRIS_GL_DEBUG") != "" {
		sort.Slice(tabs, func(i, j int) bool { return tabs[i].id < tabs[j].id })
		var b strings.Builder
		for _, t := range tabs {
			u := t.url
			if len(u) > 60 {
				u = u[:60] + "…"
			}
			fmt.Fprintf(&b, " [%d %s %s]", t.id, t.state, u)
		}
		fmt.Fprintf(os.Stderr, "Iris: engine %.0f MB in %d processes (budget %.0f MB); tabs:%s\n", mb, n, budget, b.String())
	}
	if restart {
		fmt.Fprintf(os.Stderr, "Iris: the page engine stayed over its memory budget (%.0f of %.0f MB) with nothing left to rest: restarting it\n", mb, budget)
		_ = cmd.Process.Signal(syscall.SIGTERM)
		time.AfterFunc(5*time.Second, func() { _ = cmd.Process.Kill() })
	}
}

var _ ExtensionHost = (*elxEngine)(nil)
