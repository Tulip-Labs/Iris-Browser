// Package shell is Lite Go's interface: tabs, the address bar, the new tab
// page and the settings panel, drawn with Flowcode's Material 3 and glass
// look, around pages shown by the system web view.
//
// Threads: Frame runs on the Gio event loop. Web view calls are queued with
// web and the host runs them on the window thread right after the frame
// (TakeWebCalls); web view events come back through post.
package shell

import (
	"context"
	"image"
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
	// Quit ends Lite Go entirely (closing the window may keep it ready in the background).
	Quit()
}

// Config sets up the interface.
type Config struct {
	Engine  webview.Engine // nil: no pages (tests and screenshots)
	DataDir string         // "" keeps settings and history in memory
	TotalMB int            // system memory, for the tab sleep plan
	Version string
	SelfMB  func() float64 // this process's memory (nil = unknown)
	// SetBoost turns starting with Windows on or off (nil where it does not apply).
	SetBoost func(on bool)
	// Core reuses preloaded settings, history and shield (the background mode).
	Core *Core
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
	contName    *ui.TextEdit
	editCont    int
	bar         infobar

	insecureMu sync.Mutex
	insecureOK map[string]bool

	mu    sync.Mutex
	posts []func()
	calls []func()

	blockedTotal int

	workers      [4]*worker
	wakeAt       float64
	thumbs       map[string]*thumb
	thumbSem     chan struct{}
	fetchImage   func(ctx context.Context, src string, maxW int) (image.Image, error)
	ytSearch     func(ctx context.Context, q string) ([]core.VideoResult, error)
	ai           aiPanel
	memMB, appMB float64
	lastMem      float64
	lastTick     float64
	start        time.Time
	stop         chan struct{}
	stopped      bool
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
		addr: ui.NewTextEdit("", false), ntpQ: ui.NewTextEdit("", false), newCont: ui.NewTextEdit("", false), contName: ui.NewTextEdit("", false), editCont: -1,
		insecureOK: map[string]bool{}, start: time.Now(), lastMem: -10,
		thumbs: map[string]*thumb{}, thumbSem: make(chan struct{}, 6), fetchImage: core.FetchImage, ytSearch: core.YouTubeSearch}
	a.ai.input = ui.NewTextEdit("", false)
	c := cfg.Core
	if c == nil {
		c = LoadCore(cfg.DataDir)
	}
	a.set, a.hist, a.shield = c.Settings, c.History, c.Shield
	a.plan = core.Plan(cfg.TotalMB, a.set.Memory)
	a.newTab(KNormal, "", "", true)
	a.stop = make(chan struct{})
	go func() { // the sleep policy and the memory readout need a frame now and then
		tk := time.NewTicker(2 * time.Second)
		defer tk.Stop()
		for {
			select {
			case <-tk.C:
				h.Invalidate()
			case <-a.stop:
				return
			}
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
	if !a.stopped {
		a.stopped = true
		close(a.stop)
	}
	for _, w := range a.workers {
		if w != nil && w.view != nil {
			a.web(w.view.Close)
			w.view = nil
		}
	}
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

	if a.wakeAt > 0 && a.now() >= a.wakeAt {
		a.wakeAt = 0
	}
	a.shortcuts()
	a.tick()
	a.runWorkers()

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

// Core is what loads before the window: settings, history and the shield.
type Core struct {
	Settings *core.Settings
	History  *core.History
	Shield   *core.Shield
}

// LoadCore loads them (the history and the shield finish in the background).
func LoadCore(dir string) *Core {
	c := &Core{Settings: core.LoadSettings(dir), History: core.OpenHistory(dir), Shield: core.NewShield()}
	c.Shield.On = c.Settings.Shield
	for _, h := range c.Settings.ShieldOff {
		c.Shield.SetSiteOff(h, true)
	}
	return c
}

// Do runs f on the interface's loop (from any goroutine).
func (a *App) Do(f func()) { a.post(f) }

// NewTab opens a new tab page.
func (a *App) NewTab() { a.newTab(KNormal, "", "", true) }
