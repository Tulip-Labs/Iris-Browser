// Package shell is Lite Go's interface: tabs, the address bar, the new tab
// page and the settings panel, drawn with Flowcode's Material 3 and glass
// look, around pages shown by the system web view.
//
// Threads: Frame runs on the Gio event loop. Web view calls are queued with
// web and the host runs them on the window thread right after the frame
// (TakeWebCalls); web view events come back through post.
package shell

import (
	"sync"
	"time"

	"litego/core"
	"litego/ui"
	"litego/webview"
)

// Host is what the window gives the interface.
type Host interface {
	Invalidate()
	Clipboard() ui.Clipboard
	Minimize()
	ToggleMaximize()
	SetFullscreen(on bool)
	Close()
	// FocusWindow takes the keyboard back from the page (call on the window thread).
	FocusWindow()
}

// Config sets up the interface.
type Config struct {
	Engine  webview.Engine // nil: no pages (tests and screenshots)
	DataDir string         // "" keeps settings and history in memory
	TotalMB int            // system memory, for the tab sleep plan
	Version string
	SelfMB  func() float64 // this process's memory (nil = unknown)
}

// App is the browser window's interface.
type App struct {
	h   Host
	cfg Config
	eng webview.Engine

	In        *ui.Input
	st        ui.State
	u         ui.Ui
	Scale     float32 // physical pixels per logical pixel (set by the host)
	Maximized bool    // set by the host
	// MoveAreas are the parts of the window that drag it (set each frame).
	MoveAreas []ui.Rect

	set    *core.Settings
	hist   *core.History
	shield *core.Shield
	plan   core.MemoryPlan

	tabs    []*Tab
	cur     int
	nextID  int
	closed  []closedTab
	ready   bool  // engine started
	engErr  error // engine could not start
	spare   *spare
	full    bool // the page asked for fullscreen (video)
	winFull bool // F11

	addr, ntpQ  *ui.TextEdit
	addrWas     bool
	sugg        []suggestion
	sugSel      int
	panel       bool
	panelScroll ui.Scroll
	railScroll  ui.Scroll
	stripScroll float32
	newCont     *ui.TextEdit
	bar         infobar

	insecureMu sync.Mutex
	insecureOK map[string]bool

	mu    sync.Mutex
	posts []func()
	calls []func()

	blockedTotal int
	memMB, appMB float64
	lastMem      float64
	lastTick     float64
	start        time.Time
}

type closedTab struct {
	url, title string
	kind       Kind
	container  string
}

type infobar struct {
	text, action string
	do           func()
	until        float64 // 0 = until dismissed
	warn         bool
}

// New makes the interface; call Started once the engine is running.
func New(h Host, cfg Config) *App {
	a := &App{h: h, cfg: cfg, eng: cfg.Engine, In: ui.NewInput(), Scale: 1,
		addr: ui.NewTextEdit("", false), ntpQ: ui.NewTextEdit("", false), newCont: ui.NewTextEdit("", false),
		insecureOK: map[string]bool{}, start: time.Now(), lastMem: -10}
	a.set = core.LoadSettings(cfg.DataDir)
	a.hist = core.OpenHistory(cfg.DataDir)
	a.shield = core.NewShield()
	a.shield.On = a.set.Shield
	for _, h := range a.set.ShieldOff {
		a.shield.SetSiteOff(h, true)
	}
	a.plan = core.Plan(cfg.TotalMB, a.set.Memory)
	a.newTab(KNormal, "", "", true)
	go func() { // the sleep policy and the memory readout need a frame now and then
		for range time.Tick(2 * time.Second) {
			h.Invalidate()
		}
	}()
	return a
}

// LowMemory says whether the engine should start in its low-end mode.
func (a *App) LowMemory() bool { return a.plan.Low }

// Policy is what the engine should enforce (pass to Engine.SetPolicy before Start).
func (a *App) Policy() webview.Policy {
	var scripts []string
	if a.set.YouTube {
		scripts = append(scripts, core.YouTubeScript)
	}
	return webview.Policy{
		Allow:     a.shield.Allow,
		HTTPSOnly: a.set.HTTPSOnly,
		AllowInsecure: func(u string) bool {
			a.insecureMu.Lock()
			defer a.insecureMu.Unlock()
			return core.IsPrivateHost(u) || a.insecureOK[core.Host(u)]
		},
		Scripts: scripts,
		Strict:  a.set.Strict,
	}
}

// Started reports the engine's start (call from any thread).
func (a *App) Started(err error) {
	a.post(func() {
		a.ready, a.engErr = err == nil, err
		if err != nil {
			return
		}
		if t := a.tab(); t != nil && t.URL != "" {
			a.ensureView(t)
		} else if t != nil && t.Kind == KNormal {
			a.makeSpare()
		}
	})
}

// post runs f on the interface's loop before the next frame (any thread).
func (a *App) post(f func()) {
	a.mu.Lock()
	a.posts = append(a.posts, f)
	a.mu.Unlock()
	a.h.Invalidate()
}

// web queues a web view call for the window thread.
func (a *App) web(f func()) { a.calls = append(a.calls, f) }

// TakeWebCalls returns the calls queued this frame; run them in order on the window thread.
func (a *App) TakeWebCalls() []func() {
	c := a.calls
	a.calls = nil
	return c
}

func (a *App) drain() {
	for {
		a.mu.Lock()
		p := a.posts
		a.posts = nil
		a.mu.Unlock()
		if len(p) == 0 {
			return
		}
		for _, f := range p {
			f()
		}
	}
}

// Fullscreen reports whether the window shows only the page.
func (a *App) Fullscreen() bool { return a.full || a.winFull }

// Close flushes settings and closes every page (call before the window goes).
func (a *App) Close() {
	a.set.Flush()
	for _, t := range a.tabs {
		if t.view != nil {
			v := t.view
			a.web(v.Close)
			t.view = nil
		}
	}
	if a.spare != nil && a.spare.view != nil {
		a.web(a.spare.view.Close)
	}
}

func (a *App) now() float64 { return a.In.Now }

func (a *App) theme() *ui.Theme { return ui.ThemeByID(a.set.Theme) }

func (a *App) notify(text string) {
	a.bar = infobar{text: text, until: a.now() + 3.5}
}

// Frame draws the window and handles this frame's input.
func (a *App) Frame(g ui.Gfx, w, h float32) {
	a.drain()
	if a.In.Now == 0 {
		a.In.Now = time.Since(a.start).Seconds()
	}
	th := a.theme()
	u := &a.u
	u.G, u.In, u.Th, u.St, u.Clip = g, a.In, th, &a.st, a.h.Clipboard()
	u.W, u.H, u.Layer, u.InputLayer, u.Redraw = w, h, 0, 0, false
	a.MoveAreas = a.MoveAreas[:0]

	a.shortcuts()
	a.tick()

	full := ui.Rect{W: w, H: h}
	var page ui.Rect
	if a.Fullscreen() {
		g.FillRect(full, ui.Black)
		page = full
	} else {
		g.FillRect(full, frameColor(th))
		page = a.chrome(full)
	}
	a.content(page)
	if !a.Fullscreen() {
		u.DrawTooltip()
	}
	a.sync(page)
	a.In.EndFrame()
	if u.Redraw {
		a.h.Invalidate()
	}
}

// frameColor is the window's solid tonal frame around the page.
func frameColor(th *ui.Theme) ui.Color {
	if th.Dark {
		return ui.Mix(th.G5, ui.Black, 0.25)
	}
	return th.SurfaceHigh
}

// OpenURL opens an address given on the command line (Lite Go as the default browser).
func (a *App) OpenURL(u string) {
	u = core.Resolve(u, a.set.Mode)
	if u == "" {
		return
	}
	if t := a.tab(); t != nil && t.URL == "" {
		a.navigate(t, u)
		return
	}
	a.newTab(KNormal, "", u, true)
}
