package shell

import (
	"strings"
	"testing"
	"time"

	"litego/core"
	"litego/link"
	"litego/ui"
	"litego/webview"
)

func (d *driver) open(url string) *Tab {
	t := d.a.newTab(KNormal, "", url, true)
	d.frames(3)
	return t
}

func lastView(t *testing.T, tab *Tab) *fakeView {
	t.Helper()
	v, ok := tab.view.(*fakeView)
	if !ok {
		t.Fatalf("tab %q has no page", tab.URL)
	}
	return v
}

// A click on the websites column must never open a picture: the carousel
// beside it draws tiles past its own edge, and they used to take the click.
func TestResultsClickStaysInItsColumn(t *testing.T) {
	d := newResultsDriver(t, 1440, 900)
	d.typeText("red pandas")
	d.key(ui.KEnter, false, false)
	d.settle(14)
	tab := d.a.tab()
	if tab.search == nil || len(tab.search.Images) == 0 {
		t.Fatal("no results to click")
	}
	opened := 0
	for _, x := range []float32{880, 1100, 1400} {
		for y := float32(190); y < 880; y += 58 {
			d.click(x, y)
			d.frame()
			if tab.search == nil { // a link opened: that is what a click here is for
				opened++
				d.a.do(actBack)
				d.frames(2)
				if tab.search == nil {
					t.Fatalf("could not return to the results after the click at %v,%v", x, y)
				}
				continue
			}
			if k := tab.search.viewer.kind; k != vNone {
				t.Fatalf("click at %v,%v in the websites column opened the viewer (kind %d)", x, y, k)
			}
		}
	}
	if opened == 0 {
		t.Fatal("no click on the websites column opened a link")
	}
}

func TestHitLimits(t *testing.T) {
	var u ui.Ui
	u.In = ui.NewInput()
	u.In.MX, u.In.MY = 150, 50
	r := ui.Rect{X: 100, Y: 0, W: 100, H: 100}
	if !u.Over(r) {
		t.Fatal("the pointer is in r")
	}
	u.PushHit(ui.Rect{X: 0, Y: 0, W: 120, H: 100})
	if u.Over(r) {
		t.Fatal("outside the limit, r must not be hit")
	}
	u.PushHit(ui.Rect{X: 0, Y: 0, W: 500, H: 500}) // a wider limit inside a narrower one stays narrow
	if u.Over(r) {
		t.Fatal("limits must nest")
	}
	u.PopHit()
	u.PopHit()
	if !u.Over(r) {
		t.Fatal("limits must come off")
	}
}

func TestSplitView(t *testing.T) {
	d := newDriver(t, 1440, 900, true)
	d.frames(2)
	left := d.open("https://example.com/")
	d.a.do(actSplit)
	d.frames(2)
	right := d.a.tab()
	if right == left || d.a.split.a != left || d.a.split.b != right {
		t.Fatal("split view should open a second tab on the right and move there")
	}
	d.shot("split-newtab")
	d.typeText("example.org")
	d.key(ui.KEnter, false, false)
	d.frames(3)
	lv, rv := lastView(t, left), lastView(t, right)
	if !lv.visible || !rv.visible {
		t.Fatalf("both pages must show: left %v right %v", lv.visible, rv.visible)
	}
	if lv.bounds[0]+lv.bounds[2] > rv.bounds[0] || lv.bounds[2] < 300 || rv.bounds[2] < 300 {
		t.Fatalf("panes overlap or are too small: %v %v", lv.bounds, rv.bounds)
	}
	if lv.background || rv.background {
		t.Fatal("both panes are in use: neither is a background page")
	}
	d.shot("split")
	// a click inside the left page makes it the current tab; both stay
	lv.ev.Focus()
	d.frames(2)
	if d.a.tab() != left {
		t.Fatal("the pane that takes the keyboard should become the current tab")
	}
	if !lv.visible || !rv.visible {
		t.Fatal("changing pane must keep both pages")
	}
	// the split pair is never slept or unloaded while it shows
	d.advance(4000)
	if right.view == nil || right.asleep {
		t.Fatal("the other pane was put away while showing")
	}
	// another tab shows alone; coming back brings the pair back
	third := d.open("https://example.net/")
	if o, _ := d.a.splitWith(); o != nil {
		t.Fatal("a tab outside the pair shows alone")
	}
	tv := lastView(t, third)
	if tv.bounds[2] < 1000 {
		t.Fatalf("the single page should fill the window: %v", tv.bounds)
	}
	d.a.selectTab(d.a.indexOf(left))
	d.frames(3)
	if o, _ := d.a.splitWith(); o != right || right.view == nil {
		t.Fatal("selecting one of the pair should show both again")
	}
	// closing one ends the split
	d.a.closeTab(d.a.indexOf(right))
	d.frames(2)
	if d.a.split.a != nil {
		t.Fatal("closing a pane must end the split")
	}
	if lastView(t, left).bounds[2] < 1000 {
		t.Fatal("the remaining page should take the whole width")
	}
}

func TestDownloads(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	d.open("https://example.com/")
	if d.eng.policy.Download == nil {
		t.Fatal("the engine must be told where to report downloads")
	}
	canceled := false
	dl := webview.Download{ID: 7, URL: "https://example.com/files/setup.zip", Path: "/home/u/Downloads/setup.zip", Total: 1000, Received: 100,
		Cancel: func() { canceled = true }}
	d.eng.policy.Download(dl)
	d.frames(2)
	if n, _ := d.a.downloading(); n != 1 || len(d.a.downloads) != 1 || d.a.downloads[0].name != "setup.zip" {
		t.Fatalf("download not listed: %+v", d.a.downloads)
	}
	d.shot("download-running")
	d.a.do(actDownloads)
	d.frames(2)
	if !d.a.panel || d.a.panelMode != panelDownloads {
		t.Fatal("Ctrl+Shift+D should open the downloads list")
	}
	d.shot("downloads")
	d.a.In.Now += 1
	dl.Received = 600
	d.eng.policy.Download(dl)
	d.frames(2)
	if _, f := d.a.downloading(); f < 0.59 || f > 0.61 {
		t.Fatalf("progress %v", f)
	}
	if d.a.downloads[0].speed <= 0 {
		t.Fatal("no speed measured")
	}
	var opened, revealed string
	d.a.cfg.Sys.Open = func(p string) { opened = p }
	d.a.cfg.Sys.Reveal = func(p string) { revealed = p }
	dl.Received, dl.State, dl.Cancel = 1000, webview.DownloadDone, nil
	d.eng.policy.Download(dl)
	d.frames(2)
	if n, _ := d.a.downloading(); n != 0 || len(d.a.downloads) != 1 {
		t.Fatal("a finished download is no longer running, and stays listed")
	}
	_ = opened
	_ = revealed
	// a second one, canceled from the list
	dl2 := webview.Download{ID: 8, URL: "https://example.com/big.iso", Total: -1, Received: 10, Cancel: func() { canceled = true }}
	d.eng.policy.Download(dl2)
	d.frames(2)
	if _, f := d.a.downloading(); f != -1 {
		t.Fatalf("unknown size should report -1, got %v", f)
	}
	d.a.downloads[0].Cancel()
	if !canceled {
		t.Fatal("cancel did not reach the engine")
	}
	d.shot("downloads-two")
}

func TestSandboxForUnsafeSites(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	tab := d.a.tab()
	views := len(d.eng.views)
	d.a.navigate(tab, "https://paypal.com.account-check.xyz/login")
	d.frames(2)
	if d.a.bar.text == "" || d.a.bar.action != "Open in a sandbox" || !strings.Contains(d.a.bar.text, "paypal") {
		t.Fatalf("an unsafe address must be stopped with a warning: %+v", d.a.bar)
	}
	for _, v := range d.eng.views[views:] {
		if strings.Contains(v.url, "account-check") {
			t.Fatal("the unsafe page loaded before the reader chose")
		}
	}
	d.shot("unsafe-warning")
	if !d.eng.policy.Unsafe("https://paypal.com.account-check.xyz/login") || d.eng.policy.Unsafe("https://www.paypal.com/") {
		t.Fatal("the engine must stop unsafe links clicked inside pages, and only those")
	}
	d.a.bar.do()
	d.frames(3)
	if tab.Kind != KSandbox || !tab.private() {
		t.Fatalf("the page should open in a sandbox tab, kind %d", tab.Kind)
	}
	o := d.eng.opts[len(d.eng.opts)-1]
	if !o.Sandbox || !o.Private || !strings.HasPrefix(o.Profile, "sandbox-") {
		t.Fatalf("sandbox view options %+v", o)
	}
	if v := lastView(t, tab); !strings.Contains(v.url, "account-check.xyz") {
		t.Fatalf("sandbox loaded %q", v.url)
	}
	d.shot("sandbox")
	// plain http is offered the sandbox too, and is not upgraded inside it
	d.a.insecure(tab, "http://old.example.com/")
	if d.a.bar.action != "Open in a sandbox" || d.a.bar.action2 == "" {
		t.Fatalf("http warning %+v", d.a.bar)
	}
	d.a.navigate(tab, "http://old.example.com/")
	d.frames(2)
	if v := lastView(t, tab); v.url != "http://old.example.com/" {
		t.Fatalf("a sandbox opens what it is given: %q", v.url)
	}
	// "Trust it" lets a site through for the session
	n := d.a.newTab(KNormal, "", "", true)
	d.a.navigate(n, "https://xn--pple-43d.com/")
	if d.a.bar.do2 == nil {
		t.Fatal("no way to trust a site wrongly stopped")
	}
	d.a.bar.do2()
	d.frames(3)
	if n.Kind != KNormal || n.view == nil {
		t.Fatal("a trusted site opens normally")
	}
}

func TestAdaptiveShields(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	const clean, ads = "https://clean.example.org/", "https://news.example.com/"
	scan := d.eng.policy.Scan
	if scan == nil || !scan(clean) {
		t.Fatal("a site never seen must be scanned")
	}
	tab := d.open(clean)
	for i := 0; i < 3; i++ {
		if !tab.scanning {
			t.Fatalf("visit %d: the page should be under scan", i)
		}
		d.advance(25) // long enough to tell
		d.a.navigate(tab, clean)
		d.frames(3)
	}
	if st, _ := d.a.scan.State(clean); st != core.ScanStandby {
		t.Fatalf("three clean scans should put the shield on standby, state %d", st)
	}
	if scan(clean) {
		t.Fatal("a clean site's requests should skip the shield")
	}
	if tab.scanning {
		t.Fatal("a standby site is not scanned on every visit")
	}
	// a site with things to block stays under the shield
	tab2 := d.open(ads)
	tab2.Blocked = 6
	d.advance(25)
	if st, n := d.a.scan.State(ads); st != core.ScanActive || n != 6 {
		t.Fatalf("state %d found %d", st, n)
	}
	if !scan(ads) {
		t.Fatal("a site with ads must stay checked")
	}
	// private pages leave no record
	p := d.a.newTab(KPrivate, "", "https://secret.example.net/", true)
	d.frames(3)
	d.advance(25)
	if st, _ := d.a.scan.State("https://secret.example.net/"); st != core.ScanNew || p.scanning {
		t.Fatal("a private page was recorded")
	}
	// with the shield off there is nothing to check
	d.a.shield.On = false
	if scan(ads) {
		t.Fatal("shield off: no request needs checking")
	}
	d.a.shield.On = true
	// turning adaptive off checks everything again
	d.a.set.Adaptive = false
	d.a.applyPolicy()
	for _, f := range d.a.TakeWebCalls() {
		f()
	}
	if !d.eng.policy.Scan(clean) {
		t.Fatal("adaptive off: every site is checked")
	}
}

func TestBalancer(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	free := 4000
	d.a.cfg.Sys.FreeMB = func() int { return free }
	d.frames(2)
	var tabs []*Tab
	for i := 0; i < 4; i++ {
		tabs = append(tabs, d.open("https://site"+string(rune('a'+i))+".example.com/"))
	}
	d.advance(3)
	cur := d.a.tab()
	for _, tb := range tabs {
		v := lastView(t, tb)
		if (tb != cur) != v.background {
			t.Fatalf("%s: background %v, current %v", tb.URL, v.background, tb == cur)
		}
	}
	if d.a.balance.pressure {
		t.Fatal("no pressure with memory to spare")
	}
	free = 150 // the computer runs short
	d.advance(3)
	d.advance(3)
	if !d.a.balance.pressure {
		t.Fatal("short of memory: the balancer should see it")
	}
	_, asleep, unloaded := d.a.Counts()
	if asleep+unloaded < 3 {
		t.Fatalf("background pages should sleep at once: asleep %d unloaded %d", asleep, unloaded)
	}
	if cur.view == nil || cur.asleep {
		t.Fatal("the page in use must never be put away")
	}
	for i := 0; i < 6; i++ {
		d.advance(7)
	}
	if _, asleep, unloaded = d.a.Counts(); unloaded < 3 {
		t.Fatalf("still short: background pages should be unloaded one by one (asleep %d unloaded %d)", asleep, unloaded)
	}
	if cur.view == nil {
		t.Fatal("the page in use was unloaded")
	}
	free = 4000
	d.advance(3) // the reading
	d.advance(3) // and the tick that uses it
	if d.a.balance.pressure {
		t.Fatal("pressure should end when memory is back")
	}
	if p := d.a.plan; p.BudgetMB <= 0 {
		t.Fatalf("plan %+v", p)
	}
}

func TestZoomFindPrint(t *testing.T) {
	d := newDriver(t, 1280, 800, true)
	d.frames(2)
	tab := d.open("https://example.com/article")
	v := lastView(t, tab)
	d.a.do(actZoomIn)
	d.a.do(actZoomIn)
	d.frame()
	if v.zoom < 1.24 || v.zoom > 1.26 {
		t.Fatalf("zoom %v", v.zoom)
	}
	d.a.do(actZoomReset)
	d.frame()
	if v.zoom != 1 {
		t.Fatalf("zoom reset %v", v.zoom)
	}
	v.run = func(js string) string { return "3" }
	d.key(ui.KF, true, false)
	if !d.a.find.open || d.a.st.Focus != ID("find") {
		t.Fatal("Ctrl+F should open the find bar")
	}
	d.typeText("panda")
	d.frames(2)
	found := false
	for _, js := range v.evals {
		if strings.Contains(js, `window.find("panda"`) {
			found = true
		}
	}
	if !found || d.a.find.count != 3 {
		t.Fatalf("find did not run in the page: count %d evals %v", d.a.find.count, v.evals)
	}
	d.shot("find")
	d.key(ui.KEscape, false, false)
	if d.a.find.open {
		t.Fatal("Esc should close the find bar")
	}
	d.a.do(actPrint)
	d.frame()
	if last := v.evals[len(v.evals)-1]; !strings.Contains(last, "print()") {
		t.Fatalf("print: %q", last)
	}
}

func TestKindPickerAndSession(t *testing.T) {
	d := newDriver(t, 1280, 860, true)
	d.frames(2)
	d.shot("newtab-kinds")
	tab := d.a.tab()
	d.a.setKind(tab, KContainer, "Work")
	d.frames(2)
	d.typeText("example.com")
	d.key(ui.KEnter, false, false)
	d.frames(2)
	if o := d.eng.opts[len(d.eng.opts)-1]; o.Profile != "c-work" {
		t.Fatalf("a new tab turned into a container should use its profile: %+v", o)
	}
	// the container editor now lives on the new tab page
	n := d.a.newTab(KNormal, "", "", true)
	d.a.editCont = 0
	d.a.contName.Set(d.a.set.Containers[0].Name)
	d.frames(2)
	d.shot("newtab-container-editor")
	_ = n
	d.open("https://example.org/page")
	d.a.newTab(KPrivate, "", "https://private.example.com/", true)
	d.frames(2)
	d.a.saveSession()
	s := d.a.set.Session
	if len(s) != 2 || s[0].Container != "Work" || s[1].URL != "https://example.org/page" {
		t.Fatalf("session should keep the two ordinary pages, never the private one: %+v", s)
	}
	// the next window brings them back unloaded
	eng := &fakeEngine{}
	a2 := New(&fakeHost{}, Config{TotalMB: 8192, Version: "1.0", Engine: eng, Core: d.a.core})
	a2.Started(nil)
	var urls []string
	for _, tb := range a2.tabs {
		if tb.URL != "" {
			urls = append(urls, tb.URL)
			if tb.view != nil {
				t.Fatal("restored tabs must stay unloaded until opened")
			}
		}
	}
	if len(urls) != 2 || urls[1] != "https://example.org/page" {
		t.Fatalf("restored %v", urls)
	}
	if a2.tab().URL != "" {
		t.Fatal("the window should still open on a new tab")
	}
}

func TestPhoneLink(t *testing.T) {
	d := newDriver(t, 1280, 860, true)
	d.frames(2)
	tab := d.open("https://example.com/article")
	tab.Title = "An article"
	d.a.do(actPhone)
	d.frames(2)
	if st := d.a.tab(); !st.settings || d.a.setSec != "phone" {
		t.Fatal("Ctrl+Shift+L should open the phone settings")
	}
	d.shot("phone-off")
	d.a.startLink()
	if d.a.phone.srv == nil {
		t.Skip("no network here: " + d.a.phone.err)
	}
	defer d.a.stopLink()
	if len(d.a.phone.qr) < 21 || !strings.HasPrefix(d.a.phone.srv.URL(), "http://") {
		t.Fatalf("no code for %q", d.a.phone.srv.URL())
	}
	d.a.phone.srv.ShareText(tab.Title, tab.URL)
	d.frames(2)
	d.shot("phone")
	// a file from the phone lands in the downloads list
	d.a.linkEvent(d.a.phone.seq, link.Event{Kind: link.Receiving, ID: 1, Name: "IMG_0042.jpg", Path: "/home/u/Downloads/IMG_0042.jpg", Size: 4000, Got: 1000})
	d.a.linkEvent(d.a.phone.seq, link.Event{Kind: link.Received, ID: 1, Name: "IMG_0042.jpg", Path: "/home/u/Downloads/IMG_0042.jpg", Size: 4000, Got: 4000})
	if len(d.a.downloads) != 1 || d.a.downloads[0].name != "IMG_0042.jpg" || d.a.downloads[0].State != webview.DownloadDone {
		t.Fatalf("received file not listed: %+v", d.a.downloads)
	}
	d.a.stopLink()
	d.frames(2)
	if d.a.phone.srv != nil || d.a.phone.qr != nil {
		t.Fatal("closing the link must take the code away")
	}
}

// The pastel palettes: every screen drawn in each, for the eye.
func TestPastelThemes(t *testing.T) {
	for _, id := range []string{"peach", "mint", "sorbet", "lagoon"} {
		th := ui.ThemeByID(id)
		if th.ID != id || len(th.Grad) != 3 {
			t.Fatalf("palette %s is missing its gradient", id)
		}
		d := newResultsDriver(t, 1280, 800)
		d.a.set.Theme = id
		d.frames(2)
		d.shot("theme-" + id)
		d.a.togglePanel(panelSettings)
		d.frames(2)
		d.shot("theme-" + id + "-menu")
		d.a.panel = false
		d.typeText("red pandas")
		d.key(ui.KEnter, false, false)
		d.settle(14)
		d.shot("theme-" + id + "-results")
	}
}

func TestSideApps(t *testing.T) {
	d := newDriver(t, 1440, 900, true)
	d.frames(2)
	tab := d.open("https://example.com/")
	before := len(d.eng.views)
	d.a.do(actPass)
	d.frames(4)
	if !d.a.panel || d.a.panelMode != panelApp || d.a.apps[0].view == nil {
		t.Fatal("Proton Pass should open in the side panel")
	}
	pv2 := d.a.apps[0].view.(*fakeView)
	if pv2.url != "https://pass.proton.me/" || !pv2.visible || len(d.eng.views) != before+1 {
		t.Fatalf("Pass view: %q visible %v", pv2.url, pv2.visible)
	}
	pv := lastView(t, tab)
	if !pv.visible || pv.bounds[0]+pv.bounds[2] > pv2.bounds[0] || pv2.bounds[2] < 380 {
		t.Fatalf("the page and the side app must sit side by side: %v %v", pv.bounds, pv2.bounds)
	}
	d.shot("side-app")
	d.a.do(actPass)
	d.frames(2)
	if d.a.panel || pv2.visible {
		t.Fatal("closing the panel must hide the app")
	}
	d.a.do(actPass)
	d.frames(3)
	if d.a.apps[0].view != pv2 || !pv2.visible || len(d.eng.views) != before+1 {
		t.Fatal("coming back should show the same page")
	}
	d.a.panel = false
	d.frames(2)
	d.advance(1000)
	d.frames(2)
	if d.a.apps[0].view != nil || !pv2.closed {
		t.Fatal("a side app hidden for a long while should be closed")
	}
}

func TestSyncExchange(t *testing.T) {
	d := newDriver(t, 1280, 860, true)
	d.frames(2)
	d.open("https://example.com/desk")
	d.a.newTab(KPrivate, "", "https://private.example.com/", true)
	d.frames(2)
	d.a.set.Sync.Device = "pc"
	old := time.Now().Add(-time.Hour).Unix()
	out := d.a.exchange(link.State{Device: "phone", Name: "Pixel 8", Theme: "mint", ThemeAt: time.Now().Unix() + 5,
		Tabs:    []link.Tab{{URL: "https://news.example.org/", Title: "News"}},
		History: []link.Visit{{URL: "https://go.dev/doc", Title: "Go docs", Visits: 4, Last: old}}})
	if d.a.set.Theme != "mint" {
		t.Fatal("the newer palette choice should win")
	}
	if p := d.a.set.Sync.Peers; len(p) != 1 || p[0].Name != "Pixel 8" || len(p[0].Tabs) != 1 {
		t.Fatalf("peer %+v", p)
	}
	found := false
	for _, e := range d.a.hist.Recent(50, "go.dev") {
		found = found || e.URL == "https://go.dev/doc" && e.Visits == 4
	}
	if !found {
		t.Fatal("the phone's history was not merged")
	}
	if len(out.Tabs) != 1 || out.Tabs[0].URL != "https://example.com/desk" {
		t.Fatalf("the computer tells its ordinary tabs, never private ones: %+v", out.Tabs)
	}
	for _, v := range out.History {
		if strings.Contains(v.URL, "private.example.com") {
			t.Fatal("private history left the computer")
		}
	}
	// an older palette choice from the phone does not undo a newer one here
	d.a.set.Theme, d.a.set.ThemeAt = "peach", time.Now().Unix()+100
	d.a.exchange(link.State{Device: "phone", Name: "Pixel 8", Theme: "night", ThemeAt: 1})
	if d.a.set.Theme != "peach" {
		t.Fatal("an older choice must not win")
	}
	d.a.set.Sync.On = true
	d.a.openSettings("phone")
	d.frames(2)
	d.shot("sync")
}

func TestSettingsPageAndChrome(t *testing.T) {
	d := newDriver(t, 1440, 900, true)
	d.frames(2)
	page := d.open("https://example.com/article")
	v := lastView(t, page)
	// the status bar keeps the page off the bottom edge
	if b := v.bounds; b[1]+b[3] > 900-30 {
		t.Fatalf("the page covers the status bar: %v", b)
	}
	d.shot("statusbar")
	n := len(d.a.tabs)
	d.a.openSettings("look")
	d.frames(2)
	st := d.a.tab()
	if !st.settings || len(d.a.tabs) != n+1 || st.view != nil {
		t.Fatal("settings should open in a tab of its own, with no web page")
	}
	if v.visible {
		t.Fatal("the page must hide behind the settings tab")
	}
	for _, s := range settingsSections {
		d.a.setSec = s.id
		d.frames(2)
		d.shot("settings-" + s.id)
	}
	// opening it again goes to the same tab
	d.a.selectTab(0)
	d.a.openSettings("shields")
	if len(d.a.tabs) != n+1 || !d.a.tab().settings || d.a.setSec != "shields" {
		t.Fatal("one settings tab")
	}
	// typing an address there leaves the settings
	d.a.navigate(st, "https://example.org/")
	d.frames(3)
	if st.settings || st.view == nil {
		t.Fatal("navigating must turn the settings tab into a page")
	}
	// the + menu opens tabs of each kind
	d.a.do(actKinds)
	d.frames(2)
	if !d.a.kindOpen {
		t.Fatal("the kind menu should open")
	}
	d.shot("kind-menu")
	d.key(ui.KEscape, false, false)
	d.frames(1)
	if d.a.kindOpen {
		t.Fatal("Esc closes the kind menu")
	}
	// narrow window: the settings page shrinks its column to icons
	d2 := newDriver(t, 700, 760, true)
	d2.frames(2)
	d2.a.openSettings("containers")
	d2.frames(2)
	d2.shot("settings-narrow")
}
