package shell

import (
	"encoding/json"
	"strings"

	"litego/core"
	"litego/ui"
)

// The AI panel: ask about the open page. Lite Go reads the page, asks Google AI
// Mode with the question, the page's address and its text, and writes the
// answer here as text, in the theme's colors.

const aiW = 380

type aiTurn struct {
	q, title, url string
	ans           core.AIResult
	state         loadState
}

type aiPanel struct {
	open   bool
	turns  []*aiTurn
	input  *ui.TextEdit
	scroll ui.Scroll
}

var aiPrompts = []string{"Summarize this page", "Key points", "Explain it simply", "Is it trustworthy?"}

// openAI shows the panel (and asks q when it is not empty).
func (a *App) openAI(q string) {
	a.ai.open, a.panel = true, false
	a.st.Focus = ID("aiq")
	if q != "" {
		a.askAI(q)
	}
}

// askAI reads the open page (when there is one) and asks AI Mode about it.
func (a *App) askAI(q string) {
	q = strings.TrimSpace(q)
	if q == "" {
		return
	}
	t := a.tab()
	turn := &aiTurn{q: q}
	a.ai.turns = append(a.ai.turns, turn)
	a.ai.scroll.Y = 1e9 // to the newest
	private := t != nil && t.private()
	ask := func(prompt string) {
		a.askGoogleAI(a.workerFor(private, true), "panel", prompt, q, 40, func(r core.AIResult, done bool) {
			if r.Text != "" {
				turn.ans = r
			}
			if done {
				turn.state = stDone
				if turn.ans.Text == "" {
					turn.state = stFailed
				}
			}
		})
	}
	switch {
	case t != nil && t.search != nil:
		turn.title = "Search: " + t.search.Q
		ask(q + "\n\nContext: my Google search was \"" + t.search.Q + "\"")
	case t != nil && t.view != nil && t.URL != "":
		turn.title, turn.url = t.Title, t.URL
		v := t.view
		a.web(func() {
			v.Run(core.PageScript, func(js string) {
				a.post(func() {
					var p struct{ Title, URL, Text, Sel string }
					_ = jsonUnmarshal(js, &p)
					if p.URL == "" {
						p.URL, p.Title = turn.url, turn.title
					}
					ask(core.PagePrompt(q, p.Title, p.URL, p.Text, p.Sel))
				})
			})
		})
	default:
		ask(q)
	}
}

// drawAI draws the panel in r.
func (a *App) drawAI(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 20, th, true, true)
	ui.FillRound(g, r, 20, th.Primary.Alpha(0.03))
	hr := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 56}
	ib := ui.RectAround(hr.X+30, hr.CY(), 28, 28)
	ui.FillRoundAccent(g, ib, 9, th.Primary)
	ui.DrawIcon(g, ui.ISparkle, ib.CX()-8, ib.CY()-8, 16, ui.White)
	g.Text("Ask AI", hr.X+54, ui.Mid(g, hr.Y, hr.H, ui.FTitle), ui.FTitle, th.OnSurface)
	g.Text("Google AI Mode", hr.X+54+g.Measure("Ask AI", ui.FTitle)+10, ui.Mid(g, hr.Y, hr.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant)
	if u.IconButton(ID("aiclose"), ui.Rect{X: hr.R() - 48, Y: hr.CY() - 20, W: 40, H: 40}, ui.IClose, "Close", ui.IconOpt{}) {
		a.ai.open = false
		return
	}
	x, w := r.X+18, r.W-36
	t := a.tab()

	// the page being asked about
	y := hr.B()
	pc := ui.Rect{X: x, Y: y, W: w, H: 48}
	ui.FillRound(g, pc, 14, th.Ink.Alpha(0.04))
	title, sub := "New tab", "Ask anything"
	host := ""
	switch {
	case t != nil && t.search != nil:
		title, sub = t.search.Q, "Google search"
	case t != nil && t.URL != "":
		host = core.Host(t.URL)
		title, sub = t.label(), strings.TrimPrefix(host, "www.")
	}
	mr := ui.RectAround(pc.X+22, pc.CY(), 26, 26)
	if host != "" {
		ui.FillRoundAccent(g, mr, 8, siteColor(host))
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 12, Bold: true}, ui.White)
	} else {
		ui.FillRound(g, mr, 8, th.SecondaryContainer)
		ui.DrawIcon(g, ui.IGlobe, mr.CX()-8, mr.CY()-8, 16, th.OnSecondaryContainer)
	}
	ui.TextFit(g, title, pc.X+44, pc.Y+21, ui.FSmallBold, th.OnSurface, pc.W-54)
	ui.TextFit(g, sub, pc.X+44, pc.Y+37, ui.FSmall, th.OnSurfaceVariant, pc.W-54)
	y = pc.B() + 10

	// the conversation
	inH := float32(52)
	body := ui.Rect{X: r.X, Y: y, W: r.W, H: r.B() - y - inH - 16}
	sc := &a.ai.scroll
	u.Scroll(ID("aiscroll"), body, sc)
	g.Save()
	g.Clip(body)
	cy := body.Y + 6 - sc.Y
	if len(a.ai.turns) == 0 {
		g.Text("Try", x, cy+16, ui.FSmallBold, th.OnSurfaceVariant)
		cy += 28
		for i, p := range aiPrompts {
			cr := ui.Rect{X: x, Y: cy, W: w, H: 40}
			ui.StrokeRound(g, cr.Inset(0.5), 14, 1, th.OutlineVariant)
			if u.Hover(cr) {
				ui.FillRound(g, cr, 14, th.Primary.Alpha(0.07))
			}
			ui.DrawIcon(g, ui.ISparkle, cr.X+12, cr.CY()-8, 16, th.Primary)
			g.Text(p, cr.X+38, ui.Mid(g, cr.Y, cr.H, ui.FBody), ui.FBody, th.OnSurface)
			if u.Clickable(ui.IdN("aip", i), cr) {
				a.askAI(p)
			}
			cy += 46
		}
	}
	for i, turn := range a.ai.turns {
		// the question, right-aligned
		ql := wrap(g, turn.q, ui.FBody, w*0.8-24)
		qw := float32(0)
		for _, l := range ql {
			qw = max(qw, g.Measure(l, ui.FBody))
		}
		qr := ui.Rect{X: x + w - qw - 24, Y: cy, W: qw + 24, H: float32(len(ql))*21 + 16}
		ui.FillRound(g, qr, 16, th.PrimaryContainer)
		for j, l := range ql {
			g.Text(l, qr.X+12, qr.Y+22+float32(j)*21, ui.FBody, th.OnPrimaryContainer)
		}
		cy = qr.B() + 12
		switch {
		case turn.ans.Text == "" && turn.state == stLoading:
			for k, f := range []float32{0.95, 1, 0.7} {
				shimmer(a, ui.Rect{X: x, Y: cy + float32(k)*22, W: w * f, H: 11}, 5)
			}
			cy += 76
		case turn.state == stFailed && turn.ans.Text == "":
			msg := "AI Mode did not answer. "
			if turn.ans.Captcha {
				msg = "Google asked to confirm you are human. Open AI Mode once in a tab, then ask again. "
			}
			cy = a.resultNote(ui.Rect{X: x, Y: cy, W: w}, msg, "Open AI Mode", func() { a.newTab(KNormal, "", core.ModeAI.URL(turn.q)+"&lite=0", true) })
		default:
			ls := richLines(g, turn.ans.Text, w)
			cy = drawRich(g, th, ls, x, cy)
			if turn.state == stLoading {
				a.u.Redraw = true
				ui.FillOval(g, ui.RectAround(x+5, cy+10, 7, 7), th.Primary.Alpha(0.4+0.4*float32((int(a.now()*3))%2)))
				cy += 20
			}
			if len(turn.ans.Sources) > 0 && turn.state == stDone {
				cy = a.sourceChips(turn.ans.Sources, x, cy+8, w, "aisrc"+string(rune('a'+i%26)))
			}
		}
		cy += 18
	}
	sc.Content = cy + sc.Y - body.Y
	if sc.Y > max(0, sc.Content-body.H) {
		sc.Y = max(0, sc.Content-body.H)
	}
	g.Restore()

	// the question field
	ir := ui.Rect{X: x, Y: r.B() - inH - 12, W: w, H: inH}
	id := ID("aiq")
	ui.FillRound(g, ir, 26, pageColor(th))
	rim := th.Outline
	if a.st.Focus == id {
		rim = th.Primary
	}
	ui.StrokeRound(g, ir.Inset(0.75), 25, 1.5, rim)
	send := func() {
		q := a.ai.input.Text()
		a.ai.input.Set("")
		a.askAI(q)
	}
	ph := "Ask about this page"
	if t == nil || t.URL == "" {
		ph = "Ask anything"
	}
	u.TextField(id, ui.Rect{X: ir.X + 18, Y: ir.Y, W: ir.W - 66, H: ir.H}, a.ai.input, ui.FieldOpt{Bare: true, Placeholder: ph, OnEnter: send})
	sb := ui.RectAround(ir.R()-27, ir.CY(), 38, 38)
	empty := strings.TrimSpace(a.ai.input.Text()) == ""
	col := th.Primary
	if empty {
		col = th.Primary.Alpha(0.35)
	}
	ui.FillOval(g, sb, col)
	ui.DrawIcon(g, ui.ISend, sb.CX()-9, sb.CY()-9, 18, ui.White)
	if !empty && u.Clickable(ID("aisend"), sb) {
		send()
	}
}

func jsonUnmarshal(js string, v any) error { return json.Unmarshal([]byte(js), v) }
