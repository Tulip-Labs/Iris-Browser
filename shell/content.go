package shell

import (
	"math"
	"runtime"
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

// content draws what the page area shows when it is not a live page.
func (a *App) content(r ui.Rect) {
	g, th := a.u.G, a.u.Th
	t := a.tab()
	if t == nil || r.Empty() {
		return
	}
	switch {
	case t.settings:
		a.settingsPage(r)
	case t.URL == "":
		a.ntp(r, t)
	case t.search != nil:
		a.results(r, t)
	case t.Crashed:
		why := "Its process ended (it may have run out of memory). Reload to open it again."
		a.message(r, ui.IWarning, "This page stopped working", why, "Reload", func() { a.reload(t) })
	case a.engErr != nil || a.eng == nil:
		msg := "Lite Go shows pages with Microsoft Edge WebView2, which is not installed. Run the Lite Go installer again, or get the runtime from Microsoft."
		if a.engErr != nil && !strings.Contains(a.engErr.Error(), "not available") {
			msg = "The web engine did not start: " + a.engErr.Error()
		}
		if runtime.GOOS == "linux" {
			msg = "Lite Go shows pages with WebKitGTK. Install WebKitGTK 4.1 (webkit2gtk-4.1) and open Lite Go again."
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

// fillPage paints the surface of Lite Go's own pages (new tab, results): the
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

// ntp is the new tab page, drawn by Lite Go itself so it opens instantly: the
// mark, the search and its modes, nothing else.
func (a *App) ntp(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	fillPage(g, r, 14, th)
	g.Save()
	g.Clip(r)
	defer g.Restore()
	colW := min(680, r.W-48)
	cx := r.CX()

	title, sub := "Lite Go", "Light on memory. Fast to Google and YouTube."
	switch t.Kind {
	case KPrivate:
		title, sub = "Private tab", "Nothing from this tab is kept: no history, cookies or cache after the last private tab closes."
	case KTemp:
		title, sub = "Temporary tab", "A fresh session for this tab alone. Sign in to a second account here; it is wiped when the tab closes."
	case KContainer:
		title, sub = t.Container, "A container: its own sign-ins and cookies, kept apart from your other tabs."
	case KSandbox:
		title, sub = "Sandbox", "For a site you do not trust. It cannot download, use the camera, microphone or location, or save passwords, and everything is wiped when the tab closes."
	}
	subLines := wrap(g, sub, ui.FBody, colW)
	const ms = 44
	blockH := float32(ms+16) + float32(len(subLines))*22 + 22 + 56 + 16 + 34 + 150
	y := r.Y + max(24, (r.H-blockH)*0.38)

	// heading: the mark (or the kind's icon in its color) and the title
	tw := g.Measure(title, ui.FBig)
	hx := cx - (ms+14+tw)/2
	mr := ui.Rect{X: hx, Y: y, W: ms, H: ms}
	if t.Kind == KNormal {
		logo(g, mr, th, th.Primary)
	} else {
		ic, col := a.kindIcon(t)
		ui.Shadow(g, mr, ms*0.3, th.Shadow, 0.6, 1.5)
		ui.FillRoundAccent(g, mr, ms*0.3, col)
		ui.DrawIcon(g, ic, mr.CX()-12, mr.CY()-12, 24, ui.White)
	}
	g.Text(title, hx+ms+14, ui.Mid(g, y, ms, ui.FBig), ui.FBig, th.OnSurface)
	y += ms + 16
	for _, ln := range subLines {
		ui.TextCenter(g, ln, ui.Rect{X: cx - colW/2, Y: y, W: colW, H: 22}, ui.FBody, th.OnSurfaceVariant)
		y += 22
	}
	y += 22

	if a.set.GoogleSignIn == "" && t.Kind == KNormal {
		a.signInCard(ui.Rect{X: cx - colW/2, Y: y, W: colW}, t)
		return
	}

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
	y += a.modeChips(cx, y, r.W-32, func() { a.st.Focus = id; a.suggest(a.ntpQ.Text()) })

	// footer: what the shield did and how much memory the pages use
	fy := r.B() - 34
	if fy > y+60 {
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
	_ = u
}

// modeChips draws the search modes centered at cx, in rows no wider than
// maxW (a phone takes two); picked runs after a change. It returns the height.
func (a *App) modeChips(cx, y, maxW float32, picked func()) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	const chipH, gap = 34, 8
	var widths []float32
	for _, l := range modeLabels {
		widths = append(widths, g.Measure(l, ui.FSmallBold)+50)
	}
	// rows of chips that fit
	type row struct {
		from, to int
		w        float32
	}
	var rows []row
	cur := row{}
	for i, w := range widths {
		if cur.to > cur.from && cur.w+gap+w > maxW {
			rows = append(rows, cur)
			cur = row{from: i, to: i}
		}
		if cur.to > cur.from {
			cur.w += gap
		}
		cur.w += w
		cur.to = i + 1
	}
	rows = append(rows, cur)
	xs := make([]float32, len(widths))
	ys := make([]float32, len(widths))
	for ri, rw := range rows {
		x := cx - rw.w/2
		for i := rw.from; i < rw.to; i++ {
			xs[i], ys[i] = x, y+float32(ri)*(chipH+gap)
			x += widths[i] + gap
		}
	}
	for i, l := range modeLabels {
		cr := ui.Rect{X: xs[i], Y: ys[i], W: widths[i], H: chipH}
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
		ui.DrawIcon(g, modeIcons[i], cr.X+12, cr.CY()-9, 18, fg)
		g.Text(l, cr.X+36, ui.Mid(g, cr.Y, cr.H, ui.FSmallBold), ui.FSmallBold, fg)
		if u.Clickable(ui.IdN("mode", i), cr) {
			a.set.Mode = core.Mode(i)
			a.set.Save()
			if picked != nil {
				picked()
			}
		}
	}
	return float32(len(rows))*(chipH+gap) - gap
}

func comma(n int) string {
	s := strconv.Itoa(n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

// signInCard is the first-run step: sign in to Google once, so the results and
// the AI answers (read from Google in the background) never meet human checks.
func (a *App) signInCard(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	r.H = 248
	ui.Glass(g, r, 24, th, true, true)
	ui.FillRound(g, r, 24, th.Primary.Alpha(0.04))
	x, y := r.X+28, r.Y+28
	ib := ui.Rect{X: x, Y: y, W: 44, H: 44}
	ui.FillRoundAccent(g, ib, 14, th.Primary)
	ui.DrawIcon(g, ui.IPerson, ib.CX()-12, ib.CY()-12, 24, ui.White)
	g.Text("Sign in to Google once", x+60, y+20, ui.FTitle, th.OnSurface)
	g.Text("Step 1 of 1 · takes a minute", x+60, y+40, ui.FSmall, th.OnSurfaceVariant)
	y += 66
	text := "Lite Go reads Google in the background to build your results and AI answers. When you are signed in, Google trusts these visits and does not stop them to ask whether you are human. Your password goes only to Google."
	for _, ln := range wrap(g, text, ui.FBody, r.W-56) {
		g.Text(ln, x, y+16, ui.FBody, th.OnSurfaceVariant)
		y += 22
	}
	by := r.B() - 64
	if u.Button(ID("signin"), ui.Rect{X: x, Y: by, W: 200, H: 42}, "Sign in to Google", ui.ButtonOpt{Primary: true, Icon: ui.IPerson, HasIcon: true}) {
		a.signIn(t)
	}
	lr := ui.Rect{X: x + 212, Y: by, W: 150, H: 42}
	if u.Hover(lr) {
		ui.FillRound(g, lr, 21, th.Ink.Alpha(0.05))
	}
	ui.TextCenter(g, "Not now", lr, ui.FBodyBold, th.OnSurfaceVariant)
	u.Tooltip("Searching still works; Google may sometimes ask you to prove you are human", lr)
	if u.Clickable(ID("signlater"), lr) {
		a.set.GoogleSignIn = "later"
		a.set.Save()
		a.st.Focus = ID("ntp")
	}
}
