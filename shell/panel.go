package shell

import (
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

// drawPanel is the side panel: new tabs and containers, look, search, shield and memory.
// It sits beside the page (never over it), so the page stays usable.
func (a *App) drawPanel(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 20, th, true, true)
	// header
	hr := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 56}
	logo(g, ui.RectAround(hr.X+30, hr.CY(), 26, 26), th, th.Primary)
	g.Text("Lite Go", hr.X+52, ui.Mid(g, hr.Y, hr.H, ui.FTitle), ui.FTitle, th.OnSurface)
	if u.IconButton(ID("pclose"), ui.Rect{X: hr.R() - 48, Y: hr.CY() - 20, W: 40, H: 40}, ui.IClose, "Close  Ctrl+,", ui.IconOpt{}) {
		a.panel = false
	}
	body := ui.Rect{X: r.X, Y: hr.B(), W: r.W, H: r.H - hr.H - 8}
	sc := &a.panelScroll
	u.Scroll(ID("pscroll"), body, sc)
	g.Save()
	g.Clip(body)
	x, w := body.X+18, body.W-36
	y := body.Y + 4 - sc.Y
	t := a.tab()

	section := func(title string) {
		y += 10
		g.Text(title, x, y+14, ui.FSmallBold, th.Primary)
		y += 26
	}
	divider := func() {
		y += 10
		g.FillRect(ui.Rect{X: x, Y: y, W: w, H: 1}, th.Divider)
		y += 6
	}
	note := func(s string) {
		for _, ln := range wrap(g, s, ui.FSmall, w) {
			g.Text(ln, x, y+14, ui.FSmall, th.OnSurfaceVariant)
			y += 18
		}
	}
	check := func(id, label string, v bool) bool {
		nv := u.Checkbox(ID(id), ui.Rect{X: x, Y: y, W: w, H: 36}, label, v)
		y += 36
		return nv
	}

	// new tabs
	section("New tab")
	bw := (w - 16) / 3
	kinds := []struct {
		label string
		icon  ui.Icon
		k     Kind
	}{{"Tab", ui.IPlus, KNormal}, {"Private", ui.IPrivate, KPrivate}, {"Temporary", ui.IReset, KTemp}}
	for i, k := range kinds {
		br := ui.Rect{X: x + float32(i)*(bw+8), Y: y, W: bw, H: 64}
		hot := u.Hover(br)
		ui.FillRound(g, br, 16, th.SecondaryContainer)
		if hot {
			ui.FillRound(g, br, 16, th.Ink.Alpha(0.06))
		}
		ui.DrawIcon(g, k.icon, br.CX()-10, br.Y+12, 20, th.OnSecondaryContainer)
		ui.TextCenter(g, ui.Fit(g, k.label, ui.FSmallBold, bw-8), ui.Rect{X: br.X, Y: br.Y + 36, W: br.W, H: 20}, ui.FSmallBold, th.OnSecondaryContainer)
		if u.Clickable(ui.IdN("pnew", i), br) {
			a.newTab(k.k, "", "", true)
		}
	}
	y += 72
	g.Text("Containers", x, y+14, ui.FSmallBold, th.OnSurfaceVariant)
	y += 24
	cx := x
	for i, c := range a.set.Containers {
		cw := g.Measure(c, ui.FSmallBold) + 34
		if cx+cw > x+w {
			cx = x
			y += 40
		}
		cr := ui.Rect{X: cx, Y: y, W: cw, H: 32}
		ui.StrokeRound(g, cr.Inset(0.5), 10, 1, th.Outline)
		if u.Hover(cr) {
			ui.FillRound(g, cr, 10, th.Ink.Alpha(0.06))
		}
		ui.FillOval(g, ui.RectAround(cr.X+14, cr.CY(), 10, 10), containerColor(c))
		g.Text(c, cr.X+25, ui.Mid(g, cr.Y, cr.H, ui.FSmallBold), ui.FSmallBold, th.OnSurface)
		u.Tooltip("New "+c+" tab", cr)
		if u.Clickable(ui.IdN("cont", i), cr) {
			a.newTab(KContainer, c, "", true)
		}
		cx += cw + 8
	}
	y += 40
	fr := ui.Rect{X: x, Y: y, W: w - 52, H: 38}
	add := func() {
		name := strings.TrimSpace(a.newCont.Text())
		if name == "" {
			return
		}
		for _, c := range a.set.Containers {
			if strings.EqualFold(c, name) {
				return
			}
		}
		a.set.Containers = append(a.set.Containers, name)
		a.set.Save()
		a.newCont.Set("")
	}
	u.TextField(ID("contname"), fr, a.newCont, ui.FieldOpt{Placeholder: "New container name", OnEnter: add})
	if u.IconButton(ID("contadd"), ui.Rect{X: fr.R() + 8, Y: y - 1, W: 40, H: 40}, ui.IPlus, "Add container", ui.IconOpt{}) {
		add()
	}
	y += 44
	divider()

	// look
	section("Look")
	sw := float32(34)
	for i, tm := range ui.Themes {
		cr := ui.Rect{X: x + float32(i)*(sw+8), Y: y, W: sw, H: sw}
		if cr.R() > x+w {
			break
		}
		base := tm.G5
		ui.FillOval(g, cr, base)
		ui.FillPathClip(g, ui.NewPath().Ellipse(cr), ui.Rect{X: cr.X, Y: cr.CY(), W: cr.W, H: cr.H / 2}, tm.Deep)
		ui.StrokeOval(g, cr.Inset(0.5), 1, th.Outline)
		if tm.ID == a.set.Theme {
			ui.StrokeOval(g, cr.Inset(-3), 2, th.Primary)
		}
		u.Tooltip(tm.Label, cr)
		if u.Clickable(ui.IdN("theme", i), cr) {
			a.set.Theme = tm.ID
			a.set.Save()
		}
	}
	y += sw + 14
	g.Text("Tabs", x, y+14, ui.FSmallBold, th.OnSurfaceVariant)
	y += 22
	sel := 0
	if a.set.VerticalTabs {
		sel = 1
	}
	if n := u.Segmented(ID("tablayout"), ui.Rect{X: x, Y: y, W: w, H: 36}, []string{"On top", "At the side"}, sel); n != sel {
		a.set.VerticalTabs = n == 1
		a.set.Save()
	}
	y += 44
	divider()

	// search
	section("Search")
	if n := u.Segmented(ID("pmode"), ui.Rect{X: x, Y: y, W: w, H: 36}, core.ModeNames, int(a.set.Mode)); n != int(a.set.Mode) {
		a.set.Mode = core.Mode(n)
		a.set.Save()
	}
	y += 42
	note("Google opens in English (US). AI Mode answers first; type \"yt \" before words to search YouTube.")
	divider()

	// shield
	section("Shield")
	if v := check("shon", "Block ads and trackers", a.shield.On); v != a.shield.On {
		a.set.Shield = v
		a.set.Save()
		sh := a.shield
		a.web(func() { sh.On = v }) // read on the window thread for every request
	}
	host := ""
	if t != nil {
		host = strings.TrimPrefix(core.Host(t.URL), "www.")
	}
	if host != "" && a.shield.On {
		full := core.Host(t.URL)
		off := a.siteOff(full)
		if v := check("shsite", "Allow ads on "+host, off); v != off {
			a.setSiteOff(full, v)
			a.reload(t)
		}
	}
	if v := check("https", "HTTPS only", a.set.HTTPSOnly); v != a.set.HTTPSOnly {
		a.set.HTTPSOnly = v
		a.set.Save()
		a.applyPolicy()
	}
	if v := check("yt", "Clean YouTube (no ads before videos)", a.set.YouTube); v != a.set.YouTube {
		a.set.YouTube = v
		a.set.Save()
		a.applyPolicy()
	}
	if v := check("strict", "Strict tracking prevention", a.set.Strict); v != a.set.Strict {
		a.set.Strict = v
		a.set.Save()
		a.applyPolicy()
	}
	blocked := 0
	if t != nil {
		blocked = t.Blocked
	}
	note(comma(blocked) + " blocked on this page · " + comma(a.blockedTotal) + " this session · " + comma(a.shield.Size()) + " filter domains. YouTube, sign-in, messaging and human checks are never blocked.")
	divider()

	// memory
	section("Memory")
	live, asleep, unloaded := a.Counts()
	big := "—"
	if a.memMB > 0 {
		big = mb(a.memMB)
	}
	g.Text(big, x, y+26, ui.FBig, th.OnSurface)
	bigW := g.Measure(big, ui.FBig)
	g.Text("pages", x+bigW+8, y+26, ui.FBody, th.OnSurfaceVariant)
	if a.appMB > 0 {
		s := "Lite Go " + mb(a.appMB)
		g.Text(s, x+w-g.Measure(s, ui.FSmall), y+26, ui.FSmall, th.OnSurfaceVariant)
	}
	y += 40
	// a bar: awake, asleep, unloaded
	tot := max(1, live+asleep+unloaded)
	br := ui.Rect{X: x, Y: y, W: w, H: 10}
	ui.FillRound(g, br, 5, th.SurfaceHighest)
	bx := br.X
	for i, n := range []int{live, asleep, unloaded} {
		if n == 0 {
			continue
		}
		seg := br.W * float32(n) / float32(tot)
		col := []ui.Color{th.Primary, th.Deep2.Alpha(0.6), th.Outline}[i]
		ui.FillPathClip(g, ui.NewPath().RoundRect(br, 5), ui.Rect{X: bx, Y: br.Y, W: seg, H: br.H}, col)
		bx += seg
	}
	y += 18
	note(strconv.Itoa(live) + " awake · " + strconv.Itoa(asleep) + " asleep · " + strconv.Itoa(unloaded) + " unloaded")
	y += 6
	profiles := []string{"saver", "balanced", "speed"}
	pi := 1
	for i, p := range profiles {
		if p == a.set.Memory {
			pi = i
		}
	}
	if n := u.Segmented(ID("memprof"), ui.Rect{X: x, Y: y, W: w, H: 36}, []string{"Saver", "Balanced", "Speed"}, pi); n != pi {
		a.set.Memory = profiles[n]
		a.set.Save()
		a.plan = core.Plan(a.cfg.TotalMB, a.set.Memory)
		a.lastTick = 0
	}
	y += 42
	note("Background tabs sleep after " + dur(a.plan.SleepAfter) + " and unload after " + dur(a.plan.UnloadAfter) + "; at most " + strconv.Itoa(a.plan.Live) + " tabs stay awake. Tabs playing sound stay awake.")
	y += 8
	if u.Button(ID("free"), ui.Rect{X: x, Y: y, W: w, H: 40}, "Free memory now", ui.ButtonOpt{Icon: ui.IMemory2, HasIcon: true}) {
		a.FreeMemory()
	}
	y += 48
	divider()

	// data
	section("Data")
	if u.Button(ID("clearh"), ui.Rect{X: x, Y: y, W: w, H: 40}, "Clear history", ui.ButtonOpt{}) {
		a.hist.Clear()
		a.notify("History cleared.")
	}
	y += 48
	note("Lite Go keeps no bookmarks. History feeds address suggestions and Most visited, and stays on this computer.")
	divider()

	// about
	section("About")
	ver := "Lite Go " + a.cfg.Version
	if a.eng != nil && a.eng.Version() != "" {
		ver += " · WebView2 " + a.eng.Version()
	}
	note(ver)
	note("Tulipan Labs (Cesar Jose Luis Torrecilla Gelvez) · PolyForm Noncommercial 1.0.0")
	note("Shortcuts: Ctrl+T new tab, Ctrl+Shift+N private, Ctrl+W close, Ctrl+Shift+T reopen, Ctrl+L address, Ctrl+Tab next, Alt+Left back, F11 full screen.")
	y += 16
	sc.Content = y + sc.Y - body.Y
	g.Restore()
}

func dur(s float64) string {
	if s >= 120 {
		return strconv.Itoa(int(s/60)) + " min"
	}
	return strconv.Itoa(int(s)) + " s"
}

func (a *App) setSiteOff(host string, off bool) {
	var keep []string
	for _, h := range a.set.ShieldOff {
		if h != host {
			keep = append(keep, h)
		}
	}
	if off {
		keep = append(keep, host)
	}
	a.set.ShieldOff = keep
	a.set.Save()
	a.shield.SetSiteOff(host, off)
}

// applyPolicy sends changed settings to the engine (new pages pick up scripts and strictness).
func (a *App) applyPolicy() {
	if a.eng == nil {
		return
	}
	eng, p := a.eng, a.Policy()
	a.web(func() { eng.SetPolicy(p) })
}
