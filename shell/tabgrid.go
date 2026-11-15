package shell

import (
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

// The tab grid: every tab as a card, the way a phone shows tabs, so the bar
// stays one slim row and the page keeps the whole window. Type to find a
// tab; the arrows and Enter pick one; the row at the top opens new tabs of
// every kind.

// toggleTabs opens or closes the grid.
func (a *App) toggleTabs() {
	a.tabsOpen = !a.tabsOpen
	a.tabQ.Set("")
	a.tabSel = a.cur
	if a.tabsOpen {
		a.panel, a.ai.open = false, false
		a.st.Focus = ID("tabq")
		a.tabSc.Y = 0
		a.web(a.h.FocusWindow)
	} else if a.st.Focus == ID("tabq") {
		a.st.Focus = ui.ID{}
		a.refocusPage()
	}
}

// refocusPage gives the keyboard back to the current page.
func (a *App) refocusPage() {
	if t := a.tab(); t != nil && t.view != nil && t.URL != "" {
		v := t.view
		a.web(v.Focus)
	}
}

// matching lists the tabs the search names (all of them with no search).
func (a *App) matching() []int {
	q := strings.ToLower(strings.TrimSpace(a.tabQ.Text()))
	var out []int
	for i, t := range a.tabs {
		if q == "" || strings.Contains(strings.ToLower(t.label()), q) || strings.Contains(strings.ToLower(t.URL), q) {
			out = append(out, i)
		}
	}
	return out
}

func (a *App) tabGrid(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	fillPage(g, r, 14, th)
	g.Save()
	g.Clip(r)
	defer g.Restore()
	pad := float32(24)
	if r.W < 560 {
		pad = 12
	}
	x, w := r.X+pad, r.W-2*pad

	// header: the count and the search
	y := r.Y + 18
	title := strconv.Itoa(len(a.tabs)) + " tabs"
	if len(a.tabs) == 1 {
		title = "1 tab"
	}
	g.Text(title, x, y+24, ui.FBig, th.OnSurface)
	fw := min(360, w-g.Measure(title, ui.FBig)-24)
	fr := ui.Rect{X: x + w - fw, Y: y, W: fw, H: 38}
	ui.FillRound(g, fr, 19, addrFill(th))
	ui.DrawIcon(g, ui.ISearch, fr.X+12, fr.CY()-8, 16, th.OnSurfaceVariant)
	list := a.matching()
	pick := func(i int) {
		a.tabsOpen = false
		a.st.Focus = ui.ID{}
		a.selectTab(i)
	}
	u.TextField(ID("tabq"), ui.Rect{X: fr.X + 34, Y: fr.Y, W: fr.W - 44, H: fr.H}, a.tabQ, ui.FieldOpt{Bare: true, Placeholder: "Find a tab",
		OnEnter: func() {
			if len(list) > 0 {
				pick(a.selIn(list))
			}
		}})
	a.gridKeys(list, pick)
	y = fr.B() + 14

	// new tabs of every kind
	y = a.newTabRow(x, y, w) + 16

	// the cards
	area := ui.Rect{X: r.X, Y: y, W: r.W, H: r.B() - y}
	const gap = 14
	cols := max(1, int((w+gap)/(250+gap)))
	cw := (w - float32(cols-1)*gap) / float32(cols)
	ch := min(cw*0.72, 210)
	rows := (len(list) + cols - 1) / cols
	a.tabSc.Content = float32(rows)*(ch+gap) + 24
	u.Scroll(ID("tabgrid"), area, &a.tabSc)
	g.Save()
	g.Clip(area)
	u.PushHit(area)
	for k, i := range list {
		cr := ui.Rect{X: x + float32(k%cols)*(cw+gap), Y: area.Y + 4 + float32(k/cols)*(ch+gap) - a.tabSc.Y, W: cw, H: ch}
		if cr.B() < area.Y || cr.Y > area.B() {
			continue
		}
		if a.tabCard(i, a.tabs[i], cr, i == a.selIn(list)) {
			pick(i)
			break
		}
		if len(list) != len(a.matching()) { // a card was closed
			break
		}
	}
	if len(list) == 0 {
		g.Text("No tab matches.", x, area.Y+24, ui.FBody, th.OnSurfaceVariant)
	}
	u.PopHit()
	g.Restore()
}

// selIn is the selected tab, kept among the listed ones.
func (a *App) selIn(list []int) int {
	for _, i := range list {
		if i == a.tabSel {
			return i
		}
	}
	if len(list) > 0 {
		a.tabSel = list[0]
		return list[0]
	}
	return -1
}

// gridKeys: arrows move the selection, Escape closes the grid, Ctrl+W
// closes the selected tab.
func (a *App) gridKeys(list []int, pick func(int)) {
	in := a.In
	if len(list) == 0 {
		if in.Has(ui.KEscape, false) {
			a.toggleTabs()
		}
		return
	}
	at := 0
	sel := a.selIn(list)
	for k, i := range list {
		if i == sel {
			at = k
		}
	}
	switch {
	case in.Has(ui.KRight, false) || in.Has(ui.KDown, false):
		at = min(len(list)-1, at+1)
	case in.Has(ui.KLeft, false) || in.Has(ui.KUp, false):
		at = max(0, at-1)
	case in.Has(ui.KEscape, false):
		a.toggleTabs()
		return
	}
	a.tabSel = list[at]
}

// newTabRow is the row of chips that open a new tab of each kind.
func (a *App) newTabRow(x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	type item struct {
		label, tip string
		icon       ui.Icon
		col        ui.Color
		open       func()
	}
	items := []item{
		{"New tab", "Ctrl+T", ui.IPlus, th.Primary, func() { a.newTab(KNormal, "", "", true) }},
		{"Private", "Nothing is kept  Ctrl+Shift+N", ui.IPrivate, privateColor(th), func() { a.newTab(KPrivate, "", "", true) }},
		{"Temporary", "A fresh session for this tab alone, wiped when it closes", ui.IHourglass, ui.Mix(th.Hl, th.Ink, 0.25), func() { a.newTab(KTemp, "", "", true) }},
		{"Sandbox", "For a site you do not trust: no downloads, no permissions, nothing kept", ui.IShield, sandboxColor(th), func() { a.newTab(KSandbox, "", "", true) }},
	}
	for _, c := range a.set.Containers {
		name := c.Name
		items = append(items, item{name, "Container: its own sign-ins", iconOf(c), tone(th, c.Color), func() { a.newTab(KContainer, name, "", true) }})
	}
	cx, cy := x, y
	const h = 36
	for i, it := range items {
		bw := g.Measure(it.label, ui.FSmallBold) + 46
		if cx+bw > x+w {
			cx, cy = x, cy+h+8
		}
		b := ui.Rect{X: cx, Y: cy, W: bw, H: h}
		if i == 0 {
			ui.FillRoundAccent(g, b, h/2, th.Primary)
		} else {
			ui.FillRound(g, b, h/2, it.col.Alpha(0.12))
		}
		if u.Hover(b) {
			ui.FillRound(g, b, h/2, th.Ink.Alpha(0.06))
		}
		fg, ic := ui.Mix(it.col, th.Ink, 0.3), it.col
		if i == 0 {
			fg, ic = th.OnPrimary, th.OnPrimary
		}
		ui.DrawIcon(g, it.icon, b.X+12, b.CY()-8, 16, ic)
		g.Text(it.label, b.X+34, ui.Mid(g, b.Y, b.H, ui.FSmallBold), ui.FSmallBold, fg)
		u.Tooltip(it.tip, b)
		if u.Clickable(ui.IdN("gridnew", i), b) {
			a.tabsOpen = false
			it.open()
			return cy + h
		}
		cx = b.R() + 8
	}
	return cy + h
}

// tabCard draws one tab as a card; it returns true when it was picked.
func (a *App) tabCard(i int, t *Tab, r ui.Rect, sel bool) bool {
	u, g, th := &a.u, a.u.G, a.u.Th
	id := ui.IdN("card", t.ID)
	hot := u.Hover(r)
	ui.Shadow(g, r, 18, th.Shadow, 0.8, 3)
	ui.FillRound(g, r, 18, pageColor(th))

	// the picture: the site's color with its mark, or what Lite Go shows there
	pv := ui.Rect{X: r.X + 6, Y: r.Y + 6, W: r.W - 12, H: r.H - 64}
	host := strings.TrimPrefix(core.Host(t.URL), "www.")
	var c1 ui.Color
	switch {
	case t.search != nil:
		c1 = th.Primary
	case t.URL == "":
		_, c1 = a.kindIcon(t)
		if t.Kind == KNormal {
			c1 = th.Primary
		}
	default:
		c1 = siteColor(host)
	}
	ui.FillGradient3(g, pv, 13, []ui.Color{ui.Mix(c1, pageColor(th), 0.55), ui.Mix(c1, pageColor(th), 0.72), ui.Mix(c1, pageColor(th), 0.82)})
	mk := ui.RectAround(pv.CX(), pv.CY(), 46, 46)
	switch {
	case t.search != nil:
		aiBadge(g, th, mk)
		ui.TextCenter(g, ui.Fit(g, t.search.Q, ui.FSmallBold, pv.W-24), ui.Rect{X: pv.X, Y: mk.B() + 6, W: pv.W, H: 18}, ui.FSmallBold, ui.Mix(c1, th.Ink, 0.55))
	case t.URL == "":
		if t.Kind == KNormal {
			logo(g, mk, th, th.Primary)
		} else {
			ic, col := a.kindIcon(t)
			ui.FillRoundAccent(g, mk, 14, col)
			ui.DrawIcon(g, ic, mk.CX()-12, mk.CY()-12, 24, ui.White)
		}
	default:
		ui.Shadow(g, mk, 14, th.Shadow, 0.5, 2)
		ui.FillRoundAccent(g, mk, 14, c1)
		ui.TextCenter(g, monogram(host), mk, ui.Font{Size: 20, Bold: true}, ui.White)
		ui.TextCenter(g, ui.Fit(g, host, ui.FSmallBold, pv.W-24), ui.Rect{X: pv.X, Y: mk.B() + 6, W: pv.W, H: 18}, ui.FSmallBold, ui.Mix(c1, th.Ink, 0.55))
	}
	if t.view == nil && t.URL != "" && !t.making {
		// unloaded: it comes back (hydrated) when picked
		cr := ui.Rect{X: pv.X + 8, Y: pv.Y + 8, W: g.Measure("Resting", ui.Font{Size: 10.5, Bold: true}) + 30, H: 20}
		ui.FillRound(g, cr, 10, pageColor(th).Alpha(0.85))
		ui.DrawIcon(g, ui.IHourglass, cr.X+7, cr.CY()-6, 12, th.OnSurfaceVariant)
		g.Text("Resting", cr.X+22, ui.Mid(g, cr.Y, cr.H, ui.Font{Size: 10.5, Bold: true}), ui.Font{Size: 10.5, Bold: true}, th.OnSurfaceVariant)
		u.Tooltip("Not in memory: it opens again where you left it", cr)
	}

	// the close button
	xr := ui.RectAround(pv.R()-16, pv.Y+16, 26, 26)
	ui.FillOval(g, xr, pageColor(th).Alpha(0.9))
	if u.Hover(xr) {
		ui.FillOval(g, xr, th.Danger.Alpha(0.15))
	}
	ui.DrawIcon(g, ui.IClose, xr.CX()-7, xr.CY()-7, 14, th.OnSurface)
	if u.Clickable(id.Sub("x"), xr) {
		a.closeTab(i)
		a.tabSel = min(a.tabSel, len(a.tabs)-1)
		return false
	}

	// title, then the site, state and kind
	ty := pv.B() + 10
	a.tabIcon(t, r.X+12, ty+2)
	ui.TextFit(g, t.label(), r.X+36, ty+15, ui.FBodyBold, th.OnSurface, r.W-48)
	var info []string
	if host != "" && t.search == nil {
		info = append(info, host)
	}
	switch t.Kind {
	case KPrivate:
		info = append(info, "Private")
	case KTemp:
		info = append(info, "Temporary")
	case KSandbox:
		info = append(info, "Sandbox")
	case KContainer:
		info = append(info, t.Container)
	}
	if t.Audio && !t.Muted {
		info = append(info, "Playing")
	}
	if t.search != nil {
		info = append(info, "Lite results")
	}
	ui.TextFit(g, strings.Join(info, " · "), r.X+12, ty+35, ui.FSmall, th.OnSurfaceVariant, r.W-24)

	switch {
	case i == a.cur:
		ui.StrokeRound(g, r.Inset(-1.5), 19.5, 2.5, th.Primary)
	case sel:
		ui.StrokeRound(g, r.Inset(-1), 19, 1.5, th.Primary.Alpha(0.6))
	case hot:
		ui.StrokeRound(g, r.Inset(0.5), 18, 1, th.Outline)
	}
	if hot {
		a.tabSel = i
	}
	return u.Clickable(id, r)
}
