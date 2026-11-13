package shell

import (
	"strconv"
	"strings"
	"time"

	"litego/core"
	"litego/ui"
)

// drawPanel is the side panel: the menu (page tools, look, search, shield and
// memory), the downloads list or the history.
// It sits beside the page (never over it), so the page stays usable.
func (a *App) drawPanel(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 20, th, true, true)
	// header
	hr := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 56}
	title := "Lite Go"
	switch a.panelMode {
	case panelDownloads:
		title = "Downloads"
		ui.DrawIcon(g, ui.IDownload, hr.X+19, hr.CY()-11, 22, th.Primary)
	case panelHistory:
		title = "History"
		ui.DrawIcon(g, ui.IHistory, hr.X+19, hr.CY()-11, 22, th.Primary)
	default:
		logo(g, ui.RectAround(hr.X+30, hr.CY(), 26, 26), th, th.Primary)
	}
	g.Text(title, hr.X+52, ui.Mid(g, hr.Y, hr.H, ui.FTitle), ui.FTitle, th.OnSurface)
	if u.IconButton(ID("pclose"), ui.Rect{X: hr.R() - 48, Y: hr.CY() - 20, W: 40, H: 40}, ui.IClose, "Close", ui.IconOpt{}) {
		a.panel = false
	}
	body := ui.Rect{X: r.X, Y: hr.B(), W: r.W, H: r.H - hr.H - 8}
	switch a.panelMode {
	case panelDownloads:
		a.drawDownloads(body)
		return
	case panelHistory:
		a.drawHistory(body)
		return
	}
	sc := &a.panelScroll
	u.Scroll(ID("pscroll"), body, sc)
	g.Save()
	g.Clip(body)
	a.u.PushHit(body)
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

	// what every browser has, one click away
	section("This page")
	{
		type tool struct {
			icon  ui.Icon
			label string
			tip   string
			act   action
		}
		tools := []tool{
			{ui.IHistory, "History", "Ctrl+H", actHistory},
			{ui.IDownload, "Downloads", "Ctrl+Shift+D", actDownloads},
			{ui.ISplit, "Split view", "Ctrl+Shift+S", actSplit},
			{ui.ISearch, "Find", "Find in this page  Ctrl+F", actFind},
			{ui.IPrint, "Print", "Print, or save as PDF  Ctrl+P", actPrint},
			{ui.IUndo, "Reopen", "Reopen the last closed tab  Ctrl+Shift+T", actReopen},
		}
		bw := (w - 16) / 3
		for i, tl := range tools {
			br := ui.Rect{X: x + float32(i%3)*(bw+8), Y: y + float32(i/3)*66, W: bw, H: 58}
			ui.FillRound(g, br, 16, th.Primary.Alpha(0.09))
			if u.Hover(br) {
				ui.FillRound(g, br, 16, th.Ink.Alpha(0.06))
			}
			u.Tooltip(tl.tip, br)
			ui.DrawIcon(g, tl.icon, br.CX()-10, br.Y+9, 20, th.Primary)
			ui.TextCenter(g, ui.Fit(g, tl.label, ui.FSmallBold, bw-8), ui.Rect{X: br.X, Y: br.Y + 33, W: br.W, H: 20}, ui.FSmallBold, th.OnSurface)
			if u.Clickable(ui.IdN("ptool", i), br) {
				a.do(tl.act)
			}
		}
		y += 66*2 + 4
		// zoom
		g.Text("Zoom", x, ui.Mid(g, y, 36, ui.FBody), ui.FBody, th.OnSurface)
		zr := ui.Rect{X: x + w - 148, Y: y, W: 148, H: 36}
		ui.FillRound(g, zr, 18, th.SurfaceHigh)
		if u.IconButton(ID("zout"), ui.Rect{X: zr.X + 2, Y: zr.Y + 2, W: 32, H: 32}, ui.IZoomOut, "Smaller  Ctrl+-", ui.IconOpt{Disabled: !a.livePage(t)}) {
			a.zoomBy(t, -1)
		}
		if u.IconButton(ID("zin"), ui.Rect{X: zr.R() - 34, Y: zr.Y + 2, W: 32, H: 32}, ui.IZoomIn, "Larger  Ctrl++", ui.IconOpt{Disabled: !a.livePage(t)}) {
			a.zoomBy(t, 1)
		}
		mid := ui.Rect{X: zr.X + 36, Y: zr.Y, W: zr.W - 72, H: zr.H}
		ui.TextCenter(g, zoomLabel(t), mid, ui.FBodyBold, th.OnSurface)
		u.Tooltip("Back to 100%  Ctrl+0", mid)
		if u.Clickable(ID("zreset"), mid) {
			a.zoomBy(t, 0)
		}
		y += 44
	}
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
	{
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
	}
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

	{
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
	}

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
	if v := check("shadapt", "Adaptive: scan a site, block where needed", a.set.Adaptive); v != a.set.Adaptive {
		a.set.Adaptive = v
		a.set.Save()
		a.applyPolicy()
	}
	if a.set.Adaptive && a.shield.On && a.livePage(t) && host != "" {
		st, found := a.scan.State(t.URL)
		msg := ""
		switch {
		case t.scanning:
			msg = "Scanning " + host + " now: every request is checked."
		case st == core.ScanStandby && !a.scan.Need(t.URL):
			msg = host + " was scanned and has nothing to block: the shield stands by here, and the page loads straight from the network."
		case st == core.ScanActive:
			msg = host + " has ads or trackers (" + comma(found) + " at the last scan): the shield stays on here."
		case st == core.ScanLearning:
			msg = host + " looked clean so far; a few more visits decide."
		}
		if msg != "" {
			note(msg)
			y += 4
			if u.Button(ID("rescan"), ui.Rect{X: x, Y: y, W: w, H: 34}, "Scan this site again", ui.ButtonOpt{Icon: ui.IReload, HasIcon: true}) {
				a.scan.Forget(t.URL)
				a.reload(t)
			}
			y += 42
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
		a.applyPolicy() // the cap of one page follows the profile
	}
	y += 42
	if v := check("memcap", "Limit each page to "+mb(float64(a.plan.LimitMB)), a.set.MemoryCap); v != a.set.MemoryCap {
		a.set.MemoryCap = v
		a.set.Save()
		a.applyPolicy()
	}
	if v := check("lazy", "Load pictures and frames only when reached", a.set.Lazy); v != a.set.Lazy {
		a.set.Lazy = v
		a.set.Save()
		a.applyPolicy()
		a.notify("Applies to pages opened from now on.")
	}
	if b := a.balance; a.plan.BudgetMB > 0 {
		s := "Balancer: pages may hold " + mb(float64(a.plan.BudgetMB)) + " together"
		if b.freeMB > 0 {
			s += " · " + mb(float64(b.freeMB)) + " free on this computer"
		}
		if b.pressure {
			s += " · making room now"
		}
		if b.slept+b.freed > 0 {
			s += " · put " + strconv.Itoa(b.slept) + " to sleep and unloaded " + strconv.Itoa(b.freed) + " under pressure"
		}
		note(s + ".")
	}
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
	if v := check("restore", "Reopen the last tabs when Lite Go starts", a.set.Restore); v != a.set.Restore {
		a.set.Restore = v
		a.set.Save()
	}
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
	switch a.integrity {
	case IntegrityVerified:
		note("Program file verified: it is the one that was installed.")
	case IntegrityProtected:
		note("Installed as a Windows package: Windows keeps the program read-only and verifies it.")
	case IntegrityChanged:
		note("Warning: the program file is not the one that was installed. Install Lite Go again from a source you trust.")
	}
	note("Tulipan Labs (Cesar Jose Luis Torrecilla Gelvez) · GPL 3.0")
	y += 8
	if u.Button(ID("quit"), ui.Rect{X: x, Y: y, W: w, H: 40}, "Quit Lite Go", ui.ButtonOpt{Icon: ui.IClose, HasIcon: true, Tip: "Closes the window and the part that keeps it ready"}) {
		a.h.Quit()
	}
	y += 48
	note("Shortcuts: Ctrl+T new tab, Ctrl+Shift+N private, Ctrl+W close, Ctrl+Shift+T reopen, Ctrl+L address, Ctrl+Tab next, Alt+Left back, Ctrl+F find, Ctrl+P print, Ctrl+H history, Ctrl+Shift+D downloads, Ctrl+Shift+S split view, Ctrl+plus and Ctrl+minus zoom, F11 full screen.")
	y += 16
	sc.Content = y + sc.Y - body.Y
	a.u.PopHit()
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
