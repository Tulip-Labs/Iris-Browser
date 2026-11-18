// Package route is the engine Iris's shell talks to on Linux: it draws each
// tab with Servo (light pages) or the heavy engine (Chromium), as core/route
// decides, and moves a tab between them when it crosses over. The shell sees
// one engine and one view per tab, as before. See docs/engines.md.
package route

import (
	"log"

	rules "iris/core/route"
	"iris/webview"
)

// Diverter is a light engine's view that asks before each navigation of its
// own (a link, a form, a script): divert returns true when the page should
// open in the heavy engine instead, and the view then does not go there.
type Diverter interface {
	SetDivert(divert func(url string) bool)
}

// Engine routes tabs between a light and a heavy engine.
type Engine struct {
	light, heavy webview.Engine
	rules        *rules.Router
	lightOK      bool
	next         int
}

// New makes the routing engine. light may be nil (Servo missing): every tab
// then goes to heavy.
func New(light, heavy webview.Engine, r *rules.Router) *Engine {
	if r == nil {
		r = rules.Open("")
	}
	return &Engine{light: light, heavy: heavy, rules: r, lightOK: light != nil}
}

// Rules are the routing rules (for the menu's "Open in full engine").
func (e *Engine) Rules() *rules.Router { return e.rules }

func (e *Engine) Start(window uintptr, dataDir string, low bool, ready func(err error)) {
	if e.light != nil {
		e.light.Start(window, dataDir, low, func(err error) {
			if err != nil {
				log.Println("Iris: Servo did not start, every page goes to Chromium:", err)
				e.lightOK = false
			}
		})
	}
	e.heavy.Start(window, dataDir, low, ready)
}

func (e *Engine) SetPolicy(p webview.Policy) {
	if e.light != nil {
		e.light.SetPolicy(p)
	}
	e.heavy.SetPolicy(p)
}

func (e *Engine) MemoryMB() float64 {
	m := e.heavy.MemoryMB()
	if e.light != nil {
		m += e.light.MemoryMB()
	}
	return m
}

// Version is the heavy engine's (the shell reads Chromium's version from it)
// followed by Servo's.
func (e *Engine) Version() string {
	if e.light != nil && e.lightOK {
		return e.heavy.Version() + " · " + e.light.Version()
	}
	return e.heavy.Version()
}

// pick is the engine for a tab with options o going to address u.
func (e *Engine) pick(o webview.Options, u string) rules.Engine {
	// Servo has one cookie jar: containers, private tabs and the heavy
	// engine's own pop-ups stay in the heavy engine
	if !e.lightOK || o.Profile != "" || o.Private || o.Sandbox || o.Popup != nil {
		return rules.Heavy
	}
	return e.rules.Pick(u)
}

func (e *Engine) engine(k rules.Engine) webview.Engine {
	if k == rules.Light {
		return e.light
	}
	return e.heavy
}

func (e *Engine) NewView(o webview.Options, ev webview.Events, done func(webview.View, error)) {
	e.next++
	v := &view{e: e, n: e.next, o: o, ev: ev, zoom: 1, visible: true}
	if o.Popup != nil {
		// a pop-up the heavy engine opened: its page is already there
		v.become(rules.Heavy, "", func() {})
	}
	done(v, nil)
}

// withExtensions is the routing engine when the heavy engine runs browser
// extensions: they run there (docs/engines.md).
type withExtensions struct {
	*Engine
	h webview.ExtensionHost
}

func (e withExtensions) AddExtension(dir string, done func(webview.Extension, error)) {
	e.h.AddExtension(dir, done)
}
func (e withExtensions) Extensions(done func([]webview.Extension, error)) { e.h.Extensions(done) }
func (e withExtensions) RemoveExtension(id string, done func(error))      { e.h.RemoveExtension(id, done) }
func (e withExtensions) EnableExtension(id string, on bool, done func(error)) {
	e.h.EnableExtension(id, on, done)
}

// Wrap is New as the engine the shell gets: it runs extensions exactly when
// the heavy engine does.
func Wrap(light, heavy webview.Engine, r *rules.Router) webview.Engine {
	e := New(light, heavy, r)
	if h, ok := heavy.(webview.ExtensionHost); ok {
		return withExtensions{e, h}
	}
	return e
}
