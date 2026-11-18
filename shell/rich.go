package shell

import (
	"strconv"
	"strings"

	"iris/core"
	"iris/ui"
)

// The AI answer, laid out like an article: headings, paragraphs and bullets,
// with **bold** runs inline and numbered citation pills at the end of the
// blocks that cite sources, named by their site so you know where a fact is
// from before you click.

type aiSpan struct {
	text string
	bold bool
	x    float32
}

type aiLine struct {
	spans  []aiSpan
	y      float32 // top of the line
	size   float32
	head   bool
	bullet bool
	cites  []int
	citeX  float32
}

type aiLayout struct {
	lines []aiLine
	h     float32
	size  float32
}

func spanFont(size float32, bold bool) ui.Font { return ui.Font{Size: size, Bold: bold} }

const citeH = 18

var citeF = ui.Font{Size: 10.5, Bold: true}

// citeName is the short name a citation shows: the source's site, without
// the www. and the usual endings (wikipedia, go.dev, nature).
func citeName(src []core.WebResult, n int) string {
	if n < 1 || n > len(src) {
		return strconv.Itoa(n)
	}
	k := core.SiteKey(src[n-1].URL)
	for _, end := range []string{".com", ".org", ".net", ".edu", ".gov", ".io", ".co.uk", ".co"} {
		if strings.HasSuffix(k, end) && len(k) > len(end)+1 {
			k = strings.TrimSuffix(k, end)
			break
		}
	}
	if len(k) > 18 {
		k = k[:17] + "…"
	}
	if k == "" {
		return strconv.Itoa(n)
	}
	return k
}

func citeW(g ui.Gfx, src []core.WebResult, n int) float32 {
	return g.Measure(citeName(src, n), citeF) + 14
}

// layoutAnswer wraps blocks to width w at a body size.
func layoutAnswer(g ui.Gfx, blocks []core.AIBlock, w, size float32, src []core.WebResult) aiLayout {
	lh := size * 1.6
	var out []aiLine
	y := float32(0)
	for bi, b := range blocks {
		head := b.Kind == "h"
		bullet := b.Kind == "li"
		sz := size
		if head {
			sz = size + 1.5
		}
		if bi > 0 {
			switch {
			case head:
				y += size * 0.9
			case bullet && blocks[bi-1].Kind == "li":
				y += 2
			default:
				y += size * 0.55
			}
		}
		indent := float32(0)
		if bullet {
			indent = 20
		}
		// words with their weight
		type word struct {
			s    string
			bold bool
		}
		var words []word
		bold := head
		for i, part := range strings.Split(b.Text, "**") {
			if i > 0 && !head {
				bold = !bold
			}
			for _, f := range strings.Fields(part) {
				words = append(words, word{f, bold})
			}
		}
		space := g.Measure(" ", spanFont(sz, false))
		line := aiLine{y: y, size: sz, head: head, bullet: bullet}
		x := indent
		flush := func() {
			out = append(out, line)
			y += lh + (sz-size)*1.4
			line = aiLine{y: y, size: sz, head: head}
			x = indent
		}
		for _, wd := range words {
			ww := g.Measure(wd.s, spanFont(sz, wd.bold))
			if x > indent && x+ww > w {
				flush()
			}
			// a bold run continues in the same span
			if n := len(line.spans); n > 0 && line.spans[n-1].bold == wd.bold {
				line.spans[n-1].text += " " + wd.s
			} else {
				line.spans = append(line.spans, aiSpan{text: wd.s, bold: wd.bold, x: x})
			}
			x += ww + space
		}
		if len(b.Cites) > 0 {
			cw := float32(0)
			for _, c := range b.Cites {
				cw += citeW(g, src, c) + 4
			}
			if x+cw > w && len(line.spans) > 0 {
				// carry the last word down with the citations, so they never sit alone
				last := &line.spans[len(line.spans)-1]
				word, isBold := last.text, last.bold
				if i := strings.LastIndexByte(last.text, ' '); i >= 0 {
					word = last.text[i+1:]
					last.text = last.text[:i]
				} else {
					line.spans = line.spans[:len(line.spans)-1]
				}
				if len(line.spans) == 0 {
					line.spans = append(line.spans, aiSpan{text: word, bold: isBold, x: indent})
					x = indent + g.Measure(word, spanFont(sz, isBold)) + space
				} else {
					flush()
					line.spans = append(line.spans, aiSpan{text: word, bold: isBold, x: indent})
					x = indent + g.Measure(word, spanFont(sz, isBold)) + space
				}
			}
			line.cites, line.citeX = b.Cites, x+2
		}
		if len(line.spans) > 0 || len(line.cites) > 0 {
			flush()
		}
	}
	return aiLayout{lines: out, h: y, size: size}
}

// drawAnswer draws the first n lines (all when n <= 0) at (x, y) and returns the bottom.
func (a *App) drawAnswer(l aiLayout, x, y float32, src []core.WebResult, n int, id string) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	lines := l.lines
	if n > 0 && n < len(lines) {
		lines = lines[:n]
	}
	body := ui.Mix(th.OnSurface, th.OnSurfaceVariant, 0.2)
	bottom := y
	for li, ln := range lines {
		base := y + ln.y + ln.size*1.15
		if ln.bullet {
			ui.FillOval(g, ui.RectAround(x+7, base-ln.size*0.33, 5.5, 5.5), th.Primary)
		}
		for _, sp := range ln.spans {
			col := body
			if sp.bold || ln.head {
				col = th.OnSurface
			}
			g.Text(sp.text, x+sp.x, base, spanFont(ln.size, sp.bold || ln.head), col)
		}
		cx := x + ln.citeX
		for ci, c := range ln.cites {
			cw := citeW(g, src, c)
			r := ui.Rect{X: cx, Y: base - citeH + 4, W: cw, H: citeH}
			hot := u.Hover(r)
			bg := th.Primary.Alpha(0.13)
			if hot {
				bg = th.Primary.Alpha(0.26)
			}
			ui.FillRound(g, r, citeH/2, bg)
			ui.TextCenter(g, citeName(src, c), r, citeF, th.Primary)
			if c-1 < len(src) {
				s := src[c-1]
				u.Tooltip(strings.TrimSpace(s.Title+"  ·  "+strings.TrimPrefix(core.Host(s.URL), "www.")), r)
				if u.Clickable(ui.Id(id+"/c"+strconv.Itoa(li)+"_"+strconv.Itoa(ci)), r) {
					a.visitFromResults(s.URL)
				}
			}
			cx += cw + 4
		}
		bottom = y + ln.y + l.size*1.6
	}
	return bottom
}

// sourceCards lists sources as numbered cards in cols columns.
func (a *App) sourceCards(src []core.WebResult, x, y, w float32, cols int, id string) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	if len(src) == 0 {
		return y
	}
	g.Text("Sources", x, y+14, ui.FSmallBold, th.OnSurfaceVariant)
	y += 26
	const gap, ch = 8, 54
	cw := (w - float32(cols-1)*gap) / float32(cols)
	for i, s := range src {
		r := ui.Rect{X: x + float32(i%cols)*(cw+gap), Y: y + float32(i/cols)*(ch+gap), W: cw, H: ch}
		host := strings.TrimPrefix(core.Host(s.URL), "www.")
		hot := u.Hover(r)
		ui.FillRound(g, r, 14, th.Ink.Alpha(0.035))
		if hot {
			ui.StrokeRound(g, r.Inset(0.5), 14, 1, th.Primary.Alpha(0.6))
		}
		nb := ui.Rect{X: r.X + 10, Y: r.Y + 10, W: 18, H: 18}
		ui.FillRound(g, nb, 9, th.Primary.Alpha(0.14))
		ui.TextCenter(g, strconv.Itoa(i+1), nb, ui.Font{Size: 10.5, Bold: true}, th.Primary)
		mr := ui.Rect{X: r.X + 10, Y: r.Y + 31, W: 14, H: 14}
		ui.Liquid(g, mr, mr.W/2, th.Ink)
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 8, Bold: true}, th.Ink)
		title := s.Title
		if title == "" || strings.EqualFold(title, host) {
			title = host
		}
		ui.TextFit(g, title, r.X+36, r.Y+24, ui.FSmallBold, th.OnSurface, r.W-46)
		ui.TextFit(g, host, r.X+30, r.Y+43, ui.FSmall, th.OnSurfaceVariant, r.W-40)
		u.Tooltip(s.URL, r)
		if u.Clickable(ui.IdN(id, i), r) {
			a.visitFromResults(s.URL)
		}
	}
	rows := (len(src) + cols - 1) / cols
	return y + float32(rows)*(ch+gap)
}

// sourceChips lists sources as chips that wrap: each site's mark and short
// name. With measure set it draws nothing and returns the height it needs.
func (a *App) sourceChips(src []core.WebResult, x, y, w float32, id string, measure bool) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	const h, gap = 30, 6
	top := y
	cx := x
	if !measure {
		g.Text("Sources", x, y+12, ui.FSmallBold, th.OnSurfaceVariant)
	}
	y += 20
	f := ui.FSmallBold
	for i := range src {
		name := citeName(src, i+1)
		cw := g.Measure(name, f) + 40
		if cx+cw > x+w && cx > x {
			cx, y = x, y+h+gap
		}
		if measure {
			cx += cw + gap
			continue
		}
		r := ui.Rect{X: cx, Y: y, W: cw, H: h}
		host := strings.TrimPrefix(core.Host(src[i].URL), "www.")
		hot := u.Hover(r)
		ui.FillRound(g, r, h/2, th.Ink.Alpha(0.045))
		if hot {
			ui.StrokeRound(g, r.Inset(0.5), h/2, 1, th.Primary.Alpha(0.6))
		}
		mr := ui.RectAround(r.X+15, r.CY(), 18, 18)
		ui.Liquid(g, mr, mr.W/2, th.Ink)
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 9, Bold: true}, th.Ink)
		g.Text(name, r.X+30, ui.Mid(g, r.Y, r.H, f), f, th.OnSurface)
		u.Tooltip(strings.TrimSpace(src[i].Title+"  ·  "+host), r)
		if u.Clickable(ui.IdN(id, i), r) {
			a.visitFromResults(src[i].URL)
		}
		cx = r.R() + gap
	}
	return y + h - top
}

// sourceStack is the compact "sources" chip: overlapping site marks and a count.
func (a *App) sourceStack(src []core.WebResult, x, y float32, id string, onClick func()) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	if len(src) == 0 {
		return x
	}
	n := min(4, len(src))
	label := strconv.Itoa(len(src)) + " sources"
	if len(src) == 1 {
		label = "1 source"
	}
	w := float32(n)*13 + 8 + g.Measure(label, ui.FSmallBold) + 18
	r := ui.Rect{X: x, Y: y, W: w, H: 30}
	ui.FillRound(g, r, 15, th.Ink.Alpha(0.05))
	if u.Hover(r) {
		ui.FillRound(g, r, 15, th.Ink.Alpha(0.06))
	}
	for i := n - 1; i >= 0; i-- {
		host := strings.TrimPrefix(core.Host(src[i].URL), "www.")
		mr := ui.RectAround(r.X+16+float32(i)*13, r.CY(), 20, 20)
		ui.FillOval(g, mr.Inset(-1.5), th.Surface)
		ui.Liquid(g, mr, mr.W/2, th.Ink)
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 9, Bold: true}, th.Ink)
	}
	g.Text(label, r.X+float32(n)*13+18, ui.Mid(g, r.Y, r.H, ui.FSmallBold), ui.FSmallBold, th.OnSurface)
	if u.Clickable(ui.Id(id), r) && onClick != nil {
		onClick()
	}
	return r.R()
}

// aiBadge is the accent mark of AI answers.
func aiBadge(g ui.Gfx, th *ui.Theme, r ui.Rect) {
	ui.Liquid(g, r, r.W*0.32, th.Ink)
	s := r.W * 0.62
	ui.DrawIcon(g, ui.ISparkle, r.CX()-s/2, r.CY()-s/2, s, th.Ink)
}

// writing draws the animated "Writing" status.
func (a *App) writing(x, y float32) {
	g, th := a.u.G, a.u.Th
	a.u.Redraw = true
	for i := 0; i < 3; i++ {
		ph := float32(a.now()*4) - float32(i)*0.6
		k := 0.35 + 0.65*float32(max(0, min(1, 1-absf(float32(int(ph*10)%30)/10-1))))
		ui.FillOval(g, ui.RectAround(x+float32(i)*9, y, 5.5, 5.5), th.Primary.Alpha(k))
	}
	g.Text("Writing", x+28, y+4.5, ui.FSmall, th.OnSurfaceVariant)
}

func absf(v float32) float32 {
	if v < 0 {
		return -v
	}
	return v
}
