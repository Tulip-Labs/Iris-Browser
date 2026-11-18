package shell

import (
	"time"

	"litego/core"
	"litego/ui"
	"litego/webview"
)

type panelMode uint8

const (
	panelSettings panelMode = iota
	panelDownloads
	panelHistory
	panelPhone
	panelApp // a side app: Muse, Proton Pass
)

// togglePanel opens the side panel on a mode, or closes it when it shows that mode.
func (a *App) togglePanel(m panelMode) {
	if a.panel && a.panelMode == m {
		a.panel = false
		if a.st.Focus == ID("histq") {
			a.st.Focus = ui.ID{}
		}
		return
	}
	a.panel, a.panelMode = true, m
	a.ai.open = false
	if m == panelHistory {
		a.histFor = "\x00" // read the list again
		a.histQ.Set("")
		a.st.Focus = ID("histq")
		a.web(a.h.FocusWindow)
	}
}

// ---- the resource balancer ----

// balancer keeps the computer's resources on what is being used. The tab in
// front (both tabs in split view) and tabs playing sound have priority: every
// other page is told at once that nobody is looking at it, so the engine
// gives its memory back while the page keeps running. When the pages together
// go over the plan's budget, or the computer runs short of free memory, the
// background pages are put to sleep right away, and then unloaded one by one,
// the one used longest ago first, until there is room again.
type balancer struct {
	freeMB   int  // free system memory at the last reading (0 = unknown)
	pressure bool // over the budget, or the computer is short of memory
	lastAct  float64
	slept    int // pages put to sleep under pressure
	freed    int // pages unloaded under pressure
}

// prioritize tells the engine which pages are in use and which are not.
func (a *App) prioritize() {
	cur := a.tab()
	other, _ := a.splitWith()
	for _, t := range a.tabs {
		if t.view == nil || t.asleep {
			continue
		}
		bg := t != cur && t != other && !a.keepAwake(t)
		if bg != t.background {
			t.background = bg
			v := t.view
			a.web(func() { v.SetBackground(bg) })
		}
	}
}

// rebalance makes room when memory is short (called from tick).
func (a *App) rebalance() {
	a.prioritize()
	b, p := &a.balance, a.plan
	over := p.BudgetMB > 0 && a.memMB > float64(p.BudgetMB)
	low := p.ReserveMB > 0 && b.freeMB > 0 && b.freeMB < p.ReserveMB
	b.pressure = over || low
	now := a.now()
	wait := 6.0 // a step needs a moment to show in the numbers
	if !webview.SleepFreesMemory {
		wait = 3
	}
	if !b.pressure || now-b.lastAct < wait {
		return
	}
	// very short of memory: two pages at a time, before the system steps in
	// (on Linux, the out-of-memory killer can close the whole browser)
	critical := low && b.freeMB < p.ReserveMB/2
	cur := a.tab()
	other, _ := a.splitWith()
	slept := 0
	var lru *Tab
	for _, t := range a.tabs {
		if t.view == nil || t == cur || t == other || a.keepAwake(t) {
			continue
		}
		if !t.asleep && !t.Loading {
			v := t.view
			a.web(v.Sleep)
			t.asleep, t.shown = true, false
			slept++
		}
		if !t.private() && (lru == nil || t.last < lru.last) {
			lru = t // private tabs would lose their session
		}
	}
	switch {
	case slept > 0 && webview.SleepFreesMemory:
		b.slept += slept
	case lru != nil:
		b.slept += slept
		a.unload(lru)
		b.freed++
		if critical {
			// and the next one used longest ago
			var next *Tab
			for _, t := range a.tabs {
				if t.view != nil && t != cur && t != other && !a.keepAwake(t) && !t.private() && (next == nil || t.last < next.last) {
					next = t
				}
			}
			if next != nil {
				a.unload(next)
				b.freed++
			}
		}
	default:
		return
	}
	b.lastAct = now
}

// ---- adaptive shields ----

// startScan runs when a page commits: it notes whether the shield is scanning
// this page (the engine asks the same question for its requests).
func (a *App) startScan(t *Tab, url string) {
	if t.scanURL != "" {
		return // decided when this page load began (this is a move inside the page)
	}
	t.scanURL = url
	t.scanning = false
	if !a.set.Adaptive || !a.shield.On || t.private() || a.siteOff(core.Host(url)) {
		return // private pages leave no record
	}
	if a.scan.Need(url) {
		t.scanning = true
	} else {
		a.scan.Visit(url)
	}
}

// finishScan records what the scan of t's page found, when the page was
// loaded and watched long enough to tell.
func (a *App) finishScan(t *Tab) {
	url := t.scanURL
	scanning := t.scanning
	t.scanning, t.scanURL = false, ""
	if !scanning || t.loadedAt == 0 || a.now()-t.loadedAt < 4 {
		return
	}
	if core.Host(t.URL) != core.Host(url) {
		return // it moved to another site on the way: nothing sure to say
	}
	a.scan.Record(url, t.Blocked+t.hidden)
}

// settleScans records the scans of pages that have been open for a while.
func (a *App) settleScans() {
	now := a.now()
	for _, t := range a.tabs {
		if t.scanning && t.loadedAt > 0 && now-t.loadedAt >= 20 {
			url := t.scanURL
			a.finishScan(t)
			t.scanURL = url // still the same page load
		}
	}
}

// ---- the last session ----

func (a *App) saveSession() {
	var out []core.SessionTab
	for _, t := range a.tabs {
		if t.URL == "" || t.private() || len(out) >= 60 {
			continue
		}
		out = append(out, core.SessionTab{URL: t.URL, Title: t.Title, Container: t.Container})
	}
	a.set.Session = out
	a.set.Save()
}

// restoreSession brings back the tabs of the last window, unloaded: each one
// loads when it is first opened, so starting stays as light as with no tabs.
func (a *App) restoreSession() {
	if !a.set.Restore {
		return
	}
	s := a.set.Session
	for i := len(s) - 1; i >= 0; i-- { // each new tab goes right after the first
		if s[i].URL == "" {
			continue
		}
		k := KNormal
		if s[i].Container != "" {
			if _, ok := a.set.FindContainer(s[i].Container); !ok {
				continue
			}
			k = KContainer
		}
		t := a.newTab(k, s[i].Container, "", false)
		t.URL, t.Title = s[i].URL, s[i].Title
	}
}

func (a *App) setIntegrity(r Integrity) {
	a.integrity = r
	if r == IntegrityChanged {
		a.bar = infobar{warn: true, text: "The program file is not the one that was installed. Install it again from a source you trust."}
	}
	a.h.Invalidate()
}

// ---- history ----

// drawHistory is the list of visited pages in the side panel.
func (a *App) drawHistory(body ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	fr := ui.Rect{X: body.X + 14, Y: body.Y + 2, W: body.W - 28, H: 38}
	u.TextField(ID("histq"), fr, a.histQ, ui.FieldOpt{Placeholder: "Search history"})
	q := a.histQ.Text()
	if q != a.histFor || a.now()-a.histAt > 5 {
		a.histFor, a.histAt = q, a.now()
		a.histList = a.hist.Recent(150, q)
	}
	list := ui.Rect{X: body.X, Y: fr.B() + 8, W: body.W, H: body.B() - fr.B() - 8}
	sc := &a.histSc
	u.Scroll(ID("histscroll"), list, sc)
	g.Save()
	g.Clip(list)
	u.PushHit(list)
	x, w := list.X+10, list.W-20
	y := list.Y - sc.Y
	if len(a.histList) == 0 {
		msg := "No pages visited yet"
		if q != "" {
			msg = "Nothing in the history matches"
		}
		ui.TextCenter(g, msg, ui.Rect{X: list.X, Y: list.Y + 60, W: list.W, H: 20}, ui.FBody, th.OnSurfaceVariant)
	}
	day := ""
	for i, e := range a.histList {
		if d := dayLabel(e.Last); d != day {
			day = d
			g.Text(d, x+6, y+20, ui.FSmallBold, th.Primary)
			y += 30
		}
		row := ui.Rect{X: x, Y: y, W: w, H: 46}
		y += 48
		if row.B() < list.Y || row.Y > list.B() {
			continue
		}
		if u.Hover(row) {
			ui.FillRound(g, row, 12, th.Ink.Alpha(0.06))
		}
		host := core.Host(e.URL)
		dot := ui.RectAround(row.X+20, row.CY(), 26, 26)
		ui.Liquid(g, dot, 9, th.Ink)
		letter := "?"
		if h := trimWWW(host); h != "" {
			letter = string([]rune(h)[:1])
		}
		ui.TextCenter(g, upper(letter), dot, ui.FSmallBold, th.Ink)
		title := e.Title
		if title == "" {
			title = core.Display(e.URL)
		}
		clock := e.Last.Format("15:04")
		cw := g.Measure(clock, ui.FSmall)
		ui.TextFit(g, title, row.X+42, row.Y+19, ui.FBody, th.OnSurface, row.W-58-cw)
		ui.TextFit(g, core.Display(e.URL), row.X+42, row.Y+37, ui.FSmall, th.OnSurfaceVariant, row.W-50)
		g.Text(clock, row.R()-8-cw, row.Y+19, ui.FSmall, th.OnSurfaceVariant)
		if u.Clickable(ui.IdN("hrow", i), row) {
			if a.In.Ctrl {
				a.newTab(KNormal, "", e.URL, false)
			} else {
				a.visit(e.URL)
			}
		}
	}
	sc.Content = y + sc.Y - list.Y + 8
	u.PopHit()
	g.Restore()
}

func trimWWW(h string) string {
	if len(h) > 4 && h[:4] == "www." {
		return h[4:]
	}
	return h
}

func upper(s string) string {
	if len(s) == 1 && s[0] >= 'a' && s[0] <= 'z' {
		return string(s[0] - 32)
	}
	return s
}

// dayLabel names the day of t: Today, Yesterday, or the date.
func dayLabel(t time.Time) string {
	now := time.Now()
	y, m, d := now.Date()
	today := time.Date(y, m, d, 0, 0, 0, 0, now.Location())
	switch {
	case !t.Before(today):
		return "Today"
	case !t.Before(today.AddDate(0, 0, -1)):
		return "Yesterday"
	case t.Year() == y:
		return t.Format("Monday, January 2")
	}
	return t.Format("January 2, 2006")
}
