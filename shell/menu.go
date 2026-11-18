package shell

import (
	"iris/ui"
	"iris/webview"
)

// The page's right-click menu, drawn by Iris in its own style (Linux, where
// pages are drawn off screen and Chromium's own menu has no window to open
// in). It opens where the click was, over the page: the window draws this part
// of the interface over the pages (Overlay) and gives it the pointer and the
// keys while it is up. A click outside or Escape closes it; the arrow keys and
// Enter choose.

// openMenu shows m (any older one closes first).
func (a *App) openMenu(m *webview.Menu) {
	if m == nil || len(m.Items) == 0 {
		return
	}
	a.closeMenu(-1)
	a.menu, a.menuSel = m, -1
	a.menuMX, a.menuMY = a.In.MX, a.In.MY
	a.h.Invalidate()
}

// closeMenu closes the menu with an item's command, or -1 for none.
func (a *App) closeMenu(cmd int) {
	m := a.menu
	if m == nil {
		return
	}
	a.menu = nil
	a.web(func() { m.Choose(cmd) })
	a.h.Invalidate()
}

// menuKeys reads the menu's keys before anything else can take them.
func (a *App) menuKeys() {
	m := a.menu
	if m == nil {
		return
	}
	in := a.In
	if in.Has(ui.KEscape, false) {
		a.closeMenu(-1)
		return
	}
	step := 0
	if in.Has(ui.KDown, false) {
		step = 1
	}
	if in.Has(ui.KUp, false) {
		step = -1
	}
	if step != 0 {
		n := len(m.Items)
		i := a.menuSel
		for range n {
			i = (i + step + n) % n
			if it := m.Items[i]; !it.Sep && it.Enabled {
				a.menuSel = i
				break
			}
		}
	}
	if (in.Has(ui.KEnter, false) || in.Has(ui.KSpace, false)) && a.menuSel >= 0 && a.menuSel < len(m.Items) {
		if it := m.Items[a.menuSel]; !it.Sep && it.Enabled {
			a.closeMenu(it.Cmd)
		}
	}
}

// drawMenu draws the open menu on top of everything (layer 1, the only one
// taking input while it is up).
func (a *App) drawMenu(w, h float32) {
	m := a.menu
	if m == nil {
		return
	}
	u, g, th := &a.u, a.u.G, a.u.Th
	u.Layer = 1
	defer func() { u.Layer = 0 }()
	f := ui.FBody
	rowH := u.RowH()
	const sepH, pad, rad = float32(9), float32(6), float32(12)
	mw, mh := float32(210), pad*2
	for _, it := range m.Items {
		if it.Sep {
			mh += sepH
			continue
		}
		mw = max(mw, g.Measure(it.Label, f)+44)
		mh += rowH
	}
	mw = min(mw, 380, w-16)
	// at the click, turned to the left or upwards where the window ends
	x, y := m.X, m.Y
	if x+mw > w-8 {
		x = max(8, x-mw)
	}
	if y+mh > h-8 {
		y = max(8, y-mh)
	}
	r := ui.Rect{X: x, Y: y, W: mw, H: mh}
	in := a.In
	if (in.Pressed || in.RightPressed) && !r.Contains(in.MX, in.MY) {
		a.closeMenu(-1) // a click outside closes it (and does nothing else)
		return
	}
	a.Overlay, a.OverlayRadius = r, rad
	// opaque underneath: what shows through liquid glass here is the page,
	// which the interface cannot see, so the glass sits on the theme's surface
	ui.FillRound(g, r, rad, th.SurfaceHigh)
	ui.Glass(g, r, rad, th, true, false)
	ui.StrokeRound(g, r.Inset(0.5), rad-0.5, 1, th.Divider)
	moved := in.MX != a.menuMX || in.MY != a.menuMY // the pointer, not the keys, picks
	a.menuMX, a.menuMY = in.MX, in.MY
	cy := r.Y + pad
	for i, it := range m.Items {
		if it.Sep {
			g.FillRect(ui.Rect{X: r.X + 14, Y: cy + sepH/2 - 0.5, W: r.W - 28, H: 1}, th.Divider)
			cy += sepH
			continue
		}
		row := ui.Rect{X: r.X + pad, Y: cy, W: r.W - 2*pad, H: rowH}
		cy += rowH
		over := u.Hover(row)
		if over && moved {
			a.menuSel = i
		}
		col := th.OnSurface
		if !it.Enabled {
			col = col.Alpha(0.38)
		} else if over || a.menuSel == i {
			ui.FillRound(g, row, 8, th.Hover)
		}
		g.Save()
		g.Clip(row)
		g.Text(it.Label, row.X+12, ui.Mid(g, row.Y, row.H, f), f, col)
		g.Restore()
		if it.Enabled && u.Clickable(ID("pagemenu").N(i), row) {
			a.closeMenu(it.Cmd)
			return
		}
	}
}
