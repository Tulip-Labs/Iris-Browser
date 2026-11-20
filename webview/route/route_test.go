package route

import (
	"testing"

	rules "iris/core/route"
	"iris/webview"
)

type fView struct {
	eng     *fEngine
	ev      webview.Events
	nav     []string
	closed  bool
	visible bool
	x, w    int
	zoom    float64
	divert  func(string) bool
}

func (v *fView) Navigate(u string) {
	if v.divert != nil && v.divert(u) {
		return
	}
	v.nav = append(v.nav, u)
	if v.ev.URL != nil {
		v.ev.URL(u)
	}
}
func (v *fView) Back()                         {}
func (v *fView) Forward()                      {}
func (v *fView) Reload()                       {}
func (v *fView) Stop()                         {}
func (v *fView) SetBounds(x, y, w, h int)      { v.x, v.w = x, w }
func (v *fView) SetVisible(on bool)            { v.visible = on }
func (v *fView) Sleep()                        {}
func (v *fView) Wake()                         {}
func (v *fView) Focus()                        {}
func (v *fView) Eval(string)                   {}
func (v *fView) Run(js string, d func(string)) { d("1") }
func (v *fView) SetMuted(bool)                 {}
func (v *fView) SetZoom(f float64)             { v.zoom = f }
func (v *fView) SetBackground(bool)            {}
func (v *fView) Close()                        { v.closed = true }

type divView struct{ *fView }

func (d divView) SetDivert(f func(string) bool) { d.divert = f }

type fEngine struct {
	name    string
	views   []*fView
	divert  bool
	pending []func() // NewView answers later (as the Electron engine does)
	async   bool
}

func (e *fEngine) Start(uintptr, string, bool, func(error)) {}
func (e *fEngine) NewView(o webview.Options, ev webview.Events, done func(webview.View, error)) {
	v := &fView{eng: e, ev: ev, zoom: 1}
	e.views = append(e.views, v)
	answer := func() {
		if e.divert {
			done(divView{v}, nil)
		} else {
			done(v, nil)
		}
	}
	if e.async {
		e.pending = append(e.pending, answer)
		return
	}
	answer()
}
func (e *fEngine) SetPolicy(webview.Policy) {}
func (e *fEngine) MemoryMB() float64        { return 1 }
func (e *fEngine) Version() string          { return e.name }

func setup() (*Engine, *fEngine, *fEngine, *[]string) {
	light := &fEngine{name: "Servo 0.4", divert: true}
	heavy := &fEngine{name: "156.0"}
	e := New(light, heavy, rules.Open(""))
	var urls []string
	return e, light, heavy, &urls
}

func newTab(t *testing.T, e *Engine, urls *[]string) webview.View {
	var got webview.View
	e.NewView(webview.Options{}, webview.Events{URL: func(u string) { *urls = append(*urls, u) }}, func(v webview.View, err error) { got = v })
	if got == nil {
		t.Fatal("no view")
	}
	return got
}

func TestLightThenHeavy(t *testing.T) {
	e, light, heavy, urls := setup()
	v := newTab(t, e, urls)
	v.SetBounds(10, 0, 800, 600)
	v.SetZoom(1.25)
	v.Navigate("https://en.wikipedia.org/wiki/Red_panda")
	if len(light.views) != 1 || len(heavy.views) != 0 || light.views[0].nav[0] != "https://en.wikipedia.org/wiki/Red_panda" {
		t.Fatal("Wikipedia goes to Servo")
	}
	if light.views[0].w != 800 || light.views[0].zoom != 1.25 {
		t.Error("the view starts where the tab is")
	}
	// typed into the address bar: YouTube goes to Chromium, Servo's view closes
	v.Navigate("https://www.youtube.com/")
	if len(heavy.views) != 1 || !light.views[0].closed || heavy.views[0].w != 800 || heavy.views[0].zoom != 1.25 {
		t.Fatal("YouTube moves the tab to Chromium, as it was")
	}
	// and back
	v.Navigate("https://example.com/")
	if len(light.views) != 2 || !heavy.views[0].closed {
		t.Error("an article goes back to Servo")
	}
	if e.Version() != "156.0 · Servo 0.4" {
		t.Errorf("version %q", e.Version())
	}
}

func TestLinkInServoDiverts(t *testing.T) {
	e, light, heavy, urls := setup()
	v := newTab(t, e, urls)
	v.Navigate("https://news.example/")
	// a link in the page (Servo asks before it goes)
	light.views[0].Navigate("https://www.linkedin.com/feed/")
	if len(heavy.views) != 1 || len(heavy.views[0].nav) != 1 || heavy.views[0].nav[0] != "https://www.linkedin.com/feed/" {
		t.Fatal("a link to LinkedIn opens in Chromium")
	}
	if len(light.views[0].nav) != 1 {
		t.Error("Servo did not go to LinkedIn itself")
	}
}

func TestServoCrashRemembered(t *testing.T) {
	e, light, heavy, urls := setup()
	v := newTab(t, e, urls)
	v.Navigate("https://fancy.example/app")
	light.views[0].ev.Crashed()
	if len(heavy.views) != 1 || heavy.views[0].nav[0] != "https://fancy.example/app" {
		t.Fatal("the page opens again in Chromium")
	}
	if e.Rules().Pick("https://fancy.example/other") != rules.Heavy {
		t.Error("the site is remembered")
	}
}

func TestContainersStayHeavy(t *testing.T) {
	e, light, heavy, _ := setup()
	var v webview.View
	e.NewView(webview.Options{Profile: "c-work"}, webview.Events{}, func(nv webview.View, err error) { v = nv })
	v.Navigate("https://en.wikipedia.org/")
	if len(light.views) != 0 || len(heavy.views) != 1 {
		t.Error("containers have their own cookies: Chromium")
	}
}

func TestCallsWhileMaking(t *testing.T) {
	e, _, heavy, urls := setup()
	heavy.async = true
	v := newTab(t, e, urls)
	v.Navigate("https://example.com/")
	v.Navigate("https://www.youtube.com/")
	if !e.light.(*fEngine).views[0].closed {
		t.Error("the tab left Servo the moment it moved, not once Chromium was ready")
	}
	v.SetBounds(5, 0, 640, 480)
	v.SetVisible(false)
	if len(heavy.views) != 1 || len(heavy.pending) != 1 {
		t.Fatal("making")
	}
	heavy.pending[0]()
	hv := heavy.views[0]
	if hv.w != 640 || hv.visible || len(hv.nav) != 1 {
		t.Errorf("calls made while the view was being made: w=%d visible=%v nav=%v", hv.w, hv.visible, hv.nav)
	}
	var got string
	v.Run("1", func(s string) { got = s })
	if got != "1" {
		t.Error("run")
	}
}

func TestNoServo(t *testing.T) {
	heavy := &fEngine{name: "156.0"}
	e := New(nil, heavy, nil)
	var v webview.View
	e.NewView(webview.Options{}, webview.Events{}, func(nv webview.View, err error) { v = nv })
	v.Navigate("https://en.wikipedia.org/")
	if len(heavy.views) != 1 || e.Version() != "156.0" {
		t.Error("without Servo every page goes to Chromium")
	}
}

type extEngine struct{ fEngine }

func (e *extEngine) AddExtension(string, func(webview.Extension, error)) {}
func (e *extEngine) Extensions(done func([]webview.Extension, error))    { done(nil, nil) }
func (e *extEngine) RemoveExtension(string, func(error))                 {}
func (e *extEngine) EnableExtension(string, bool, func(error))           {}

func TestExtensionsOnlyWhereHeavyHasThem(t *testing.T) {
	if _, ok := Wrap(&fEngine{}, &fEngine{}, nil).(webview.ExtensionHost); ok {
		t.Error("a heavy engine without extensions must not offer them")
	}
	if _, ok := Wrap(&fEngine{}, &extEngine{}, nil).(webview.ExtensionHost); !ok {
		t.Error("Electron runs extensions")
	}
}
