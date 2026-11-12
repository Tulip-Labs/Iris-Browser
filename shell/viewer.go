package shell

import (
	"image"
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
	"litego/webview"
)

// The side viewer: a picture or a video opened from the results shows in the
// column beside them (or over the page on a narrow window), so the answer and
// the other results stay in view. Videos play in a small web view of their own.

const (
	vNone = iota
	vImage
	vVideo
	vImages
	vVideos
)

type viewer struct {
	kind, idx int
	scroll    ui.Scroll
}

// sideView is the web view that plays a video beside the results.
type sideView struct {
	view    webview.View
	making  bool
	url     string
	private bool
	shown   bool
	bounds  [4]int
	idle    float64
}

// imageFor loads a picture at up to maxW pixels wide (cached like thumbnails).
func (a *App) imageFor(src string, maxW int) image.Image {
	if maxW <= 320 {
		return a.thumbFor(src)
	}
	key := "big:" + src
	t := a.thumbs[key]
	if t == nil {
		t = &thumb{loading: true}
		a.thumbs[key] = t
		fetch := a.fetchImage
		go func() {
			a.thumbSem <- struct{}{}
			defer func() { <-a.thumbSem }()
			ctx, cancel := ctxTimeout(15)
			defer cancel()
			img, err := fetch(ctx, src, maxW)
			a.post(func() { t.loading, t.img, t.failed = false, img, err != nil })
		}()
	}
	t.used = a.now()
	return t.img
}

// containRect fits an image of size (iw, ih) inside r, centered.
func containRect(r ui.Rect, iw, ih int) ui.Rect {
	if iw <= 0 || ih <= 0 {
		return r
	}
	ar := float32(iw) / float32(ih)
	w, h := r.W, r.W/ar
	if h > r.H {
		h, w = r.H, r.H*ar
	}
	return ui.RectAround(r.CX(), r.CY(), w, h)
}

// drawViewer draws the opened picture or video (or all of them) in r.
func (a *App) drawViewer(s *Search, t *Tab, r ui.Rect, overPage bool) {
	u, g, th := &a.u, a.u.G, a.u.Th
	v := &s.viewer
	// header: back to the websites (or the results), and what this is
	hy := r.Y + 14
	back := "Websites"
	if overPage {
		back = "Results"
	}
	bw := g.Measure(back, ui.FBodyBold) + 44
	br := ui.Rect{X: r.X - 6, Y: hy, W: bw, H: 36}
	if u.Hover(br) {
		ui.FillRound(g, br, 18, th.Ink.Alpha(0.06))
	}
	ui.DrawIcon(g, ui.IArrowLeft, br.X+10, br.CY()-9, 18, th.Primary)
	g.Text(back, br.X+34, ui.Mid(g, br.Y, br.H, ui.FBodyBold), ui.FBodyBold, th.Primary)
	if u.Clickable(ID("vback"), br) || a.st.Focus == (ui.ID{}) && u.In.Has(ui.KEscape, false) {
		*v = viewer{}
		return
	}
	area := ui.Rect{X: r.X, Y: hy + 50, W: r.W, H: r.B() - hy - 50 - 16}
	switch v.kind {
	case vImage:
		a.viewImage(s, area, br)
	case vVideo:
		a.viewVideo(s, area, br)
	case vImages:
		a.viewAllImages(s, area)
	case vVideos:
		a.viewAllVideos(s, area)
	}
}

func (a *App) viewImage(s *Search, r ui.Rect, head ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	v := &s.viewer
	n := len(s.Images)
	if n == 0 {
		*v = viewer{}
		return
	}
	v.idx = max(0, min(n-1, v.idx))
	im := s.Images[v.idx]
	g.Text(strconv.Itoa(v.idx+1)+" of "+strconv.Itoa(n), head.R()+10, ui.Mid(g, head.Y, head.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant)
	// the picture: full size when Google names it, the thumbnail until then
	stage := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: max(160, r.H-190)}
	ui.FillRound(g, stage, 20, th.Ink.Alpha(0.04))
	var img image.Image
	if strings.HasPrefix(im.Full, "http") {
		img = a.imageFor(im.Full, 1400)
	}
	if img == nil {
		img = a.thumbFor(im.Src)
	}
	if img != nil {
		b := img.Bounds()
		g.Image(img, containRect(stage.Inset(10), b.Dx(), b.Dy()), 14)
	} else {
		shimmer(a, stage, 20)
	}
	if u.Hover(stage) || true {
		if v.idx > 0 && roundBtn(a, ui.RectAround(stage.X+30, stage.CY(), 42, 42), ui.IChevronLeft, "Previous picture") {
			v.idx--
		}
		if v.idx < n-1 && roundBtn(a, ui.RectAround(stage.R()-30, stage.CY(), 42, 42), ui.IChevron, "Next picture") {
			v.idx++
		}
	}
	if a.st.Focus == (ui.ID{}) {
		if u.In.Has(ui.KLeft, false) && v.idx > 0 {
			v.idx--
		}
		if u.In.Has(ui.KRight, false) && v.idx < n-1 {
			v.idx++
		}
	}
	// what it is and where it comes from
	y := stage.B() + 18
	host := strings.TrimPrefix(core.Host(im.Page), "www.")
	title := im.Alt
	if title == "" {
		title = host
	}
	ui.TextFit(g, title, r.X, y+16, ui.FBodyBold, th.OnSurface, r.W)
	if host != "" {
		mr := ui.Rect{X: r.X, Y: y + 26, W: 18, H: 18}
		ui.FillRoundAccent(g, mr, 6, siteColor(host))
		ui.TextCenter(g, monogram(host), mr, ui.Font{Size: 9.5, Bold: true}, ui.White)
		ui.TextFit(g, host, r.X+26, y+40, ui.FSmall, th.OnSurfaceVariant, r.W-30)
	}
	y += 58
	bx := r.X
	if im.Page != "" {
		bw := float32(150)
		if u.Button(ID("vvisit"), ui.Rect{X: bx, Y: y, W: bw, H: 38}, "Visit website", ui.ButtonOpt{Primary: true, Icon: ui.IGlobe, HasIcon: true}) {
			a.visitFromResults(im.Page)
		}
		bx += bw + 10
	}
	if strings.HasPrefix(im.Full, "http") {
		if u.Button(ID("vfull"), ui.Rect{X: bx, Y: y, W: 140, H: 38}, "Open image", ui.ButtonOpt{Icon: ui.IExternal, HasIcon: true}) {
			t := a.tab()
			a.newTab(t.Kind, t.Container, im.Full, true)
		}
	}
	// a strip of the other pictures
	y += 54
	const th0 = 56
	if y+th0 <= r.B() {
		x := r.X
		start := max(0, min(v.idx-3, n-int(r.W/(th0*1.3+8))))
		for i := start; i < n && x+th0 < r.R(); i++ {
			tr := ui.Rect{X: x, Y: y, W: th0 * 1.3, H: th0}
			if img := a.thumbFor(s.Images[i].Src); img != nil {
				g.Image(img, tr, 10)
			} else {
				shimmer(a, tr, 10)
			}
			if i == v.idx {
				ui.StrokeRound(g, tr.Inset(-2), 12, 2.5, th.Primary)
			}
			if u.Clickable(ui.IdN("vstrip", i), tr) {
				v.idx = i
			}
			x += tr.W + 8
		}
	}
}

func (a *App) viewVideo(s *Search, r ui.Rect, head ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	v := &s.viewer
	if len(s.Videos) == 0 {
		*v = viewer{}
		return
	}
	v.idx = max(0, min(len(s.Videos)-1, v.idx))
	vd := s.Videos[v.idx]
	// open in a tab, step through the videos
	bx := r.R() - 40
	if u.IconButton(ID("vnext"), ui.Rect{X: bx, Y: head.Y, W: 36, H: 36}, ui.IChevron, "Next video", ui.IconOpt{Disabled: v.idx >= len(s.Videos)-1}) {
		v.idx++
	}
	bx -= 38
	if u.IconButton(ID("vprev"), ui.Rect{X: bx, Y: head.Y, W: 36, H: 36}, ui.IChevronLeft, "Previous video", ui.IconOpt{Disabled: v.idx == 0}) {
		v.idx--
	}
	bx -= 38
	if u.IconButton(ID("vtab"), ui.Rect{X: bx, Y: head.Y, W: 36, H: 36}, ui.IExternal, "Open in a tab", ui.IconOpt{}) {
		a.visitFromResults(vd.URL())
		return
	}
	ui.TextFit(g, vd.Title, head.R()+10, ui.Mid(g, head.Y, head.H, ui.FSmallBold), ui.FSmallBold, th.OnSurface, bx-head.R()-18)
	// the YouTube page itself, laid out for this column
	pr := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}
	ui.FillRound(g, pr, 16, th.Ink.Alpha(0.04))
	a.videoThumb(vd, ui.Rect{X: pr.X, Y: pr.Y, W: pr.W, H: pr.W * 9 / 16}, 16)
	a.sideRect, a.sideURL = pr, vd.URL()
}

func (a *App) viewAllImages(s *Search, r ui.Rect) {
	u, g := &a.u, a.u.G
	v := &s.viewer
	u.Scroll(ID("vall"), r, &v.scroll)
	g.Save()
	g.Clip(r)
	cols := max(2, int(r.W/170))
	const gap = 8
	cw := (r.W - float32(cols-1)*gap) / float32(cols)
	ch := cw * 0.78
	for i, im := range s.Images {
		tr := ui.Rect{X: r.X + float32(i%cols)*(cw+gap), Y: r.Y + float32(i/cols)*(ch+gap) - v.scroll.Y, W: cw, H: ch}
		if tr.B() < r.Y || tr.Y > r.B() {
			continue
		}
		if img := a.thumbFor(im.Src); img != nil {
			g.Image(img, tr, 12)
		} else {
			shimmer(a, tr, 12)
		}
		if u.Hover(tr) {
			ui.StrokeRound(g, tr.Inset(1), 11, 2, a.u.Th.Primary)
		}
		if u.Clickable(ui.IdN("vall", i), tr) {
			*v = viewer{kind: vImage, idx: i}
		}
	}
	v.scroll.Content = float32((len(s.Images)+cols-1)/cols) * (ch + gap)
	g.Restore()
}

func (a *App) viewAllVideos(s *Search, r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	v := &s.viewer
	u.Scroll(ID("vallv"), r, &v.scroll)
	g.Save()
	g.Clip(r)
	tw := min(200, r.W*0.42)
	rowH := tw*9/16 + 14
	for i, vd := range s.Videos {
		y := r.Y + float32(i)*rowH - v.scroll.Y
		row := ui.Rect{X: r.X - 6, Y: y - 4, W: r.W + 12, H: rowH - 6}
		if row.B() < r.Y || row.Y > r.B() {
			continue
		}
		if u.Hover(row) {
			ui.FillRound(g, row, 14, th.Ink.Alpha(0.05))
		}
		a.videoThumb(vd, ui.Rect{X: r.X, Y: y, W: tw, H: tw * 9 / 16}, 12)
		tx := r.X + tw + 14
		tl := wrap(g, vd.Title, ui.FBodyBold, r.R()-tx)
		if len(tl) > 2 {
			tl = tl[:2]
		}
		ty := y + 4
		for _, ln := range tl {
			g.Text(ln, tx, ty+14, ui.FBodyBold, th.OnSurface)
			ty += 20
		}
		ui.TextFit(g, videoMeta(vd), tx, ty+14, ui.FSmall, th.OnSurfaceVariant, r.R()-tx)
		if u.Clickable(ui.IdN("vallv", i), row) {
			*v = viewer{kind: vVideo, idx: i}
		}
	}
	v.scroll.Content = float32(len(s.Videos)) * rowH
	g.Restore()
}

// syncSide shows, moves, hides or closes the side video view (after the frame is laid out).
func (a *App) syncSide() {
	sv := &a.side
	want := a.sideURL != "" && !a.sideRect.Empty()
	t := a.tab()
	private := t != nil && t.private()
	if want && sv.view != nil && sv.private != private {
		a.closeSide()
	}
	if !want {
		if sv.view != nil && sv.shown {
			v := sv.view
			sv.shown, sv.url, sv.idle = false, "", a.now()
			// hiding does not stop a video: leave the page so it goes quiet
			a.web(func() { v.SetVisible(false); v.Navigate("about:blank") })
		}
		if sv.view != nil && !sv.shown && a.now()-sv.idle > 20 {
			a.closeSide()
		}
		return
	}
	if sv.view == nil {
		if !sv.making && a.ready && a.eng != nil {
			sv.making, sv.private = true, private
			o := webview.Options{}
			if private {
				o = webview.Options{Profile: "private", Private: true}
			}
			eng := a.eng
			ev := webview.Events{
				Fullscreen: func(f bool) {
					a.post(func() {
						a.sideFull, a.full = f, f
						a.h.SetFullscreen(f || a.winFull)
					})
				},
				NewTab: func(url string, p *webview.Popup) {
					a.post(func() { a.newTab(KNormal, "", url, true) })
				},
				Key: func(k webview.Key) bool {
					act := vkAction(k)
					if act == actNone {
						return false
					}
					a.post(func() { a.do(act) })
					return true
				},
			}
			a.web(func() {
				eng.NewView(o, ev, func(v webview.View, err error) {
					if err == nil {
						v.SetVisible(false)
					}
					a.post(func() {
						sv.making = false
						if err == nil {
							sv.view, sv.shown, sv.url, sv.bounds = v, false, "", [4]int{}
						}
					})
				})
			})
		}
		return
	}
	v := sv.view
	if sv.url != a.sideURL {
		sv.url = a.sideURL
		u := a.sideURL
		a.web(func() { v.Navigate(u) })
	}
	r, sc := a.sideRect, a.Scale
	b := [4]int{int(r.X*sc + 0.5), int(r.Y*sc + 0.5), int(r.W*sc + 0.5), int(r.H*sc + 0.5)}
	if b != sv.bounds {
		sv.bounds = b
		a.web(func() { v.SetBounds(b[0], b[1], b[2], b[3]) })
	}
	if !sv.shown {
		sv.shown = true
		a.web(func() { v.SetVisible(true) })
	}
}

func (a *App) closeSide() {
	if v := a.side.view; v != nil {
		a.web(v.Close)
	}
	a.side = sideView{}
}

// ---- signing in to Google once ----

const signInURL = "https://accounts.google.com/ServiceLogin?hl=en&continue=https%3A%2F%2Fwww.google.com%2F%3Fhl%3Den%26litego%3Dsignedin"

// signIn opens Google's sign-in in tab t (the default container, which the
// results and the AI answers use).
func (a *App) signIn(t *Tab) {
	if t == nil || t.Kind != KNormal {
		t = a.newTab(KNormal, "", "", true)
	}
	t.search = nil
	t.Title = "Sign in to Google"
	a.navigate(t, signInURL)
}

// signedIn notices the end of the sign-in and turns the tab back into a new tab page.
func (a *App) signedIn(t *Tab, url string) bool {
	if !strings.Contains(url, "litego=signedin") || !strings.Contains(core.Host(url), "google.") {
		return false
	}
	a.set.GoogleSignIn = "done"
	a.set.Save()
	a.unload(t)
	t.URL, t.Title, t.Loading = "", "", false
	if t == a.tab() {
		a.ntpQ.Set("")
		a.st.Focus = ID("ntp")
	}
	a.notify("Signed in to Google. Results and AI answers come without human checks now.")
	return true
}
