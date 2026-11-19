package route

import (
	"log"

	rules "iris/core/route"
	"iris/webview"
)

// view is one tab: the view of the engine drawing it now, and what the
// shell asked of it, so the next engine's view starts the same.
type view struct {
	e    *Engine
	n    int
	o    webview.Options
	ev   webview.Events
	kind rules.Engine
	cur  webview.View

	making  bool     // a view is being made
	waiting []func() // what was asked meanwhile
	gen     int      // which view the current events belong to
	url     string   // the page now
	closed  bool

	x, y, w, h    int
	bounds        bool
	visible       bool
	zoom          float64
	muted, bg     bool
	asleep, focus bool
}

// become makes sure the tab is drawn by engine k, then runs then.
func (v *view) become(k rules.Engine, why string, then func()) {
	if v.closed {
		return
	}
	if v.making {
		v.waiting = append(v.waiting, func() { v.become(k, why, then) })
		return
	}
	if v.cur != nil && v.kind == k {
		then()
		return
	}
	// a tab is never in both engines: the old engine lets it go now, before
	// the new one makes it
	if v.cur != nil {
		v.cur.Close()
		v.cur = nil
	}
	v.making = true
	v.gen++
	gen := v.gen
	name := map[rules.Engine]string{rules.Light: "Servo", rules.Heavy: "Chromium"}[k]
	log.Printf("Iris: tab %d drawn by %s%s", v.n, name, why)
	v.e.engine(k).NewView(v.o, v.events(gen, k), func(nv webview.View, err error) {
		v.making = false
		if err != nil || nv == nil {
			if k == rules.Light {
				// Servo could not make the page: Chromium does
				v.become(rules.Heavy, " (Servo failed)", then)
			} else if v.ev.Crashed != nil {
				v.ev.Crashed()
			}
			v.flush()
			return
		}
		if v.closed {
			nv.Close()
			return
		}
		v.cur, v.kind = nv, k
		if d, ok := nv.(Diverter); ok {
			d.SetDivert(func(u string) bool {
				if v.gen != gen || v.e.pick(v.o, u) != rules.Heavy {
					return false
				}
				v.become(rules.Heavy, " ("+host(u)+")", func() { v.cur.Navigate(u) })
				return true
			})
		}
		// the new view starts as the shell left the tab
		if v.bounds {
			nv.SetBounds(v.x, v.y, v.w, v.h)
		}
		if v.zoom != 1 {
			nv.SetZoom(v.zoom)
		}
		if v.muted {
			nv.SetMuted(true)
		}
		if v.bg {
			nv.SetBackground(true)
		}
		nv.SetVisible(v.visible)
		then()
		if v.focus {
			nv.Focus()
		}
		v.flush()
	})
}

func (v *view) flush() {
	w := v.waiting
	v.waiting = nil
	for _, f := range w {
		f()
	}
}

// do runs f on the current view, once there is one.
func (v *view) do(f func(webview.View)) {
	if v.making {
		v.waiting = append(v.waiting, func() { v.do(f) })
		return
	}
	if v.cur != nil {
		f(v.cur)
	}
}

// events are the shell's events, from the view of generation gen only (a
// view being replaced says nothing more).
func (v *view) events(gen int, k rules.Engine) webview.Events {
	ev := v.ev
	live := func() bool { return v.gen == gen && !v.closed }
	out := ev
	out.URL = func(u string) {
		if !live() {
			return
		}
		v.url = u
		if ev.URL != nil {
			ev.URL(u)
		}
	}
	out.Crashed = func() {
		if !live() {
			return
		}
		if k == rules.Light && v.url != "" {
			// Servo could not draw this site: Chromium does, from now on
			u := v.url
			v.e.rules.Failed(u)
			v.become(rules.Heavy, " (Servo crashed on "+host(u)+")", func() { v.cur.Navigate(u) })
			return
		}
		if ev.Crashed != nil {
			ev.Crashed()
		}
	}
	guard := func(f func()) {
		if live() {
			f()
		}
	}
	if ev.Title != nil {
		out.Title = func(t string) { guard(func() { ev.Title(t) }) }
	}
	if ev.Loading != nil {
		out.Loading = func(on bool) { guard(func() { ev.Loading(on) }) }
	}
	if ev.History != nil {
		out.History = func(b, f bool) { guard(func() { ev.History(b, f) }) }
	}
	if ev.Audio != nil {
		out.Audio = func(on bool) { guard(func() { ev.Audio(on) }) }
	}
	if ev.Focus != nil {
		out.Focus = func() { guard(ev.Focus) }
	}
	return out
}

func (v *view) Navigate(u string) {
	v.url = u
	k := v.e.pick(v.o, u)
	v.become(k, " ("+host(u)+")", func() { v.cur.Navigate(u) })
}

func (v *view) Back()    { v.do(func(c webview.View) { c.Back() }) }
func (v *view) Forward() { v.do(func(c webview.View) { c.Forward() }) }
func (v *view) Reload()  { v.do(func(c webview.View) { c.Reload() }) }
func (v *view) Stop()    { v.do(func(c webview.View) { c.Stop() }) }

func (v *view) SetBounds(x, y, w, h int) {
	v.x, v.y, v.w, v.h, v.bounds = x, y, w, h, true
	v.do(func(c webview.View) { c.SetBounds(x, y, w, h) })
}

func (v *view) SetVisible(on bool) {
	v.visible = on
	v.do(func(c webview.View) { c.SetVisible(on) })
}

func (v *view) Sleep() {
	v.asleep = true
	v.do(func(c webview.View) { c.Sleep() })
}

func (v *view) Wake() {
	v.asleep = false
	v.do(func(c webview.View) { c.Wake() })
}

func (v *view) Focus() {
	v.focus = true
	v.do(func(c webview.View) { c.Focus() })
}

func (v *view) Eval(js string) { v.do(func(c webview.View) { c.Eval(js) }) }

func (v *view) Run(js string, done func(string)) {
	if v.cur == nil && !v.making {
		done("null")
		return
	}
	v.do(func(c webview.View) { c.Run(js, done) })
}

func (v *view) SetMuted(on bool) {
	v.muted = on
	v.do(func(c webview.View) { c.SetMuted(on) })
}

func (v *view) SetZoom(f float64) {
	v.zoom = f
	v.do(func(c webview.View) { c.SetZoom(f) })
}

func (v *view) SetBackground(on bool) {
	v.bg = on
	v.do(func(c webview.View) { c.SetBackground(on) })
}

func (v *view) Close() {
	v.closed = true
	v.gen++
	if v.cur != nil {
		v.cur.Close()
		v.cur = nil
	}
}

// Engine says which engine draws the tab now.
func (v *view) Engine() rules.Engine { return v.kind }

func host(u string) string {
	if i := indexAfter(u, "://"); i >= 0 {
		u = u[i:]
	}
	for i, c := range u {
		if c == '/' || c == '?' || c == '#' {
			return u[:i]
		}
	}
	return u
}

func indexAfter(s, sep string) int {
	for i := 0; i+len(sep) <= len(s); i++ {
		if s[i:i+len(sep)] == sep {
			return i + len(sep)
		}
	}
	return -1
}
