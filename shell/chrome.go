package shell

import (
	"hash/fnv"
	"math"
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

const (
	stripH = 40
	barH   = 48
	ctlW   = 46 * 3
	panelW = 340
)

var (
	modeLabels = []string{"AI Mode", "Web", "Images", "Videos", "YouTube"}
	modeIcons  = []ui.Icon{ui.ISparkle, ui.IGlobe, ui.IImage, ui.IVideo, ui.IYouTube}
)

type suggestion struct {
	icon       ui.Icon
	title, sub string
	url        string
}

// vertical says whether tabs sit in a side rail (only when there is room).
func (a *App) vertical(w float32) bool { return a.set.VerticalTabs && w >= 720 }

// chrome draws the window's frame and returns where the page goes.
func (a *App) chrome(full ui.Rect) ui.Rect {
	w := full.W
	vert := a.vertical(w)
	y := float32(0)
	if !vert {
		strip := ui.Rect{W: w - ctlW, H: stripH}
		a.tabStrip(strip)
		a.windowControls(ui.Rect{X: w - ctlW, W: ctlW, H: stripH})
		y = stripH
	}
	bar := ui.Rect{Y: y, W: w, H: barH}
	if vert {
		a.windowControls(ui.Rect{X: w - ctlW, W: ctlW, H: stripH})
		bar.W -= ctlW
	}
	addr := a.toolbar(bar, vert)
	y += barH

	// suggestions open under the address bar and push the page down (the page
	// is a native window and would cover anything drawn over it)
	sugH := float32(0)
	if a.st.Focus == ID("addr") && len(a.sugg) > 0 {
		sugH = float32(len(a.sugg))*40 + 12
	}
	sugTop := y
	y += sugH
	if a.bar.text != "" {
		if a.bar.until > 0 && a.now() > a.bar.until {
			a.bar = infobar{}
		} else {
			a.infobar(ui.Rect{X: 8, Y: y, W: w - 16, H: 40})
			y += 46
		}
	}
	x := float32(8)
	if vert {
		rw := float32(232)
		if w < 1000 {
			rw = 64
		}
		a.rail(ui.Rect{X: 0, Y: barH, W: rw, H: full.H - barH})
		x = rw
	}
	right := w - 8
	if a.panel {
		pr := ui.Rect{X: w - panelW - 8, Y: sugTop, W: panelW, H: full.H - sugTop - 8}
		a.drawPanel(pr)
		right = pr.X - 8
	}
	if sugH > 0 {
		a.suggestions(ui.Rect{X: addr.X, Y: sugTop + 2, W: addr.W, H: sugH - 6}, ID("sugA"))
	}
	return ui.Rect{X: x, Y: y, W: max(0, right-x), H: max(0, full.H-y-8)}
}

// logo is Lite Go's mark: a liquid accent tile with a ring in motion and a spark.
func logo(g ui.Gfx, r ui.Rect, th *ui.Theme, base ui.Color) {
	ui.Shadow(g, r, r.W*0.3, th.Shadow, 0.6, 1.5)
	ui.FillRoundAccent(g, r, r.W*0.3, base)
	s := r.W / 24
	ring := ui.NewPath().Arc(r.CX(), r.CY(), 6.6*s, 140, 470, true)
	ui.Pen(g, ring, 2.1*s, ui.White)
	ui.FillOval(g, ui.RectAround(r.X+17.2*s, r.Y+7.4*s, 4.6*s, 4.6*s), th.Hl)
	ui.FillOval(g, ui.RectAround(r.CX(), r.CY(), 3.2*s, 3.2*s), ui.White)
}

func siteColor(host string) ui.Color {
	pal := []string{"#4f6bd8", "#c2457a", "#2f8f6b", "#b9741f", "#7b55c7", "#2a8fb0", "#b8403a", "#5d7a2b"}
	h := fnv.New32a()
	h.Write([]byte(strings.TrimPrefix(host, "www.")))
	return ui.Hex(pal[h.Sum32()%uint32(len(pal))])
}

func monogram(host string) string {
	h := strings.TrimPrefix(host, "www.")
	h = strings.TrimPrefix(h, "m.")
	for _, r := range h {
		return strings.ToUpper(string(r))
	}
	return "?"
}

// tabIcon draws a tab's leading icon in a 16x16 box at (x, y).
func (a *App) tabIcon(t *Tab, x, y float32) {
	g, th := a.u.G, a.u.Th
	switch {
	case t.Loading:
		a.u.Redraw = true
		ph := float32(math.Mod(a.now()*400, 360))
		ui.StrokeOval(g, ui.Rect{X: x + 1.5, Y: y + 1.5, W: 13, H: 13}, 2, th.Primary.Alpha(0.18))
		ui.Pen(g, ui.NewPath().Arc(x+8, y+8, 6.5, ph, ph+110, true), 2, th.Primary)
	case t.URL == "":
		ic := ui.IHome
		switch t.Kind {
		case KPrivate:
			ic = ui.IPrivate
		case KTemp:
			ic = ui.IReset
		case KContainer:
			ic = ui.IContainer
		}
		ui.DrawIcon(g, ic, x, y, 16, th.OnSurfaceVariant)
	default:
		host := core.Host(t.URL)
		c := siteColor(host)
		ui.FillRoundAccent(g, ui.Rect{X: x, Y: y, W: 16, H: 16}, 5, c)
		ui.TextCenter(g, monogram(host), ui.Rect{X: x, Y: y, W: 16, H: 16}, ui.Font{Size: 10, Bold: true}, ui.White)
	}
	switch t.Kind {
	case KPrivate:
		if t.URL != "" {
			ui.FillOval(g, ui.Rect{X: x + 9, Y: y + 9, W: 10, H: 10}, ui.Hex("#2b2233"))
			ui.DrawIcon(g, ui.IPrivate, x+9.5, y+9.5, 9, ui.White)
		}
	case KContainer:
		ui.FillOval(g, ui.Rect{X: x + 10, Y: y + 10, W: 8, H: 8}, containerColor(t.Container))
		ui.StrokeOval(g, ui.Rect{X: x + 10, Y: y + 10, W: 8, H: 8}, 1.2, frameColor(th))
	case KTemp:
		if t.URL != "" {
			ui.FillOval(g, ui.Rect{X: x + 10, Y: y + 10, W: 8, H: 8}, th.Hl)
		}
	}
}

func containerColor(name string) ui.Color {
	pal := []string{"#3a7bd5", "#e0702a", "#2f9e62", "#c23b7a", "#8a5cd1", "#c9a227"}
	h := fnv.New32a()
	h.Write([]byte(strings.ToLower(name)))
	return ui.Hex(pal[h.Sum32()%uint32(len(pal))])
}

func (t *Tab) label() string {
	switch {
	case t.URL == "" && t.Kind == KPrivate:
		return "Private tab"
	case t.URL == "" && t.Kind == KTemp:
		return "Temporary tab"
	case t.URL == "" && t.Kind == KContainer:
		return t.Container
	case t.URL == "":
		return "New tab"
	case t.Title != "":
		return t.Title
	}
	return core.Display(t.URL)
}

// drawTab draws one tab; narrow tabs show only their icon.
func (a *App) drawTab(i int, t *Tab, r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	active := i == a.cur
	id := ui.IdN("tab", t.ID)
	hot := u.Hover(r)
	if active {
		ui.Glass(g, r, 11, th, true, true)
	} else if hot {
		ui.FillRound(g, r, 11, th.Ink.Alpha(0.06))
	}
	if u.Clickable(id, r) && !active {
		a.selectTab(i)
	}
	u.Tooltip(t.label(), r)
	narrow := r.W < 76
	ix := r.X + 10
	if narrow {
		ix = r.CX() - 8
	}
	a.tabIcon(t, ix, r.CY()-8)
	if narrow {
		return
	}
	tx := ix + 24
	right := r.R() - 8
	showClose := active || hot || r.W > 150
	if showClose {
		cr := ui.RectAround(right-11, r.CY(), 22, 22)
		if u.Hover(cr) {
			ui.FillOval(g, cr, th.Ink.Alpha(0.10))
		}
		ui.DrawIcon(g, ui.IClose, cr.CX()-7, cr.CY()-7, 14, th.OnSurfaceVariant)
		if u.Clickable(id.Sub("x"), cr) {
			a.closeTab(i)
			return
		}
		right = cr.X - 2
	}
	if t.Audio || t.Muted {
		mr := ui.RectAround(right-11, r.CY(), 22, 22)
		ic := ui.IVolume
		if t.Muted {
			ic = ui.IMute
		}
		if u.Hover(mr) {
			ui.FillOval(g, mr, th.Ink.Alpha(0.10))
		}
		ui.DrawIcon(g, ic, mr.CX()-7, mr.CY()-7, 14, th.Primary)
		if u.Clickable(id.Sub("m"), mr) {
			a.toggleMute(t)
		}
		u.Tooltip("Mute or unmute this tab", mr)
		right = mr.X - 2
	}
	f := ui.FSmall
	col := th.OnSurfaceVariant
	if active {
		f, col = ui.FSmallBold, th.OnSurface
	}
	if t.view == nil && t.URL != "" && !t.making {
		col = col.Alpha(0.6) // unloaded: comes back when clicked
	} else if t.asleep {
		col = col.Alpha(0.8)
	}
	ui.TextFit(g, t.label(), tx, ui.Mid(g, r.Y, r.H, f), f, col, right-tx-2)
}

// tabStrip draws the tabs across the top, with the window's drag areas.
func (a *App) tabStrip(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	mark := ui.Rect{X: r.X, Y: r.Y, W: 48, H: r.H}
	logo(g, ui.RectAround(mark.CX()+2, mark.CY()+2, 22, 22), th, th.Primary)
	a.MoveAreas = append(a.MoveAreas, mark)
	area := r.CutLeft(48)
	n := float32(len(a.tabs))
	const plusW, minW, maxW, gapMove = 40, 52, 236, 56
	avail := area.W - plusW - gapMove
	tw := min(maxW, max(minW, avail/n))
	total := tw * n
	over := total > avail
	if over && u.Hover(area) {
		a.stripScroll = a.stripScroll - u.In.WheelY*60 - u.In.WheelX*60
	}
	if !over {
		a.stripScroll = 0
	}
	a.stripScroll = max(0, min(a.stripScroll, total-avail))
	g.Save()
	g.Clip(ui.Rect{X: area.X, Y: area.Y, W: min(total, avail) + 4, H: area.H})
	x := area.X - a.stripScroll
	for i, t := range a.tabs {
		tr := ui.Rect{X: x + 2, Y: r.Y + 5, W: tw - 4, H: r.H - 7}
		if tr.R() > area.X && tr.X < area.X+avail+4 {
			a.drawTab(i, t, tr)
		}
		x += tw
	}
	g.Restore()
	px := area.X + min(total, avail) + 2
	if u.IconButton(ID("newtab"), ui.Rect{X: px, Y: r.Y + 4, W: 36, H: 34}, ui.IPlus, "New tab  Ctrl+T", ui.IconOpt{}) {
		a.newTab(KNormal, "", "", true)
	}
	px += plusW
	if px < r.R() {
		a.MoveAreas = append(a.MoveAreas, ui.Rect{X: px, Y: r.Y, W: r.R() - px, H: r.H})
	}
	_ = th
}

// rail is the side tab list.
func (a *App) rail(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	narrow := r.W < 100
	nb := ui.Rect{X: r.X + 8, Y: r.Y + 4, W: r.W - 16, H: 38}
	if narrow {
		if u.IconButton(ID("railnew"), nb, ui.IPlus, "New tab  Ctrl+T", ui.IconOpt{}) {
			a.newTab(KNormal, "", "", true)
		}
	} else if u.Button(ID("railnew"), nb, "New tab", ui.ButtonOpt{Icon: ui.IPlus, HasIcon: true, Tip: "Ctrl+T"}) {
		a.newTab(KNormal, "", "", true)
	}
	list := ui.Rect{X: r.X, Y: nb.B() + 8, W: r.W, H: r.H - (nb.B() + 8 - r.Y) - 56}
	const rowH = 40
	sc := &a.railScroll
	sc.Content = float32(len(a.tabs)) * (rowH + 2)
	u.Scroll(ID("rail"), list, sc)
	g.Save()
	g.Clip(list)
	for i, t := range a.tabs {
		tr := ui.Rect{X: r.X + 8, Y: list.Y + float32(i)*(rowH+2) - sc.Y, W: r.W - 16, H: rowH}
		if tr.B() < list.Y || tr.Y > list.B() {
			continue
		}
		a.drawTab(i, t, tr)
	}
	g.Restore()
	by := r.B() - 48
	g.FillRect(ui.Rect{X: r.X + 12, Y: by - 4, W: r.W - 24, H: 1}, th.Divider)
	bw := float32(40)
	bx := r.X + 8
	if u.IconButton(ID("railpriv"), ui.Rect{X: bx, Y: by, W: bw, H: 40}, ui.IPrivate, "New private tab  Ctrl+Shift+N", ui.IconOpt{}) {
		a.newTab(KPrivate, "", "", true)
	}
	if !narrow {
		if u.IconButton(ID("railtemp"), ui.Rect{X: bx + bw + 4, Y: by, W: bw, H: 40}, ui.IReset, "New temporary tab", ui.IconOpt{}) {
			a.newTab(KTemp, "", "", true)
		}
	}
}

func (a *App) windowControls(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	bw := r.W / 3
	icons := []ui.Icon{ui.IMinimize, ui.IMaximize, ui.IClose}
	tips := []string{"Minimize", "Maximize", "Close"}
	if a.Maximized {
		icons[1], tips[1] = ui.IRestore, "Restore"
	}
	for i, ic := range icons {
		br := ui.Rect{X: r.X + float32(i)*bw, Y: r.Y, W: bw, H: r.H}
		id := ui.IdN("win", i)
		hot, down := u.Hover(br), u.IsActive(id)
		col := th.OnSurfaceVariant
		switch {
		case i == 2 && (hot || down):
			g.FillRect(br, ui.Hex("#c42b1c"))
			col = ui.White
		case down:
			g.FillRect(br, th.Ink.Alpha(0.12))
		case hot:
			g.FillRect(br, th.Ink.Alpha(0.07))
		}
		ui.DrawIcon(g, ic, br.CX()-8, br.CY()-8, 16, col)
		u.Tooltip(tips[i], br)
		if u.Clickable(id, br) {
			switch i {
			case 0:
				a.h.Minimize()
			case 1:
				a.h.ToggleMaximize()
			case 2:
				a.h.Close()
			}
		}
	}
}

// toolbar draws navigation, the address bar and the status buttons; it returns the address bar.
func (a *App) toolbar(r ui.Rect, vert bool) ui.Rect {
	u, g, th := &a.u, a.u.G, a.u.Th
	t := a.tab()
	x := r.X + 6
	if vert {
		mark := ui.Rect{X: r.X, Y: r.Y, W: 52, H: r.H}
		logo(g, ui.RectAround(mark.CX()+2, mark.CY(), 24, 24), th, th.Primary)
		a.MoveAreas = append(a.MoveAreas, mark)
		x = mark.R()
	}
	cy := r.CY()
	btn := func(id string, ic ui.Icon, tip string, dis bool) bool {
		b := ui.Rect{X: x, Y: cy - 20, W: 40, H: 40}
		x += 40
		return u.IconButton(ID(id), b, ic, tip, ui.IconOpt{Disabled: dis})
	}
	hasPage := t != nil && t.URL != ""
	if btn("back", ui.IChevronLeft, "Back  Alt+Left", t == nil || !t.CanBack) {
		a.do(actBack)
	}
	if btn("fwd", ui.IChevron, "Forward  Alt+Right", t == nil || !t.CanFwd) {
		a.do(actForward)
	}
	if t != nil && t.Loading {
		if btn("stop", ui.IClose, "Stop", false) && t.view != nil {
			v := t.view
			a.web(v.Stop)
			t.Loading = false
		}
	} else if btn("reload", ui.IReset, "Reload  Ctrl+R", !hasPage) {
		a.do(actReload)
	}
	x += 6

	// right side: shield, memory, panel
	rx := r.R() - 6
	rx -= 40
	if u.IconButton(ID("panel"), ui.Rect{X: rx, Y: cy - 20, W: 40, H: 40}, ui.IMore, "Lite Go menu  Ctrl+,", ui.IconOpt{Toggled: a.panel}) {
		a.panel = !a.panel
	}
	compact := r.W < 760
	if !compact {
		mw := float32(92)
		rx -= mw + 4
		a.memoryPill(ui.Rect{X: rx, Y: cy - 15, W: mw, H: 30})
	}
	rx -= 44
	a.shieldButton(ui.Rect{X: rx, Y: cy - 20, W: 40, H: 40}, t)
	rx -= 8

	aw := rx - x
	if vert && aw > 980 {
		pad := (aw - 980) / 2
		a.MoveAreas = append(a.MoveAreas, ui.Rect{X: x, Y: r.Y, W: pad, H: r.H}, ui.Rect{X: rx - pad, Y: r.Y, W: pad, H: r.H})
		x += pad
		aw = 980
	}
	ar := ui.Rect{X: x, Y: cy - 18, W: aw, H: 36}
	a.addressBar(ar, t)
	if t != nil && t.Loading && t.URL != "" {
		u.Redraw = true
		p := float32(math.Mod(a.now()*0.9, 1))
		seg := ar.W * 0.28
		sx := ar.X + 12 + (ar.W-24+seg)*p - seg
		g.Save()
		g.Clip(ui.Rect{X: ar.X + 12, Y: ar.B() - 3, W: ar.W - 24, H: 3})
		ui.FillRoundAccent(g, ui.Rect{X: sx, Y: ar.B() - 2.5, W: seg, H: 2.5}, 1.25, th.Primary)
		g.Restore()
	}
	return ar
}

func (a *App) shieldButton(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	host := ""
	if t != nil {
		host = core.Host(t.URL)
	}
	on := a.shield.On && !a.siteOff(host)
	col := th.OnSurfaceVariant.Alpha(0.6)
	if on {
		col = th.Primary
	}
	tip := "Shield is off"
	if on {
		tip = "Shield blocks ads and trackers"
	}
	if u.IconButton(ID("shield"), r, ui.IShield, tip, ui.IconOpt{Accent: col}) {
		a.panel = true
		a.panelScroll.Y = 0
	}
	if on && t != nil && t.Blocked > 0 {
		s := strconv.Itoa(t.Blocked)
		if t.Blocked > 999 {
			s = "999+"
		}
		f := ui.Font{Size: 9.5, Bold: true}
		bw := max(16, g.Measure(s, f)+8)
		br := ui.Rect{X: r.R() - bw + 2, Y: r.Y + 3, W: bw, H: 15}
		ui.FillRound(g, br, 7.5, th.Primary)
		ui.TextCenter(g, s, br, f, th.OnPrimary)
	}
}

func (a *App) siteOff(host string) bool {
	for _, h := range a.set.ShieldOff {
		if h == host {
			return true
		}
	}
	return false
}

func mb(v float64) string {
	if v >= 1024 {
		return strconv.FormatFloat(v/1024, 'f', 1, 64) + " GB"
	}
	return strconv.Itoa(int(v+0.5)) + " MB"
}

func (a *App) memoryPill(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	id := ID("mem")
	hot := u.Hover(r)
	ui.FillRound(g, r, r.H/2, th.Surface.Alpha(0.9))
	ui.StrokeRound(g, r.Inset(0.5), r.H/2, 1, th.OutlineVariant)
	if hot {
		ui.FillRound(g, r, r.H/2, th.Ink.Alpha(0.06))
	}
	col := th.OnSurfaceVariant
	if a.memMB > 2048 {
		col = th.Danger
	}
	ui.DrawIcon(g, ui.IMemory2, r.X+10, r.CY()-8, 16, col)
	label := "Memory"
	if a.memMB > 0 {
		label = mb(a.memMB)
	}
	ui.TextFit(g, label, r.X+30, ui.Mid(g, r.Y, r.H, ui.FSmallBold), ui.FSmallBold, th.OnSurface, r.W-36)
	live, asleep, unloaded := a.Counts()
	u.Tooltip("Pages "+mb(a.memMB)+" · "+strconv.Itoa(live)+" awake, "+strconv.Itoa(asleep)+" asleep, "+strconv.Itoa(unloaded)+" unloaded", r)
	if u.Clickable(id, r) {
		a.panel = true
	}
}

// addressBar is the search and address pill.
func (a *App) addressBar(r ui.Rect, t *Tab) {
	u, g, th, in := &a.u, a.u.G, a.u.Th, a.In
	id := ID("addr")
	focused := a.st.Focus == id
	if a.addrWas && !focused {
		a.sugg = nil
		if t != nil {
			a.addr.Set(t.URL)
		}
	}
	rad := r.H / 2
	if focused {
		ui.Glass(g, r, rad, th, true, true)
		ui.StrokeRound(g, r.Inset(1), rad-1, 2, th.Primary)
	} else {
		ui.FillRound(g, r, rad, addrFill(th))
		if u.Hover(r) {
			ui.FillRound(g, r, rad, th.Ink.Alpha(0.05))
		}
	}
	// leading icon: security, or the search mode while typing
	ic, icCol := ui.IGlobe, th.OnSurfaceVariant
	tip := ""
	switch {
	case focused:
		ic, icCol = modeIcons[a.set.Mode], th.Primary
	case t != nil && strings.HasPrefix(t.URL, "https://"):
		ic, tip = ui.ILock, "Secure connection"
	case t != nil && strings.HasPrefix(t.URL, "http://"):
		ic, icCol, tip = ui.IWarning, th.Danger, "Not secure"
	case t == nil || t.URL == "":
		ic = modeIcons[a.set.Mode]
	}
	ui.DrawIcon(g, ic, r.X+13, r.CY()-8, 16, icCol)
	u.Tooltip(tip, ui.Rect{X: r.X, Y: r.Y, W: 38, H: r.H})
	inner := ui.Rect{X: r.X + 36, Y: r.Y, W: r.W - 48, H: r.H}
	// the tab's kind, as a chip at the end
	if t != nil && t.Kind != KNormal {
		lbl := map[Kind]string{KPrivate: "Private", KTemp: "Temporary", KContainer: t.Container}[t.Kind]
		cw := g.Measure(lbl, ui.FSmallBold) + 30
		cr := ui.Rect{X: r.R() - cw - 6, Y: r.CY() - 12, W: cw, H: 24}
		bg, fg := th.SecondaryContainer, th.OnSecondaryContainer
		dot := th.Primary
		switch t.Kind {
		case KPrivate:
			bg, fg, dot = ui.Hex("#2b2233"), ui.White, ui.Hex("#c9a7ff")
		case KContainer:
			dot = containerColor(t.Container)
		case KTemp:
			dot = th.Hl
		}
		ui.FillRound(g, cr, 12, bg)
		ui.FillOval(g, ui.RectAround(cr.X+12, cr.CY(), 8, 8), dot)
		g.Text(lbl, cr.X+21, ui.Mid(g, cr.Y, cr.H, ui.FSmallBold), ui.FSmallBold, fg)
		inner.W -= cw + 6
	}
	if !focused {
		text := ""
		col := th.OnSurface
		if t != nil && t.URL != "" {
			text = core.Display(t.URL)
		} else {
			text, col = "Search with "+modeLabels[a.set.Mode]+" or type an address", th.Ink3
		}
		if t != nil && t.URL != "" {
			// host in full color, the rest softer
			host := strings.TrimPrefix(core.Host(t.URL), "www.")
			base := ui.Mid(g, r.Y, r.H, ui.FBody)
			if strings.HasPrefix(text, host) {
				hw := g.Measure(host, ui.FBody)
				g.Text(host, inner.X, base, ui.FBody, th.OnSurface)
				ui.TextFit(g, text[len(host):], inner.X+hw, base, ui.FBody, th.OnSurfaceVariant, inner.W-hw)
			} else {
				ui.TextFit(g, text, inner.X, base, ui.FBody, col, inner.W)
			}
		} else {
			ui.TextFit(g, text, inner.X, ui.Mid(g, r.Y, r.H, ui.FBody), ui.FBody, col, inner.W)
		}
		if u.Live() && in.Pressed && r.Contains(in.MX, in.MY) {
			a.st.Focus = id
			if t != nil {
				a.addr.Set(t.URL)
			}
			a.addr.SelectAll()
			a.sugg, a.sugSel = nil, 0
			in.Pressed = false // the press only focuses
		}
		a.addrWas = a.st.Focus == id
		return
	}
	changed := u.TextField(id, inner, a.addr, ui.FieldOpt{Bare: true, OnEnter: func() { a.open(a.addr.Text()) }})
	if changed {
		a.suggest(a.addr.Text())
	}
	a.suggestKeys(id, func() {
		a.st.Focus = ui.ID{}
		a.sugg = nil
		if t != nil {
			a.addr.Set(t.URL)
			if v := t.view; v != nil {
				a.web(v.Focus)
			}
		}
	})
	a.addrWas = a.st.Focus == id
}

func addrFill(th *ui.Theme) ui.Color {
	if th.Dark {
		return ui.Mix(th.G5, ui.White, 0.07)
	}
	return th.Surface
}

// suggestKeys moves the selection with the arrows; Escape runs cancel.
func (a *App) suggestKeys(id ui.ID, cancel func()) {
	in := a.In
	if a.st.Focus != id {
		return
	}
	if in.Has(ui.KDown, false) && len(a.sugg) > 0 {
		a.sugSel = (a.sugSel + 1) % len(a.sugg)
	}
	if in.Has(ui.KUp, false) && len(a.sugg) > 0 {
		a.sugSel = (a.sugSel + len(a.sugg) - 1) % len(a.sugg)
	}
	if in.Has(ui.KEscape, false) {
		if len(a.sugg) > 0 && id == ID("ntp") {
			a.sugg = nil
		} else {
			cancel()
		}
	}
}

// suggest fills the suggestion list for typed text.
func (a *App) suggest(text string) {
	q := strings.TrimSpace(text)
	a.sugSel = 0
	if q == "" {
		a.sugg = nil
		return
	}
	var out []suggestion
	seen := map[string]bool{}
	if core.IsURLLike(q) {
		u := core.URLFor(q)
		out = append(out, suggestion{ui.IGlobe, core.Display(u), "Open site", u})
		seen[u] = true
	} else {
		m := a.set.Mode
		out = append(out, suggestion{modeIcons[m], q, "Search · " + modeLabels[m], core.Resolve(q, m)})
	}
	for _, e := range a.hist.Suggest(q, 6) {
		if seen[e.URL] {
			continue
		}
		seen[e.URL] = true
		title := e.Title
		if title == "" {
			title = core.Display(e.URL)
		}
		out = append(out, suggestion{ui.IHistory, title, core.Display(e.URL), e.URL})
	}
	if !core.IsURLLike(q) && a.set.Mode != core.ModeYouTube {
		out = append(out, suggestion{ui.IYouTube, q, "Search YouTube", core.ModeYouTube.URL(q)})
	}
	a.sugg = out
}

// open goes to the selected suggestion, or resolves the text.
func (a *App) open(text string) {
	url := core.Resolve(text, a.set.Mode)
	if a.sugSel > 0 && a.sugSel < len(a.sugg) {
		url = a.sugg[a.sugSel].url
	}
	a.visit(url)
}

// visit opens url in the current tab and gives the keyboard to the page.
func (a *App) visit(url string) {
	t := a.tab()
	a.st.Focus = ui.ID{}
	a.sugg, a.sugSel = nil, 0
	if url == "" || t == nil {
		return
	}
	a.navigate(t, url)
	a.addr.Set(t.URL)
	if v := t.view; v != nil {
		a.web(v.Focus)
	}
}

// suggestions draws the list in r.
func (a *App) suggestions(r ui.Rect, id ui.ID) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 18, th, true, true)
	y := r.Y + 6
	for i, s := range a.sugg {
		row := ui.Rect{X: r.X + 6, Y: y, W: r.W - 12, H: 40}
		if i == a.sugSel {
			ui.FillRound(g, row, 12, th.SecondaryContainer)
		} else if u.Hover(row) {
			ui.FillRound(g, row, 12, th.Ink.Alpha(0.05))
		}
		ui.DrawIcon(g, s.icon, row.X+12, row.CY()-9, 18, th.OnSurfaceVariant)
		f := ui.FBody
		tw := g.Measure(s.title, f)
		maxT := row.W * 0.62
		ui.TextFit(g, s.title, row.X+42, ui.Mid(g, row.Y, row.H, f), f, th.OnSurface, maxT)
		sx := row.X + 42 + min(tw, maxT) + 12
		ui.TextFit(g, s.sub, sx, ui.Mid(g, row.Y, row.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant, row.R()-sx-10)
		if u.Hover(row) && u.In.Pressed {
			u.In.Pressed = false // keep the field focused
			a.visit(s.url)
			return
		}
		y += 40
	}
	_ = id
}

func (a *App) infobar(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	bg, fg, ic := th.SecondaryContainer, th.OnSecondaryContainer, ui.IInfo
	if a.bar.warn {
		bg, fg, ic = th.ErrorContainer, th.OnErrorContainer, ui.IWarning
	}
	ui.FillRound(g, r, 14, bg)
	ui.DrawIcon(g, ic, r.X+12, r.CY()-9, 18, fg)
	right := r.R() - 40
	if u.IconButton(ID("barx"), ui.Rect{X: r.R() - 38, Y: r.CY() - 16, W: 32, H: 32}, ui.IClose, "Dismiss", ui.IconOpt{}) {
		a.bar = infobar{}
		return
	}
	if a.bar.action != "" {
		bw := g.Measure(a.bar.action, ui.FBodyBold) + 32
		br := ui.Rect{X: right - bw, Y: r.CY() - 15, W: bw, H: 30}
		if u.Button(ID("bara"), br, a.bar.action, ui.ButtonOpt{Primary: a.bar.warn}) {
			do := a.bar.do
			a.bar = infobar{}
			if do != nil {
				do()
			}
			return
		}
		right = br.X - 8
	}
	ui.TextFit(g, a.bar.text, r.X+40, ui.Mid(g, r.Y, r.H, ui.FBody), ui.FBody, fg, right-r.X-44)
}
