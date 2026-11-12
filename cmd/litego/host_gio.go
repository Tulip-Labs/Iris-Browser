//go:build !(linux && webkit) || android

// The Gio window: Windows, macOS, and Linux builds without WebKitGTK.

package main

import (
	"image"
	"image/color"
	"io"
	"log"
	"os"
	"strings"
	"sync/atomic"
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

func runMain() { app.Main() }

func (r *resident) window(urls []string) {
	go func() {
		w := new(app.Window)
		w.Option(app.Title("Lite Go"), app.Size(unit.Dp(1280), unit.Dp(820)), app.MinSize(unit.Dp(480), unit.Dp(420)), app.Decorated(false))
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
	backs atomic.Int32 // back presses that arrived while a page had the focus (Android)
}

func (h *host) Invalidate()             { h.w.Invalidate() }
func (h *host) Clipboard() ui.Clipboard { return &h.clip }
func (h *host) Minimize() {
	if mobile {
		h.w.Run(toBack) // a phone has no minimize: Lite Go goes behind the other apps
		return
	}
	h.later(func() { h.w.Perform(system.ActionMinimize) })
}
func (h *host) Close() { h.quit = true; h.w.Invalidate() }
func (h *host) Quit()  { h.exit = true; h.quit = true; h.w.Invalidate() }
func (h *host) FocusWindow() {
	if mobile {
		focusApp()
		return
	}
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
	if mobile && !on {
		h.later(func() { h.w.Run(exitFullscreen) })
	}
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
		Core: r.core, SetBoost: setStartup, Mobile: mobile})
	onBack(func() bool {
		h.backs.Add(1)
		h.w.Invalidate()
		return true
	})
	eng.SetPolicy(a.Policy())
	for _, u := range urls {
		a.OpenURL(u)
	}
	r.shown(a, h)
	g := r.gfx
	rd := &giox.Reader{Tag: tag, IME: mobile}
	var bars ui.Color
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
				onView(e)
				started = true
				h.hwnd = win
				low := a.LowMemory()
				w.Run(func() { eng.Start(win, webDir, low, a.Started) })
			}
		case app.URLEvent: // a link opened with Lite Go (Android)
			if e.URL != nil {
				u := e.URL.String()
				a.Do(func() { a.OpenURL(u) })
			}
		case app.ConfigEvent:
			maximized = e.Config.Mode == app.Maximized
			a.Maximized = maximized
		case app.FrameEvent:
			if !started && !engineOS() {
				started = true
				a.Started(webview.ErrUnavailable)
			}
			// the interface fills the whole window and keeps clear of the system
			// bars itself (a.Insets), so the pages share its coordinates
			insets := e.Insets
			e.Insets = app.Insets{}
			gtx := app.NewContext(&ops, e)
			scale := gtx.Metric.PxPerDp
			a.Scale = scale
			if frames < 3 {
				gtx.Execute(key.FocusCmd{Tag: tag})
				frames++
			}
			rd.Read(gtx, in, scale)
			for n := h.backs.Swap(0); n > 0; n-- {
				in.Keys = append(in.Keys, ui.KeyPress{Key: ui.KBack})
			}
			in.Now = time.Since(start).Seconds()
			if mobile {
				// clear of the status bar, the navigation bar and the keyboard
				m := gtx.Metric
				a.Insets = [4]float32{float32(m.Dp(insets.Top)) / scale, float32(m.Dp(insets.Right)) / scale,
					float32(m.Dp(insets.Bottom)) / scale, float32(m.Dp(insets.Left)) / scale}
				if c := a.BarColor(); c != bars {
					bars = c
					nc := color.NRGBA{R: uint8(c >> 16), G: uint8(c >> 8), B: uint8(c), A: 255}
					w.Option(app.StatusColor(nc), app.NavigationColor(nc))
				}
			}

			area := clip.Rect{Max: e.Size}.Push(gtx.Ops)
			event.Op(gtx.Ops, tag)
			hint := key.HintText
			if a.EditingAddress() {
				hint = key.HintURL // the keyboard with "/" and ".com", no autocorrect
			}
			key.InputHintOp{Tag: tag, Hint: hint}.Add(gtx.Ops)
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
			rd.Publish(gtx, a.Editing())
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
