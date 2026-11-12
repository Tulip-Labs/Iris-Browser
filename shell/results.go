package shell

import (
	"context"
	"image"
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

// Search is one results page.
type Search struct {
	Q       string
	Mode    core.Mode
	URL     string
	private bool
	aiOpen  bool
	// the picture carousel and the video stack: where they are and where they go
	imgPos, imgTo   float32
	vidPos, vidTo   float32
	lastT           float64
	drag            string
	scroll2         ui.Scroll
	viewer          viewer
	dragX, dragFrom float32
	moved           bool
	scroll          ui.Scroll

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

// startSearch reads Google and YouTube for q in the background.
func (a *App) startSearch(q string, m core.Mode, url string, private bool) *Search {
	s := &Search{Q: q, Mode: m, URL: url, private: private}
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
//
// To be dependable it finishes as soon as Google marks the answer complete (or
// the text stops changing), keeps a partial answer when time runs out, and
// tries once more on a fresh page when nothing came back.
func (a *App) askGoogleAI(w *worker, tag, prompt, question string, timeout float64, update func(r core.AIResult, done bool)) {
	a.askGoogleAITry(w, tag, prompt, timeout, update, 0)
}

func (a *App) askGoogleAITry(w *worker, tag, prompt string, timeout float64, update func(r core.AIResult, done bool), attempt int) {
	last, stable := "", 0
	var best core.AIResult
	a.enqueue(w, &job{tag: tag, url: core.ModeAI.URL(prompt), script: core.AIScript, timeout: timeout, every: 0.6,
		handle: func(js string) bool {
			r := core.ParseAI(js, prompt)
			if r.Captcha {
				update(r, true)
				return true
			}
			if len(r.Text) >= len(best.Text) || len(r.Sources) > len(best.Sources) {
				best = r
			}
			if r.Text != "" && r.Text == last && !r.Busy {
				stable++
			} else {
				stable = 0
			}
			last = r.Text
			need := 3
			if len(r.Text) > 400 {
				need = 2
			}
			done := r.Text != "" && (r.Done && !r.Busy && stable >= 1 || stable >= need)
			update(r, done)
			return done
		},
		fail: func() {
			switch {
			case best.Text != "":
				update(best, true) // keep what was written
			case attempt == 0:
				a.askGoogleAITry(w, tag, prompt, timeout, update, 1)
			default:
				update(core.AIResult{}, true)
			}
		}})
}

// warmAI opens the AI page early (while the user types), so the first answer
// does not wait for Google's page to start.
func (a *App) warmAI(private bool) {
	w := a.workerFor(private, true)
	if w.view != nil || w.making || w.cur != nil || len(w.queue) > 0 || a.eng == nil || !a.ready {
		return
	}
	a.enqueue(w, &job{tag: "warm", url: "https://www.google.com/?hl=en&gl=us", script: "1", timeout: 8, every: 0.5,
		handle: func(string) bool { return true }})
}

// ---- drawing ----

func shimmer(a *App, r ui.Rect, rad float32) {
	th := a.u.Th
	a.u.Redraw = true
	k := float32(0.5 + 0.5*math.Sin(a.now()*3+float64(r.Y)*0.02))
	ui.FillRound(a.u.G, r, rad, th.Ink.Alpha(0.05+0.04*k))
}

// results draws the results page in r. On a wide window it has two columns:
// at the left the pictures, the videos and the AI answer; at the right the
// websites, or whatever picture or video you opened, shown in place. On a
// narrow window they stack, and an opened picture or video takes the page.
func (a *App) results(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	s := t.search
	now := a.now()
	dt := float32(min(0.1, max(0, now-s.lastT)))
	s.lastT = now
	if a.sideFull {
		a.sideRect = r // a video in full screen
		return
	}
	if s.viewer.kind != vVideo && a.sideURL != "" && !a.sideFull {
		a.sideURL = ""
	}
	ui.FillRound(g, r, 14, pageColor(th))
	g.Save()
	g.Clip(r)
	defer g.Restore()

	ranked := core.Rank(s.Web, s.Q, a.set.SiteRanks)
	wide := r.W >= 1060
	pad := float32(28)

	// header: the question, what Lite Go did, and the original
	head := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: 86}
	hx := r.X + pad
	ui.TextFit(g, s.Q, hx, r.Y+44, ui.Font{Size: 24, Bold: true}, th.OnSurface, r.W-2*pad-160)
	info := "Ads and promotions removed"
	if len(ranked) > 0 {
		info += " · " + strconv.Itoa(len(ranked)) + " websites ranked by source quality"
	}
	ui.DrawIcon(g, ui.IShield, hx, r.Y+56, 14, th.Primary)
	ui.TextFit(g, info, hx+20, r.Y+68, ui.FSmall, th.OnSurfaceVariant, r.W-2*pad-180)
	ob := ui.Rect{X: r.R() - pad - 132, Y: r.Y + 22, W: 132, H: 34}
	if u.Button(ID("og"), ob, "On Google", ui.ButtonOpt{Icon: ui.IExternal, HasIcon: true, Tip: "Open Google's own page"}) {
		a.openOriginal(t)
		return
	}
	g.FillRect(ui.Rect{X: r.X + 20, Y: head.B() - 1, W: r.W - 40, H: 1}, th.Divider)
	body := ui.Rect{X: r.X, Y: head.B(), W: r.W, H: r.H - head.H}

	if s.captcha && len(s.Web) == 0 && s.AI.Text == "" {
		y := body.Y + 22
		y = a.resultNote(ui.Rect{X: hx, Y: y, W: min(640, r.W-2*pad)}, "Google asked to confirm you are human. Signing in to Google once stops this; or open the search on Google.", "Sign in to Google", func() { a.signIn(t) })
		a.resultNote(ui.Rect{X: hx, Y: y, W: 400}, "", "Open on Google", func() { a.openOriginal(t) })
		return
	}

	if !wide {
		if s.viewer.kind != vNone {
			a.drawViewer(s, t, body.Inset(0), true)
			return
		}
		u.Scroll(ID("results"), body, &s.scroll)
		g.Save()
		g.Clip(body)
		y := body.Y + 22 - s.scroll.Y
		x, w := r.X+pad, r.W-2*pad
		y = a.mediaAndAnswer(s, x, y, w, dt)
		y = sectionTitle(a, ui.IGlobe, "Websites", "", x, y, nil) + 6
		y = a.websites(s, t, ranked, x, y, w)
		s.scroll.Content = y - (body.Y - s.scroll.Y)
		g.Restore()
		return
	}

	// two columns, each scrolling on its own
	gap := float32(32)
	rw := min(560, max(400, (r.W-2*pad-gap)*0.42))
	lw := r.W - 2*pad - gap - rw
	left := ui.Rect{X: r.X, Y: body.Y, W: pad + lw + gap/2, H: body.H}
	right := ui.Rect{X: left.R(), Y: body.Y, W: r.R() - left.R(), H: body.H}
	g.FillRect(ui.Rect{X: right.X, Y: body.Y + 16, W: 1, H: body.H - 32}, th.Divider)

	u.Scroll(ID("results"), left, &s.scroll)
	g.Save()
	g.Clip(left)
	y := a.mediaAndAnswer(s, r.X+pad, body.Y+22-s.scroll.Y, lw, dt)
	s.scroll.Content = y + 30 - (body.Y - s.scroll.Y)
	g.Restore()

	col := ui.Rect{X: right.X + gap/2, Y: body.Y, W: rw, H: body.H}
	if s.viewer.kind != vNone {
		a.drawViewer(s, t, col, false)
		return
	}
	u.Scroll(ID("sites"), right, &s.scroll2)
	g.Save()
	g.Clip(right)
	y = body.Y + 22 - s.scroll2.Y
	y = sectionTitle(a, ui.IGlobe, "Websites", "", col.X, y, nil) + 6
	y = a.websites(s, t, ranked, col.X, y, col.W)
	s.scroll2.Content = y - (body.Y - s.scroll2.Y)
	g.Restore()
}

// mediaAndAnswer is the left column: pictures, videos, then the AI answer.
func (a *App) mediaAndAnswer(s *Search, x, y, w, dt float32) float32 {
	if len(s.Images) > 0 || s.imgSt == stLoading {
		y = a.imageCarousel(s, x, y, w, dt) + 28
	}
	if len(s.Videos) > 0 || s.vidSt == stLoading {
		y = a.videoStack(s, x, y, w, dt) + 24
	}
	return a.aiCard(s, ui.Rect{X: x, Y: y, W: w})
}

// websites lists the ranked links and the way to more.
func (a *App) websites(s *Search, t *Tab, ranked []core.Ranked, x, y, w float32) float32 {
	u := &a.u
	switch {
	case s.webSt == stLoading && len(ranked) == 0:
		y = a.webSkeleton(x, y, w)
	case len(ranked) == 0:
		y = a.resultNote(ui.Rect{X: x, Y: y, W: w}, "No websites came back for this search.", "Open on Google", func() { a.openOriginal(t) })
	default:
		y = a.webItems(s, ranked, 0, x, y, w)
	}
	mr := ui.Rect{X: x, Y: y + 6, W: 220, H: 40}
	if u.Button(ID("moreog"), mr, "More results on Google", ui.ButtonOpt{Icon: ui.IExternal, HasIcon: true}) {
		a.openOriginal(t)
	}
	return mr.B() + 30
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

func sectionTitle(a *App, ic ui.Icon, title, note string, x, y float32, more func(), wOpt ...float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.DrawIcon(g, ic, x, y+1, 18, th.Primary)
	g.Text(title, x+26, y+15, ui.FTitle, th.OnSurface)
	if note != "" {
		g.Text(note, x+34+g.Measure(title, ui.FTitle), y+15, ui.FSmall, th.OnSurfaceVariant)
	}
	if more != nil && len(wOpt) > 0 {
		lbl := "More"
		mw := g.Measure(lbl, ui.FSmallBold) + 34
		mr := ui.Rect{X: x + wOpt[0] - mw, Y: y - 4, W: mw, H: 28}
		if u.Hover(mr) {
			ui.FillRound(g, mr, 14, th.Ink.Alpha(0.06))
		}
		g.Text(lbl, mr.X+10, ui.Mid(g, mr.Y, mr.H, ui.FSmallBold), ui.FSmallBold, th.Primary)
		ui.DrawIcon(g, ui.IChevron, mr.R()-20, mr.CY()-6, 12, th.Primary)
		u.Tooltip("See them all at the side", mr)
		if u.Clickable(ui.Id("more/"+title), mr) {
			more()
		}
	}
	return y + 34
}

func labelColor(th *ui.Theme, label string) ui.Color {
	switch label {
	case "Reference", "Academic":
		return tone(th, "blue")
	case "Docs":
		return tone(th, "turquoise")
	case "Research":
		return tone(th, "purple")
	case "Official":
		return tone(th, "green")
	case "Discussion":
		return tone(th, "orange")
	case "News":
		return tone(th, "red")
	case "Shop":
		return tone(th, "yellow")
	}
	return th.Primary
}

// webItems draws ranked links; start numbers them for ids.
func (a *App) webItems(s *Search, rs []core.Ranked, start int, x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	titleF := ui.Font{Size: 17.5, Bold: true}
	for k, r := range rs {
		i := start + k
		host := strings.TrimPrefix(core.Host(r.URL), "www.")
		row := ui.Rect{X: x - 14, Y: y - 10, W: w + 28, H: 0}
		tl := wrap(g, r.Title, titleF, w)
		if len(tl) > 2 {
			tl = tl[:2]
		}
		sl := wrap(g, r.Snippet, ui.FBody, w)
		if len(sl) > 2 {
			sl = sl[:2]
			sl[1] = ui.Fit(g, sl[1]+" …", ui.FBody, w)
		}
		row.H = 34 + float32(len(tl))*25 + float32(len(sl))*22 + 16
		hot := u.Hover(row)
		if hot {
			ui.FillRound(g, row, 16, th.Ink.Alpha(0.035))
		}
		// site line: mark, name, path, kind
		mr := ui.Rect{X: x, Y: y, W: 22, H: 22}
		ui.FillRoundAccent(g, mr, 7, siteColor(host))
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 11, Bold: true}, ui.White)
		site := r.Site
		if site == "" || strings.HasPrefix(site, "http") || len(site) > 40 {
			site = host
		}
		sx := x + 30
		g.Text(site, sx, y+15, ui.FSmallBold, th.OnSurface)
		sx += g.Measure(site, ui.FSmallBold) + 8
		if r.Label != "" {
			lc := labelColor(th, r.Label)
			lw := g.Measure(r.Label, ui.Font{Size: 10.5, Bold: true}) + 14
			lr := ui.Rect{X: sx, Y: y + 2, W: lw, H: 18}
			ui.FillRound(g, lr, 9, lc.Alpha(0.14))
			ui.TextCenter(g, r.Label, lr, ui.Font{Size: 10.5, Bold: true}, ui.Mix(lc, th.Ink, 0.25))
			sx += lw + 8
		}
		path := strings.TrimPrefix(core.Display(r.URL), strings.TrimPrefix(core.Host(r.URL), "www."))
		ui.TextFit(g, path, sx, y+15, ui.FSmall, th.Ink3, x+w-sx-100)
		ty := y + 30
		for _, ln := range tl {
			g.Text(ln, x, ty+18, titleF, th.Primary)
			if hot {
				g.FillRect(ui.Rect{X: x, Y: ty + 21, W: g.Measure(ln, titleF), H: 1.3}, th.Primary.Alpha(0.6))
			}
			ty += 25
		}
		for _, ln := range sl {
			g.Text(ln, x, ty+17, ui.FBody, th.OnSurfaceVariant)
			ty += 22
		}
		// the reader's own say about the site: raise, lower, hide
		acted := false
		if hot {
			bx := x + w - 96
			key := core.SiteKey(r.URL)
			cur := a.set.SiteRanks[key]
			for j, b := range []struct {
				ic   ui.Icon
				tip  string
				rank int
			}{{ui.IStar, "Raise " + key, 1}, {ui.IChevronDown, "Lower " + key, -1}, {ui.IClose, "Hide " + key, -2}} {
				br := ui.Rect{X: bx + float32(j)*32, Y: y - 6, W: 30, H: 30}
				if u.IconButton(ui.IdN("rank"+strconv.Itoa(j), i), br, b.ic, b.tip, ui.IconOpt{Toggled: cur == b.rank}) {
					acted = true
					if a.set.SiteRanks == nil {
						a.set.SiteRanks = map[string]int{}
					}
					if cur == b.rank {
						delete(a.set.SiteRanks, key)
					} else {
						a.set.SiteRanks[key] = b.rank
						if b.rank == -2 {
							a.bar = infobar{text: key + " is hidden from your results.", action: "Undo",
								do: func() { delete(a.set.SiteRanks, key); a.set.Save() }, until: a.now() + 8}
						}
					}
					a.set.Save()
				}
			}
		}
		u.Tooltip(r.URL, ui.Rect{X: x, Y: y + 30, W: w, H: float32(len(tl)) * 25})
		if u.Clickable(ui.IdN("web", i), row) && !acted {
			a.visitFromResults(r.URL)
		}
		y = row.B() + 18
	}
	return y
}

func (a *App) webSkeleton(x, y, w float32) float32 {
	for i := 0; i < 4; i++ {
		shimmer(a, ui.Rect{X: x, Y: y, W: w * 0.35, H: 12}, 6)
		shimmer(a, ui.Rect{X: x, Y: y + 26, W: w * 0.7, H: 17}, 8)
		shimmer(a, ui.Rect{X: x, Y: y + 54, W: w * 0.95, H: 11}, 5)
		y += 100
	}
	return y
}

// ease moves pos toward to at a calm speed; true while still moving.
func ease(pos *float32, to, dt float32) bool {
	d := to - *pos
	if absf(d) < 0.002 {
		*pos = to
		return false
	}
	*pos += d * min(1, dt*11)
	return true
}

// dragOn tracks a horizontal drag that starts inside r; it returns the pointer
// movement since the press while it lasts.
func (a *App) dragOn(s *Search, id string, r ui.Rect, from float32) (dx float32, active bool) {
	in := a.In
	if in.Pressed && r.Contains(in.MX, in.MY) && a.u.Live() {
		s.drag, s.dragX, s.dragFrom, s.moved = id, in.MX, from, false
	}
	if s.drag != id {
		return 0, false
	}
	if !in.Down {
		s.drag = ""
		return in.MX - s.dragX, false
	}
	dx = in.MX - s.dragX
	if absf(dx) > 6 {
		s.moved = true
	}
	return dx, true
}

// tapped reports a click on r that was not the end of a drag.
func (a *App) tapped(s *Search, r ui.Rect) bool {
	in := a.In
	return in.Released && !s.moved && r.Contains(in.MX, in.MY) && r.Contains(in.PressX, in.PressY) && a.u.Live()
}

func roundBtn(a *App, r ui.Rect, ic ui.Icon, tip string) bool {
	u, g, th := &a.u, a.u.G, a.u.Th
	hot := u.Hover(r)
	ui.Shadow(g, r, r.W/2, th.Shadow, 0.7, 2)
	ui.FillOval(g, r, pageColor(th))
	if hot {
		ui.FillOval(g, r, th.Primary.Alpha(0.1))
	}
	ui.StrokeOval(g, r.Inset(0.5), 1, th.OutlineVariant)
	ui.DrawIcon(g, ic, r.CX()-9, r.CY()-9, 18, th.OnSurface)
	u.Tooltip(tip, r)
	return u.Clickable(ui.Id("rb/"+tip), r)
}

// imageCarousel shows the pictures in a row you can drag, scroll sideways or step through.
func (a *App) imageCarousel(s *Search, x, y, w, dt float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	y = sectionTitle(a, ui.IImage, "Images", imageNote(s), x, y, func() { s.viewer = viewer{kind: vImages} }, w)
	const h, gap = 190, 12
	view := ui.Rect{X: x, Y: y, W: w, H: h}
	if len(s.Images) == 0 {
		if s.imgSt == stLoading {
			for i, f := range []float32{1.4, 1, 1.3, 0.8, 1.5} {
				_ = i
				tw := h * f
				if x+tw > view.R() {
					break
				}
				shimmer(a, ui.Rect{X: x, Y: y, W: tw, H: h}, 18)
				x += tw + gap
			}
			return y + h
		}
		g.Text("No pictures for this search.", x, y+16, ui.FBody, th.OnSurfaceVariant)
		return y + 30
	}
	// widths follow each picture's own shape
	widths := make([]float32, len(s.Images))
	total := float32(0)
	for i, im := range s.Images {
		ar := float32(1.35)
		if t := a.thumbs[im.Src]; t != nil && t.img != nil {
			b := t.img.Bounds()
			ar = min(1.9, max(0.62, float32(b.Dx())/float32(max(1, b.Dy()))))
		}
		widths[i] = h * ar
		total += widths[i] + gap
	}
	total -= gap
	maxOff := max(0, total-w)
	// input: drag, sideways wheel, arrows
	if dx, active := a.dragOn(s, "img", view, s.imgTo); active {
		s.imgTo = s.imgFrom(dx)
		s.imgPos = s.imgTo
	}
	if u.Hover(view) && u.In.WheelX != 0 {
		s.imgTo -= u.In.WheelX * 90
		u.In.WheelX = 0
	}
	s.imgTo = min(maxOff, max(0, s.imgTo))
	if ease(&s.imgPos, s.imgTo, dt) {
		u.Redraw = true
	}
	g.Save()
	g.Clip(ui.Rect{X: view.X - 6, Y: view.Y - 6, W: view.W + 12, H: view.H + 12}) // room for the lift on hover
	tx := x - s.imgPos
	for i, im := range s.Images {
		tr := ui.Rect{X: tx, Y: y, W: widths[i], H: h}
		tx += widths[i] + gap
		if tr.R() < view.X-40 || tr.X > view.R()+40 {
			continue
		}
		hot := u.Hover(tr) && view.Contains(u.In.MX, u.In.MY)
		if hot {
			tr = ui.RectAround(tr.CX(), tr.CY(), tr.W*1.03, tr.H*1.03)
			ui.Shadow(g, tr, 18, th.Shadow, 1, 4)
		}
		if img := a.thumbFor(im.Src); img != nil {
			g.Image(img, tr, 18)
		} else {
			shimmer(a, tr, 18)
		}
		if hot {
			host := strings.TrimPrefix(core.Host(im.Page), "www.")
			cap := im.Alt
			if cap == "" {
				cap = host
			}
			cr := ui.Rect{X: tr.X, Y: tr.B() - 44, W: tr.W, H: 44}
			g.Save()
			g.Clip(tr)
			g.FillPathGradient(ui.NewPath().RoundRect(ui.Rect{X: tr.X, Y: cr.Y - 16, W: tr.W, H: 76}, 18), ui.Black.Alpha(0), ui.Black.Alpha(0.7), cr.Y-16, tr.B())
			g.Restore()
			ui.TextFit(g, cap, cr.X+12, cr.Y+20, ui.FSmallBold, ui.White, cr.W-24)
			if host != "" && host != cap {
				ui.TextFit(g, host, cr.X+12, cr.Y+36, ui.FSmall, ui.White.Alpha(0.8), cr.W-24)
			}
		}
		if a.tapped(s, tr) {
			s.viewer = viewer{kind: vImage, idx: i}
		}
	}
	g.Restore()
	if u.Hover(view) {
		if s.imgPos > 1 && roundBtn(a, ui.RectAround(x+24, y+h/2, 40, 40), ui.IChevronLeft, "Previous pictures") {
			s.imgTo -= w * 0.8
		}
		if s.imgPos < maxOff-1 && roundBtn(a, ui.RectAround(view.R()-24, y+h/2, 40, 40), ui.IChevron, "More pictures") {
			s.imgTo += w * 0.8
		}
	}
	return y + h
}

func (s *Search) imgFrom(dx float32) float32 { return s.dragFrom - dx }

func imageNote(s *Search) string {
	if len(s.Images) == 0 {
		return ""
	}
	return strconv.Itoa(len(s.Images)) + " pictures · click one to see it at the side"
}

func (a *App) videoThumb(v core.VideoResult, r ui.Rect, rad float32) {
	g := a.u.G
	var img image.Image
	if r.W > 300 {
		img = a.bigVideoThumb(v, r.W)
	} else {
		img = a.thumbFor(v.Thumb())
	}
	if img != nil {
		g.Image(img, r, rad)
	} else {
		shimmer(a, r, rad)
	}
	if v.Length != "" {
		f := ui.Font{Size: 11.5, Bold: true}
		bw := g.Measure(v.Length, f) + 12
		br := ui.Rect{X: r.R() - bw - 10, Y: r.B() - 30, W: bw, H: 20}
		ui.FillRound(g, br, 6, ui.Black.Alpha(0.75))
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

// videoStack shows the videos as a stack of big cards: the front one plays on
// click, the next ones peek out behind it; drag, scroll sideways or use the
// arrows to move through them.
func (a *App) videoStack(s *Search, x, y, w, dt float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	note := ""
	if n := len(s.Videos); n > 0 {
		note = strconv.Itoa(int(s.vidTo)+1) + " of " + strconv.Itoa(n)
	}
	y = sectionTitle(a, ui.IVideo, "Videos", note, x, y, func() { s.viewer = viewer{kind: vVideos} }, w)
	cw := min(w*0.72, 600)
	thH := cw * 9 / 16
	ch := thH + 76
	area := ui.Rect{X: x, Y: y, W: w, H: ch + 24}
	if len(s.Videos) == 0 {
		if s.vidSt == stLoading {
			shimmer(a, ui.Rect{X: x, Y: y, W: cw, H: thH}, 22)
			return y + ch
		}
		g.Text("No videos for this search.", x, y+16, ui.FBody, th.OnSurfaceVariant)
		return y + 30
	}
	n := len(s.Videos)
	if dx, active := a.dragOn(s, "vid", area, s.vidTo); !active && dx != 0 && s.moved {
		if dx < -50 {
			s.vidTo++
		} else if dx > 50 {
			s.vidTo--
		}
	} else if active {
		s.vidPos = s.vidTo - max(-0.6, min(0.6, dx/cw))
	}
	if u.Hover(area) && u.In.WheelX != 0 {
		s.vidTo -= u.In.WheelX / 1.5
		u.In.WheelX = 0
	}
	s.vidTo = float32(math.Round(float64(min(float32(n-1), max(0, s.vidTo)))))
	if s.drag != "vid" && ease(&s.vidPos, s.vidTo, dt) {
		u.Redraw = true
	}
	// back to front: cards further in the stack are smaller, lower and shaded
	front := int(math.Floor(float64(s.vidPos)))
	for k := min(n-1, front+3); k >= max(0, front-1); k-- {
		d := float32(k) - s.vidPos
		var r ui.Rect
		shade := float32(0)
		if d >= 0 {
			sc := 1 - d*0.07
			r = ui.Rect{X: x + d*(46+cw*0.04), Y: y + d*10, W: cw * sc, H: thH * sc}
			r.Y += (thH - r.H) / 2
			shade = min(0.5, d*0.16)
		} else {
			r = ui.Rect{X: x + d*cw*1.1, Y: y, W: cw, H: thH} // leaving to the left
		}
		if r.R() < area.X-20 {
			continue
		}
		v := s.Videos[k]
		ui.Shadow(g, r, 22, th.Shadow, 1.2, 6)
		a.videoThumb(v, r, 22)
		if shade > 0 {
			ui.FillRound(g, r, 22, pageColor(th).Alpha(shade))
		}
		isFront := absf(d) < 0.5
		if isFront {
			pr := ui.RectAround(r.CX(), r.CY(), 64, 64)
			hot := u.Hover(r)
			ui.FillOval(g, pr, ui.Black.Alpha(map[bool]float32{true: 0.7, false: 0.5}[hot]))
			ui.DrawIcon(g, ui.IPlay, pr.CX()-12, pr.CY()-14, 28, ui.White)
			// the title and channel under the front card
			ty := r.B() + 14
			tw := cw - 130 // room for the controls at the right
			tl := wrap(g, v.Title, ui.Font{Size: 16, Bold: true}, tw)
			if len(tl) > 1 {
				tl = tl[:1]
				tl[0] = ui.Fit(g, v.Title, ui.Font{Size: 16, Bold: true}, tw)
			}
			for _, ln := range tl {
				g.Text(ln, r.X, ty+16, ui.Font{Size: 16, Bold: true}, th.OnSurface)
				ty += 24
			}
			ui.DrawIcon(g, ui.IYouTube, r.X, ty+3, 16, ui.Hex("#e62117"))
			ui.TextFit(g, videoMeta(v), r.X+22, ty+16, ui.FSmall, th.OnSurfaceVariant, tw-24)
			if a.tapped(s, r) {
				s.viewer = viewer{kind: vVideo, idx: k}
			}
		} else if a.tapped(s, r) {
			s.vidTo = float32(k)
		}
	}
	// controls under the front card, at its right: arrows and where you are
	cx := x + cw - 98
	cy := y + thH + 34
	if roundBtn(a, ui.RectAround(cx+22, cy, 40, 40), ui.IChevronLeft, "Previous video") {
		s.vidTo--
	}
	if roundBtn(a, ui.RectAround(cx+72, cy, 40, 40), ui.IChevron, "Next video") {
		s.vidTo++
	}
	dn := min(n, 10)
	dx0 := cx + 47 - (float32(dn)*11-4)/2
	for i := 0; i < dn; i++ {
		c := th.OutlineVariant
		r := ui.RectAround(dx0+float32(i)*11+3, cy+30, 6, 6)
		if i == int(s.vidTo) || i == dn-1 && int(s.vidTo) >= dn {
			c = th.Primary
		}
		ui.FillOval(g, r, c)
	}
	return y + ch + 10
}

// aiCard draws the AI answer: a preview that opens in place, its sources, and
// where it came from.
func (a *App) aiCard(s *Search, r ui.Rect) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	short := !s.aiOpen
	pad := float32(22)
	tw := r.W - 2*pad
	size := float32(15)
	if short {
		size = 14.5
	}
	lay := layoutAnswer(g, s.AI.Blocks, tw, size)
	n := len(lay.lines)
	long := n > 10 || len(s.AI.Sources) > 0
	cut := short && n > 10
	if cut {
		n = 9
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
		h += textH + 12 + srcH + 48
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
		// footer: open or close the full answer, and where it came from
		by := card.B() - 46
		fx := card.X + pad - 8
		if long {
			lbl := "Show more"
			if !short {
				lbl = "Show less"
			}
			br := ui.Rect{X: fx, Y: by, W: g.Measure(lbl, ui.FSmallBold) + 40, H: 32}
			if u.Hover(br) {
				ui.FillRound(g, br, 16, th.Ink.Alpha(0.06))
			}
			g.Text(lbl, br.X+12, ui.Mid(g, br.Y, br.H, ui.FSmallBold), ui.FSmallBold, th.Primary)
			ic := ui.IChevronDown
			if !short {
				ic = ui.IChevron
			}
			ui.DrawIcon(g, ic, br.R()-24, br.CY()-7, 14, th.Primary)
			if u.Clickable(ui.Id("aimore"), br) {
				s.aiOpen = !s.aiOpen
			}
			fx = br.R() + 10
			if short {
				fx = a.sourceStack(s.AI.Sources, fx, by+1, "aistack", func() { s.aiOpen = true }) + 10
			}
		}
		lbl := "Answer by Google AI Mode"
		lw := g.Measure(lbl, ui.FSmall) + 30
		lr := ui.Rect{X: card.R() - pad - lw + 8, Y: by, W: lw, H: 32}
		if lr.X > fx {
			hot := u.Hover(lr)
			col := th.OnSurfaceVariant
			if hot {
				col = th.Primary
			}
			g.Text(lbl, lr.X+4, ui.Mid(g, lr.Y, lr.H, ui.FSmall), ui.FSmall, col)
			ui.DrawIcon(g, ui.IExternal, lr.R()-20, lr.CY()-7, 14, col)
			u.Tooltip("Open this answer on Google AI Mode", lr)
			if u.Clickable(ui.Id("aisource"), lr) {
				a.newTab(KNormal, "", core.ModeAI.URL(s.Q)+"&lite=0", true)
			}
		}
	}
	if s.AI.Text != "" {
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
