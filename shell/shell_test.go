package shell

import (
	"os"
	"path/filepath"
	"testing"

	"litego/raster"
	"litego/ui"
	"litego/webview"
)

// ---- a fake engine that records what the interface asks of it ----

type fakeView struct {
	ev               webview.Events
	url              string
	visible, closed  bool
	asleep           bool
	bounds           [4]int
	focused, reloads int
}

func (v *fakeView) Navigate(u string) {
	v.url = u
	v.ev.URL(u)
	v.ev.Loading(true)
	v.ev.Loading(false)
}
func (v *fakeView) Back()                    {}
func (v *fakeView) Forward()                 {}
func (v *fakeView) Reload()                  { v.reloads++ }
func (v *fakeView) Stop()                    {}
func (v *fakeView) SetBounds(x, y, w, h int) { v.bounds = [4]int{x, y, w, h} }
func (v *fakeView) SetVisible(on bool)       { v.visible = on }
func (v *fakeView) Sleep()                   { v.asleep, v.visible = true, false }
func (v *fakeView) Wake()                    { v.asleep = false }
func (v *fakeView) Focus()                   { v.focused++ }
func (v *fakeView) Eval(string)              {}
func (v *fakeView) SetMuted(bool)            {}
func (v *fakeView) Close()                   { v.closed = true }

type fakeEngine struct {
	views []*fakeView
	opts  []webview.Options
}

func (e *fakeEngine) Start(uintptr, string, bool, func(error)) {}
func (e *fakeEngine) NewView(o webview.Options, ev webview.Events, done func(webview.View, error)) {
	v := &fakeView{ev: ev, visible: true}
	e.views = append(e.views, v)
	e.opts = append(e.opts, o)
	done(v, nil)
}
func (e *fakeEngine) SetPolicy(webview.Policy) {}
func (e *fakeEngine) MemoryMB() float64        { return 412 }
func (e *fakeEngine) Version() string          { return "142.0" }

type fakeHost struct{ full bool }

type noClip struct{}

func (noClip) Set(string) {}

func (h *fakeHost) Invalidate()             {}
func (h *fakeHost) Clipboard() ui.Clipboard { return noClip{} }
func (h *fakeHost) Minimize()               {}
func (h *fakeHost) ToggleMaximize()         {}
func (h *fakeHost) SetFullscreen(on bool)   { h.full = on }
func (h *fakeHost) Close()                  {}
func (h *fakeHost) FocusWindow()            {}

// ---- driver ----

var fonts = raster.NewFonts()

type driver struct {
	t    *testing.T
	a    *App
	eng  *fakeEngine
	w, h float32
	last *raster.Canvas
}

func newDriver(t *testing.T, w, h float32, withEngine bool) *driver {
	d := &driver{t: t, w: w, h: h}
	cfg := Config{TotalMB: 8192, Version: "1.0"}
	if withEngine {
		d.eng = &fakeEngine{}
		cfg.Engine = d.eng
	}
	d.a = New(&fakeHost{}, cfg)
	if withEngine {
		d.a.Started(nil)
	}
	d.a.In.Now = 1
	return d
}

func (d *driver) frame() {
	c := raster.New(int(d.w), int(d.h), 1, fonts)
	d.a.Frame(c, d.w, d.h)
	for _, f := range d.a.TakeWebCalls() {
		f()
	}
	if d.eng != nil {
		for _, v := range d.eng.views {
			if v.visible && !v.closed && v.bounds[2] > 0 {
				mockPage(c, v)
			}
		}
	}
	d.last = c
}

func (d *driver) frames(n int) {
	for i := 0; i < n; i++ {
		d.frame()
	}
}

func (d *driver) typeText(s string) { d.a.In.Typed = s; d.frame() }
func (d *driver) key(k ui.Key, ctrl, shift bool) {
	d.a.In.Keys = append(d.a.In.Keys, ui.KeyPress{Key: k, Ctrl: ctrl, Shift: shift})
	d.frame()
}
func (d *driver) click(x, y float32) {
	in := d.a.In
	in.MX, in.MY = x, y
	d.frame()
	in.Down, in.Pressed, in.PressX, in.PressY = true, true, x, y
	d.frame()
	in.Down, in.Released = false, true
	d.frame()
}

func (d *driver) shot(name string) {
	if dir := os.Getenv("SHOTS"); dir != "" {
		if err := d.last.SavePNG(filepath.Join(dir, name+".png")); err != nil {
			d.t.Fatal(err)
		}
	}
}

func (d *driver) advance(sec float64) {
	d.a.In.Now += sec
	d.frame()
}

// ---- tests ----

func TestStartsOnNewTabPage(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(3)
	if len(d.a.tabs) != 1 || d.a.tab().URL != "" {
		t.Fatal("must start with one new tab page")
	}
	if d.a.st.Focus != ID("ntp") {
		t.Fatal("the new tab page search must have the keyboard")
	}
	if d.a.spare == nil || d.a.spare.view == nil {
		t.Fatal("a spare page should be ready before the first search")
	}
	shot := d
	shot.shot("ntp")
}

func TestSearchOpensInSpareView(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	spare := d.eng.views[0]
	d.typeText("lofi beats")
	if len(d.a.sugg) == 0 {
		t.Fatal("no suggestions while typing")
	}
	d.shot("ntp-suggest")
	d.key(ui.KEnter, false, false)
	d.frames(2)
	tab := d.a.tab()
	if tab.view != webview.View(spare) {
		t.Fatal("the first page must use the spare view")
	}
	if want := "https://www.google.com/search?gl=us&hl=en&udm=50&q=lofi+beats"; spare.url != want {
		t.Fatalf("url %q, want %q", spare.url, want)
	}
	if !spare.visible || spare.bounds[2] == 0 {
		t.Fatalf("page not shown: visible=%v bounds=%v", spare.visible, spare.bounds)
	}
	if spare.focused == 0 {
		t.Fatal("the page should get the keyboard after a search")
	}
	if len(d.eng.views) != 1 {
		t.Fatal("no spare should be kept once no new tab page waits")
	}
	// the address bar shows the page and pushes suggestions above the page
	d.a.do(actAddress)
	d.frame()
	d.typeText("you")
	if d.a.st.Focus != ID("addr") || len(d.a.sugg) == 0 {
		t.Fatal("address bar did not suggest")
	}
	y := spare.bounds[1]
	if y < 88+40 {
		t.Fatalf("suggestions must push the page down, page top %d", y)
	}
	d.shot("address-suggest")
}

func TestHTTPSAndShortcuts(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	d.typeText("youtube.com")
	d.key(ui.KEnter, false, false)
	if got := d.a.tab().URL; got != "https://youtube.com" {
		t.Fatalf("got %q", got)
	}
	if vkAction(webview.Key{VK: 'T', Ctrl: true}) != actNewTab || vkAction(webview.Key{VK: 0x25, Alt: true}) != actBack {
		t.Fatal("page shortcuts")
	}
	d.key(ui.KT, true, false)
	if len(d.a.tabs) != 2 || d.a.cur != 1 {
		t.Fatal("Ctrl+T")
	}
	d.frame()
	if d.a.spare == nil || d.a.spare.view == nil {
		t.Fatal("a new tab page should prepare a spare page while the user types")
	}
	d.key(ui.KW, true, false)
	d.key(ui.KW, true, false)
	if len(d.a.tabs) != 1 || d.a.tab().URL != "" {
		t.Fatal("closing the last tab must leave a new tab page")
	}
	d.key(ui.KT, true, true)
	if d.a.tab().URL != "https://youtube.com" {
		t.Fatal("Ctrl+Shift+T must reopen")
	}
}

func TestMemoryPlan(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	for i := 0; i < 10; i++ {
		d.a.newTab(KNormal, "", "https://example"+string(rune('a'+i))+".com/", true)
		d.frame()
	}
	d.a.tabs[3].Audio = true
	d.advance(130) // past sleep
	live, asleep, unloaded := d.a.Counts()
	if live != 2 || asleep+unloaded != 8 { // the open tab and the one playing sound stay awake
		t.Fatalf("after 2 min: live %d asleep %d unloaded %d", live, asleep, unloaded)
	}
	if live+asleep > d.a.plan.Live {
		t.Fatalf("more pages held than the plan allows: %d", live+asleep)
	}
	d.advance(1000)
	_, asleep, unloaded = d.a.Counts()
	if asleep != 0 || unloaded != 8 {
		t.Fatalf("after 15 min: asleep %d unloaded %d", asleep, unloaded)
	}
	// clicking an unloaded tab brings its page back
	before := len(d.eng.views)
	d.a.selectTab(2)
	d.frames(2)
	if d.a.tab().view == nil || len(d.eng.views) == before {
		t.Fatal("unloaded tab did not reload")
	}
	if v := d.a.tab().view.(*fakeView); v.url != "https://examplec.com/" && v.url != "https://exampleb.com/" {
		t.Fatalf("reloaded %q", v.url)
	}
}

func TestPrivateAndContainers(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	d.a.do(actPrivate)
	d.frame()
	d.shot("private")
	d.typeText("example.com")
	d.key(ui.KEnter, false, false)
	o := d.eng.opts[len(d.eng.opts)-1]
	if !o.Private {
		t.Fatal("private tab must use an InPrivate profile")
	}
	d.a.newTab(KContainer, "Work", "https://mail.google.com/", true)
	d.frame()
	if o := d.eng.opts[len(d.eng.opts)-1]; o.Profile != "c-work" || o.Private {
		t.Fatalf("container profile %+v", o)
	}
	d.frame()
	d.shot("container")
}

func TestLayouts(t *testing.T) {
	d := newDriver(t, 1440, 900, true)
	d.frames(2)
	for _, u := range []string{"https://www.youtube.com/", "https://github.com/", "https://go.dev/doc/"} {
		d.a.newTab(KNormal, "", u, true)
		d.frame()
	}
	d.a.tabs[1].Title = "YouTube"
	d.a.tabs[2].Title = "GitHub"
	d.a.tabs[3].Title = "Documentation - The Go Programming Language"
	d.a.tabs[1].Blocked = 37
	d.a.tabs[1].Audio = true
	d.a.lastMem = -10
	d.a.selectTab(1)
	d.a.panel = true
	d.frames(2)
	d.shot("panel")
	d.a.panel = false
	d.a.set.VerticalTabs = true
	d.a.set.Theme = "night"
	d.frames(2)
	d.shot("vertical-night")
	// narrow windows still work
	d.w, d.h = 600, 820
	d.a.set.VerticalTabs = false
	d.a.set.Theme = "meadow"
	d.a.selectTab(0)
	d.frames(2)
	d.shot("narrow")
}

func TestNoEngine(t *testing.T) {
	d := newDriver(t, 1100, 720, false)
	d.frames(2)
	d.typeText("example.com")
	d.key(ui.KEnter, false, false)
	d.frames(2)
	d.shot("no-engine")
}

// mockPage stands in for the native page in screenshots (the real one is drawn by WebView2).
func mockPage(g ui.Gfx, v *fakeView) {
	r := ui.Rect{X: float32(v.bounds[0]), Y: float32(v.bounds[1]), W: float32(v.bounds[2]), H: float32(v.bounds[3])}
	g.FillRect(r, ui.White)
	ink := ui.Hex("#e9e9ee")
	g.FillRect(ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 56}, ui.Hex("#f6f6f8"))
	ui.FillRound(g, ui.Rect{X: r.X + 24, Y: r.Y + 16, W: 120, H: 24}, 6, ink)
	ui.FillRound(g, ui.Rect{X: r.CX() - 200, Y: r.Y + 12, W: 400, H: 32}, 16, ink)
	cols := int(max(1, (r.W-48)/260))
	cw := (r.W - 48 - float32(cols-1)*16) / float32(cols)
	for i := 0; i < cols*2; i++ {
		x := r.X + 24 + float32(i%cols)*(cw+16)
		y := r.Y + 80 + float32(i/cols)*(cw*0.56+70)
		if y+cw*0.56 > r.B() {
			break
		}
		ui.FillRound(g, ui.Rect{X: x, Y: y, W: cw, H: cw * 0.56}, 10, ink)
		ui.FillRound(g, ui.Rect{X: x, Y: y + cw*0.56 + 12, W: cw * 0.8, H: 12}, 6, ink)
		ui.FillRound(g, ui.Rect{X: x, Y: y + cw*0.56 + 32, W: cw * 0.5, H: 10}, 5, ink)
	}
	g.Text("Page area (drawn by WebView2 in the app)", r.X+24, r.B()-20, ui.FSmall, ui.Hex("#a0a0aa"))
}
