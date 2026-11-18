package shell

import (
	"context"
	"image"
	"math"
	"strconv"
	"strings"
	"time"

	"iris/core"
	"iris/ui"
)

// Iris results: a Google search shown on Iris's own page, in the palette of
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
	// the goggle the links are ranked with ("" = all), and the pages read so far
	goggle  string
	page    int
	moreSt  loadState
	moreEnd bool
}

// startSearch reads Google and YouTube for q in the background.
func (a *App) startSearch(q string, m core.Mode, url string, private bool) *Search {
	s := &Search{Q: q, Mode: m, URL: url, private: private, moreSt: stDone}
	w := a.workerFor(private, false)
	w.cancel(func(j *job) bool { return true }) // a new search replaces waiting ones
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

// ---- drawing ----

func shimmer(a *App, r ui.Rect, rad float32) {
	th := a.u.Th
	a.u.Redraw = true
	k := float32(0.5 + 0.5*math.Sin(a.now()*3+float64(r.Y)*0.02))
	ui.FillRound(a.u.G, r, rad, th.Ink.Alpha(0.05+0.04*k))
}

// results draws the results page in r, minimal like Kagi: the question and
// the goggles that re-rank it, then on a wide window two columns: at the left
// the AI answer and the websites (more load as you read on); at the right the
// pictures and the videos as stacks of cards, or whatever you opened, shown
// in place. On a narrow window they follow one another.
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
	fillPage(g, r, 14, th)
	g.Save()
	g.Clip(r)
	defer g.Restore()

	ranked := core.Rank(s.Web, s.Q, a.set.SiteRanks)
	pad := float32(28)
	if r.W < 700 {
		pad = 14
	}
	wide := r.W >= 1000

	// header: the question, a quiet count, and Google's own page
	hx := r.X + pad
	y := r.Y + 18
	ob := ui.Rect{X: r.R() - pad - 118, Y: y + 6, W: 118, H: 32}
	ui.Glass(g, ob, 16, th, u.Hover(ob), false)
	g.Text("On Google", ob.X+14, ui.Mid(g, ob.Y, ob.H, ui.FSmallBold), ui.FSmallBold, th.OnSurfaceVariant)
	ui.DrawIcon(g, ui.IExternal, ob.R()-26, ob.CY()-7, 14, th.OnSurfaceVariant)
	u.Tooltip("Open Google's own page", ob)
	if u.Clickable(ID("og"), ob) {
		a.openOriginal(t)
		return
	}
	// Google's AI Mode, only when asked for: a tab of its own
	ab := ui.Rect{X: ob.X - 8 - 104, Y: ob.Y, W: 104, H: 32}
	ui.Glass(g, ab, 16, th, u.Hover(ab), false)
	g.Text("AI Mode", ab.X+14, ui.Mid(g, ab.Y, ab.H, ui.FSmallBold), ui.FSmallBold, th.OnSurfaceVariant)
	ui.DrawIcon(g, ui.IExternal, ab.R()-26, ab.CY()-7, 14, th.OnSurfaceVariant)
	u.Tooltip("Ask Google AI Mode in a new tab", ab)
	if u.Clickable(ID("aimode"), ab) {
		a.newTab(KNormal, "", core.ModeAI.URL(s.Q)+"&lite=0", true)
		return
	}
	ui.TextFit(g, s.Q, hx, y+30, ui.Font{Size: 26, Bold: true}, th.OnSurface, ab.X-hx-12)
	y += 46
	info := "Ads removed"
	if len(ranked) > 0 {
		info = strconv.Itoa(len(ranked)) + " websites  ·  ads removed"
	}
	g.Text(info, hx, y+14, ui.FSmall, th.Ink3)
	y += 30
	g.FillRect(ui.Rect{X: r.X + pad, Y: y, W: r.W - 2*pad, H: 1}, th.Divider)
	body := ui.Rect{X: r.X, Y: y + 1, W: r.W, H: r.B() - y - 1}

	if s.captcha && len(s.Web) == 0 {
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
		a.u.PushHit(body)
		y := body.Y + 20 - s.scroll.Y
		x, w := r.X+pad, r.W-2*pad
		y = a.media(s, x, y, w, dt)
		y = sectionTitle(a, ui.IGlobe, "Websites", "", x, y, nil) + 4
		y = a.websites(s, t, ranked, x, y, w, body.B())
		s.scroll.Content = y - (body.Y - s.scroll.Y)
		a.u.PopHit()
		g.Restore()
		return
	}

	// two columns, each scrolling on its own
	gap := float32(32)
	rw := min(520, max(360, (r.W-2*pad-gap)*0.38))
	lw := r.W - 2*pad - gap - rw
	left := ui.Rect{X: r.X, Y: body.Y, W: pad + lw + gap/2, H: body.H}
	right := ui.Rect{X: left.R(), Y: body.Y, W: r.R() - left.R(), H: body.H}

	u.Scroll(ID("results"), left, &s.scroll)
	g.Save()
	g.Clip(left)
	a.u.PushHit(left)
	y = body.Y + 20 - s.scroll.Y
	y = sectionTitle(a, ui.IGlobe, "Websites", "", r.X+pad, y, nil) + 4
	y = a.websites(s, t, ranked, r.X+pad, y, lw, left.B())
	s.scroll.Content = y + 30 - (body.Y - s.scroll.Y)
	a.u.PopHit()
	g.Restore()

	col := ui.Rect{X: right.X + gap/2, Y: body.Y, W: rw, H: body.H}
	if s.viewer.kind != vNone {
		a.drawViewer(s, t, col, false)
		return
	}
	u.Scroll(ID("sites"), right, &s.scroll2)
	g.Save()
	g.Clip(right)
	a.u.PushHit(right)
	y = body.Y + 20 - s.scroll2.Y
	y = a.media(s, col.X, y, col.W, dt)
	s.scroll2.Content = y - (body.Y - s.scroll2.Y)
	a.u.PopHit()
	g.Restore()
}

// media is the pictures and the videos, each a stack of cards.
func (a *App) media(s *Search, x, y, w, dt float32) float32 {
	if len(s.Images) > 0 || s.imgSt == stLoading {
		y = a.imageStack(s, x, y, w, dt) + 26
	}
	if len(s.Videos) > 0 || s.vidSt == stLoading {
		y = a.videoStack(s, x, y, w, dt) + 24
	}
	return y
}

// websites draws the ranked links as cards; more load as the reader nears
// the end, for as long as Google has relevant ones (bottom is where the
// column ends on screen).
func (a *App) websites(s *Search, t *Tab, ranked []core.Ranked, x, y, w, bottom float32) float32 {
	switch {
	case s.webSt == stLoading && len(ranked) == 0:
		return a.webSkeleton(x, y, w)
	case len(ranked) == 0:
		return a.resultNote(ui.Rect{X: x, Y: y, W: w}, "No websites came back for this search.", "Open on Google", func() { a.openOriginal(t) })
	}
	y = a.webItems(s, ranked, 0, x, y, w)
	switch {
	case s.moreSt == stLoading:
		y = a.webSkeleton(x, y, w)
	case !s.moreEnd && s.webSt == stDone && y < bottom+500:
		a.moreResults(s)
	case s.moreEnd:
		g, th := a.u.G, a.u.Th
		ui.TextCenter(g, "That is everything relevant Google has for this search.", ui.Rect{X: x, Y: y, W: w, H: 30}, ui.FSmall, th.Ink3)
		y += 40
	}
	return y + 20
}

// moreResults reads the next page of Google's links and adds the new ones.
func (a *App) moreResults(s *Search) {
	if s.moreSt == stLoading || s.moreEnd {
		return
	}
	if s.page >= 8 {
		s.moreEnd = true
		return
	}
	s.page++
	s.moreSt = stLoading
	w := a.workerFor(s.private, false)
	before := len(s.Web)
	a.enqueue(w, &job{tag: "more", url: core.ModeWeb.URL(s.Q) + "&start=" + strconv.Itoa(s.page*10), script: core.WebScript, timeout: 15, every: 0.4,
		handle: func(js string) bool {
			web, captcha := core.ParseWeb(js)
			if len(web) == 0 && !captcha {
				return false
			}
			seen := map[string]bool{}
			for _, r := range s.Web {
				seen[r.URL] = true
			}
			for _, r := range web {
				if !seen[r.URL] {
					seen[r.URL] = true
					s.Web = append(s.Web, r)
				}
			}
			s.moreSt = stDone
			if len(s.Web)-before < 3 || captcha {
				s.moreEnd = true // Google has run out of relevant links
			}
			return true
		},
		fail: func() { s.moreSt, s.moreEnd = stFailed, true }})
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

// webItems draws ranked links as cards of glass; start numbers them for ids.
func (a *App) webItems(s *Search, rs []core.Ranked, start int, x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	titleF := ui.Font{Size: 17, Bold: true}
	const in = 18
	tw := w - 2*in
	for k, r := range rs {
		i := start + k
		host := strings.TrimPrefix(core.Host(r.URL), "www.")
		tl := wrap(g, r.Title, titleF, tw)
		if len(tl) > 2 {
			tl = tl[:2]
		}
		sl := wrap(g, r.Snippet, ui.FBody, tw)
		if len(sl) > 3 {
			sl = sl[:3]
			sl[2] = ui.Fit(g, sl[2]+" …", ui.FBody, tw)
		}
		card := ui.Rect{X: x, Y: y, W: w, H: 16 + 24 + 8 + float32(len(tl))*24 + float32(len(sl))*21 + 16}
		hot := u.Hover(card)
		ui.Glass(g, card, 18, th, hot, hot)
		cx, cy := x+in, y+16
		// site line: mark, name, kind, path
		mr := ui.Rect{X: cx, Y: cy, W: 22, H: 22}
		ui.Liquid(g, mr, 7, th.Ink)
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 11, Bold: true}, th.Ink)
		site := r.Site
		if site == "" || strings.HasPrefix(site, "http") || len(site) > 40 {
			site = host
		}
		sx := cx + 30
		g.Text(site, sx, cy+15, ui.FSmallBold, th.OnSurface)
		sx += g.Measure(site, ui.FSmallBold) + 8
		path := strings.TrimPrefix(core.Display(r.URL), strings.TrimPrefix(core.Host(r.URL), "www."))
		ui.TextFit(g, path, sx, cy+15, ui.FSmall, th.Ink3, cx+tw-sx-104)
		ty := cy + 30
		for _, ln := range tl {
			g.Text(ln, cx, ty+18, titleF, th.Primary)
			if hot {
				g.FillRect(ui.Rect{X: cx, Y: ty + 21, W: g.Measure(ln, titleF), H: 1.3}, th.Ink.Alpha(0.5))
			}
			ty += 24
		}
		for _, ln := range sl {
			g.Text(ln, cx, ty+16, ui.FBody, th.OnSurfaceVariant)
			ty += 21
		}
		// the reader's own say about the site: raise, lower, hide
		acted := false
		if hot {
			bx := cx + tw - 96
			key := core.SiteKey(r.URL)
			cur := a.set.SiteRanks[key]
			for j, b := range []struct {
				ic   ui.Icon
				tip  string
				rank int
			}{{ui.IStar, "Raise " + key, 1}, {ui.IChevronDown, "Lower " + key, -1}, {ui.IClose, "Hide " + key, -2}} {
				br := ui.Rect{X: bx + float32(j)*32, Y: cy - 5, W: 30, H: 30}
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
		u.Tooltip(r.URL, ui.Rect{X: cx, Y: cy + 30, W: tw, H: float32(len(tl)) * 24})
		if u.Clickable(ui.IdN("web", i), card) && !acted {
			a.visitFromResults(r.URL)
		}
		y = card.B() + 12
	}
	return y
}

func (a *App) webSkeleton(x, y, w float32) float32 {
	g, th := a.u.G, a.u.Th
	for i := 0; i < 3; i++ {
		card := ui.Rect{X: x, Y: y, W: w, H: 118}
		ui.Glass(g, card, 18, th, false, false)
		shimmer(a, ui.Rect{X: x + 18, Y: y + 18, W: w * 0.3, H: 12}, 6)
		shimmer(a, ui.Rect{X: x + 18, Y: y + 44, W: w * 0.66, H: 17}, 8)
		shimmer(a, ui.Rect{X: x + 18, Y: y + 74, W: w * 0.88, H: 11}, 5)
		y += 134
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
	if in.Pressed && a.u.Over(r) && a.u.Live() {
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
	return in.Released && !s.moved && a.u.Over(r) && r.Contains(in.PressX, in.PressY) && a.u.Live()
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

// imageStack shows the pictures as a stack of cards, like the videos: the
// front card in the picture's own shape and sharp (the full picture loads for
// it), the next ones peeking out behind; drag, scroll sideways or use the
// arrows to move through them, click the front one to open it.
func (a *App) imageStack(s *Search, x, y, w, dt float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	n := len(s.Images)
	note := ""
	if n > 0 {
		note = strconv.Itoa(int(s.imgTo)+1) + " of " + strconv.Itoa(n)
	}
	y = sectionTitle(a, ui.IImage, "Images", note, x, y, func() { s.viewer = viewer{kind: vImages} }, w)
	const peek = 3
	maxW := w - float32(peek)*20 - 4
	H := min(maxW*0.72, 340)
	area := ui.Rect{X: x, Y: y, W: w, H: H + 70}
	if n == 0 {
		if s.imgSt == stLoading {
			shimmer(a, ui.Rect{X: x, Y: y, W: H * 1.4, H: H}, 22)
			return y + H + 20
		}
		g.Text("No pictures for this search.", x, y+16, ui.FBody, th.OnSurfaceVariant)
		return y + 30
	}
	if dx, active := a.dragOn(s, "img", area, s.imgTo); !active && dx != 0 && s.moved {
		if dx < -50 {
			s.imgTo++
		} else if dx > 50 {
			s.imgTo--
		}
	} else if active {
		s.imgPos = s.imgTo - max(-0.6, min(0.6, dx/maxW))
	}
	if u.Hover(area) && u.In.WheelX != 0 {
		s.imgTo -= u.In.WheelX / 1.5
		u.In.WheelX = 0
	}
	s.imgTo = float32(math.Round(float64(min(float32(n-1), max(0, s.imgTo)))))
	if s.drag != "img" && ease(&s.imgPos, s.imgTo, dt) {
		u.Redraw = true
	}
	// each picture's own shape: from the sharp copy once it is in, else the thumbnail
	shape := func(k int) (image.Image, float32) {
		im := s.Images[k]
		var img image.Image
		if absf(float32(k)-s.imgPos) < 0.5 {
			src := im.Full
			if src == "" {
				src = im.Src
			}
			img = a.imageFor(src, int(maxW*1.2))
			if img == nil {
				img = a.thumbFor(im.Src)
			}
		} else {
			img = a.thumbFor(im.Src)
		}
		ar := float32(1.4)
		if img != nil {
			b := img.Bounds()
			ar = min(2.2, max(0.56, float32(b.Dx())/float32(max(1, b.Dy()))))
		}
		return img, ar
	}
	front := int(math.Floor(float64(s.imgPos)))
	// the front card's right edge: the cards behind peek out past it
	_, far := shape(max(0, min(n-1, front)))
	frontR := x + min(H*far, maxW)
	for k := min(n-1, front+peek); k >= max(0, front-1); k-- {
		d := float32(k) - s.imgPos
		img, ar := shape(k)
		cw, ch := H*ar, H
		if cw > maxW {
			cw, ch = maxW, maxW/ar
		}
		var r ui.Rect
		shade := float32(0)
		if d >= 0 {
			sc := 1 - d*0.07
			r = ui.Rect{W: cw * sc, H: ch * sc}
			r.X = x + d*20
			if d >= 0.5 {
				r.X = max(r.X, frontR+d*20-r.W)
			}
			r.Y = y + (H-r.H)/2
			shade = min(0.5, d*0.16)
		} else {
			r = ui.Rect{X: x + d*maxW*1.1, Y: y + (H-ch)/2, W: cw, H: ch}
		}
		if r.R() < area.X-20 {
			continue
		}
		ui.Shadow(g, r, 20, th.Shadow, 1.1, 5)
		if img != nil {
			g.Image(img, r, 20)
		} else {
			shimmer(a, r, 20)
		}
		if shade > 0 {
			ui.FillRound(g, r, 20, pageColor(th).Alpha(shade))
		}
		if absf(d) < 0.5 {
			if a.tapped(s, r) {
				s.viewer = viewer{kind: vImage, idx: k}
			}
		} else if a.tapped(s, r) {
			s.imgTo = float32(k)
		}
	}
	// under the stack: what the front picture shows and where it is from, then the arrows
	im := s.Images[min(n-1, max(0, int(s.imgTo)))]
	host := strings.TrimPrefix(core.Host(im.Page), "www.")
	cap := im.Alt
	if cap == "" {
		cap = host
	}
	cy := y + H + 14
	ui.TextFit(g, cap, x, cy+16, ui.Font{Size: 15, Bold: true}, th.OnSurface, w-110)
	if host != "" && host != cap {
		ui.TextFit(g, host, x, cy+36, ui.FSmall, th.OnSurfaceVariant, w-110)
	}
	if roundBtn(a, ui.RectAround(x+w-74, cy+18, 38, 38), ui.IChevronLeft, "Previous picture") {
		s.imgTo--
	}
	if roundBtn(a, ui.RectAround(x+w-26, cy+18, 38, 38), ui.IChevron, "Next picture") {
		s.imgTo++
	}
	return y + H + 64
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
	cw := min(w-64, 620)
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
			r = ui.Rect{X: x + d*20 + cw*(1-sc), Y: y + d*10, W: cw * sc, H: thH * sc}
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
			ui.DrawIcon(g, ui.IYouTube, r.X, ty+3, 16, th.Ink2)
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
