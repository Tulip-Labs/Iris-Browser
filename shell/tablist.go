package shell

import (
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

// The tab list: the tabs button opens it under the address bar, the way the
// suggestions open, and closes it again. Type to find a tab; the arrows and Enter pick one;
// the row at the top opens new tabs of every kind.

// toggleTabs opens or closes the list.
func (a *App) toggleTabs() {
	if a.tabsDrop {
		a.tabsDrop = false
		a.refocusPage()
		return
	}
	a.tabsDrop = true
	a.tabQ.Set("")
	a.tabSel = a.cur
	a.tabSc.Y = max(0, float32(a.cur-4)*52)
	a.st.Focus = ID("tabq")
	a.web(a.h.FocusWindow)
}

// tabsOpen says whether the list is showing.
func (a *App) tabsOpen() bool { return a.tabsDrop }

// refocusPage gives the keyboard back to the current page.
func (a *App) refocusPage() {
	if a.st.Focus == ID("tabq") {
		a.st.Focus = ui.ID{}
	}
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

// drawTabList draws the list in r: a search and the new-tab buttons on one
// row, then the tabs.
func (a *App) drawTabList(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 18, th, true, true)
	u.PushHit(r)
	defer u.PopHit()
	x, w := r.X+10, r.W-20
	y := r.Y + 10
	list := a.matching()
	pick := func(i int) {
		a.tabsDrop = false
		a.st.Focus = ui.ID{}
		a.selectTab(i)
	}
	// the row: find, then New tab and the other kinds at the right
	bx := a.newTabRow(x+w, y)
	fr := ui.Rect{X: x, Y: y, W: max(120, bx-x-8), H: 40}
	ui.FillRound(g, fr, 20, addrFill(th))
	ui.DrawIcon(g, ui.ISearch, fr.X+12, fr.CY()-8, 16, th.OnSurfaceVariant)
	u.TextField(ID("tabq"), ui.Rect{X: fr.X + 34, Y: fr.Y, W: fr.W - 44, H: fr.H}, a.tabQ, ui.FieldOpt{Bare: true,
		Placeholder: "Find among " + strconv.Itoa(len(a.tabs)) + " tabs",
		OnEnter: func() {
			if len(list) > 0 {
				pick(a.selIn(list))
			}
		}})
	area := ui.Rect{X: r.X, Y: fr.B() + 10, W: r.W, H: r.B() - fr.B() - 16}
	a.listKeys(list, area.H)
	if a.In.Has(ui.KEscape, false) {
		a.toggleTabs()
		return
	}
	const rh = 48
	a.tabSc.Content = float32(len(list)) * rh
	u.Scroll(ID("tablist"), area, &a.tabSc)
	g.Save()
	g.Clip(area)
	sel := a.selIn(list)
	for k, i := range list {
		row := ui.Rect{X: x - 2, Y: area.Y + float32(k)*rh - a.tabSc.Y, W: w + 4, H: rh - 4}
		if row.B() < area.Y || row.Y > area.B() {
			continue
		}
		if a.tabRow(i, a.tabs[i], row, i == sel) {
			pick(i)
			break
		}
		if len(list) != len(a.matching()) { // a tab was closed
			break
		}
	}
	if len(list) == 0 {
		g.Text("No tab matches.", x+8, area.Y+22, ui.FBody, th.OnSurfaceVariant)
	}
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

// listKeys: Up and Down move the selection (Escape closes, in drawPanel).
func (a *App) listKeys(list []int, h float32) {
	in := a.In
	if len(list) == 0 {
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
	case in.Has(ui.KDown, false):
		at = min(len(list)-1, at+1)
	case in.Has(ui.KUp, false):
		at = max(0, at-1)
	default:
		return
	}
	a.tabSel = list[at]
	// keep the selection in view
	top := float32(at) * 52
	if top < a.tabSc.Y {
		a.tabSc.Y = top
	} else if top+52 > a.tabSc.Y+h && h > 0 {
		a.tabSc.Y = min(top, top+52-h)
	}
}

// newTabRow draws, right-aligned to right at height y, the New tab button
// and round buttons for the other kinds of tab; it returns its left edge.
func (a *App) newTabRow(right, y float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	type item struct {
		label, tip string
		icon       ui.Icon
		col        ui.Color
		open       func()
	}
	items := []item{
		{"Private", "Nothing is kept  Ctrl+Shift+N", ui.IPrivate, privateColor(th), func() { a.newTab(KPrivate, "", "", true) }},
		{"Temporary", "A fresh session for this tab alone, wiped when it closes", ui.IHourglass, ui.Mix(th.Hl, th.Ink, 0.25), func() { a.newTab(KTemp, "", "", true) }},
		{"Sandbox", "For a site you do not trust: no downloads, no permissions, nothing kept", ui.IShield, sandboxColor(th), func() { a.newTab(KSandbox, "", "", true) }},
	}
	for _, c := range a.set.Containers {
		name := c.Name
		items = append(items, item{name, "Container: its own sign-ins", iconOf(c), tone(th, c.Color), func() { a.newTab(KContainer, name, "", true) }})
	}
	cx := right
	for i := len(items) - 1; i >= 0; i-- {
		it := items[i]
		cx -= 40
		b := ui.Rect{X: cx, Y: y, W: 40, H: 40}
		ui.FillOval(g, b, it.col.Alpha(0.13))
		if u.Hover(b) {
			ui.FillOval(g, b, th.Ink.Alpha(0.06))
		}
		ui.DrawIcon(g, it.icon, b.CX()-9, b.CY()-9, 18, it.col)
		u.Tooltip(it.label+": "+it.tip, b)
		if u.Clickable(ui.IdN("listkind", i), b) {
			a.tabsDrop = false
			it.open()
		}
		cx -= 6
	}
	lbl := "New tab"
	bw := g.Measure(lbl, ui.FSmallBold) + 46
	cx -= bw
	if u.Button(ID("listnew"), ui.Rect{X: cx, Y: y, W: bw, H: 40}, lbl, ui.ButtonOpt{Primary: true, Icon: ui.IPlus, HasIcon: true, Tip: "Ctrl+T"}) {
		a.tabsDrop = false
		a.newTab(KNormal, "", "", true)
	}
	return cx
}

// tabRow draws one tab in the list; it returns true when it was picked.
func (a *App) tabRow(i int, t *Tab, r ui.Rect, sel bool) bool {
	u, g, th := &a.u, a.u.G, a.u.Th
	id := ui.IdN("trow", t.ID)
	hot := u.Hover(r)
	switch {
	case i == a.cur:
		ui.FillRound(g, r, 14, th.SecondaryContainer)
	case sel || hot:
		ui.FillRound(g, r, 14, th.Ink.Alpha(0.06))
	}
	if hot {
		a.tabSel = i
	}
	a.tabIcon(t, r.X+12, r.CY()-8)
	host := strings.TrimPrefix(core.Host(t.URL), "www.")
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
	switch {
	case t.Audio && !t.Muted:
		info = append(info, "Playing")
	case t.view == nil && t.URL != "" && !t.making:
		info = append(info, "Resting")
	}
	if t.search != nil {
		info = append(info, "Lite results")
	}
	tw := r.W - 40 - 36
	ui.TextFit(g, t.label(), r.X+38, r.Y+20, ui.FBodyBold, th.OnSurface, tw)
	ui.TextFit(g, strings.Join(info, " · "), r.X+38, r.Y+38, ui.FSmall, th.OnSurfaceVariant, tw)
	// close
	if hot || i == a.cur {
		xr := ui.Rect{X: r.R() - 36, Y: r.CY() - 15, W: 30, H: 30}
		if u.IconButton(id.Sub("x"), xr, ui.IClose, "Close tab  Ctrl+W", ui.IconOpt{}) {
			a.closeTab(i)
			a.tabSel = min(a.tabSel, len(a.tabs)-1)
			return false
		}
	}
	u.Tooltip(t.URL, r)
	return u.Clickable(id, r)
}
