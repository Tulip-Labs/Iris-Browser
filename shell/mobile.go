package shell

import (
	"strconv"

	"litego/core"
	"litego/ui"
)

// The phone layout (Android): the address bar on top, the buttons at the
// bottom where the thumb is, tabs as a grid of cards, and the menu and the AI
// panel as full-screen sheets. Everything else (the new tab page, Lite
// results, Shields, the memory plan) is the same as on the desktop.

const (
	mBarH = 56 // the address row
	mNavH = 56 // the bottom buttons
)

// Mobile reports whether the interface uses the phone layout.
func (a *App) Mobile() bool { return a.cfg.Mobile }

// BarColor is the color for the system's status and navigation bars.
func (a *App) BarColor() ui.Color { return frameColor(a.theme()) }

// EditingAddress says whether the address bar has the keyboard.
func (a *App) EditingAddress() bool { return a.st.Focus == ID("addr") }

// Editing is the text field being edited, for the host's input method (nil: none).
func (a *App) Editing() *ui.TextEdit { return a.st.Editing }

// mobileChrome draws the phone's bars and returns where the page goes (empty
// while a sheet covers it).
func (a *App) mobileChrome(full ui.Rect) ui.Rect {
	u, g, th := &a.u, a.u.G, a.u.Th
	in := a.Insets
	w := full.W
	t := a.tab()
	top := in[0]
	bottom := full.H - in[2]
	typing := a.st.Focus == ID("addr")

	// the address row: shield, address, AI
	row := ui.Rect{X: in[3], Y: top, W: w - in[3] - in[1], H: mBarH}
	cy := row.CY()
	a.shieldButton(ui.Rect{X: row.X + 6, Y: cy - 20, W: 40, H: 40}, t)
	ax := row.X + 50
	rx := row.R() - 6
	if !typing {
		rx -= 40
		if u.IconButton(ID("ai"), ui.Rect{X: rx, Y: cy - 20, W: 40, H: 40}, ui.ISparkle, "Ask AI about this page", ui.IconOpt{Toggled: a.ai.open, Accent: th.Primary}) {
			if a.ai.open {
				a.ai.open = false
			} else {
				a.tabsOpen, a.panel = false, false
				a.openAI("")
			}
		}
		rx -= 4
	}
	ar := ui.Rect{X: ax, Y: cy - 21, W: rx - ax, H: 42}
	a.addressBar(ar, t)
	if t != nil && t.Loading && t.URL != "" {
		u.Redraw = true
		p := float32(a.now()*0.9) - float32(int(a.now()*0.9))
		seg := ar.W * 0.28
		sx := ar.X + 12 + (ar.W-24+seg)*p - seg
		g.Save()
		g.Clip(ui.Rect{X: ar.X + 12, Y: ar.B() - 3, W: ar.W - 24, H: 3})
		ui.FillRoundAccent(g, ui.Rect{X: sx, Y: ar.B() - 2.5, W: seg, H: 2.5}, 1.25, th.Primary)
		g.Restore()
	}
	y := row.B()

	// suggestions push the page down (the page is a native view over us)
	if typing && len(a.sugg) > 0 {
		sugH := float32(len(a.sugg))*44 + 12
		a.suggestions(ui.Rect{X: row.X + 8, Y: y + 2, W: row.W - 16, H: sugH - 6}, ID("sugA"))
		y += sugH
	}
	if a.bar.text != "" {
		if a.bar.until > 0 && a.now() > a.bar.until {
			a.bar = infobar{}
		} else {
			a.infobar(ui.Rect{X: row.X + 8, Y: y, W: row.W - 16, H: 40})
			y += 46
		}
	}

	// the bottom buttons (hidden while typing: the keyboard is there)
	if !typing {
		bottom -= mNavH
		a.mobileNav(ui.Rect{X: in[3], Y: bottom, W: w - in[3] - in[1], H: mNavH}, t)
	}
	area := ui.Rect{X: in[3], Y: y, W: w - in[3] - in[1], H: max(0, bottom-y)}
	switch {
	case a.tabsOpen:
		a.tabGrid(area)
		return ui.Rect{}
	case a.panel:
		a.drawPanel(area.Inset(6))
		return ui.Rect{}
	case a.ai.open:
		a.drawAI(area.Inset(6))
		return ui.Rect{}
	}
	return area
}

// mobileNav: back, forward, new tab, tabs, menu.
func (a *App) mobileNav(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	g.FillRect(ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 1}, th.Divider)
	slot := r.W / 5
	at := func(i int) ui.Rect {
		return ui.RectAround(r.X+slot*(float32(i)+0.5), r.CY(), 48, 48)
	}
	if u.IconButton(ID("mback"), at(0), ui.IArrowLeft, "Back", ui.IconOpt{Disabled: t == nil || !t.canBack()}) {
		a.closeSheets()
		a.do(actBack)
	}
	if u.IconButton(ID("mfwd"), at(1), ui.IArrowRight, "Forward", ui.IconOpt{Disabled: t == nil || !t.canForward()}) {
		a.closeSheets()
		a.do(actForward)
	}
	if u.IconButton(ID("mnew"), at(2), ui.IPlus, "New tab", ui.IconOpt{Accent: th.Primary}) {
		a.closeSheets()
		a.do(actNewTab)
		a.focusAddress()
	}
	// the tabs button: a rounded square with the count
	tr := at(3)
	if u.Clickable(ID("mtabs"), tr) {
		a.tabsOpen = !a.tabsOpen
		a.panel, a.ai.open = false, false
	}
	if a.tabsOpen || u.Hover(tr) {
		ui.FillRound(g, tr, 24, th.Ink.Alpha(0.08))
	}
	box := ui.RectAround(tr.CX(), tr.CY(), 22, 22)
	col := th.OnSurfaceVariant
	if a.tabsOpen {
		col = th.Primary
	}
	ui.StrokeRound(g, box, 6, 2, col)
	n := strconv.Itoa(len(a.tabs))
	if len(a.tabs) > 99 {
		n = "99+"
	}
	ui.TextCenter(g, n, box, ui.Font{Size: 11, Bold: true}, col)
	if u.IconButton(ID("mmenu"), at(4), ui.IMore, "Menu", ui.IconOpt{Toggled: a.panel}) {
		a.panel = !a.panel
		a.tabsOpen, a.ai.open = false, false
	}
}

func (a *App) closeSheets() { a.tabsOpen, a.panel, a.ai.open = false, false, false }

// tabGrid shows the open tabs as cards, two to a row.
func (a *App) tabGrid(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	g.FillRect(r, frameColor(th))
	// header: count, new private tab, done
	hr := ui.Rect{X: r.X + 16, Y: r.Y + 4, W: r.W - 32, H: 44}
	label := strconv.Itoa(len(a.tabs)) + " tabs"
	if len(a.tabs) == 1 {
		label = "1 tab"
	}
	g.Text(label, hr.X, ui.Mid(g, hr.Y, hr.H, ui.FTitle), ui.FTitle, th.OnSurface)
	bx := hr.R() - 72
	if u.Button(ID("tdone"), ui.Rect{X: bx, Y: hr.CY() - 18, W: 72, H: 36}, "Done", ui.ButtonOpt{Primary: true}) {
		a.tabsOpen = false
	}
	bx -= 44
	if u.IconButton(ID("tpriv"), ui.Rect{X: bx, Y: hr.CY() - 20, W: 40, H: 40}, ui.IPrivate, "New private tab", ui.IconOpt{}) {
		a.tabsOpen = false
		a.do(actPrivate)
		a.focusAddress()
	}
	body := ui.Rect{X: r.X, Y: hr.B() + 6, W: r.W, H: r.B() - hr.B() - 6}
	cols := 2
	if body.W >= 640 {
		cols = 3
	}
	gap := float32(12)
	cw := (body.W - 32 - gap*float32(cols-1)) / float32(cols)
	ch := cw * 1.15
	rows := (len(a.tabs) + cols - 1) / cols
	sc := &a.tabScroll
	sc.Content = float32(rows)*(ch+gap) + 16
	u.Scroll(ID("tgrid"), body, sc)
	g.Save()
	g.Clip(body)
	closeAt := -1
	for i, t := range a.tabs {
		c := ui.Rect{X: body.X + 16 + float32(i%cols)*(cw+gap), Y: body.Y + 4 + float32(i/cols)*(ch+gap) - sc.Y, W: cw, H: ch}
		if c.B() < body.Y || c.Y > body.B() {
			continue
		}
		if a.tabCard(i, t, c) {
			closeAt = i
		}
	}
	g.Restore()
	if closeAt >= 0 {
		a.closeTab(closeAt)
		if len(a.tabs) == 0 {
			a.tabsOpen = false
		}
	}
}

// tabCard draws one tab; it returns true when its close button was tapped.
func (a *App) tabCard(i int, t *Tab, c ui.Rect) bool {
	u, g, th := &a.u, a.u.G, a.u.Th
	cur := i == a.cur
	ui.Shadow(g, c, 16, th.Shadow, 0.5, 1)
	ui.FillRound(g, c, 16, pageColor(th))
	if cur {
		ui.StrokeRound(g, c.Inset(1), 15, 2.5, th.Primary)
	} else {
		ui.StrokeRound(g, c.Inset(0.5), 16, 1, th.OutlineVariant)
	}
	// title row
	a.tabIcon(t, c.X+12, c.Y+12)
	g.Save()
	g.Clip(ui.Rect{X: c.X + 34, Y: c.Y, W: c.W - 34 - 38, H: 40})
	ui.TextFit(g, t.label(), c.X+34, ui.Mid(g, c.Y+2, 36, ui.FSmallBold), ui.FSmallBold, th.OnSurface, c.W-34-38)
	g.Restore()
	closed := u.IconButton(ui.IdN("tclose", i), ui.Rect{X: c.R() - 38, Y: c.Y + 2, W: 36, H: 36}, ui.IClose, "Close tab", ui.IconOpt{})
	// the body: the site's mark, or what the tab is
	body := ui.Rect{X: c.X + 8, Y: c.Y + 40, W: c.W - 16, H: c.H - 48}
	ui.FillRound(g, body, 12, th.SurfaceHigh)
	switch {
	case t.search != nil:
		ui.DrawIcon(g, ui.ISearch, body.CX()-14, body.CY()-26, 28, th.Primary)
		ui.TextCenter(g, t.search.Q, ui.Rect{X: body.X + 8, Y: body.CY() + 6, W: body.W - 16, H: 22}, ui.FSmall, th.OnSurfaceVariant)
	case t.URL == "":
		ic, col := a.kindIcon(t)
		ui.DrawIcon(g, ic, body.CX()-16, body.CY()-16, 32, col)
	default:
		host := core.Host(t.URL)
		m := ui.RectAround(body.CX(), body.CY()-10, 44, 44)
		ui.FillRoundAccent(g, m, 13, siteColor(host))
		ui.TextCenter(g, monogram(host), m, ui.Font{Size: 22, Bold: true}, ui.White)
		ui.TextCenter(g, core.Display(t.URL), ui.Rect{X: body.X + 8, Y: m.B() + 6, W: body.W - 16, H: 20}, ui.FSmall, th.OnSurfaceVariant)
	}
	if !closed && u.Clickable(ui.IdN("tcard", i), c) {
		a.selectTab(i)
		a.tabsOpen = false
	}
	return closed
}

// mobileBack handles the system back button: it closes what is open, then
// goes back in the page, then sends Lite Go behind the other apps.
func (a *App) mobileBack() {
	t := a.tab()
	switch {
	case a.full:
		a.full = false
		a.h.SetFullscreen(a.winFull) // leaves the fullscreen video
	case a.st.Focus == ID("addr"):
		a.st.Focus = ui.ID{}
	case a.tabsOpen || a.panel || a.ai.open:
		a.closeSheets()
	case t != nil && t.search != nil && t.search.viewer.kind != vNone:
		t.search.viewer = viewer{}
	case t != nil && t.canBack():
		a.back(t)
	case t != nil && t.search != nil && t.pageURL == "" && len(a.tabs) > 1 && t.Kind != KNormal:
		a.closeTab(a.cur)
	default:
		a.h.Minimize() // the host sends the app to the back
	}
}
