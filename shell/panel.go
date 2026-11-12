package shell

import (
	"strconv"
	"strings"
	"time"

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
	kinds := []Kind{KNormal, KPrivate, KTemp}
	labels := []string{"Tab", "Private", "Temporary"}
	for i, k := range kinds {
		br := ui.Rect{X: x + float32(i)*(bw+8), Y: y, W: bw, H: 64}
		ic, col := a.kindIcon(&Tab{Kind: k})
		if k == KNormal {
			ic = ui.IPlus
		}
		ui.FillRound(g, br, 16, col.Alpha(0.12))
		if u.Hover(br) {
			ui.FillRound(g, br, 16, th.Ink.Alpha(0.06))
		}
		ui.DrawIcon(g, ic, br.CX()-10, br.Y+12, 20, col)
		ui.TextCenter(g, ui.Fit(g, labels[i], ui.FSmallBold, bw-8), ui.Rect{X: br.X, Y: br.Y + 36, W: br.W, H: 20}, ui.FSmallBold, th.OnSurface)
		if u.Clickable(ui.IdN("pnew", i), br) {
			a.newTab(k, "", "", true)
		}
	}
	y += 72
	g.Text("Containers", x, y+14, ui.FSmallBold, th.OnSurfaceVariant)
	y += 26
	for i := 0; i < len(a.set.Containers); i++ {
		c := a.set.Containers[i]
		row := ui.Rect{X: x - 6, Y: y, W: w + 12, H: 44}
		col := tone(th, c.Color)
		if u.Hover(row) {
			ui.FillRound(g, row, 14, th.Ink.Alpha(0.05))
		}
		ib := ui.RectAround(x+16, row.CY(), 32, 32)
		ui.FillRoundAccent(g, ib, 10, col)
		ui.DrawIcon(g, iconOf(c), ib.CX()-9, ib.CY()-9, 18, ui.White)
		ui.TextFit(g, c.Name, x+42, ui.Mid(g, row.Y, row.H, ui.FBodyBold), ui.FBodyBold, th.OnSurface, w-130)
		eb := ui.Rect{X: row.R() - 44, Y: row.CY() - 18, W: 36, H: 36}
		if u.IconButton(ui.IdN("cedit", i), eb, ui.IEdit, "Edit "+c.Name, ui.IconOpt{Toggled: a.editCont == i}) {
			if a.editCont == i {
				a.editCont = -1
			} else {
				a.editCont = i
				a.contName.Set(c.Name)
			}
		}
		ob := ui.Rect{X: eb.X - 40, Y: eb.Y, W: 36, H: 36}
		if u.IconButton(ui.IdN("copen", i), ob, ui.IPlus, "New "+c.Name+" tab", ui.IconOpt{Accent: col}) {
			a.newTab(KContainer, c.Name, "", true)
		}
		if u.Clickable(ui.IdN("crow", i), ui.Rect{X: row.X, Y: row.Y, W: ob.X - row.X, H: row.H}) {
			a.newTab(KContainer, c.Name, "", true)
		}
		y += 46
		if a.editCont != i {
			continue
		}
		// the editor: name, icon and color
		card := ui.Rect{X: x - 6, Y: y, W: w + 12, H: 0}
		ey := y + 10
		nr := ui.Rect{X: x + 4, Y: ey, W: w - 8, H: 38}
		rename := func() {
			n := strings.TrimSpace(a.contName.Text())
			if n == "" || strings.EqualFold(n, c.Name) {
				return
			}
			if _, taken := a.set.FindContainer(n); taken {
				return
			}
			for _, t := range a.tabs {
				if t.Kind == KContainer && t.Container == c.Name {
					t.Container = n
				}
			}
			a.set.Containers[i].Name = n
			a.set.Save()
		}
		ey += 46
		ic := float32(30)
		per := int((w - 8 + 6) / (ic + 6))
		for j, name := range core.ContainerIcons {
			cr := ui.Rect{X: x + 4 + float32(j%per)*(ic+6), Y: ey + float32(j/per)*(ic+6), W: ic, H: ic}
			sel := name == c.Icon
			if sel {
				ui.FillRound(g, cr, 9, col)
			} else if u.Hover(cr) {
				ui.FillRound(g, cr, 9, th.Ink.Alpha(0.07))
			}
			icol := th.OnSurfaceVariant
			if sel {
				icol = ui.White
			}
			ui.DrawIcon(g, contIcons[name], cr.CX()-9, cr.CY()-9, 18, icol)
			if u.Clickable(ui.Id("cicon/"+name), cr) {
				a.set.Containers[i].Icon = name
				a.set.Save()
			}
		}
		ey += float32((len(core.ContainerIcons)+per-1)/per)*(ic+6) + 6
		for j, name := range core.ContainerColors {
			cr := ui.Rect{X: x + 4 + float32(j)*(ic+6), Y: ey, W: ic, H: ic}
			cc := tone(th, name)
			ui.FillOval(g, cr.Inset(3), cc)
			if name == c.Color {
				ui.StrokeOval(g, cr.Inset(0.5), 2, cc)
			}
			u.Tooltip(strings.ToUpper(name[:1])+name[1:], cr)
			if u.Clickable(ui.Id("ccol/"+name), cr) {
				a.set.Containers[i].Color = name
				a.set.Save()
			}
		}
		ey += ic + 10
		del := ui.Rect{X: x + 4, Y: ey, W: 150, H: 36}
		removed := u.Button(ui.Id("cdel"), del, "Remove", ui.ButtonOpt{Icon: ui.ITrash, HasIcon: true, Tip: "Its tabs keep their sign-ins until they close"})
		ey += 46
		card.H = ey - card.Y
		ui.StrokeRound(g, card, 14, 1, th.OutlineVariant)
		u.TextField(ID("cname"), nr, a.contName, ui.FieldOpt{Placeholder: "Name", OnEnter: rename})
		if a.st.Focus != ID("cname") {
			rename()
		}
		y = ey + 8
		if removed {
			a.set.Containers = append(a.set.Containers[:i], a.set.Containers[i+1:]...)
			a.set.Save()
			a.editCont = -1
			break
		}
	}
	fr := ui.Rect{X: x, Y: y + 2, W: w - 52, H: 38}
	add := func() {
		if a.addContainer(a.newCont.Text()) {
			a.newCont.Set("")
		}
	}
	u.TextField(ID("contname"), fr, a.newCont, ui.FieldOpt{Placeholder: "New container name", OnEnter: add})
	if u.IconButton(ID("contadd"), ui.Rect{X: fr.R() + 8, Y: y + 1, W: 40, H: 40}, ui.IPlus, "Add container", ui.IconOpt{}) {
		add()
	}
	y += 48
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
	if v := check("lite", "Lite results for Google searches", a.set.LiteResults); v != a.set.LiteResults {
		a.set.LiteResults = v
		a.set.Save()
	}
	note("Google opens in English (US) and is shown on Lite Go's own page: the AI answer, links, pictures and videos, in your theme. \"On Google\" shows the original. Type \"yt \" before words to search YouTube.")
	divider()

	// Google account
	signed := a.set.GoogleSignIn == "done"
	status := "Not signed in: Google may ask to prove you are human"
	if signed {
		status = "Signed in: results and AI answers come without human checks"
	}
	note(status)
	y += 4
	lbl := "Sign in to Google"
	if signed {
		lbl = "Sign in again"
	}
	if u.Button(ID("psignin"), ui.Rect{X: x, Y: y, W: w, H: 38}, lbl, ui.ButtonOpt{Icon: ui.IPerson, HasIcon: true}) {
		a.signIn(a.tab())
	}
	y += 46
	divider()

	// startup
	section("Startup")
	if v := check("boost", "Open instantly (stay ready in the background)", a.set.Boost); v != a.set.Boost {
		a.set.Boost = v
		a.set.Save()
		if a.cfg.SetBoost != nil {
			a.cfg.SetBoost(v)
		}
	}
	note("Lite Go keeps a small, page-free part of itself running after you close the window and when Windows starts, so the window appears the moment you click it.")
	divider()

	// shield
	section("Lite Shields")
	if v := check("shon", "Shields on", a.shield.On); v != a.shield.On {
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
		if v := check("shsite", "Shields off on "+host, off); v != off {
			a.setSiteOff(full, v)
			a.reload(t)
		}
	}
	reloadLists := false
	if v := check("lists", "Block ads and trackers (filter lists)", a.set.Lists); v != a.set.Lists {
		a.set.Lists = v
		a.set.Save()
		reloadLists = true
	}
	if v := check("cookies", "Hide cookie notices", a.set.Cookies); v != a.set.Cookies {
		a.set.Cookies = v
		a.set.Save()
		reloadLists = true
	}
	if v := check("clean", "Remove tracking from links", a.set.CleanLinks); v != a.set.CleanLinks {
		a.set.CleanLinks = v
		a.set.Save()
		a.applyPolicy()
	}
	if v := check("farble", "Fingerprinting protection", a.set.Farble); v != a.set.Farble {
		a.set.Farble = v
		a.set.Save()
		a.applyPolicy()
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
	if v := check("ytlight", "Light YouTube (H.264, no glow or previews)", a.set.YouTubeLight); v != a.set.YouTubeLight {
		a.set.YouTubeLight = v
		a.set.Save()
		a.applyPolicy()
	}
	if v := check("strict", "Strict tracking prevention", a.set.Strict); v != a.set.Strict {
		a.set.Strict = v
		a.set.Save()
		a.applyPolicy()
	}
	if reloadLists {
		h := a.h
		a.core.LoadLists(false, h.Invalidate)
	}
	blocked := 0
	if t != nil {
		blocked = t.Blocked
	}
	note(comma(blocked) + " blocked on this page · " + comma(a.blockedTotal) + " this session")
	// the lists: how many rules and how fresh
	lists := "Filter lists are loading…"
	if f := a.core.Filters.Load(); f != nil {
		lists = comma(f.Rules) + " blocking and " + comma(f.Hiding) + " hiding rules"
		if !a.core.ListsAt.IsZero() {
			lists += " · updated " + ago(a.core.ListsAt)
		}
	} else if !a.set.Lists && !a.set.Cookies {
		lists = "Filter lists are off; the built-in list of " + comma(a.shield.Size()) + " tracker domains still works"
	} else if a.core.ListsErr != nil {
		lists = "Could not download the filter lists yet; the built-in list of " + comma(a.shield.Size()) + " domains works meanwhile"
	}
	note(lists)
	y += 4
	if u.Button(ID("updlists"), ui.Rect{X: x, Y: y, W: w, H: 36}, "Update filter lists", ui.ButtonOpt{Icon: ui.IReload, HasIcon: true, Tip: "EasyList, EasyPrivacy, uBlock filters and EasyList Cookie"}) {
		h := a.h
		a.core.LoadLists(true, func() { a.post(func() { a.notify("Filter lists updated.") }); h.Invalidate() })
		a.notify("Updating the filter lists…")
	}
	y += 44
	note("Sign-in, messaging, human checks and YouTube playback are never blocked. Style sheets and fonts always load, so pages keep their look.")
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
	y += 46
	if u.Button(ID("memrep"), ui.Rect{X: x, Y: y, W: w, H: 36}, "Save a memory report", ui.ButtonOpt{Tip: "Writes memory-report.txt to the settings folder"}) {
		if p, err := a.memoryReport(); err == nil {
			a.notify("Saved " + p)
			a.bar.until = a.now() + 8
		} else {
			a.notify("Could not save the report: " + err.Error())
		}
	}
	y += 44
	divider()

	// data
	section("Data")
	if u.Button(ID("clearh"), ui.Rect{X: x, Y: y, W: w, H: 40}, "Clear history", ui.ButtonOpt{}) {
		a.hist.Clear()
		a.notify("History cleared.")
	}
	y += 48
	note("Lite Go keeps no bookmarks. History feeds address suggestions and stays on this computer.")
	divider()

	// about
	section("About")
	ver := "Lite Go " + a.cfg.Version
	if a.eng != nil && a.eng.Version() != "" {
		ver += " · WebView2 " + a.eng.Version()
	}
	note(ver)
	note("Tulipan Labs (Cesar Jose Luis Torrecilla Gelvez) · PolyForm Noncommercial 1.0.0")
	y += 8
	if u.Button(ID("quit"), ui.Rect{X: x, Y: y, W: w, H: 40}, "Quit Lite Go", ui.ButtonOpt{Icon: ui.IClose, HasIcon: true, Tip: "Closes the window and the part that keeps it ready"}) {
		a.h.Quit()
	}
	y += 48
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

// ago says how long ago t was, briefly.
func ago(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Hour:
		return "just now"
	case d < 24*time.Hour:
		return strconv.Itoa(int(d.Hours())) + " h ago"
	}
	n := int(d.Hours() / 24)
	if n == 1 {
		return "yesterday"
	}
	return strconv.Itoa(n) + " days ago"
}
