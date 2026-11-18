// Command litego-setup installs Lite Go for the current user (and removes it with --uninstall).
package main

import (
	"log"
	"os"
	"time"

	"gioui.org/app"
	"gioui.org/io/event"
	"gioui.org/io/key"
	"gioui.org/io/pointer"
	"gioui.org/io/system"
	"gioui.org/op"
	"gioui.org/op/clip"
	"gioui.org/unit"

	"image"

	"litego/giox"
	"litego/setup"
)

func main() {
	uninstallMode := false
	for _, a := range os.Args[1:] {
		if a == "--uninstall" || a == "/uninstall" {
			uninstallMode = true
		}
	}
	go func() {
		w := new(app.Window)
		title := "Iris Setup"
		if uninstallMode {
			title = "Remove Iris"
		}
		w.Option(app.Title(title), app.Size(unit.Dp(600), unit.Dp(480)), app.MinSize(unit.Dp(600), unit.Dp(480)), app.MaxSize(unit.Dp(600), unit.Dp(480)), app.Decorated(false))
		w.Perform(system.ActionCenter)
		if err := loop(w, uninstallMode); err != nil {
			log.Println(err)
			os.Exit(1)
		}
		os.Exit(0)
	}()
	app.Main()
}

type host struct {
	w     *app.Window
	after []func()
	quit  bool
}

func (h *host) Invalidate() { h.w.Invalidate() }
func (h *host) Minimize()   { h.after = append(h.after, func() { h.w.Perform(system.ActionMinimize) }) }
func (h *host) Close()      { h.quit = true; h.w.Invalidate() }

var tag = new(int)

func loop(w *app.Window, uninstallMode bool) error {
	h := &host{w: w}
	s := setup.New(h, uninstallMode)
	g := giox.NewGfx()
	rd := &giox.Reader{Tag: tag}
	var ops op.Ops
	start := time.Now()
	for {
		switch e := w.Event().(type) {
		case app.DestroyEvent:
			return e.Err
		case app.FrameEvent:
			gtx := app.NewContext(&ops, e)
			scale := gtx.Metric.PxPerDp
			rd.Read(gtx, s.In, scale)
			s.In.Now = time.Since(start).Seconds()
			area := clip.Rect{Max: e.Size}.Push(gtx.Ops)
			event.Op(gtx.Ops, tag)
			key.InputHintOp{Tag: tag, Hint: key.HintAny}.Add(gtx.Ops)
			area.Pop()
			g.Begin(gtx.Ops, scale)
			s.Frame(g, float32(e.Size.X)/scale, float32(e.Size.Y)/scale)
			g.End()
			for _, r := range s.MoveAreas {
				st := clip.Rect{Min: image.Pt(int(r.X*scale), int(r.Y*scale)), Max: image.Pt(int((r.X+r.W)*scale), int((r.Y+r.H)*scale))}.Push(gtx.Ops)
				system.ActionInputOp(system.ActionMove).Add(gtx.Ops)
				st.Pop()
			}
			pointer.CursorDefault.Add(gtx.Ops)
			e.Frame(gtx.Ops)
			for _, f := range h.after {
				f()
			}
			h.after = h.after[:0]
			if h.quit {
				return nil
			}
		}
	}
}
