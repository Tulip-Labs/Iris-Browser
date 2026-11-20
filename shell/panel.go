package shell

import (
	"runtime"
	"strconv"
	"strings"
	"time"

	"iris/core"
	"iris/ui"
)

// drawPanel is the side panel: the menu (tools, then the settings in
// sections that open in place), the downloads list or the history. It sits
// beside the page (never over it), so the page stays usable.
func (a *App) drawPanel(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 20, th, true, true)
	hr := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 54}
	title := "Iris"
	switch a.panelMode {
	case panelDownloads:
		title = "Downloads"
		ui.DrawIcon(g, ui.IDownload, hr.X+19, hr.CY()-11, 22, th.Primary)
	case panelHistory:
		title = "History"
		ui.DrawIcon(g, ui.IHistory, hr.X+19, hr.CY()-11, 22, th.Primary)
	default:
		logo(g, ui.RectAround(hr.X+30, hr.CY(), 26, 26), th)
	}
	g.Text(title, hr.X+52, ui.Mid(g, hr.Y, hr.H, ui.FTitle), ui.FTitle, th.OnSurface)
	if u.IconButton(ID("pclose"), ui.Rect{X: hr.R() - 46, Y: hr.CY() - 19, W: 38, H: 38}, ui.IClose, "Close  Esc", ui.IconOpt{}) {
		a.panel = false
		a.pageFocus()
	}
	if a.st.Focus != ID("histq") && a.In.Has(ui.KEscape, false) {
		a.panel = false
		a.pageFocus()
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
	x, w := body.X+16, body.W-32
	y := body.Y + 2 - sc.Y
	t := a.tab()

	// what every browser has, one click away
	type tool struct {
		icon  ui.Icon
		label string
		tip   string
		act   action
	}
	tools := []tool{
		{ui.IPrivate, "Private", "New private tab  Ctrl+Shift+N", actPrivate},
		{ui.IHistory, "History", "Ctrl+H", actHistory},
		{ui.IDownload, "Downloads", "Ctrl+Shift+D", actDownloads},
		{ui.IUndo, "Reopen", "Reopen the last closed tab  Ctrl+Shift+T", actReopen},
		{ui.ISplit, "Split", "Split view  Ctrl+Shift+S", actSplit},
		{ui.ISearch, "Find", "Find in this page  Ctrl+F", actFind},
		{ui.IPrint, "Print", "Print, or save as PDF  Ctrl+P", actPrint},
		{ui.IMemory2, "Free memory", "Let every background tab rest now", actFree},
	}
	cols := 4
	if w < 300 {
		cols = 3
	}
	bw := (w - float32(cols-1)*8) / float32(cols)
	for i, tl := range tools {
		br := ui.Rect{X: x + float32(i%cols)*(bw+8), Y: y + float32(i/cols)*70, W: bw, H: 62}
		if u.Hover(br) {
			ui.FillRound(g, br, 16, th.Ink.Alpha(0.06))
		}
		u.Tooltip(tl.tip, br)
		// a drop of clear liquid glass with the icon in ink
		tile := ui.RectAround(br.CX(), br.Y+19, 34, 34)
		ui.Liquid(g, tile, 11, th.Ink)
		ui.DrawIcon(g, tl.icon, tile.CX()-9, tile.CY()-9, 18, th.Ink)
		ui.TextCenter(g, ui.Fit(g, tl.label, ui.FSmallBold, bw-6), ui.Rect{X: br.X, Y: br.Y + 40, W: br.W, H: 18}, ui.FSmallBold, th.OnSurface)
		if u.Clickable(ui.IdN("ptool", i), br) {
			a.do(tl.act)
		}
	}
	y += float32((len(tools)+cols-1)/cols)*70 + 4

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
	y += 46

	// your name, for the AI answers
	g.Text("Your name", x, y+14, ui.FSmallBold, th.OnSurfaceVariant)
	y += 22
	if a.nameEd == nil {
		a.nameEd = ui.NewTextEdit(a.set.Name, false)
	}
	nr := ui.Rect{X: x, Y: y, W: w, H: 38}
	if u.TextField(ID("pname"), nr, a.nameEd, ui.FieldOpt{Placeholder: "So the AI answers greet you by name"}) {
		a.set.Name = strings.TrimSpace(a.nameEd.Text())
		a.set.Save()
	}
	y += 46

	// Google: only while Iris is not signed in
	if a.set.GoogleSignIn != "done" {
		if u.Button(ID("psignin"), ui.Rect{X: x, Y: y, W: w, H: 40}, "Sign in to Google", ui.ButtonOpt{Icon: ui.IPerson, HasIcon: true, Primary: true,
			Tip: "Results and AI answers then come without human checks"}) {
			a.signIn(t)
		}
		y += 48
	}

	// the settings, one section open at a time
	for _, sec := range settingsSections {
		row := ui.Rect{X: x - 6, Y: y, W: w + 12, H: 44}
		open := a.setSec == sec.id
		if open {
			ui.FillRound(g, row, 14, th.Primary.Alpha(0.10))
		} else if u.Hover(row) {
			ui.FillRound(g, row, 14, th.Ink.Alpha(0.05))
		}
		ui.DrawIcon(g, sec.icon, row.X+12, row.CY()-10, 20, th.Primary)
		g.Text(sec.label, row.X+44, ui.Mid(g, row.Y, row.H, ui.FBodyBold), ui.FBodyBold, th.OnSurface)
		ic := ui.IChevron
		if open {
			ic = ui.IChevronDown
		}
		ui.DrawIcon(g, ic, row.R()-28, row.CY()-8, 16, th.OnSurfaceVariant)
		u.Tooltip(sec.tip, row)
		if u.Clickable(ui.Id("psec/"+sec.id), row) {
			if open {
				a.setSec = ""
			} else {
				a.setSec = sec.id
			}
		}
		y += 48
		if open {
			if sec.id == "containers" {
				y = a.containerSettings(x, y-10, w)
			} else if sec.id == "extensions" {
				y = a.extensionSettings(x, y-10, w)
			} else {
				y = a.settingsBody(x, y-10, w, sec.id)
			}
			y += 6
		}
	}
	y += 8
	sc.Content = y + sc.Y - body.Y
	a.u.PopHit()
	g.Restore()
}

// settingsBody draws one section of the settings (sec) from y, in a column
// at x of width w, and returns where it ends.
func (a *App) settingsBody(x, y, w float32, sec string) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	section := func(string) { y += 6 } // the menu's row is the title
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
	_, _ = divider, check
	if sec == "memory" {
		// memory
		section("Performance")
		live, asleep, unloaded := a.Counts()
		big := "—"
		if a.memMB > 0 {
			big = mb(a.memMB)
		}
		g.Text(big, x, y+26, ui.FBig, th.OnSurface)
		bigW := g.Measure(big, ui.FBig)
		g.Text("pages", x+bigW+8, y+26, ui.FBody, th.OnSurfaceVariant)
		if a.appMB > 0 {
			s := "Iris " + mb(a.appMB)
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

	}
	if sec == "data" {
		// data
		section("History and data")
		if v := check("restore", "Reopen the last tabs when Iris starts", a.set.Restore); v != a.set.Restore {
			a.set.Restore = v
			a.set.Save()
		}
		if u.Button(ID("clearh"), ui.Rect{X: x, Y: y, W: w, H: 40}, "Clear history", ui.ButtonOpt{}) {
			a.hist.Clear()
			a.notify("History cleared.")
		}
		y += 48
		note("Iris keeps no bookmarks. History feeds address suggestions and stays on this computer.")
		divider()

	}
	if sec == "about" {
		// about
		section("About Iris")
		ver := "Iris " + a.cfg.Version
		if a.eng != nil && a.eng.Version() != "" {
			engine := "WebView2 "
			if runtime.GOOS == "linux" {
				engine = ""
			}
			ver += " · " + engine + a.eng.Version()
		}
		note(ver)
		switch a.integrity {
		case IntegrityVerified:
			note("Program file verified: it is the one that was installed.")
		case IntegrityProtected:
			note("Installed as a Windows package: Windows keeps the program read-only and verifies it.")
		case IntegrityChanged:
			note("Warning: the program file is not the one that was installed. Install Iris again from a source you trust.")
		}
		note("Tulipan Labs (Cesar Jose Luis Torrecilla Gelvez) · GPL 3.0")
		if k := a.updateKind(); k != "" {
			divider()
			section("Updates")
			note("Installed " + kindLabels[k] + ".")
			if k.CanSelf() {
				if v := check("autoupd", "Update automatically from the latest GitHub release", a.set.AutoUpdate); v != a.set.AutoUpdate {
					a.set.AutoUpdate = v
					a.set.Save()
				}
				note("New versions download in the background, checked against the release's checksums; installing one takes a click.")
			} else {
				note("Updates for this copy come from " + k.Managed() + ".")
			}
			if a.upd.status != "" {
				note(a.upd.status)
			}
			y += 6
			label := "Check for updates"
			if a.upd.ready != "" {
				label = "Install the update"
			}
			if u.Button(ID("updnow"), ui.Rect{X: x, Y: y, W: w, H: 40}, label, ui.ButtonOpt{Icon: ui.IReload, HasIcon: true, Disabled: a.upd.busy}) {
				if a.upd.ready != "" {
					a.installUpdate(k, a.upd.ready, a.upd.latest)
				} else {
					a.checkUpdate(true)
				}
			}
			y += 48
			divider()
		}
		note("Shortcuts: Ctrl+T new tab, Ctrl+Shift+N private, Ctrl+W close, Ctrl+Shift+T reopen, Ctrl+L address, Ctrl+Tab next, Alt+Left back, Ctrl+F find, Ctrl+P print, Ctrl+H history, Ctrl+Shift+D downloads, Ctrl+Shift+S split view, Ctrl+plus and Ctrl+minus zoom, F11 full screen.")
		y += 16
	}
	return y
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
	a.applyPolicy() // WebKit's compiled shield changes with it
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

// pageFocus gives the keyboard back to the current page.
func (a *App) pageFocus() {
	if t := a.tab(); t != nil && t.view != nil && t.URL != "" {
		v := t.view
		a.web(v.Focus)
	}
}
