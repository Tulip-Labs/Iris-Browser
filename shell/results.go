package shell

import (
	"context"
	"math"
	"strconv"
	"strings"
	"time"

	"litego/core"
	"litego/ui"
)

// Lite results: a Google search shown on Lite Go's own page, in the palette of
// the theme: the AI answer, the links, a gallery of pictures and the videos.

type loadState uint8

const (
	stLoading loadState = iota
	stDone
	stFailed
)

const (
	secAll = iota
	secAI
	secImages
	secVideos
)

var secNames = []string{"All", "AI Mode", "Images", "Videos"}
var secIcons = []ui.Icon{ui.IGrid, ui.ISparkle, ui.IImage, ui.IVideo}

// Search is one results page.
type Search struct {
	Q       string
	Mode    core.Mode
	URL     string
	private bool
	section int
	scroll  ui.Scroll

	Web      []core.WebResult
	webSt    loadState
	Images   []core.ImageResult
	imgSt    loadState
	Videos   []core.VideoResult
	vidSt    loadState
	AI       core.AIResult
	aiSt     loadState
	captcha  bool
	aiStable int
	cancel   bool
}

func sectionFor(m core.Mode) int {
	switch m {
	case core.ModeImages:
		return secImages
	case core.ModeVideos:
		return secVideos
	}
	return secAll
}

// startSearch reads Google and YouTube for q in the background.
func (a *App) startSearch(q string, m core.Mode, url string, private bool) *Search {
	s := &Search{Q: q, Mode: m, URL: url, private: private, section: sectionFor(m)}
	w := a.workerFor(private, false)
	w.cancel(func(j *job) bool { return true }) // a new search replaces waiting ones
	aw := a.workerFor(private, true)
	aw.cancel(func(j *job) bool { return j.tag == "search" })
	a.enqueue(w, &job{url: core.ModeWeb.URL(q), script: core.WebScript, timeout: 15, every: 0.4,
		handle: func(js string) bool {
			web, captcha := core.ParseWeb(js)
			s.captcha = s.captcha || captcha
			if len(web) == 0 && !captcha {
				return false // not rendered yet
			}
			s.Web, s.webSt = web, stDone
			return true
		},
		fail: func() {
			if s.webSt == stLoading {
				s.webSt = stFailed
			}
		}})
	a.enqueue(w, &job{url: core.ModeImages.URL(q), script: core.ImagesScript, timeout: 12, every: 0.5,
		handle: func(js string) bool {
			imgs, captcha := core.ParseImages(js)
			s.captcha = s.captcha || captcha
			if len(imgs) > len(s.Images) {
				s.Images = imgs
			}
			if len(imgs) >= 18 || captcha {
				s.imgSt = stDone
				return true
			}
			return false
		},
		fail: func() {
			if len(s.Images) > 0 {
				s.imgSt = stDone
			} else {
				s.imgSt = stFailed
			}
		}})
	a.askGoogleAI(aw, "search", q, q, 35, func(r core.AIResult, done bool) {
		s.captcha = s.captcha || r.Captcha
		if r.Text != "" {
			s.AI = r
		}
		if done {
			if s.AI.Text == "" {
				s.aiSt = stFailed
			} else {
				s.aiSt = stDone
			}
		}
	})
	yt := a.ytSearch
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		v, err := yt(ctx, q)
		a.post(func() {
			s.Videos = v
			if err != nil || len(v) == 0 {
				s.vidSt = stFailed
			} else {
				s.vidSt = stDone
			}
		})
	}()
	return s
}

// askGoogleAI asks Google AI Mode (prompt) and streams its answer to update;
// done is true once the answer has stopped changing.
func (a *App) askGoogleAI(w *worker, tag, prompt, question string, timeout float64, update func(r core.AIResult, done bool)) {
	last, stable := "", 0
	a.enqueue(w, &job{tag: tag, url: core.ModeAI.URL(prompt), script: core.AIScript, timeout: timeout, every: 0.7,
		handle: func(js string) bool {
			r := core.ParseAI(js, prompt)
			if r.Captcha {
				update(r, true)
				return true
			}
			if r.Text != "" && r.Text == last && !r.Busy {
				stable++
			} else {
				stable = 0
			}
			last = r.Text
			done := stable >= 3 && len(r.Text) > 0
			update(r, done)
			return done
		},
		fail: func() { update(core.AIResult{}, true) }})
}

// ---- drawing ----

func shimmer(a *App, r ui.Rect, rad float32) {
	th := a.u.Th
	a.u.Redraw = true
	k := float32(0.5 + 0.5*math.Sin(a.now()*3+float64(r.Y)*0.02))
	ui.FillRound(a.u.G, r, rad, th.Ink.Alpha(0.05+0.04*k))
}

// results draws the results page in r.
func (a *App) results(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	s := t.search
	ui.FillRound(g, r, 14, pageColor(th))
	g.Save()
	g.Clip(r)
	defer g.Restore()

	// header: the question, the sections and the original page
	hx := r.X + 28
	head := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 108}
	ui.TextFit(g, s.Q, hx, r.Y+42, ui.Font{Size: 22, Bold: true}, th.OnSurface, r.W-56-150)
	ob := ui.Rect{X: r.R() - 28 - 140, Y: r.Y + 18, W: 140, H: 34}
	if u.Button(ID("og"), ob, "On Google", ui.ButtonOpt{Icon: ui.IExternal, HasIcon: true, Tip: "Open Google's own page"}) {
		a.openOriginal(t)
		return
	}
	cx := hx
	for i, n := range secNames {
		cw := g.Measure(n, ui.FSmallBold) + 46
		cr := ui.Rect{X: cx, Y: r.Y + 62, W: cw, H: 32}
		sel := s.section == i
		if sel {
			ui.FillRound(g, cr, 16, th.SecondaryContainer)
		} else if u.Hover(cr) {
			ui.FillRound(g, cr, 16, th.Ink.Alpha(0.06))
		}
		fg := th.OnSurfaceVariant
		if sel {
			fg = th.OnSecondaryContainer
		}
		ui.DrawIcon(g, secIcons[i], cr.X+12, cr.CY()-8, 16, fg)
		g.Text(n, cr.X+34, ui.Mid(g, cr.Y, cr.H, ui.FSmallBold), ui.FSmallBold, fg)
		if u.Clickable(ui.IdN("sec", i), cr) {
			s.section, s.scroll.Y = i, 0
		}
		cx += cw + 6
	}
	g.FillRect(ui.Rect{X: r.X + 20, Y: head.B() - 1, W: r.W - 40, H: 1}, th.Divider)

	body := ui.Rect{X: r.X, Y: head.B(), W: r.W, H: r.H - head.H}
	u.Scroll(ID("results"), body, &s.scroll)
	g.Save()
	g.Clip(body)
	y := body.Y + 20 - s.scroll.Y
	x0, w := r.X+28, r.W-56
	if s.captcha && len(s.Web) == 0 && s.AI.Text == "" {
		a.resultNote(ui.Rect{X: x0, Y: y, W: w, H: 0}, "Google asked to confirm you are human. Open the search on Google once, then results show here again.", "Open on Google", func() { a.openOriginal(t) })
		g.Restore()
		return
	}
	var end float32
	switch s.section {
	case secAll:
		end = a.resultsAll(s, x0, y, w)
	case secAI:
		cw := min(w, 860)
		end = a.aiCard(s, ui.Rect{X: x0 + (w-cw)/2, Y: y, W: cw}, false)
	case secImages:
		end = a.imageGrid(s, x0, y, w, 0)
	case secVideos:
		end = a.videoGrid(s, x0, y, w, 0)
	}
	s.scroll.Content = end - (body.Y - s.scroll.Y) + 28
	g.Restore()
}

func (a *App) openOriginal(t *Tab) {
	s := t.search
	t.search = nil
	t.lastSearch = s
	a.navigate(t, s.URL+"&lite=0")
}

func (a *App) resultNote(r ui.Rect, text, action string, do func()) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	y := r.Y
	for _, ln := range wrap(g, text, ui.FBody, r.W) {
		g.Text(ln, r.X, y+16, ui.FBody, th.OnSurfaceVariant)
		y += 22
	}
	if action != "" {
		bw := g.Measure(action, ui.FBodyBold) + 40
		if u.Button(ui.Id("note/"+action), ui.Rect{X: r.X, Y: y + 8, W: bw, H: 36}, action, ui.ButtonOpt{}) {
			do()
		}
		y += 52
	}
	return y
}

func (a *App) resultsAll(s *Search, x, y, w float32) float32 {
	g, th := a.u.G, a.u.Th
	if w >= 900 {
		lw := min(720, w*0.6)
		rx, rw := x+lw+36, w-lw-36
		ly := a.aiCard(s, ui.Rect{X: x, Y: y, W: lw}, s.Mode != core.ModeAI)
		ly = a.webList(s, x, ly+18, lw)
		ry := a.sideHeader("Images", ui.IImage, rx, y, rw, secImages, s)
		ry = a.imageGrid(s, rx, ry, rw, 9)
		ry = a.sideHeader("Videos", ui.IVideo, rx, ry+18, rw, secVideos, s)
		ry = a.videoList(s, rx, ry, rw, 4)
		_ = th
		return max(ly, ry)
	}
	y = a.aiCard(s, ui.Rect{X: x, Y: y, W: w}, s.Mode != core.ModeAI)
	y = a.sideHeader("Images", ui.IImage, x, y+18, w, secImages, s)
	y = a.imageGrid(s, x, y, w, 4)
	y = a.sideHeader("Videos", ui.IVideo, x, y+18, w, secVideos, s)
	y = a.videoList(s, x, y, w, 2)
	y = a.webList(s, x, y+18, w)
	_ = g
	return y
}

func (a *App) sideHeader(title string, ic ui.Icon, x, y, w float32, sec int, s *Search) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.DrawIcon(g, ic, x, y+2, 18, th.Primary)
	g.Text(title, x+26, y+16, ui.FBodyBold, th.OnSurface)
	more := "More"
	mw := g.Measure(more, ui.FSmallBold) + 22
	mr := ui.Rect{X: x + w - mw, Y: y - 2, W: mw, H: 26}
	if u.Hover(mr) {
		ui.FillRound(g, mr, 13, th.Ink.Alpha(0.06))
	}
	g.Text(more, mr.X+8, ui.Mid(g, mr.Y, mr.H, ui.FSmallBold), ui.FSmallBold, th.Primary)
	ui.DrawIcon(g, ui.IChevron, mr.R()-14, mr.CY()-6, 12, th.Primary)
	if u.Clickable(ui.Id("more/"+title), mr) {
		s.section, s.scroll.Y = sec, 0
	}
	return y + 32
}

// aiCard draws the AI answer; short keeps it to a preview that opens the AI view.
func (a *App) aiCard(s *Search, r ui.Rect, short bool) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	pad := float32(22)
	tw := r.W - 2*pad
	size := float32(15)
	if short {
		size = 14.5
	}
	lay := layoutAnswer(g, s.AI.Blocks, tw, size)
	n := len(lay.lines)
	cut := short && n > 9
	if cut {
		n = 8
	}
	textH := float32(0)
	if n > 0 {
		textH = lay.lines[n-1].y + size*1.6
	}
	cols := max(1, min(3, int(tw/250)))
	srcH := float32(0)
	if !short && len(s.AI.Sources) > 0 && s.aiSt != stLoading {
		rows := (len(s.AI.Sources) + cols - 1) / cols
		srcH = 26 + float32(rows)*62 + 10
	}
	h := float32(66)
	switch {
	case len(s.AI.Blocks) == 0 && s.aiSt == stLoading:
		h += 4*26 + 8
	case len(s.AI.Blocks) == 0:
		h += 34
	default:
		h += textH + 12 + srcH
		if short {
			h += 44
		}
	}
	card := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: h}
	ui.Glass(g, card, 22, th, true, true)
	ui.FillRound(g, card, 22, th.Primary.Alpha(0.035))

	// header: badge, name, status, actions
	aiBadge(g, th, ui.Rect{X: card.X + pad, Y: card.Y + 18, W: 28, H: 28})
	g.Text("AI Mode", card.X+pad+38, card.Y+37, ui.FBodyBold, th.OnSurface)
	sx := card.X + pad + 38 + g.Measure("AI Mode", ui.FBodyBold) + 14
	switch {
	case s.aiSt == stLoading:
		a.writing(sx, card.Y+32)
	case len(s.AI.Sources) > 0:
		g.Text(strconv.Itoa(len(s.AI.Sources))+" sources", sx, card.Y+37, ui.FSmall, th.OnSurfaceVariant)
	}
	ax := card.R() - pad + 6
	act := func(id string, ic ui.Icon, tip string) bool {
		ax -= 34
		return u.IconButton(ui.Id(id), ui.Rect{X: ax, Y: card.Y + 15, W: 32, H: 32}, ic, tip, ui.IconOpt{})
	}
	if act("ai-open", ui.IExternal, "Continue in AI Mode") {
		a.newTab(KNormal, "", core.ModeAI.URL(s.Q)+"&lite=0", true)
	}
	if s.aiSt != stLoading && act("ai-again", ui.IReload, "Ask again") {
		a.regenAI(s)
	}
	if s.AI.Text != "" && act("ai-copy", ui.ICopy, "Copy the answer") {
		a.u.Clip.Set(s.AI.Text)
		a.notify("Answer copied.")
	}
	y := card.Y + 62
	switch {
	case len(s.AI.Blocks) == 0 && s.aiSt == stLoading:
		for i, f := range []float32{1, 0.94, 0.98, 0.62} {
			shimmer(a, ui.Rect{X: card.X + pad, Y: y + float32(i)*26 + 6, W: tw * f, H: 12}, 6)
		}
	case len(s.AI.Blocks) == 0:
		g.Text("No AI answer for this search.", card.X+pad, y+18, ui.FBody, th.OnSurfaceVariant)
	default:
		y = a.drawAnswer(lay, card.X+pad, y, s.AI.Sources, n, "aic")
		if cut {
			// the preview fades into the card
			fr := ui.Rect{X: card.X + 1, Y: y - 46, W: card.W - 2, H: 46}
			bg := ui.Mix(pageColor(th), th.Primary, 0.035)
			g.FillPathGradient(ui.NewPath().RoundRect(fr, 0), bg.Alpha(0), bg, fr.Y, fr.B())
		}
		if s.aiSt == stLoading {
			ui.FillRound(g, ui.Rect{X: card.X + pad, Y: y - 4, W: 9, H: 3}, 1.5, th.Primary.Alpha(0.5+0.5*float32(int(a.now()*2)%2)))
			a.u.Redraw = true
		}
		y += 12
		if srcH > 0 {
			a.sourceCards(s.AI.Sources, card.X+pad, y, tw, cols, "aisrc")
		}
		if short {
			by := card.B() - 46
			lbl := "Show more"
			if !cut {
				lbl = "Open AI Mode view"
			}
			br := ui.Rect{X: card.X + pad - 8, Y: by, W: g.Measure(lbl, ui.FSmallBold) + 40, H: 32}
			if u.Hover(br) {
				ui.FillRound(g, br, 16, th.Ink.Alpha(0.06))
			}
			g.Text(lbl, br.X+12, ui.Mid(g, br.Y, br.H, ui.FSmallBold), ui.FSmallBold, th.Primary)
			ui.DrawIcon(g, ui.IChevronDown, br.R()-24, br.CY()-7, 14, th.Primary)
			if u.Clickable(ui.Id("aimore"), br) {
				s.section, s.scroll.Y = secAI, 0
			}
			a.sourceStack(s.AI.Sources, br.R()+10, by+1, "aistack", func() { s.section, s.scroll.Y = secAI, 0 })
		}
	}
	if !short && s.AI.Text != "" {
		// keep the conversation going in the side panel
		fr := ui.Rect{X: card.X, Y: card.B() + 14, W: card.W, H: 48}
		ui.FillRound(g, fr, 24, pageColor(th))
		ui.StrokeRound(g, fr.Inset(0.5), 24, 1, th.Outline)
		if u.Hover(fr) {
			ui.FillRound(g, fr, 24, th.Primary.Alpha(0.05))
		}
		ui.DrawIcon(g, ui.ISparkle, fr.X+18, fr.CY()-9, 18, th.Primary)
		g.Text("Ask a follow-up", fr.X+46, ui.Mid(g, fr.Y, fr.H, ui.FBody), ui.FBody, th.Ink3)
		if u.Clickable(ui.Id("followup"), fr) {
			a.openAI("")
		}
		return fr.B()
	}
	return card.B()
}

// regenAI asks AI Mode again for the search.
func (a *App) regenAI(s *Search) {
	s.AI, s.aiSt = core.AIResult{}, stLoading
	aw := a.workerFor(s.private, true)
	a.askGoogleAI(aw, "search", s.Q, s.Q, 35, func(r core.AIResult, done bool) {
		if r.Text != "" {
			s.AI = r
		}
		if done {
			s.aiSt = stDone
			if s.AI.Text == "" {
				s.aiSt = stFailed
			}
		}
	})
}

func (a *App) webList(s *Search, x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	if s.webSt == stLoading {
		for i := 0; i < 4; i++ {
			shimmer(a, ui.Rect{X: x, Y: y, W: w * 0.4, H: 12}, 6)
			shimmer(a, ui.Rect{X: x, Y: y + 22, W: w * 0.7, H: 16}, 8)
			shimmer(a, ui.Rect{X: x, Y: y + 48, W: w * 0.95, H: 11}, 5)
			y += 92
		}
		return y
	}
	if len(s.Web) == 0 {
		return a.resultNote(ui.Rect{X: x, Y: y, W: w}, "No links came back for this search.", "Open on Google", func() { a.openOriginal(a.tab()) })
	}
	titleF := ui.Font{Size: 17, Bold: true}
	for i, r := range s.Web {
		host := strings.TrimPrefix(core.Host(r.URL), "www.")
		mr := ui.Rect{X: x, Y: y + 2, W: 28, H: 28}
		ui.FillOval(g, mr, siteColor(host))
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 12, Bold: true}, ui.White)
		site := r.Site
		if site == "" || strings.HasPrefix(site, "http") {
			site = host
		}
		ui.TextFit(g, site, x+38, y+13, ui.FSmallBold, th.OnSurface, w-40)
		ui.TextFit(g, core.Display(r.URL), x+38, y+29, ui.FSmall, th.Ink3, w-40)
		ty := y + 42
		tl := wrap(g, r.Title, titleF, w)
		if len(tl) > 2 {
			tl = tl[:2]
		}
		hitH := float32(len(tl)) * 24
		hit := ui.Rect{X: x, Y: y, W: w, H: 42 + hitH}
		hot := u.Hover(hit)
		for _, ln := range tl {
			g.Text(ln, x, ty+17, titleF, th.Primary)
			if hot {
				g.FillRect(ui.Rect{X: x, Y: ty + 20, W: g.Measure(ln, titleF), H: 1.2}, th.Primary)
			}
			ty += 24
		}
		sl := wrap(g, r.Snippet, ui.FBody, w)
		if len(sl) > 3 {
			sl = sl[:3]
			sl[2] = ui.Fit(g, sl[2]+" …", ui.FBody, w)
		}
		for _, ln := range sl {
			g.Text(ln, x, ty+16, ui.FBody, th.OnSurfaceVariant)
			ty += 21
		}
		u.Tooltip(r.URL, ui.Rect{X: x, Y: y + 42, W: w, H: hitH})
		if u.Clickable(ui.IdN("web", i), hit) {
			a.visitFromResults(r.URL)
		}
		y = ty + 22
	}
	return y
}

// imageGrid draws up to n pictures (0 = all) in columns that fill w.
func (a *App) imageGrid(s *Search, x, y, w float32, n int) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	cols := 3
	if n == 0 {
		cols = max(2, int(w/210))
	} else if w < 500 {
		cols = 4
	}
	const gap = 8
	cw := (w - float32(cols-1)*gap) / float32(cols)
	ch := cw * 0.78
	if n == 0 {
		ch = cw * 0.72
	}
	imgs := s.Images
	if n > 0 && len(imgs) > n {
		imgs = imgs[:n]
	}
	if len(imgs) == 0 {
		if s.imgSt == stLoading {
			for i := 0; i < max(n, 6) && i < 12; i++ {
				shimmer(a, ui.Rect{X: x + float32(i%cols)*(cw+gap), Y: y + float32(i/cols)*(ch+gap), W: cw, H: ch}, 12)
			}
			return y + float32((max(n, 6)+cols-1)/cols)*(ch+gap)
		}
		g.Text("No pictures for this search.", x, y+16, ui.FBody, th.OnSurfaceVariant)
		return y + 30
	}
	for i, im := range imgs {
		r := ui.Rect{X: x + float32(i%cols)*(cw+gap), Y: y + float32(i/cols)*(ch+gap), W: cw, H: ch}
		if r.B() < 0 || r.Y > a.u.H {
			continue
		}
		if img := a.thumbFor(im.Src); img != nil {
			g.Image(img, r, 12)
		} else {
			shimmer(a, r, 12)
		}
		if u.Hover(r) {
			ui.StrokeRound(g, r.Inset(1), 11, 2, th.Primary)
			if im.Alt != "" {
				cap := ui.Rect{X: r.X, Y: r.B() - 28, W: r.W, H: 28}
				g.Save()
				g.Clip(r)
				g.FillPath(ui.NewPath().RoundRect(ui.Rect{X: r.X, Y: cap.Y, W: r.W, H: 40}, 12), ui.Black.Alpha(0.55))
				g.Restore()
				ui.TextFit(g, im.Alt, cap.X+10, ui.Mid(g, cap.Y, cap.H, ui.FSmall), ui.FSmall, ui.White, cap.W-20)
			}
		}
		if u.Clickable(ui.IdN("img", i), r) {
			if im.Page != "" {
				a.visitFromResults(im.Page)
			} else if strings.HasPrefix(im.Src, "http") {
				a.visitFromResults(im.Src)
			}
		}
	}
	rows := (len(imgs) + cols - 1) / cols
	return y + float32(rows)*(ch+gap)
}

func (a *App) videoThumb(v core.VideoResult, r ui.Rect) {
	g := a.u.G
	if img := a.thumbFor(v.Thumb()); img != nil {
		g.Image(img, r, 12)
	} else {
		shimmer(a, r, 12)
	}
	if v.Length != "" {
		f := ui.Font{Size: 11, Bold: true}
		bw := g.Measure(v.Length, f) + 10
		br := ui.Rect{X: r.R() - bw - 6, Y: r.B() - 24, W: bw, H: 18}
		ui.FillRound(g, br, 5, ui.Black.Alpha(0.75))
		ui.TextCenter(g, v.Length, br, f, ui.White)
	}
}

func videoMeta(v core.VideoResult) string {
	var p []string
	for _, s := range []string{v.Channel, v.Views, v.Age} {
		if s != "" {
			p = append(p, s)
		}
	}
	return strings.Join(p, " · ")
}

// videoList is the compact list beside the links.
func (a *App) videoList(s *Search, x, y, w float32, n int) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	if len(s.Videos) == 0 {
		if s.vidSt == stLoading {
			for i := 0; i < n; i++ {
				shimmer(a, ui.Rect{X: x, Y: y + float32(i)*86, W: 136, H: 76}, 12)
				shimmer(a, ui.Rect{X: x + 148, Y: y + float32(i)*86 + 8, W: w - 160, H: 12}, 6)
			}
			return y + float32(n)*86
		}
		g.Text("No videos for this search.", x, y+16, ui.FBody, th.OnSurfaceVariant)
		return y + 30
	}
	for i, v := range s.Videos {
		if i >= n {
			break
		}
		row := ui.Rect{X: x - 6, Y: y - 4, W: w + 12, H: 84}
		if u.Hover(row) {
			ui.FillRound(g, row, 14, th.Ink.Alpha(0.05))
		}
		a.videoThumb(v, ui.Rect{X: x, Y: y, W: 136, H: 76})
		tx := x + 148
		tl := wrap(g, v.Title, ui.FBodyBold, w-150)
		if len(tl) > 2 {
			tl = tl[:2]
		}
		ty := y + 4
		for _, ln := range tl {
			g.Text(ln, tx, ty+14, ui.FBodyBold, th.OnSurface)
			ty += 20
		}
		ui.TextFit(g, videoMeta(v), tx, ty+14, ui.FSmall, th.OnSurfaceVariant, w-150)
		if u.Clickable(ui.IdN("vid", i), row) {
			a.visitFromResults(v.URL())
		}
		y += 88
	}
	return y
}

// videoGrid is the Videos section: cards in columns.
func (a *App) videoGrid(s *Search, x, y, w float32, _ int) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	cols := max(1, int(w/300))
	const gap = 18
	cw := (w - float32(cols-1)*gap) / float32(cols)
	th0 := cw * 9 / 16
	ch := th0 + 74
	if len(s.Videos) == 0 {
		if s.vidSt == stLoading {
			for i := 0; i < cols*2; i++ {
				shimmer(a, ui.Rect{X: x + float32(i%cols)*(cw+gap), Y: y + float32(i/cols)*(ch+gap), W: cw, H: th0}, 12)
			}
			return y + 2*(ch+gap)
		}
		g.Text("No videos for this search.", x, y+16, ui.FBody, th.OnSurfaceVariant)
		return y + 30
	}
	for i, v := range s.Videos {
		r := ui.Rect{X: x + float32(i%cols)*(cw+gap), Y: y + float32(i/cols)*(ch+gap), W: cw, H: ch}
		if r.B() < 0 || r.Y > a.u.H {
			continue
		}
		hot := u.Hover(r)
		tr := ui.Rect{X: r.X, Y: r.Y, W: cw, H: th0}
		a.videoThumb(v, tr)
		if hot {
			ui.StrokeRound(g, tr.Inset(1), 11, 2, th.Primary)
		}
		ty := tr.B() + 8
		tl := wrap(g, v.Title, ui.FBodyBold, cw)
		if len(tl) > 2 {
			tl = tl[:2]
		}
		for _, ln := range tl {
			g.Text(ln, r.X, ty+14, ui.FBodyBold, th.OnSurface)
			ty += 20
		}
		ui.TextFit(g, videoMeta(v), r.X, ty+14, ui.FSmall, th.OnSurfaceVariant, cw)
		if u.Clickable(ui.IdN("vidg", i), r) {
			a.visitFromResults(v.URL())
		}
	}
	rows := (len(s.Videos) + cols - 1) / cols
	return y + float32(rows)*(ch+gap)
}
