package shell

import (
	"context"
	"image"
	"image/color"
	"iris/shields"
	"strings"
	"time"

	"iris/core"
	"os"
	"path/filepath"
	"testing"

	"iris/raster"
	"iris/ui"
	"iris/webview"
)

// ---- a fake engine that records what the interface asks of it ----

type fakeView struct {
	ev               webview.Events
	url              string
	visible, closed  bool
	asleep           bool
	bounds           [4]int
	focused, reloads int
	backs            int
	run              func(js string) string
	evals            []string
	zoom             float64
	background       bool
}

func (v *fakeView) Navigate(u string) {
	v.url = u
	if v.ev.Loading != nil {
		v.ev.Loading(true)
	}
	if v.ev.URL != nil {
		v.ev.URL(u)
	}
	if v.ev.Loading != nil {
		v.ev.Loading(false)
	}
}
func (v *fakeView) Back()                    { v.backs++ }
func (v *fakeView) Forward()                 {}
func (v *fakeView) Reload()                  { v.reloads++ }
func (v *fakeView) Stop()                    {}
func (v *fakeView) SetBounds(x, y, w, h int) { v.bounds = [4]int{x, y, w, h} }
func (v *fakeView) SetVisible(on bool)       { v.visible = on }
func (v *fakeView) Sleep()                   { v.asleep, v.visible = true, false }
func (v *fakeView) Wake()                    { v.asleep = false }
func (v *fakeView) Focus()                   { v.focused++ }
func (v *fakeView) Eval(js string)           { v.evals = append(v.evals, js) }
func (v *fakeView) Run(js string, done func(string)) {
	if v.run != nil {
		done(v.run(js))
		return
	}
	done("null")
}
func (v *fakeView) SetMuted(bool)         {}
func (v *fakeView) SetZoom(f float64)     { v.zoom = f }
func (v *fakeView) SetBackground(on bool) { v.background = on }
func (v *fakeView) Close()                { v.closed = true }

type fakeEngine struct {
	run    func(js string) string
	views  []*fakeView
	opts   []webview.Options
	policy webview.Policy
}

func (e *fakeEngine) Start(uintptr, string, bool, func(error)) {}
func (e *fakeEngine) NewView(o webview.Options, ev webview.Events, done func(webview.View, error)) {
	v := &fakeView{ev: ev, visible: true, run: e.run}
	e.views = append(e.views, v)
	e.opts = append(e.opts, o)
	done(v, nil)
}
func (e *fakeEngine) SetPolicy(p webview.Policy) { e.policy = p }
func (e *fakeEngine) MemoryMB() float64          { return 412 }
func (e *fakeEngine) Version() string            { return "142.0" }

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
func (h *fakeHost) Quit()                   {}

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
	d.a.set.GoogleSignIn = "later" // the first-run sign-in has its own test
	if withEngine {
		d.eng.SetPolicy(d.a.Policy()) // as the host does before starting the engine
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
	if len(d.eng.views) != 0 {
		t.Fatal("no page is made ahead of time")
	}
	shot := d
	shot.shot("ntp")
}

func TestSearchOpensPage(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	d.a.set.LiteResults = false // this test is about the page itself
	d.typeText("lofi beats")
	if len(d.a.sugg) == 0 {
		t.Fatal("no suggestions while typing")
	}
	d.shot("ntp-suggest")
	d.key(ui.KEnter, false, false)
	d.frames(2)
	tab := d.a.tab()
	spare := lastView(t, tab)
	if want := core.ModeWeb.URL("lofi beats"); spare.url != want {
		t.Fatalf("url %q, want %q", spare.url, want)
	}
	if !spare.visible || spare.bounds[2] == 0 {
		t.Fatalf("page not shown: visible=%v bounds=%v", spare.visible, spare.bounds)
	}
	if spare.focused == 0 {
		t.Fatal("the page should get the keyboard after a search")
	}

	// the address bar shows the page and pushes suggestions above the page
	d.a.do(actAddress)
	d.frame()
	d.typeText("you")
	if d.a.st.Focus != ID("addr") || len(d.a.sugg) == 0 {
		t.Fatal("address bar did not suggest")
	}
	y := spare.bounds[1]
	if y < barH+40 {
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
	if d.a.tab().view != nil {
		t.Fatal("a new tab page holds no page until something opens")
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
	d.a.newTab(KContainer, "Work", "https://mail.google.com/", false)
	d.a.newTab(KPrivate, "", "https://example.com/", false)
	d.a.panel = true
	d.a.editCont = 0
	d.a.contName.Set("Work")
	d.frames(2)
	d.shot("panel")
	d.a.editCont = -1
	d.a.panel = false
	d.a.set.VerticalTabs = true
	d.a.set.Theme = "liquid"
	d.frames(2)
	d.shot("vertical-night")
	// narrow windows still work
	d.w, d.h = 600, 820
	d.a.set.VerticalTabs = false
	d.a.set.Theme = "daylight"
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

// ---- Iris results and the AI panel ----

func fixtures(js string) string {
	switch {
	case strings.Contains(js, "a h3"):
		return `{"web":[
 {"t":"Red panda - Wikipedia","u":"https://en.wikipedia.org/wiki/Red_panda","s":"The red panda (Ailurus fulgens) is a small mammal native to the eastern Himalayas and southwestern China. It has dense reddish-brown fur with a black belly and legs.","site":"Wikipedia"},
 {"t":"Red Panda | Species | WWF","u":"https://www.worldwildlife.org/species/red-panda","s":"Red pandas are shy, solitary animals that spend most of their lives in trees. They are endangered, with fewer than 10,000 left in the wild.","site":"World Wildlife Fund"},
 {"t":"Red panda facts and photos | National Geographic","u":"https://www.nationalgeographic.com/animals/mammals/facts/red-panda","s":"Learn how red pandas use their bushy tails for balance and warmth in cold mountain forests.","site":"National Geographic"},
 {"t":"Smithsonian's National Zoo: Red panda","u":"https://nationalzoo.si.edu/animals/red-panda","s":"Red pandas eat mostly bamboo leaves and shoots, plus fruit, roots and eggs.","site":"Smithsonian's National Zoo"}]}`
	case strings.Contains(js, "imgrefurl"):
		var b strings.Builder
		b.WriteString(`{"images":[`)
		for i := 0; i < 24; i++ {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"src":"https://img/` + string(rune('a'+i)) + `","page":"https://example.com/p","alt":"Red panda in a tree"}`)
		}
		b.WriteString(`]}`)
		return b.String()
	case strings.Contains(js, "aimc"):
		return `{"blocks":[
 {"k":"p","t":"red pandas","c":[]},
 {"k":"p","t":"**Red pandas** are small, tree-dwelling mammals of the **eastern Himalayas** and southwestern China, about the size of a house cat. Despite the name, they are not close relatives of giant pandas.","c":[1,2]},
 {"k":"h","t":"What they eat","c":[]},
 {"k":"li","t":"**Bamboo** leaves and shoots make up most of the diet, up to a third of their body weight a day.","c":[2,3]},
 {"k":"li","t":"Fruit, acorns, roots and eggs when they find them.","c":[4]},
 {"k":"h","t":"Why they are endangered","c":[]},
 {"k":"p","t":"Habitat loss and poaching have cut their numbers to **under 10,000** in the wild; protected forests and zoo programs are helping.","c":[2,5]},
 {"k":"p","t":"Show more","c":[]}],
 "src":[{"t":"Red panda - Wikipedia","u":"https://en.wikipedia.org/wiki/Red_panda"},{"t":"Red Panda | Species | WWF","u":"https://www.worldwildlife.org/species/red-panda"},{"t":"Red panda facts | National Geographic","u":"https://www.nationalgeographic.com/animals/mammals/facts/red-panda"},{"t":"Red panda | Smithsonian's National Zoo","u":"https://nationalzoo.si.edu/animals/red-panda"},{"t":"Red Panda Network","u":"https://redpandanetwork.org/"}],
 "ai":"Red pandas are small, tree-dwelling mammals.\nWhat they eat\nBamboo\nWhy they are endangered\nHabitat loss","busy":false}`
	case strings.Contains(js, "getSelection"):
		return `{"title":"Red panda - Wikipedia","url":"https://en.wikipedia.org/wiki/Red_panda","text":"The red panda is a small mammal.","sel":""}`
	}
	return "null"
}

func synthImage(seed int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, 160, 120))
	hues := [][3]int{{190, 80, 40}, {60, 110, 70}, {170, 120, 70}, {70, 90, 140}, {200, 150, 90}, {120, 60, 50}}
	h := hues[seed%len(hues)]
	for y := 0; y < 120; y++ {
		for x := 0; x < 160; x++ {
			k := (x + y + seed*13) % 255
			img.Set(x, y, color.RGBA{uint8((h[0] + k/3) % 256), uint8((h[1] + y/2) % 256), uint8((h[2] + x/4) % 256), 255})
		}
	}
	return img
}

func newResultsDriver(t *testing.T, w, h float32) *driver {
	d := newDriver(t, w, h, true)
	d.eng.run = fixtures
	n := 0
	d.a.fetchImage = func(ctx context.Context, src string, maxW int) (image.Image, error) {
		n++
		return synthImage(n), nil
	}
	d.a.ytSearch = func(ctx context.Context, q string) ([]core.VideoResult, error) {
		return []core.VideoResult{
			{ID: "a", Title: "Red Pandas: the Firefoxes of the Himalayas", Channel: "Nature Now", Length: "12:04", Views: "1.2M views", Age: "1 year ago"},
			{ID: "b", Title: "Baby red panda's first snow day", Channel: "Zoo Diaries", Length: "3:41", Views: "860K views", Age: "2 months ago"},
			{ID: "c", Title: "How red pandas survive the cold", Channel: "Wild Science", Length: "8:15", Views: "430K views", Age: "3 weeks ago"},
			{ID: "d", Title: "Red panda documentary (full)", Channel: "Earth Films", Length: "52:10", Views: "2.9M views", Age: "4 years ago"},
			{ID: "e", Title: "Feeding time at the red panda house", Channel: "City Zoo", Length: "5:02", Views: "120K views", Age: "6 days ago"},
			{ID: "f", Title: "Red panda vs giant panda: what is different?", Channel: "Explainers", Length: "9:48", Views: "2M views", Age: "1 year ago"},
		}, nil
	}
	d.frames(2)
	return d
}

func (d *driver) settle(n int) {
	for i := 0; i < n; i++ {
		time.Sleep(5 * time.Millisecond)
		d.advance(0.8)
	}
}

func TestAIPanel(t *testing.T) {
	d := newResultsDriver(t, 1440, 900)
	d.a.newTab(KNormal, "", "https://en.wikipedia.org/wiki/Red_panda", true)
	d.frames(3)
	d.a.tab().Title = "Red panda - Wikipedia"
	d.a.openAI("")
	d.frames(2)
	d.shot("ai-empty")
	d.a.askAI("Summarize this page")
	d.settle(10)
	turn := d.a.ai.turns[0]
	if turn.state != stDone || !strings.Contains(turn.ans.Text, "Bamboo") {
		t.Fatalf("no answer: %v %q", turn.state, turn.ans.Text)
	}
	turn.showSrc = true
	d.frames(2)
	d.shot("ai-answer")
}

func TestFirstRunSignIn(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.a.set.GoogleSignIn = ""
	d.frames(2)
	d.shot("signin")
	tab := d.a.tab()
	d.a.signIn(tab)
	d.frames(3)
	if !strings.HasPrefix(tab.URL, "https://accounts.google.com/") {
		t.Fatalf("sign-in should open: %q", tab.URL)
	}
	v := tab.view.(*fakeView)
	v.ev.URL("https://www.google.com/?hl=en&iris=signedin")
	d.frames(2)
	if d.a.set.GoogleSignIn != "done" || tab.URL != "" {
		t.Fatalf("sign-in not noticed: %q %q", d.a.set.GoogleSignIn, tab.URL)
	}
}

func TestLiteShields(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	e := shields.New()
	e.Add(strings.NewReader("||doubleclick.net^\n@@||doubleclick.net/ok/$script\nexample.com##.sponsored\n##.ad-slot\n"))
	d.a.core.Filters.Store(e)
	d.eng.run = func(js string) string {
		if strings.Contains(js, "classList") {
			return `{"c":["ad-slot","main"],"i":[]}`
		}
		return "null"
	}
	d.frames(2)
	p := d.a.Policy()
	if p.Allow("https://ad.doubleclick.net/x.js", "https://example.com/", "script") {
		t.Fatal("a listed ad should be blocked")
	}
	if !p.Allow("https://ad.doubleclick.net/ok/x.js", "https://example.com/", "script") {
		t.Fatal("an exception should let it load")
	}
	if !p.Allow("https://accounts.google.com/x.js", "https://example.com/", "script") {
		t.Fatal("sign-in is never blocked")
	}
	if p.Rewrite == nil || p.Rewrite("https://a.com/?utm_source=x&id=1") != "https://a.com/?id=1" {
		t.Fatal("links should be cleaned")
	}
	tab := d.a.newTab(KNormal, "", "https://www.example.com/news?fbclid=abc", true)
	d.settle(4)
	if tab.URL != "https://www.example.com/news" {
		t.Fatalf("typed address not cleaned: %q", tab.URL)
	}
	v := tab.view.(*fakeView)
	all := strings.Join(v.evals, "\n")
	if !strings.Contains(all, ".sponsored{display:none") || !strings.Contains(all, ".ad-slot{display:none") {
		t.Fatalf("hiding rules not applied: %q", all)
	}
}

func TestRunnableDownloads(t *testing.T) {
	for _, p := range []string{"/d/setup.exe", "/d/Setup.EXE", "/d/setup.exe.", "/d/setup.exe . ", "/d/x.AppImage", "/d/a.msix",
		"/d/s.vbe", "/d/disk.iso", "/d/l.url", "/d/i.appinstaller", "/d/run.sh"} {
		if !runnable(p) {
			t.Errorf("%s would be opened, not shown", p)
		}
	}
	for _, p := range []string{"/d/photo.jpg", "/d/doc.pdf", "/d/notes.txt", "/d/song.mp3", "/d/archive.tar.gz"} {
		if runnable(p) {
			t.Errorf("%s would only be shown in its folder", p)
		}
	}
}

func TestTimeLeft(t *testing.T) {
	for sec, want := range map[float64]string{-40: "1 s left", 5: "6 s left", 90: "2 min left", 7200: "2.0 h left", 1e9: "more than 99 h left"} {
		if got := timeLeft(sec); got != want {
			t.Errorf("timeLeft(%v) = %q, want %q", sec, got, want)
		}
	}
}

// A Google search opens on Google's own page (cleaned by the policy's
// script) with Iris's filters over it; a filter opens the same search with it.
func TestGoogleFilterBar(t *testing.T) {
	d := newDriver(t, 1440, 900, true)
	d.typeText("red pandas")
	d.key(ui.KEnter, false, false)
	d.frames(4)
	tab := d.a.tab()
	if tab.search != nil || tab.view == nil {
		t.Fatal("a Google search should open on Google's page")
	}
	v := tab.view.(*fakeView)
	if _, ok := core.ReadGoogleFilters(v.url); !ok {
		t.Fatalf("not a Google search: %s", v.url)
	}
	found := false
	for _, s := range d.eng.policy.Scripts {
		found = found || strings.Contains(s, "__irisG")
	}
	if !found {
		t.Fatal("the cleaning script is not in the policy")
	}
	top := float32(v.bounds[1])
	d.shot("google-filters")
	// the time filter is the first control of the bar over the page: Week is
	// its fourth of six segments (380 wide on a wide window)
	x := float32(v.bounds[0]) + 4 + 380*3.5/6
	d.click(x, top-44+(44-6-30)/2+15)
	d.frames(3)
	if f, _ := core.ReadGoogleFilters(v.url); f.Time != "w" {
		t.Fatalf("the Week filter did not apply: %s", v.url)
	}
}
