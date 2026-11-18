//go:build !(linux && webkit)

// The Gio window: Windows, and Linux builds without WebKitGTK.

package main

import (
	"image"
	"io"
	"log"
	"os"
	"strings"
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

	"iris/giox"
	"iris/shell"
	"iris/ui"
	"iris/webview"
)

func runMain() { app.Main() }

func (r *resident) window(urls []string) {
	go func() {
		w := new(app.Window)
		// the size the reader left, and maximized unless they chose otherwise
		ws := r.core.Settings.Window
		if ws.W < 480 || ws.H < 420 {
			ws.W, ws.H = 1280, 820
		}
		w.Option(app.Title("Iris"), app.Size(unit.Dp(ws.W), unit.Dp(ws.H)), app.MinSize(unit.Dp(480), unit.Dp(420)), app.Decorated(false))
		if !ws.Windowed {
			w.Option(app.Maximized.Option())
		}
		if err := r.loop(w, urls); err != nil {
			log.Println(err)
		}
		r.closed()
	}()
}

func (h *host) raise() { h.later(func() { h.w.Perform(system.ActionRaise) }) }

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
func (h *host) Minimize() {
	h.later(func() { h.w.Perform(system.ActionMinimize) })
}
func (h *host) Close() { h.quit = true; h.w.Invalidate() }
func (h *host) Quit()  { h.exit = true; h.quit = true; h.w.Invalidate() }
func (h *host) FocusWindow() {
	focusWindow(h.hwnd)
}

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

// tag receives every pointer and key event of the window.
var tag = new(int)

func (r *resident) loop(w *app.Window, urls []string) error {
	webDir := r.webDir
	h := &host{w: w}
	eng := webview.New()
	a := shell.New(h, shell.Config{Engine: eng, DataDir: r.conf, TotalMB: totalMB(), Version: version, SelfMB: webview.SelfMB,
		Core: r.core, SetBoost: setStartup, Sys: sysHooks(), UpdateKind: installKind()})
	eng.SetPolicy(a.Policy())
	for _, u := range urls {
		a.OpenURL(u)
	}
	r.shown(a, h)
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
		case app.ViewEvent:
			// the native window (HWND, NSView or X11 window): the system web
			// view goes inside it, and lives on the window's thread
			if win, ok := nativeWindow(e); ok && !started {
				started = true
				h.hwnd = win
				low := a.LowMemory()
				w.Run(func() { eng.Start(win, webDir, low, a.Started) })
			}
		case app.ConfigEvent:
			maximized = e.Config.Mode == app.Maximized
			a.Maximized = maximized
			// remember how the reader leaves the window (never a video's full
			// screen or the minimized state)
			switch e.Config.Mode {
			case app.Maximized:
				r.core.Settings.SetWindow(false, 0, 0)
			case app.Windowed:
				if s := a.Scale; s > 0 && frames >= 3 {
					r.core.Settings.SetWindow(true, int(float32(e.Config.Size.X)/s), int(float32(e.Config.Size.Y)/s))
				}
			}
		case app.FrameEvent:
			if !started && !engineOS() {
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
