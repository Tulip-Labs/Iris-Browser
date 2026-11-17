package shell

import (
	"hash/fnv"
	"math"
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

const (
	barH   = 52
	ctlW   = 42 * 3
	panelW = 360
)

var (
	modeLabels = []string{"AI Mode", "Web", "Images", "Videos", "YouTube"}
	modeIcons  = []ui.Icon{ui.ISparkle, ui.IGlobe, ui.IImage, ui.IVideo, ui.IYouTube}
)

type suggestion struct {
	icon       ui.Icon
	title, sub string
	url        string
}

// chrome draws the window's one slim bar (navigation, the address, the tabs
// button and the menu) and returns where the page goes. Tabs live in the tab
// grid, opened from the bar, as on a phone.
func (a *App) chrome(full ui.Rect) ui.Rect {
	w := full.W
	addr := a.toolbar(ui.Rect{W: w, H: barH})
	y := float32(barH)

	// suggestions open under the address bar and push the page down (the page
	// is a native surface and would cover anything drawn over it)
	sugH := float32(0)
	if a.st.Focus == ID("addr") && len(a.sugg) > 0 {
		sugH = float32(len(a.sugg))*40 + 12
	}
	sugTop := y
	y += sugH
	if a.find.open {
		a.findBar(ui.Rect{X: 8, Y: y, W: w - 16, H: 40})
		y += 46
	}
	if a.bar.text != "" {
		if a.bar.until > 0 && a.now() > a.bar.until {
			a.bar = infobar{}
		} else {
			a.infobar(ui.Rect{X: 8, Y: y, W: w - 16, H: 40})
			y += 46
		}
	}
	x := float32(8)
	right := w - 8
	if a.panel {
		pw := min(float32(panelW), max(280, w*0.42))
		if w < 560 {
			pw = w - 16 // a phone-sized window: the menu takes the width
		}
		pr := ui.Rect{X: w - pw - 8, Y: sugTop, W: pw, H: full.H - sugTop - 8}
		a.drawPanel(pr)
		right = pr.X - 8
	} else if a.ai.open {
		pw := float32(aiW)
		if w < 900 {
			pw = min(320, w-16)
		}
		pr := ui.Rect{X: w - pw - 8, Y: sugTop, W: pw, H: full.H - sugTop - 8}
		a.drawAI(pr)
		right = pr.X - 8
	}
	if sugH > 0 {
		a.suggestions(ui.Rect{X: addr.X, Y: sugTop + 2, W: addr.W, H: sugH - 6}, ID("sugA"))
	}
	return ui.Rect{X: x, Y: y, W: max(0, right-x), H: max(0, full.H-y-8)}
}

// logo is Lite Go's mark: a liquid accent tile with a ring in motion and a spark.
func logo(g ui.Gfx, r ui.Rect, th *ui.Theme, base ui.Color) {
	ui.Shadow(g, r, r.W*0.3, th.Shadow, 0.6, 1.5)
	ui.FillRoundAccent(g, r, r.W*0.3, base)
	s := r.W / 24
	ring := ui.NewPath().Arc(r.CX(), r.CY(), 6.6*s, 140, 470, true)
	ui.Pen(g, ring, 2.1*s, ui.White)
	ui.FillOval(g, ui.RectAround(r.X+17.2*s, r.Y+7.4*s, 4.6*s, 4.6*s), th.Hl)
	ui.FillOval(g, ui.RectAround(r.CX(), r.CY(), 3.2*s, 3.2*s), ui.White)
}

func siteColor(host string) ui.Color {
	pal := []string{"#4f6bd8", "#c2457a", "#2f8f6b", "#b9741f", "#7b55c7", "#2a8fb0", "#b8403a", "#5d7a2b"}
	h := fnv.New32a()
	h.Write([]byte(strings.TrimPrefix(host, "www.")))
	return ui.Hex(pal[h.Sum32()%uint32(len(pal))])
}

func monogram(host string) string {
	h := core.SiteKey("https://" + host) // en.wikipedia.org is W, not E
	h = strings.TrimPrefix(h, "m.")
	for _, r := range h {
		return strings.ToUpper(string(r))
	}
	return "?"
}

// tabIcon draws a tab's leading icon in a 16x16 box at (x, y).
func (a *App) tabIcon(t *Tab, x, y float32) {
	g, th := a.u.G, a.u.Th
	switch {
	case t.Loading:
		a.u.Redraw = true
		ph := float32(math.Mod(a.now()*400, 360))
		ui.StrokeOval(g, ui.Rect{X: x + 1.5, Y: y + 1.5, W: 13, H: 13}, 2, th.Primary.Alpha(0.18))
		ui.Pen(g, ui.NewPath().Arc(x+8, y+8, 6.5, ph, ph+110, true), 2, th.Primary)
	case t.search != nil:
		ui.FillRoundAccent(g, ui.Rect{X: x, Y: y, W: 16, H: 16}, 5, th.Primary)
		ui.DrawIcon(g, modeIcons[t.search.Mode], x+2, y+2, 12, ui.White)
	case t.URL == "":
		ic, col := a.kindIcon(t)
		if t.Kind == KNormal {
			col = th.OnSurfaceVariant
		}
		ui.DrawIcon(g, ic, x, y, 16, col)
		return
	default:
		host := core.Host(t.URL)
		c := siteColor(host)
		ui.FillRoundAccent(g, ui.Rect{X: x, Y: y, W: 16, H: 16}, 5, c)
		ui.TextCenter(g, monogram(host), ui.Rect{X: x, Y: y, W: 16, H: 16}, ui.Font{Size: 10, Bold: true}, ui.White)
	}
	// the tab's kind as a small badge on its icon
	if t.Kind != KNormal {
		ic, col := a.kindIcon(t)
		badge(g, ui.Rect{X: x + 8.5, Y: y + 8.5, W: 11, H: 11}, ic, col, frameColor(th))
	}
}

func (t *Tab) label() string {
	switch {
	case t.URL == "" && t.Kind == KPrivate:
		return "Private tab"
	case t.URL == "" && t.Kind == KTemp:
		return "Temporary tab"
	case t.URL == "" && t.Kind == KContainer:
		return t.Container
	case t.URL == "":
		return "New tab"
	case t.Title != "":
		return t.Title
	}
	return core.Display(t.URL)
}

func (a *App) windowControls(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	bw := r.W / 3
	icons := []ui.Icon{ui.IMinimize, ui.IMaximize, ui.IClose}
	tips := []string{"Minimize", "Maximize", "Close"}
	if a.Maximized {
		icons[1], tips[1] = ui.IRestore, "Restore"
	}
	for i, ic := range icons {
		br := ui.Rect{X: r.X + float32(i)*bw, Y: r.Y, W: bw, H: r.H}
		id := ui.IdN("win", i)
		hot, down := u.Hover(br), u.IsActive(id)
		col := th.OnSurfaceVariant
		switch {
		case i == 2 && (hot || down):
			g.FillRect(br, ui.Hex("#c42b1c"))
			col = ui.White
		case down:
			g.FillRect(br, th.Ink.Alpha(0.12))
		case hot:
			g.FillRect(br, th.Ink.Alpha(0.07))
		}
		ui.DrawIcon(g, ic, br.CX()-8, br.CY()-8, 16, col)
		u.Tooltip(tips[i], br)
		if u.Clickable(id, br) {
			switch i {
			case 0:
				a.h.Minimize()
			case 1:
				a.h.ToggleMaximize()
			case 2:
				a.h.Close()
			}
		}
	}
}

// toolbar is the bar: back, forward and reload at the left (where the hand
// and the mouse start), the address in the middle, then the tabs button, the
// shield and the menu; on a narrow window only what is needed stays.
func (a *App) toolbar(r ui.Rect) ui.Rect {
	u, g, th := &a.u, a.u.G, a.u.Th
	t := a.tab()
	cy := r.CY()
	compact := r.W < 640
	a.windowControls(ui.Rect{X: r.R() - ctlW, Y: r.Y, W: ctlW, H: 40})
	rx := r.R() - ctlW - 6

	// navigation: one soft pill
	hasPage := t != nil && t.URL != ""
	n := 3
	if compact {
		n = 1
	}
	nav := ui.Rect{X: r.X + 10, Y: cy - 19, W: float32(n)*36 + 6, H: 38}
	ui.FillRound(g, nav, 19, th.Ink.Alpha(0.045))
	x := nav.X + 3
	btn := func(id string, ic ui.Icon, tip string, dis bool) bool {
		b := ui.Rect{X: x, Y: cy - 18, W: 36, H: 36}
		x += 36
		return u.IconButton(ID(id), b, ic, tip, ui.IconOpt{Disabled: dis})
	}
	if btn("back", ui.IArrowLeft, "Back  Alt+Left", t == nil || !t.canBack()) {
		a.do(actBack)
	}
	if !compact {
		if btn("fwd", ui.IArrowRight, "Forward  Alt+Right", t == nil || !t.canForward()) {
			a.do(actForward)
		}
		if t != nil && t.Loading {
			if btn("stop", ui.IClose, "Stop", false) && t.view != nil {
				v := t.view
				a.web(v.Stop)
				t.Loading = false
			}
		} else if btn("reload", ui.IReload, "Reload  Ctrl+R", !hasPage) {
			a.do(actReload)
		}
	}
	left := nav.R() + 10

	// right: menu, shield, downloads, tabs, and Sign in until Google knows you
	icon := func(id string, ic ui.Icon, tip string, on bool) bool {
		rx -= 38
		return u.IconButton(ID(id), ui.Rect{X: rx, Y: cy - 18, W: 36, H: 36}, ic, tip, ui.IconOpt{Toggled: on})
	}
	if icon("panel", ui.IMore, "Menu: tools, look, shields, memory and more  Ctrl+,", a.panel && a.panelMode == panelSettings) {
		a.togglePanel(panelSettings)
	}
	if !compact {
		rx -= 38
		a.shieldButton(ui.Rect{X: rx, Y: cy - 18, W: 36, H: 36}, t)
	}
	if len(a.downloads) > 0 {
		rx -= 38
		a.downloadButton(ui.Rect{X: rx, Y: cy - 18, W: 36, H: 36})
	}
	rx -= 44
	a.tabsButton(ui.Rect{X: rx, Y: cy - 19, W: 42, H: 38})
	if a.set.GoogleSignIn != "done" && !compact {
		lbl := "Sign in"
		bw := g.Measure(lbl, ui.FSmallBold) + 44
		rx -= bw + 6
		br := ui.Rect{X: rx, Y: cy - 16, W: bw, H: 32}
		if u.Button(ID("barsignin"), br, lbl, ui.ButtonOpt{Primary: true, Icon: ui.IPerson, HasIcon: true,
			Tip: "Sign in to Google once: results and AI answers then come without human checks"}) {
			a.signIn(t)
		}
	}
	rx -= 10

	// the address: centered in the window when there is room, never wider than a calm line
	aw := min(rx-left, float32(760))
	ax := max(left, min(r.CX()-aw/2, rx-aw))
	if ax > left+4 {
		a.MoveAreas = append(a.MoveAreas, ui.Rect{X: left, Y: r.Y, W: ax - left - 4, H: r.H})
	}
	if rx > ax+aw+4 {
		a.MoveAreas = append(a.MoveAreas, ui.Rect{X: ax + aw + 4, Y: r.Y, W: rx - ax - aw - 4, H: r.H})
	}
	ar := ui.Rect{X: ax, Y: cy - 19, W: aw, H: 38}
	a.addressBar(ar, t)
	if t != nil && t.Loading && t.URL != "" {
		u.Redraw = true
		p := float32(math.Mod(a.now()*0.9, 1))
		seg := ar.W * 0.28
		sx := ar.X + 14 + (ar.W-28+seg)*p - seg
		g.Save()
		g.Clip(ui.Rect{X: ar.X + 14, Y: ar.B() - 3, W: ar.W - 28, H: 3})
		ui.FillRoundAccent(g, ui.Rect{X: sx, Y: ar.B() - 2.5, W: seg, H: 2.5}, 1.25, th.Primary)
		g.Restore()
	}
	return ar
}

// tabsButton shows how many tabs are open and opens the tab list.
func (a *App) tabsButton(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	hot := u.Hover(r)
	if a.tabsOpen() {
		ui.FillRound(g, r, 12, th.SecondaryContainer)
	} else if hot {
		ui.FillRound(g, r, 12, th.Ink.Alpha(0.07))
	}
	box := ui.RectAround(r.CX(), r.CY(), 24, 22)
	col := th.OnSurface
	if a.tabsOpen() {
		col = th.OnSecondaryContainer
	}
	ui.StrokeRound(g, box, 7, 1.8, col)
	s := strconv.Itoa(len(a.tabs))
	if len(a.tabs) > 99 {
		s = ":D"
	}
	ui.TextCenter(g, s, box, ui.Font{Size: 11.5, Bold: true}, col)
	u.Tooltip("Tabs  Ctrl+Shift+A", r)
	if u.Clickable(ID("tabsbtn"), r) {
		a.toggleTabs()
	}
}

func (a *App) shieldButton(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	host := ""
	if t != nil {
		host = core.Host(t.URL)
	}
	on := a.shield.On && !a.siteOff(host)
	col := th.OnSurfaceVariant.Alpha(0.6)
	if on {
		col = th.Primary
	}
	tip := "Shield is off"
	if on {
		tip = "Shield blocks ads and trackers"
	}
	if u.IconButton(ID("shield"), r, ui.IShield, tip, ui.IconOpt{Accent: col}) {
		a.panel, a.panelMode = true, panelSettings
		a.panelScroll.Y = 0
	}
	if on && t != nil && t.Blocked > 0 {
		s := strconv.Itoa(t.Blocked)
		if t.Blocked > 999 {
			s = "999+"
		}
		f := ui.Font{Size: 9.5, Bold: true}
		bw := max(16, g.Measure(s, f)+8)
		br := ui.Rect{X: r.R() - bw + 2, Y: r.Y + 3, W: bw, H: 15}
		ui.FillRound(g, br, 7.5, th.Primary)
		ui.TextCenter(g, s, br, f, th.OnPrimary)
	}
}

func (a *App) siteOff(host string) bool {
	for _, h := range a.set.ShieldOff {
		if h == host {
			return true
		}
	}
	return false
}

func mb(v float64) string {
	if v >= 1024 {
		return strconv.FormatFloat(v/1024, 'f', 1, 64) + " GB"
	}
	return strconv.Itoa(int(v+0.5)) + " MB"
}

// addressBar is the search and address pill.
func (a *App) addressBar(r ui.Rect, t *Tab) {
	u, g, th, in := &a.u, a.u.G, a.u.Th, a.In
	id := ID("addr")
	focused := a.st.Focus == id
	if a.addrWas && !focused {
		a.sugg = nil
		if t != nil {
			a.addr.Set(t.addrText())
		}
	}
	rad := r.H / 2
	if focused {
		ui.Glass(g, r, rad, th, true, true)
		ui.FillRound(g, r, rad, th.Primary.Alpha(0.04))
		ui.StrokeRound(g, r.Inset(1), rad-1, 2, th.Primary)
	} else {
		ui.FillRound(g, r, rad, addrFill(th))
		if u.Hover(r) {
			ui.FillRound(g, r, rad, th.Ink.Alpha(0.05))
		}
	}
	// leading icon: security, or the search mode while typing
	ic, icCol := ui.IGlobe, th.OnSurfaceVariant
	tip := ""
	switch {
	case focused:
		ic, icCol = ui.ISearch, th.Primary
	case t != nil && strings.HasPrefix(t.URL, "https://"):
		ic, tip = ui.ILock, "Secure connection"
	case t != nil && strings.HasPrefix(t.URL, "http://"):
		ic, icCol, tip = ui.IWarning, th.Danger, "Not secure"
	case t == nil || t.URL == "":
		ic = ui.ISearch
	}
	if t != nil && t.search != nil && !focused {
		ic, icCol, tip = modeIcons[t.search.Mode], th.Primary, "Lite results"
	}
	ui.DrawIcon(g, ic, r.X+13, r.CY()-8, 16, icCol)
	u.Tooltip(tip, ui.Rect{X: r.X, Y: r.Y, W: 38, H: r.H})
	inner := ui.Rect{X: r.X + 36, Y: r.Y, W: r.W - 48, H: r.H}
	// the tab's kind, as a chip at the end
	if t != nil && t.Kind != KNormal {
		lbl := map[Kind]string{KPrivate: "Private", KTemp: "Temporary", KContainer: t.Container}[t.Kind]
		kic, col := a.kindIcon(t)
		cw := g.Measure(lbl, ui.FSmallBold) + 36
		cr := ui.Rect{X: r.R() - cw - 6, Y: r.CY() - 12, W: cw, H: 24}
		ui.FillRound(g, cr, 12, col.Alpha(0.16))
		ui.DrawIcon(g, kic, cr.X+8, cr.CY()-7, 14, col)
		g.Text(lbl, cr.X+27, ui.Mid(g, cr.Y, cr.H, ui.FSmallBold), ui.FSmallBold, ui.Mix(col, th.Ink, 0.35))
		inner.W -= cw + 6
	}
	if !focused {
		text := ""
		col := th.OnSurface
		if t != nil && t.search != nil {
			ui.TextFit(g, t.search.Q, inner.X, ui.Mid(g, r.Y, r.H, ui.FBody), ui.FBody, th.OnSurface, inner.W)
			if u.Live() && in.Pressed && r.Contains(in.MX, in.MY) {
				a.st.Focus = id
				a.addr.Set(t.search.Q)
				a.addr.SelectAll()
				a.sugg, a.sugSel = nil, 0
				in.Pressed = false
			}
			a.addrWas = a.st.Focus == id
			return
		}
		if t != nil && t.URL != "" {
			text = core.Display(t.URL)
		} else {
			text, col = "Search or type an address", th.Ink3
		}
		if t != nil && t.URL != "" {
			// host in full color, the rest softer
			host := strings.TrimPrefix(core.Host(t.URL), "www.")
			base := ui.Mid(g, r.Y, r.H, ui.FBody)
			if strings.HasPrefix(text, host) {
				hw := g.Measure(host, ui.FBody)
				g.Text(host, inner.X, base, ui.FBody, th.OnSurface)
				ui.TextFit(g, text[len(host):], inner.X+hw, base, ui.FBody, th.OnSurfaceVariant, inner.W-hw)
			} else {
				ui.TextFit(g, text, inner.X, base, ui.FBody, col, inner.W)
			}
		} else {
			ui.TextFit(g, text, inner.X, ui.Mid(g, r.Y, r.H, ui.FBody), ui.FBody, col, inner.W)
		}
		if u.Live() && in.Pressed && r.Contains(in.MX, in.MY) {
			a.st.Focus = id
			if t != nil {
				a.addr.Set(t.addrText())
			}
			a.addr.SelectAll()
			a.sugg, a.sugSel = nil, 0
			in.Pressed = false // the press only focuses
		}
		a.addrWas = a.st.Focus == id
		return
	}
	changed := u.TextField(id, inner, a.addr, ui.FieldOpt{Bare: true, OnEnter: func() { a.open(a.addr.Text()) }})
	if changed {
		a.suggest(a.addr.Text())
	}
	a.suggestKeys(id, func() {
		a.st.Focus = ui.ID{}
		a.sugg = nil
		if t != nil {
			a.addr.Set(t.addrText())
			if v := t.view; v != nil {
				a.web(v.Focus)
			}
		}
	})
	a.addrWas = a.st.Focus == id
}

func addrFill(th *ui.Theme) ui.Color {
	if th.Dark {
		return ui.Mix(th.G5, ui.White, 0.07)
	}
	return th.Surface
}

// suggestKeys moves the selection with the arrows; Escape runs cancel.
func (a *App) suggestKeys(id ui.ID, cancel func()) {
	in := a.In
	if a.st.Focus != id {
		return
	}
	if in.Has(ui.KDown, false) && len(a.sugg) > 0 {
		a.sugSel = (a.sugSel + 1) % len(a.sugg)
	}
	if in.Has(ui.KUp, false) && len(a.sugg) > 0 {
		a.sugSel = (a.sugSel + len(a.sugg) - 1) % len(a.sugg)
	}
	if in.Has(ui.KEscape, false) {
		if len(a.sugg) > 0 && id == ID("ntp") {
			a.sugg = nil
		} else {
			cancel()
		}
	}
}

// suggest fills the suggestion list for typed text.
func (a *App) suggest(text string) {
	q := strings.TrimSpace(text)
	a.sugSel = 0
	if q == "" {
		a.sugg = nil
		return
	}
	var out []suggestion
	seen := map[string]bool{}
	if core.IsURLLike(q) {
		u := core.URLFor(q)
		out = append(out, suggestion{ui.IGlobe, core.Display(u), "Open site", u})
		seen[u] = true
	} else {
		m := a.set.Mode
		out = append(out, suggestion{ui.ISearch, q, "Search", core.Resolve(q, m)})
	}
	for _, e := range a.hist.Suggest(q, 6) {
		if seen[e.URL] {
			continue
		}
		seen[e.URL] = true
		title := e.Title
		if title == "" {
			title = core.Display(e.URL)
		}
		out = append(out, suggestion{ui.IHistory, title, core.Display(e.URL), e.URL})
	}
	if !core.IsURLLike(q) && a.set.Mode != core.ModeYouTube {
		out = append(out, suggestion{ui.IYouTube, q, "Search YouTube", core.ModeYouTube.URL(q)})
	}
	a.sugg = out
}

// open goes to the selected suggestion, or resolves the text.
func (a *App) open(text string) {
	url := core.Resolve(text, a.set.Mode)
	if a.sugSel > 0 && a.sugSel < len(a.sugg) {
		url = a.sugg[a.sugSel].url
	}
	a.visit(url)
}

// visit opens url in the current tab and gives the keyboard to the page.
func (a *App) visit(url string) {
	t := a.tab()
	a.st.Focus = ui.ID{}
	a.sugg, a.sugSel = nil, 0
	if url == "" || t == nil {
		return
	}
	if t.URL != "" && t.search == nil && !t.Crashed && core.SiteKey(url) != core.SiteKey(t.URL) {
		// another website opens in a new tab; the page here stays
		n := a.newTab(t.Kind, t.Container, url, true)
		n.opener = t
		a.addr.Set(n.addrText())
		return
	}
	a.navigate(t, url)
	a.addr.Set(t.addrText())
	if v := t.view; v != nil {
		a.web(v.Focus)
	}
}

// suggestions draws the list in r.
func (a *App) suggestions(r ui.Rect, id ui.ID) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 18, th, true, true)
	y := r.Y + 6
	for i, s := range a.sugg {
		row := ui.Rect{X: r.X + 6, Y: y, W: r.W - 12, H: 40}
		if i == a.sugSel {
			ui.FillRound(g, row, 12, th.SecondaryContainer)
		} else if u.Hover(row) {
			ui.FillRound(g, row, 12, th.Ink.Alpha(0.05))
		}
		ui.DrawIcon(g, s.icon, row.X+12, row.CY()-9, 18, th.OnSurfaceVariant)
		f := ui.FBody
		tw := g.Measure(s.title, f)
		maxT := row.W * 0.62
		ui.TextFit(g, s.title, row.X+42, ui.Mid(g, row.Y, row.H, f), f, th.OnSurface, maxT)
		sx := row.X + 42 + min(tw, maxT) + 12
		ui.TextFit(g, s.sub, sx, ui.Mid(g, row.Y, row.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant, row.R()-sx-10)
		if u.Hover(row) && u.In.Pressed {
			u.In.Pressed = false // keep the field focused
			a.visit(s.url)
			return
		}
		y += 40
	}
	_ = id
}

func (a *App) infobar(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	bg, fg, ic := th.SecondaryContainer, th.OnSecondaryContainer, ui.IInfo
	if a.bar.warn {
		bg, fg, ic = th.ErrorContainer, th.OnErrorContainer, ui.IWarning
	}
	ui.FillRound(g, r, 14, bg)
	ui.DrawIcon(g, ic, r.X+12, r.CY()-9, 18, fg)
	right := r.R() - 40
	if u.IconButton(ID("barx"), ui.Rect{X: r.R() - 38, Y: r.CY() - 16, W: 32, H: 32}, ui.IClose, "Dismiss", ui.IconOpt{}) {
		a.bar = infobar{}
		return
	}
	if a.bar.action != "" {
		bw := g.Measure(a.bar.action, ui.FBodyBold) + 32
		br := ui.Rect{X: right - bw, Y: r.CY() - 15, W: bw, H: 30}
		if u.Button(ID("bara"), br, a.bar.action, ui.ButtonOpt{Primary: a.bar.warn}) {
			do := a.bar.do
			a.bar = infobar{}
			if do != nil {
				do()
			}
			return
		}
		right = br.X - 8
	}
	if a.bar.action2 != "" {
		bw := g.Measure(a.bar.action2, ui.FBodyBold) + 28
		br := ui.Rect{X: right - bw, Y: r.CY() - 15, W: bw, H: 30}
		if u.Button(ID("barb"), br, a.bar.action2, ui.ButtonOpt{}) {
			do := a.bar.do2
			a.bar = infobar{}
			if do != nil {
				do()
			}
			return
		}
		right = br.X - 8
	}
	ui.TextFit(g, a.bar.text, r.X+40, ui.Mid(g, r.Y, r.H, ui.FBody), ui.FBody, fg, right-r.X-44)
}
