// Command litego is Lite Go: a light browser whose interface is drawn with Gio
// and whose pages are shown by the system web view (WebView2 on Windows).
package main

import (
	"image"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"gioui.org/app"
	"gioui.org/io/clipboard"
	"gioui.org/io/event"
	"gioui.org/io/key"
	"gioui.org/io/pointer"
	"gioui.org/io/system"
	"gioui.org/op"
	"gioui.org/op/clip"
	"gioui.org/unit"

	"litego/giox"
	"litego/shell"
	"litego/ui"
	"litego/webview"
)

const version = "1.0.0"

func main() {
	// a small, steady footprint: collect garbage sooner and keep the Go heap
	// under a soft ceiling (pages live in WebView2's own processes)
	debug.SetGCPercent(50)
	debug.SetMemoryLimit(128 << 20)
	background := false
	var urls []string
	for _, a := range os.Args[1:] {
		switch {
		case a == "--background":
			background = true
		case !strings.HasPrefix(a, "-"):
			urls = append(urls, a)
		}
	}
	conf, webDir := dirs()
	// Lite Go runs once: a second launch hands its addresses to the running one,
	// whose window then appears at once (it is already loaded).
	if background && running(conf) {
		return // already ready
	}
	if !background && handOff(conf, urls) {
		return
	}
	reqs := listen(conf)
	r := &resident{conf: conf, webDir: webDir, core: shell.LoadCore(conf), gfx: giox.NewGfx()}
	if r.core.Settings.Boost {
		setStartup(true)
	}
	go func() {
		if !background {
			r.open(urls)
		}
		for req := range reqs {
			if len(req) == 1 && req[0] == "--quit" { // the setup is updating Lite Go
				r.core.Settings.Flush()
				os.Exit(0)
			}
			r.open(req)
		}
	}()
	app.Main()
}

// resident is the running Lite Go: what stays loaded between windows.
type resident struct {
	conf, webDir string
	core         *shell.Core
	gfx          *giox.Gfx
	mu           sync.Mutex
	cur          *shell.App
	host         *host
}

// open shows the window (making it if needed) with urls in new tabs.
func (r *resident) open(urls []string) {
	r.mu.Lock()
	a, h := r.cur, r.host
	r.mu.Unlock()
	if a != nil {
		a.Do(func() {
			if len(urls) == 0 {
				a.NewTab()
			}
			for _, u := range urls {
				a.OpenURL(u)
			}
			h.later(func() { h.w.Perform(system.ActionRaise) })
		})
		return
	}
	go func() {
		w := new(app.Window)
		w.Option(app.Title("Lite Go"), app.Size(unit.Dp(1280), unit.Dp(820)), app.MinSize(unit.Dp(480), unit.Dp(420)), app.Decorated(false))
		err := r.loop(w, urls)
		if err != nil {
			log.Println(err)
		}
		r.mu.Lock()
		r.cur, r.host = nil, nil
		r.mu.Unlock()
		if !r.core.Settings.Boost {
			r.core.Settings.Flush()
			os.Exit(0)
		}
		runtime.GC()
		debug.FreeOSMemory() // between windows only the small resident part stays
	}()
}

type pendingClip struct{ text *string }

func (c *pendingClip) Set(s string) { c.text = &s }

// host is the shell.Host of the desktop window.
type host struct {
	w     *app.Window
	hwnd  uintptr
	clip  pendingClip
	after []func() // window actions, done after the frame
	quit  bool
	exit  bool
}

func (h *host) Invalidate()             { h.w.Invalidate() }
func (h *host) Clipboard() ui.Clipboard { return &h.clip }
func (h *host) Minimize()               { h.later(func() { h.w.Perform(system.ActionMinimize) }) }
func (h *host) Close()                  { h.quit = true; h.w.Invalidate() }
func (h *host) Quit()                   { h.exit = true; h.quit = true; h.w.Invalidate() }
func (h *host) FocusWindow()            { focusWindow(h.hwnd) }

var maximized bool

func (h *host) ToggleMaximize() {
	h.later(func() {
		if maximized {
			h.w.Perform(system.ActionUnmaximize)
		} else {
			h.w.Perform(system.ActionMaximize)
		}
	})
}

func (h *host) SetFullscreen(on bool) {
	h.later(func() {
		if on {
			h.w.Option(app.Fullscreen.Option())
		} else {
			h.w.Option(app.Windowed.Option())
		}
	})
}

func (h *host) later(f func()) { h.after = append(h.after, f); h.w.Invalidate() }

// dirs: settings and history in the config folder, the web engine's cache in the local cache folder.
func dirs() (conf, web string) {
	base, err := os.UserConfigDir()
	if err != nil {
		base = "."
	}
	conf = filepath.Join(base, "Lite Go")
	cache, err := os.UserCacheDir()
	if err != nil {
		cache = base
	}
	web = filepath.Join(cache, "Lite Go", "Web")
	_ = os.MkdirAll(conf, 0o755)
	_ = os.MkdirAll(web, 0o755)
	return
}

// tag receives every pointer and key event of the window.
var tag = new(int)

func (r *resident) loop(w *app.Window, urls []string) error {
	webDir := r.webDir
	h := &host{w: w}
	eng := webview.New()
	a := shell.New(h, shell.Config{Engine: eng, DataDir: r.conf, TotalMB: totalMB(), Version: version, SelfMB: webview.SelfMB,
		Core: r.core, SetBoost: setStartup})
	eng.SetPolicy(a.Policy())
	for _, u := range urls {
		a.OpenURL(u)
	}
	r.mu.Lock()
	r.cur, r.host = a, h
	r.mu.Unlock()
	g := r.gfx
	rd := &giox.Reader{Tag: tag}
	var ops op.Ops
	in := a.In
	frames := 0
	start := time.Now()
	started := false
	run := func(calls []func()) {
		if len(calls) > 0 {
			w.Run(func() {
				for _, f := range calls {
					f()
				}
			})
		}
	}
	for {
		switch e := w.Event().(type) {
		case app.DestroyEvent:
			a.Close() // keeps settings; the pages go with the window
			return e.Err
		case app.Win32ViewEvent:
			if e.Valid() && !started {
				started = true
				h.hwnd = e.HWND
				low := a.LowMemory()
				// the engine lives on the window thread: start it there
				w.Run(func() { eng.Start(e.HWND, webDir, low, a.Started) })
			}
		case app.ConfigEvent:
			maximized = e.Config.Mode == app.Maximized
			a.Maximized = maximized
		case app.FrameEvent:
			if !started && runtime.GOOS != "windows" {
				started = true
				a.Started(webview.ErrUnavailable)
			}
			gtx := app.NewContext(&ops, e)
			scale := gtx.Metric.PxPerDp
			a.Scale = scale
			if frames < 3 {
				gtx.Execute(key.FocusCmd{Tag: tag})
				frames++
			}
			rd.Read(gtx, in, scale)
			in.Now = time.Since(start).Seconds()

			area := clip.Rect{Max: e.Size}.Push(gtx.Ops)
			event.Op(gtx.Ops, tag)
			key.InputHintOp{Tag: tag, Hint: key.HintText}.Add(gtx.Ops)
			area.Pop()

			g.Begin(gtx.Ops, scale)
			a.Frame(g, float32(e.Size.X)/scale, float32(e.Size.Y)/scale)
			g.End()
			// the drag areas of our own title bar
			for _, r := range a.MoveAreas {
				st := clip.Rect{Min: pt(r.X*scale, r.Y*scale), Max: pt((r.X+r.W)*scale, (r.Y+r.H)*scale)}.Push(gtx.Ops)
				system.ActionInputOp(system.ActionMove).Add(gtx.Ops)
				st.Pop()
			}
			if h.clip.text != nil {
				gtx.Execute(clipboard.WriteCmd{Type: "application/text", Data: io.NopCloser(strings.NewReader(*h.clip.text))})
				h.clip.text = nil
			}
			pointer.CursorDefault.Add(gtx.Ops)
			e.Frame(gtx.Ops)
			run(a.TakeWebCalls())
			for _, f := range h.after {
				f()
			}
			h.after = h.after[:0]
			if h.quit {
				a.Close()
				run(a.TakeWebCalls())
				if h.exit {
					r.core.Settings.Flush()
					os.Exit(0)
				}
				return nil
			}
		}
	}
}

func pt(x, y float32) image.Point { return image.Pt(int(x+0.5), int(y+0.5)) }
