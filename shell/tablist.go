package shell

import (
	"strings"

	"litego/core"
	"litego/ui"
)

// The tab list: the tabs button opens it at the side, like the menu, and the
// page stays beside it. Type to find a tab; the arrows and Enter pick one;
// the row at the top opens new tabs of every kind.

// toggleTabs opens or closes the list.
func (a *App) toggleTabs() {
	if a.tabsOpen() {
		a.panel = false
		a.refocusPage()
		return
	}
	a.panel, a.panelMode, a.ai.open = true, panelTabs, false
	a.tabQ.Set("")
	a.tabSel = a.cur
	a.tabSc.Y = max(0, float32(a.cur-4)*52)
	a.st.Focus = ID("tabq")
	a.web(a.h.FocusWindow)
}

// tabsOpen says whether the list is showing.
func (a *App) tabsOpen() bool { return a.panel && a.panelMode == panelTabs }

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

// drawTabList fills the side panel's body with the tabs.
func (a *App) drawTabList(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	x, w := r.X+12, r.W-24
	y := r.Y

	// new tabs of every kind, as small buttons
	y = a.newTabRow(x, y, w) + 10

	// the search
	fr := ui.Rect{X: x, Y: y, W: w, H: 36}
	ui.FillRound(g, fr, 18, addrFill(th))
	ui.DrawIcon(g, ui.ISearch, fr.X+12, fr.CY()-8, 16, th.OnSurfaceVariant)
	list := a.matching()
	pick := func(i int) {
		a.panel = false
		a.st.Focus = ui.ID{}
		a.selectTab(i)
	}
	u.TextField(ID("tabq"), ui.Rect{X: fr.X + 34, Y: fr.Y, W: fr.W - 44, H: fr.H}, a.tabQ, ui.FieldOpt{Bare: true, Placeholder: "Find a tab",
		OnEnter: func() {
			if len(list) > 0 {
				pick(a.selIn(list))
			}
		}})
	a.listKeys(list, r.B()-fr.B()-8)
	y = fr.B() + 8

	// the rows
	area := ui.Rect{X: r.X, Y: y, W: r.W, H: r.B() - y}
	const rh = 52
	a.tabSc.Content = float32(len(list))*rh + 8
	u.Scroll(ID("tablist"), area, &a.tabSc)
	g.Save()
	g.Clip(area)
	u.PushHit(area)
	sel := a.selIn(list)
	for k, i := range list {
		row := ui.Rect{X: x - 4, Y: area.Y + float32(k)*rh - a.tabSc.Y, W: w + 8, H: rh - 4}
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
		g.Text("No tab matches.", x, area.Y+20, ui.FBody, th.OnSurfaceVariant)
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

// newTabRow is a row of small buttons that open a new tab of each kind.
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
	// the first is a full-width button; the others are round icon buttons with tips
	nb := ui.Rect{X: x, Y: y, W: w, H: 38}
	if u.Button(ID("listnew"), nb, "New tab", ui.ButtonOpt{Primary: true, Icon: ui.IPlus, HasIcon: true, Tip: "Ctrl+T"}) {
		a.panel = false
		items[0].open()
		return y + 38
	}
	y = nb.B() + 8
	cx := x
	for i, it := range items[1:] {
		if cx+38 > x+w {
			cx, y = x, y+42
		}
		b := ui.Rect{X: cx, Y: y, W: 38, H: 38}
		ui.FillRound(g, b, 19, it.col.Alpha(0.13))
		if u.Hover(b) {
			ui.FillRound(g, b, 19, th.Ink.Alpha(0.06))
		}
		ui.DrawIcon(g, it.icon, b.CX()-9, b.CY()-9, 18, it.col)
		u.Tooltip(it.label+": "+it.tip, b)
		if u.Clickable(ui.IdN("listkind", i), b) {
			a.panel = false
			it.open()
			return y + 38
		}
		cx = b.R() + 6
	}
	return y + 38
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
