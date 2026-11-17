// Package shell is Lite Go's interface: tabs, the address bar, the new tab
// page and the settings panel, drawn with Flowcode's Material 3 and glass
// look, around pages shown by the system web view.
//
// Threads: Frame runs on the Gio event loop. Web view calls are queued with
// web and the host runs them on the window thread right after the frame
// (TakeWebCalls); web view events come back through post.
package shell

import (
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync/atomic"

	"context"
	"image"
	"litego/shields"
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
	// SetBoost turns starting with Windows on or off (nil where it does not apply);
	// Lite Go keeps nothing running in the background, so it is only turned off.
	SetBoost func(on bool)
	// Core reuses preloaded settings, history and shield (the background mode).
	Core *Core
	// Sys is what the operating system does for the interface.
	Sys Sys
	// UpdateKind is how this copy was installed (update.Detect); "" turns
	// updates off (tests and screenshots).
	UpdateKind string
}

// Sys is what the operating system does for the interface; any may be nil.
type Sys struct {
	// Open opens a file with its program; Reveal shows it in its folder.
	Open, Reveal func(path string)
	// PickFiles shows the system's file box and returns what was chosen
	// (it waits for the reader; called off the loop).
	PickFiles func() []string
	// FreeMB is the system memory still free (0 = unknown).
	FreeMB func() int
	// Integrity checks Lite Go's own program file against the record made
	// when it was installed (it may take a moment; called off the loop).
	Integrity func() Integrity
}

// Integrity is the result of checking Lite Go's own program file.
type Integrity uint8

const (
	IntegrityUnknown   Integrity = iota // no record to check against
	IntegrityVerified                   // the file is the one that was installed
	IntegrityProtected                  // installed as a Windows package: Windows keeps it read-only and verified
	IntegrityChanged                    // the file is not the one that was installed
)

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
	core   *Core
	hist   *core.History
	shield *core.Shield
	scan   *core.SiteScan
	plan   core.MemoryPlan

	split     splitView
	find      findBar
	downloads []*download
	upd       updater
	keptPages []webview.View // pages of closed tabs that are still downloading
	panelMode panelMode
	histQ     *ui.TextEdit
	histList  []core.Entry
	histFor   string
	histAt    float64
	histSc    ui.Scroll
	dlSc      ui.Scroll
	kindEdit  bool // the container editor on the new tab page
	balance   balancer
	integrity Integrity
	setSec    string // the menu's open section ("" = none)
	nameEd    *ui.TextEdit
	kindOpen    bool    // the row of other kinds of tab, under the bar
	stripScroll float32 // the tab strip, when the tabs do not fit

	tabs    []*Tab
	cur     int
	nextID  int
	closed  []closedTab
	ready   bool  // engine started
	engErr  error // engine could not start
	full    bool  // the page asked for fullscreen (video)
	winFull bool  // F11

	addr, ntpQ  *ui.TextEdit
	addrWas     bool
	sugg        []suggestion
	sugSel      int
	panel       bool
	panelScroll ui.Scroll
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
	side         sideView
	sideRect     ui.Rect
	sideURL      string
	sideFull     bool
	memMB, appMB float64
	lastMem      float64
	lastTick     float64
	lastFree     float64
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
	// a second, quieter choice
	action2 string
	do2     func()
	until   float64 // 0 = until dismissed
	warn    bool
}

// New makes the interface; call Started once the engine is running.
func New(h Host, cfg Config) *App {
	a := &App{h: h, cfg: cfg, eng: cfg.Engine, In: ui.NewInput(), Scale: 1,
		addr: ui.NewTextEdit("", false), ntpQ: ui.NewTextEdit("", false), newCont: ui.NewTextEdit("", false), contName: ui.NewTextEdit("", false), editCont: -1,
		insecureOK: map[string]bool{}, start: time.Now(), lastMem: -10,
		thumbs: map[string]*thumb{}, thumbSem: make(chan struct{}, 6), fetchImage: core.FetchImage, ytSearch: core.YouTubeSearch}
	a.ai.input = ui.NewTextEdit("", false)
	a.histQ, a.find.q = ui.NewTextEdit("", false), ui.NewTextEdit("", false)
	a.split.ratio = 0.5
	c := cfg.Core
	if c == nil {
		c = LoadCore(cfg.DataDir)
	}
	a.set, a.hist, a.shield, a.scan, a.core = c.Settings, c.History, c.Shield, c.Scan, c
	// one way to search: everything on Lite results (no modes, no background part)
	a.set.Mode, a.set.LiteResults, a.set.Boost, a.set.VerticalTabs = core.ModeWeb, true, false, false
	a.plan = core.Plan(cfg.TotalMB, a.set.Memory)
	a.newTab(KNormal, "", "", true)
	a.restoreSession()
	if f := cfg.Sys.Integrity; f != nil {
		go func() {
			r := f()
			a.post(func() { a.setIntegrity(r) })
		}()
	}
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
	if a.set.YouTubeLight {
		scripts = append(scripts, core.YouTubeLightScript)
	}
	if a.set.Farble {
		scripts = append(scripts, shields.FarbleScript())
	}
	adaptive, scan := a.set.Adaptive, a.scan
	var rewrite func(string) string
	if a.set.CleanLinks {
		rewrite = shields.Clean
	}
	sh, c := a.shield, a.core
	return webview.Policy{
		Rewrite: rewrite,
		// the built-in domain list and the filter lists together; exceptions
		// in the lists (fixes for sites) lift blocks from both
		Allow: func(u, page, kind string) bool {
			if sh.Exempt(u, page) {
				return true
			}
			dom := sh.Allow(u, page)
			f := c.Filters.Load()
			if f == nil {
				return dom
			}
			q := shields.Request{URL: u, Page: page, Kind: kindOf(kind)}
			if !dom {
				return f.Excepted(q)
			}
			return !f.Blocked(q)
		},
		NewTabFor: newSiteTab,
		HTTPSOnly: a.set.HTTPSOnly,
		AllowInsecure: func(u string) bool {
			a.insecureMu.Lock()
			defer a.insecureMu.Unlock()
			return core.IsPrivateHost(u) || a.insecureOK[core.Host(u)]
		},
		Scripts: scripts,
		Strict:  a.set.Strict,
		// adaptive shields: a site found clean is not checked request by request
		Scan: func(u string) bool {
			if !sh.On {
				return false // nothing to check with the shield off
			}
			return !adaptive || scan.Need(u)
		},
		Unsafe:   func(u string) bool { return core.Risk(u) != "" && !a.allowedInsecure(u) },
		Download: func(d webview.Download) { a.post(func() { a.onDownload(d) }) },
	}
}

// newSiteTab says whether a clicked link from page from to address to opens
// in a new tab: another website does; sign-in steps (which must stay in their
// tab to come back) and pages of the same site do not.
func newSiteTab(from, to string) bool {
	lt, lf := strings.ToLower(to), strings.ToLower(from)
	if !strings.HasPrefix(lt, "http") || !strings.HasPrefix(lf, "http") {
		return false
	}
	if core.SiteKey(from) == core.SiteKey(to) {
		return false
	}
	for _, s := range []string{"accounts.", "login.", "auth.", "signin", "sign-in", "oauth", "sso.", "/login", "/auth", "consent.", "checkout", "pay."} {
		if strings.Contains(lt, s) || strings.Contains(lf, "accounts.google.") {
			return false
		}
	}
	return true
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
	a.saveSession()
	for _, t := range a.tabs {
		a.finishScan(t)
	}
	a.scan.Flush()
	a.set.Flush()
	if !a.stopped {
		a.stopped = true
		close(a.stop)
	}
	for _, v := range a.keptPages {
		a.web(v.Close)
	}
	a.keptPages = nil
	for _, w := range a.workers {
		if w != nil && w.view != nil {
			a.web(w.view.Close)
			w.view = nil
		}
	}
	a.closeSide()
	for _, t := range a.tabs {
		if t.view != nil {
			v := t.view
			a.web(v.Close)
			t.view = nil
		}
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
	a.st.Editing = nil
	u.ResetHit()

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
		if th.Grad != nil {
			ui.FillGradient3(g, full, 0, th.Grad)
		} else {
			g.FillRect(full, frameColor(th))
		}
		page = a.chrome(full)
	}
	a.sideRect, a.sideURL = ui.Rect{}, ""
	if a.sideFull && a.side.url != "" {
		a.sideURL = a.side.url
	}
	page, beside, other := a.panes(page)
	a.content(page)
	if other != nil {
		a.otherPane(beside, other)
	}
	if !a.Fullscreen() {
		u.DrawTooltip()
	}
	a.sync(page, beside, other)
	a.syncSide()
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
	Scan     *core.SiteScan
	// Lite Shields' filter lists: loaded and refreshed in the background
	Filters  atomic.Pointer[shields.Engine]
	ListsAt  time.Time
	ListsErr error
	listsMu  sync.Mutex
	loading  bool
	dir      string
	// OnLists runs when new filter lists are in place (any goroutine)
	OnLists func()
}

// LoadCore loads them (the history and the shield finish in the background).
func LoadCore(dir string) *Core {
	c := &Core{Settings: core.LoadSettings(dir), History: core.OpenHistory(dir), Shield: core.NewShield(), Scan: core.OpenSiteScan(dir), dir: dir}
	c.Shield.On = c.Settings.Shield
	for _, h := range c.Settings.ShieldOff {
		c.Shield.SetSiteOff(h, true)
	}
	c.LoadLists(false, nil)
	return c
}

// LoadLists (re)builds the filter engine from the saved lists, downloading
// missing or old ones; force downloads them all again. done runs after.
func (c *Core) LoadLists(force bool, done func()) {
	c.listsMu.Lock()
	if c.loading {
		c.listsMu.Unlock()
		return
	}
	c.loading = true
	c.listsMu.Unlock()
	set := c.Settings
	wanted := map[string]bool{"easylist": set.Lists, "easyprivacy": set.Lists, "ublock": set.Lists, "cookies": set.Cookies}
	dir := c.dir
	go func() {
		defer func() {
			c.listsMu.Lock()
			c.loading = false
			c.listsMu.Unlock()
			if done != nil {
				done()
			}
		}()
		if dir == "" {
			return
		}
		ldir := filepath.Join(dir, "lists")
		if force {
			for _, l := range shields.Lists {
				_ = os.Chtimes(filepath.Join(ldir, l.ID+".txt"), time.Time{}, time.Unix(0, 0))
			}
		}
		// first what is saved (quick), then fresh copies where needed
		if e, at, _ := shields.Load(context.Background(), ldir, wanted, false); e.Rules+e.Hiding > 0 {
			c.Filters.Store(e)
			c.ListsAt = at
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		e, at, err := shields.Load(ctx, ldir, wanted, true)
		c.ListsErr = err
		if e.Rules+e.Hiding > 0 {
			c.Filters.Store(e)
			c.ListsAt = at
		} else if !set.Lists && !set.Cookies {
			c.Filters.Store(nil)
		}
		if f := c.OnLists; f != nil {
			f()
		}
		runtime.GC()
		debug.FreeOSMemory()
	}()
}

// Do runs f on the interface's loop (from any goroutine).
func (a *App) Do(f func()) { a.post(f) }

// NewTab opens a new tab page.
func (a *App) NewTab() { a.newTab(KNormal, "", "", true) }

func ctxTimeout(sec int) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), time.Duration(sec)*time.Second)
}

func kindOf(k string) shields.Kind {
	switch k {
	case "script":
		return shields.KindScript
	case "image":
		return shields.KindImage
	case "media":
		return shields.KindMedia
	case "xmlhttprequest":
		return shields.KindXHR
	case "ping":
		return shields.KindPing
	}
	return shields.KindOther
}
