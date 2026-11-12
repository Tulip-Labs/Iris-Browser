package shell

import (
	"math"
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

type quick struct {
	name, url, color string
}

// quickSites open with one click from the new tab page (no bookmarks to keep).
var quickSites = []quick{
	{"Google", "https://www.google.com/", "#4285f4"},
	{"YouTube", "https://www.youtube.com/", "#e62117"},
	{"Gmail", "https://mail.google.com/", "#d93025"},
	{"Maps", "https://www.google.com/maps", "#188038"},
	{"WhatsApp", "https://web.whatsapp.com/", "#1fa855"},
	{"Drive", "https://drive.google.com/", "#e3a008"},
	{"GitHub", "https://github.com/", "#24292f"},
	{"Wikipedia", "https://www.wikipedia.org/", "#55595f"},
}

// content draws what the page area shows when it is not a live page.
func (a *App) content(r ui.Rect) {
	g, th := a.u.G, a.u.Th
	t := a.tab()
	if t == nil || r.Empty() {
		return
	}
	switch {
	case t.URL == "":
		a.ntp(r, t)
	case t.Crashed:
		a.message(r, ui.IWarning, "This page stopped working",
			"Its process ended (it may have run out of memory). Reload to open it again.", "Reload", func() { a.reload(t) })
	case a.engErr != nil || a.eng == nil:
		msg := "Lite Go shows pages with Microsoft Edge WebView2, which is not installed. Run the Lite Go installer again, or get the runtime from Microsoft."
		if a.engErr != nil && !strings.Contains(a.engErr.Error(), "not available") {
			msg = "The web engine did not start: " + a.engErr.Error()
		}
		a.message(r, ui.IGlobe, "The web engine is not available", msg, "", nil)
	case t.view == nil:
		// the page is being made: a calm surface with a small progress ring
		ui.FillRound(g, r, 12, pageColor(th))
		a.u.Redraw = true
		ph := float32(math.Mod(a.now()*360, 360))
		ui.Pen(g, ui.NewPath().Arc(r.CX(), r.CY(), 14, ph, ph+100, true), 3, th.Primary)
	default:
		// the live page covers this; a hairline frames it
		ui.StrokeRound(g, ui.Rect{X: r.X - 1, Y: r.Y - 1, W: r.W + 2, H: r.H + 2}, 3, 1, th.OutlineVariant)
	}
}

func pageColor(th *ui.Theme) ui.Color {
	if th.Dark {
		return th.G5
	}
	return ui.White
}

func (a *App) message(r ui.Rect, ic ui.Icon, title, text, action string, do func()) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.FillRound(g, r, 12, pageColor(th))
	w := min(520, r.W-48)
	x := r.CX() - w/2
	y := r.Y + r.H*0.3
	ib := ui.RectAround(r.CX(), y, 56, 56)
	ui.FillOval(g, ib, th.SecondaryContainer)
	ui.DrawIcon(g, ic, ib.CX()-14, ib.CY()-14, 28, th.OnSecondaryContainer)
	y = ib.B() + 34
	ui.TextCenter(g, title, ui.Rect{X: x, Y: y - 20, W: w, H: 28}, ui.FTitle, th.OnSurface)
	y += 20
	for _, ln := range wrap(g, text, ui.FBody, w) {
		ui.TextCenter(g, ln, ui.Rect{X: x, Y: y, W: w, H: 22}, ui.FBody, th.OnSurfaceVariant)
		y += 22
	}
	if action != "" {
		bw := g.Measure(action, ui.FBodyBold) + 48
		if u.Button(ID("msg"), ui.Rect{X: r.CX() - bw/2, Y: y + 16, W: bw, H: 40}, action, ui.ButtonOpt{Primary: true}) && do != nil {
			do()
		}
	}
}

// wrap breaks text into lines no wider than w.
func wrap(g ui.Gfx, text string, f ui.Font, w float32) []string {
	var out []string
	line := ""
	for _, word := range strings.Fields(text) {
		try := word
		if line != "" {
			try = line + " " + word
		}
		if g.Measure(try, f) > w && line != "" {
			out = append(out, line)
			line = word
		} else {
			line = try
		}
	}
	if line != "" {
		out = append(out, line)
	}
	return out
}

// ntp is the new tab page, drawn by Lite Go itself so it opens instantly.
func (a *App) ntp(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.FillRound(g, r, 14, pageColor(th))
	g.Save()
	g.Clip(r)
	defer g.Restore()
	colW := min(680, r.W-48)
	cx := r.CX()
	compact := r.H < 560
	y := r.Y + max(28, r.H*0.13)
	if compact {
		y = r.Y + 24
	}

	// heading: the mark and what kind of tab this is
	title, sub := "Lite Go", "Light on memory. Fast to Google and YouTube."
	markCol := th.Primary
	switch t.Kind {
	case KPrivate:
		title, sub, markCol = "Private tab", "Nothing from this tab is kept: no history, cookies or cache after the last private tab closes.", ui.Hex("#3a2d48")
	case KTemp:
		title, sub, markCol = "Temporary tab", "A fresh session for this tab alone. Sign in to a second account here; it is wiped when the tab closes.", th.Hl
	case KContainer:
		title, sub, markCol = t.Container, "A container: its own sign-ins and cookies, kept apart from your other tabs.", containerColor(t.Container)
	}
	ms := float32(40)
	tw := g.Measure(title, ui.FBig)
	hx := cx - (ms+14+tw)/2
	mr := ui.Rect{X: hx, Y: y, W: ms, H: ms}
	logo(g, mr, th, markCol)
	if t.Kind == KPrivate || t.Kind == KContainer || t.Kind == KTemp {
		ic := map[Kind]ui.Icon{KPrivate: ui.IPrivate, KContainer: ui.IContainer, KTemp: ui.IReset}[t.Kind]
		ui.FillRoundAccent(g, mr, ms*0.3, markCol)
		ui.DrawIcon(g, ic, mr.CX()-11, mr.CY()-11, 22, ui.White)
	}
	g.Text(title, hx+ms+14, ui.Mid(g, y, ms, ui.FBig), ui.FBig, th.OnSurface)
	y += ms + 14
	for _, ln := range wrap(g, sub, ui.FBody, colW) {
		ui.TextCenter(g, ln, ui.Rect{X: cx - colW/2, Y: y, W: colW, H: 22}, ui.FBody, th.OnSurfaceVariant)
		y += 22
	}
	y += 18

	// the search pill
	sr := ui.Rect{X: cx - colW/2, Y: y, W: colW, H: 56}
	id := ID("ntp")
	focused := a.st.Focus == id
	ui.Glass(g, sr, 28, th, true, true)
	if focused {
		ui.StrokeRound(g, sr.Inset(1), 27, 2, th.Primary)
	}
	ui.DrawIcon(g, modeIcons[a.set.Mode], sr.X+20, sr.CY()-11, 22, th.Primary)
	fr := ui.Rect{X: sr.X + 52, Y: sr.Y, W: sr.W - 70, H: sr.H}
	ph := "Ask " + modeLabels[a.set.Mode] + " or type an address"
	if a.set.Mode == core.ModeYouTube {
		ph = "Search YouTube or type an address"
	}
	if a.u.TextField(id, fr, a.ntpQ, ui.FieldOpt{Bare: true, Font: ui.Font{Size: 16}, Placeholder: ph, OnEnter: func() { a.open(a.ntpQ.Text()) }}) {
		a.suggest(a.ntpQ.Text())
	}
	a.suggestKeys(id, func() { a.st.Focus = ui.ID{} })
	sugTop := sr.B() + 8
	y = sr.B() + 16

	// search modes as M3 filter chips
	const chipH = 34
	var widths []float32
	total := float32(0)
	for i, l := range modeLabels {
		w := g.Measure(l, ui.FSmallBold) + 50
		widths = append(widths, w)
		total += w
		if i > 0 {
			total += 8
		}
	}
	x := cx - total/2
	for i, l := range modeLabels {
		cr := ui.Rect{X: x, Y: y, W: widths[i], H: chipH}
		sel := core.Mode(i) == a.set.Mode
		if sel {
			ui.FillRound(g, cr, 10, th.SecondaryContainer)
		} else {
			ui.StrokeRound(g, cr.Inset(0.5), 10, 1, th.Outline)
		}
		if u.Hover(cr) {
			ui.FillRound(g, cr, 10, th.Ink.Alpha(0.06))
		}
		fg := th.OnSurfaceVariant
		if sel {
			fg = th.OnSecondaryContainer
		}
		ic := modeIcons[i]
		if sel {
			ic = ui.ICheck
		}
		ui.DrawIcon(g, ic, cr.X+12, cr.CY()-9, 18, fg)
		g.Text(l, cr.X+36, ui.Mid(g, cr.Y, cr.H, ui.FSmallBold), ui.FSmallBold, fg)
		if u.Clickable(ui.IdN("mode", i), cr) {
			a.set.Mode = core.Mode(i)
			a.set.Save()
			a.st.Focus = id
			a.suggest(a.ntpQ.Text())
		}
		x += widths[i] + 8
	}
	y += chipH + 30

	// tiles: quick sites, then the most visited (never for private tabs)
	tile := func(i int, idp, name, url string, col ui.Color, tr ui.Rect) {
		hot := u.Hover(tr)
		if hot {
			ui.Glass(g, tr, 18, th, false, true)
		}
		cr := ui.RectAround(tr.CX(), tr.Y+32, 48, 48)
		ui.FillRoundAccent(g, cr, 16, col)
		ui.TextCenter(g, monogram(core.Host(url)), cr, ui.Font{Size: 20, Bold: true}, ui.White)
		if name == "YouTube" {
			// a small play mark reads better than a letter
			ui.FillRoundAccent(g, cr, 16, col)
			ui.DrawIcon(g, ui.IPlay, cr.CX()-11, cr.CY()-11, 22, ui.White)
		}
		ui.TextCenter(g, ui.Fit(g, name, ui.FSmall, tr.W-8), ui.Rect{X: tr.X, Y: cr.B() + 6, W: tr.W, H: 20}, ui.FSmall, th.OnSurface)
		u.Tooltip(core.Display(url), tr)
		if u.Clickable(ui.IdN(idp, i), tr) {
			a.visit(url)
		}
	}
	const th0 = 96
	tw0 := float32(92)
	cols := 4
	if colW >= 8*78 {
		cols, tw0 = 8, min(92, colW/8)
	}
	gridW := float32(cols) * tw0
	gx := cx - gridW/2
	for i, q := range quickSites {
		c, row := i%cols, i/cols
		tile(i, "quick", q.name, q.url, ui.Hex(q.color), ui.Rect{X: gx + float32(c)*tw0, Y: y + float32(row)*th0, W: tw0 - 6, H: th0 - 6})
	}
	y += float32((len(quickSites)+cols-1)/cols) * th0
	if !t.private() {
		var top []core.Entry
		quickHost := map[string]bool{}
		for _, q := range quickSites {
			quickHost[core.Host(q.url)] = true
		}
		for _, e := range a.hist.Top(16) {
			if !quickHost[core.Host(e.URL)] && len(top) < cols {
				top = append(top, e)
			}
		}
		if len(top) > 0 && y+th0+40 < r.B()-40 {
			y += 10
			g.Text("Most visited", gx+8, y+14, ui.FSmallBold, th.OnSurfaceVariant)
			y += 26
			for i, e := range top {
				name := e.Title
				if name == "" || len(name) > 22 {
					name = strings.TrimPrefix(core.Host(e.URL), "www.")
				}
				tile(i, "top", name, e.URL, siteColor(core.Host(e.URL)), ui.Rect{X: gx + float32(i)*tw0, Y: y, W: tw0 - 6, H: th0 - 6})
			}
			y += th0
		}
	}

	// footer: what the shield did and how much memory the pages use
	fy := r.B() - 34
	if fy > y+8 {
		parts := []string{}
		if a.shield.On {
			parts = append(parts, "Shield on · "+comma(a.blockedTotal)+" ads and trackers blocked")
		} else {
			parts = append(parts, "Shield off")
		}
		if a.memMB > 0 {
			parts = append(parts, "Pages "+mb(a.memMB))
		}
		s := strings.Join(parts, "   ·   ")
		sw := g.Measure(s, ui.FSmall) + 24
		ui.DrawIcon(g, ui.IShield, cx-sw/2-4, fy-1, 16, th.Primary)
		g.Text(s, cx-sw/2+18, fy+12, ui.FSmall, th.OnSurfaceVariant)
	}

	if focused && len(a.sugg) > 0 {
		h := float32(len(a.sugg))*40 + 12
		a.suggestions(ui.Rect{X: sr.X, Y: sugTop, W: sr.W, H: h}, ID("sugN"))
	}
}

func comma(n int) string {
	s := strconv.Itoa(n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}
