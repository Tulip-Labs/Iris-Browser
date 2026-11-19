package shell

import (
	"math"
	"runtime"
	"strconv"
	"strings"

	"iris/ui"
)

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
	case t.search != nil:
		a.results(r, t)
	case t.Crashed:
		why := "Its process ended (it may have run out of memory). Reload to open it again."
		a.message(r, ui.IWarning, "This page stopped working", why, "Reload", func() { a.reload(t) })
	case a.engErr != nil || a.eng == nil:
		msg := "Iris shows pages with its own page engines (Servo and Electron), which are missing. Run the Iris installer again."
		if a.engErr != nil && !strings.Contains(a.engErr.Error(), "not available") {
			msg = "The web engine did not start: " + a.engErr.Error()
		}
		if runtime.GOOS == "linux" {
			msg = "Chromium, which shows the pages, did not start. Install Iris again, or run iris from a terminal to see why."
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

// fillPage paints the surface of Iris's own pages (new tab, results): the
// page color, or a pale version of the palette's merging pastels.
func fillPage(g ui.Gfx, r ui.Rect, rad float32, th *ui.Theme) {
	if th.Grad == nil {
		ui.FillRound(g, r, rad, pageColor(th))
		return
	}
	c := []ui.Color{ui.Mix(th.Grad[0], ui.White, 0.62), ui.Mix(th.Grad[1], ui.White, 0.7), ui.Mix(th.Grad[2], ui.White, 0.62)}
	ui.FillGradient3(g, r, rad, c)
}

func pageColor(th *ui.Theme) ui.Color {
	if th.Dark {
		return th.G5
	}
	return ui.White
}

func (a *App) message(r ui.Rect, ic ui.Icon, title, text, action string, do func()) {
	u, g, th := &a.u, a.u.G, a.u.Th
	fillPage(g, r, 12, th)
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

// ntp is the new tab page, drawn by Iris itself so it opens instantly:
// the mark and the name, and the search under them. Nothing else.
func (a *App) ntp(r ui.Rect, t *Tab) {
	g, th := a.u.G, a.u.Th
	fillPage(g, r, 14, th)
	g.Save()
	g.Clip(r)
	defer g.Restore()
	colW := min(640, r.W-32)
	cx := r.CX()

	title, sub := "Iris", ""
	switch t.Kind {
	case KPrivate:
		title, sub = "Private tab", "Nothing from this tab is kept: no history, cookies or cache."
	case KTemp:
		title, sub = "Temporary tab", "A fresh session for this tab alone, wiped when it closes."
	case KContainer:
		title, sub = t.Container, "Its own sign-ins and cookies, apart from your other tabs."
	case KSandbox:
		title, sub = "Sandbox", "No downloads, no permissions, nothing kept: for a site you do not trust."
	}
	subLines := wrap(g, sub, ui.FBody, colW)
	ms := float32(64)
	if r.H < 420 {
		ms = 44
	}
	blockH := ms + 18 + 40 + float32(len(subLines))*22 + 20 + 56
	y := r.Y + max(20, (r.H-blockH)*0.42)

	// the mark (or the kind's icon in its color), centered, the name under it
	mr := ui.RectAround(cx, y+ms/2, ms, ms)
	if t.Kind == KNormal {
		logo(g, mr, th)
	} else {
		ic, col := a.kindIcon(t)
		_ = col
		ui.Shadow(g, mr, ms*0.3, th.Shadow, 0.5, 1.5)
		ui.Liquid(g, mr, ms*0.3, th.Ink)
		ui.DrawIcon(g, ic, mr.CX()-ms*0.27, mr.CY()-ms*0.27, ms*0.54, th.Ink)
	}
	y += ms + 18
	tf := ui.Font{Size: 30, Bold: true}
	ui.TextCenter(g, title, ui.Rect{X: cx - colW/2, Y: y, W: colW, H: 40}, tf, th.OnSurface)
	y += 44
	for _, ln := range subLines {
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
		ui.FillRound(g, sr, 28, th.Primary.Alpha(0.04))
		ui.StrokeRound(g, sr.Inset(1), 27, 2, th.Primary)
	}
	ui.DrawIcon(g, ui.ISearch, sr.X+20, sr.CY()-11, 22, th.Primary)
	fr := ui.Rect{X: sr.X + 54, Y: sr.Y, W: sr.W - 72, H: sr.H}
	if a.u.TextField(id, fr, a.ntpQ, ui.FieldOpt{Bare: true, Font: ui.Font{Size: 16.5}, Placeholder: "Search Google and YouTube, or type an address", OnEnter: func() { a.open(a.ntpQ.Text()) }}) {
		a.suggest(a.ntpQ.Text())
	}
	a.suggestKeys(id, func() { a.st.Focus = ui.ID{} })
	if focused && len(a.sugg) > 0 {
		h := float32(len(a.sugg))*40 + 12
		a.suggestions(ui.Rect{X: sr.X, Y: sr.B() + 8, W: sr.W, H: h}, ID("sugN"))
	}
}

func comma(n int) string {
	s := strconv.Itoa(n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}
