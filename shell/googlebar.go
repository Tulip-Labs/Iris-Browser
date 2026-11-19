package shell

import (
	"iris/core"
	"iris/ui"
)

// googleBar draws the filters of a Google search over its page (time, exact
// words, type of site, content farms) and returns what is left for the page.
// A choice opens the same search with the new filters.
func (a *App) googleBar(page ui.Rect) ui.Rect {
	t := a.tab()
	if t == nil || t.URL == "" || t.Crashed || a.Fullscreen() || page.H < 200 {
		return page
	}
	f, ok := core.ReadGoogleFilters(t.URL)
	if !ok {
		return page
	}
	u, g, th := &a.u, a.u.G, a.u.Th
	const barH, h, gap = float32(44), float32(30), float32(10)
	y := page.Y + (barH-6-h)/2
	// widths: the two choices of several share what the toggles leave
	exactL, allL := "Exact words", "No SEO spam"
	ew := g.Measure(exactL, ui.FSmallBold) + 40
	aw := g.Measure(allL, ui.FSmallBold) + 40
	rest := page.W - ew - aw - 4*gap - 8
	tw, yw := min(rest*0.55, 380), min(rest*0.45, 330)
	x := page.X + 4
	if tw > 200 {
		times := make([]string, len(core.GoogleTimes))
		sel := 0
		for i, c := range core.GoogleTimes {
			times[i] = c.Label
			if c.ID == f.Time {
				sel = i
			}
		}
		if n := u.Segmented(ID("gf-time"), ui.Rect{X: x, Y: y, W: tw, H: h}, times, sel); n != sel {
			f.Time = core.GoogleTimes[n].ID
			a.navigate(t, f.Apply(t.URL))
		}
		x += tw + gap
	}
	if a.googleToggle(ID("gf-exact"), ui.Rect{X: x, Y: y, W: ew, H: h}, exactL, "Google's verbatim: these words as written, no guesses or synonyms", f.Exact) {
		f.Exact = !f.Exact
		a.navigate(t, f.Apply(t.URL))
	}
	x += ew + gap
	if yw > 180 {
		types := make([]string, len(core.GoogleTypes))
		sel := 0
		for i, c := range core.GoogleTypes {
			types[i] = c.Label
			if c.ID == f.Type {
				sel = i
			}
		}
		if n := u.Segmented(ID("gf-type"), ui.Rect{X: x, Y: y, W: yw, H: h}, types, sel); n != sel {
			f.Type = core.GoogleTypes[n].ID
			a.navigate(t, f.Apply(t.URL))
		}
		x += yw + gap
	}
	if a.googleToggle(ID("gf-all"), ui.Rect{X: x, Y: y, W: aw, H: h}, allL, "Leaves out content farms, coupon and download sites and listicles built for ads; the best sources come first", !f.All) {
		f.All = !f.All
		a.navigate(t, f.Apply(t.URL))
	}
	_ = th
	return ui.Rect{X: page.X, Y: page.Y + barH, W: page.W, H: page.H - barH}
}

// googleToggle is a filter that is on or off: a pill with a check when on.
func (a *App) googleToggle(id ui.ID, r ui.Rect, label, tip string, on bool) bool {
	u, g, th := &a.u, a.u.G, a.u.Th
	rad := r.H / 2
	fg := th.OnSurface
	if on {
		ui.FillRound(g, r, rad, th.SecondaryContainer)
		fg = th.OnSecondaryContainer
	}
	hot := u.Hot(id, r, true)
	if hot > 0 {
		ui.FillRound(g, r, rad, fg.Alpha(0.08*hot))
	}
	ui.StrokeRound(g, r.Inset(0.5), rad-0.5, 1, th.Outline)
	f := ui.FSmallBold
	tw := g.Measure(label, f)
	cw := float32(0)
	if on {
		cw = 20
	}
	x := r.CX() - (tw+cw)/2
	if on {
		ui.DrawIcon(g, ui.ICheck, x, r.CY()-8, 16, fg)
		x += cw
	}
	g.Text(label, x, ui.Mid(g, r.Y, r.H, f), f, fg)
	u.Tooltip(tip, r)
	return u.Clickable(id, r)
}
