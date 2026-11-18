package shell

import (
	"encoding/json"
	"image"
	"math"
	"strings"

	"iris/core"
	"iris/ui"
)

// The now-playing pill: while a tab plays sound (music, a video), a small
// liquid-glass pill beside the address shows what it is, tinted with the
// colors of its artwork or thumbnail, with sound waves that move while it
// plays. A click on it goes to that tab; a click on the waves pauses or
// plays again. It stays a little while after a pause, so playing on is one
// click away.

type nowPlaying struct {
	tab                *Tab
	url                string // the page the details were read for
	title, artist, art string
	asked              float64 // when the details were last read
	reading            bool
	tint               ui.Color
	tintOf             string // the artwork the tint was taken from
}

// nowPlayingScript reads what a page is playing: the Media Session details
// sites give (title, artist, artwork), else YouTube's thumbnail, the page's
// own picture and title.
const nowPlayingScript = `(() => {
  const m = navigator.mediaSession && navigator.mediaSession.metadata;
  let art = '';
  if (m && m.artwork && m.artwork.length) art = m.artwork[m.artwork.length - 1].src || '';
  const h = location.hostname.replace(/^(www|m|music)\./, '');
  if (!art && h === 'youtube.com') {
    const id = new URLSearchParams(location.search).get('v');
    if (id) art = 'https://i.ytimg.com/vi/' + encodeURIComponent(id) + '/mqdefault.jpg';
  }
  const meta = (p) => { const e = document.querySelector('meta[property="' + p + '"]'); return e ? e.content : ''; };
  if (!art) art = meta('og:image');
  const media = [...document.querySelectorAll('video, audio')];
  const on = media.find((x) => !x.paused);
  return {
    title: ((m && m.title) || meta('og:title') || document.title || '').slice(0, 200),
    artist: ((m && m.artist) || '').slice(0, 120),
    art: /^https:\/\//.test(art) ? art.slice(0, 2000) : '',
    paused: !on,
  };
})()`

// toggleMediaScript pauses what plays, or plays again what was paused.
const toggleMediaScript = `(() => {
  const media = [...document.querySelectorAll('video, audio')];
  const on = media.filter((x) => !x.paused);
  if (on.length) { on.forEach((x) => x.pause()); return; }
  const last = media.find((x) => x.currentTime > 0) || media[0];
  if (last) last.play().catch(() => {});
})()`

// playingTab is the tab whose sound the pill shows: the one playing (this
// tab first), else the one paused most recently, for a minute.
func (a *App) playingTab() *Tab {
	var best *Tab
	for _, t := range a.tabs {
		if t.view == nil || t.closed {
			continue
		}
		if t.Audio {
			if t == a.tab() {
				return t
			}
			if best == nil || !best.Audio {
				best = t
			}
			continue
		}
		if best == nil && t.audioEnd > 0 && a.now()-t.audioEnd < 60 {
			best = t
		}
	}
	return best
}

// readNowPlaying asks the tab what it plays, now and then (a playlist moves
// on to the next song).
func (a *App) readNowPlaying(t *Tab) {
	np := &a.np
	if np.tab != t || np.url != t.URL {
		*np = nowPlaying{tab: t, url: t.URL, tint: np.tint, tintOf: np.tintOf, title: t.Title}
	}
	if np.reading || (np.asked > 0 && a.now()-np.asked < 8) {
		return
	}
	np.reading, np.asked = true, a.now()
	v, url := t.view, t.URL
	a.web(func() {
		v.Run(nowPlayingScript, func(js string) {
			var got struct {
				Title, Artist, Art string
				Paused             bool
			}
			ok := json.Unmarshal([]byte(js), &got) == nil
			a.post(func() {
				np.reading = false
				if !ok || np.tab != t || t.URL != url {
					return
				}
				if got.Title != "" {
					np.title = got.Title
				}
				np.artist, np.art = got.Artist, got.Art
				// Iris fetches the artwork itself: never from this computer or
				// its network, whatever the page names
				if core.IsPrivateHost(np.art) {
					np.art = ""
				}
			})
		})
	})
}

// tintOf is the colour of an artwork: its average, made a little livelier,
// so the glass takes the picture's mood without shouting.
func tintOf(img image.Image) ui.Color {
	b := img.Bounds()
	if b.Empty() {
		return 0
	}
	var r, g, bl, n float64
	step := max(1, min(b.Dx(), b.Dy())/24)
	for y := b.Min.Y; y < b.Max.Y; y += step {
		for x := b.Min.X; x < b.Max.X; x += step {
			cr, cg, cb, _ := img.At(x, y).RGBA()
			r, g, bl, n = r+float64(cr>>8), g+float64(cg>>8), bl+float64(cb>>8), n+1
		}
	}
	if n == 0 {
		return 0
	}
	r, g, bl = r/n, g/n, bl/n
	// more saturation: away from the grey of the same brightness
	grey := (r + g + bl) / 3
	sat := func(c float64) int { return int(math.Max(0, math.Min(255, grey+(c-grey)*1.6))) }
	return ui.ARGB(255, sat(r), sat(g), sat(bl))
}

// nowPlayingPill draws the pill in r (the space the toolbar gave it).
func (a *App) nowPlayingPill(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	np := &a.np
	a.readNowPlaying(t)
	var art image.Image
	if np.art != "" {
		art = a.thumbFor(np.art)
		if art != nil && np.tintOf != np.art {
			np.tint, np.tintOf = tintOf(art), np.art
		}
	}
	tint := np.tint
	if tint == 0 || np.art == "" {
		tint = th.Primary
	}
	rad := r.H / 2
	hot := u.Hot(ID("np"), r, true)
	g.Save()
	g.Clip(r.Inset(-1))
	// liquid glass, washed with the artwork's colour
	ui.Glass(g, r, rad, th, true, hot > 0.5)
	g.FillPathGradient(ui.NewPath().RoundRect(r, rad), tint.Alpha(0.34+0.08*hot), tint.Alpha(0.12), r.Y, r.B())
	ui.StrokeRound(g, r.Inset(0.5), rad-0.5, 1, tint.Alpha(0.45))

	// the artwork, round
	ar := ui.Rect{X: r.X + 5, Y: r.Y + 5, W: r.H - 10, H: r.H - 10}
	if art != nil {
		g.Image(art, ar, ar.W/2)
	} else {
		ui.FillOval(g, ar, tint.Alpha(0.55))
		ui.DrawIcon(g, ui.IVolume, ar.CX()-7, ar.CY()-7, 14, ui.White)
	}

	// the sound waves, which are also the pause and play button
	playing := t.Audio
	wr := ui.Rect{X: r.R() - r.H - 2, Y: r.Y, W: r.H, H: r.H}
	whot := u.Hot(ID("np-wave"), wr, true)
	if whot > 0.5 {
		ui.FillOval(g, wr.Inset(4), th.Ink.Alpha(0.10))
		ic := ui.IPause
		if !playing {
			ic = ui.IPlay
		}
		ui.DrawIcon(g, ic, wr.CX()-7, wr.CY()-7, 14, th.Ink)
	} else {
		a.soundWaves(wr.Inset2(9, 10), playing, ui.Mix(tint, th.Ink, 0.35))
	}
	u.Tooltip(map[bool]string{true: "Pause", false: "Play"}[playing], wr)

	// what it is
	tx := ar.R() + 9
	tw := wr.X - tx - 2
	title := np.title
	if title == "" {
		title = t.label()
	}
	title = strings.TrimSuffix(strings.TrimSpace(title), " - YouTube")
	sub := np.artist
	if sub == "" {
		sub = strings.TrimPrefix(core.Host(t.URL), "www.")
	}
	ui.TextFit(g, title, tx, r.Y+r.H/2-1, ui.FSmallBold, th.OnSurface, tw)
	ui.TextFit(g, sub, tx, r.Y+r.H/2+12, ui.Font{Size: 10.5}, th.OnSurfaceVariant, tw)
	g.Restore()

	switch {
	case u.Clickable(ID("np-wave"), wr):
		v := t.view
		a.web(func() { v.Eval(toggleMediaScript) })
	case u.Clickable(ID("np"), r):
		for i, x := range a.tabs {
			if x == t {
				a.selectTab(i)
			}
		}
	}
	if t != a.tab() {
		u.Tooltip("Go to the tab playing this", ui.Rect{X: r.X, Y: r.Y, W: wr.X - r.X, H: r.H})
	}
}

// soundWaves draws four bars that rise and fall while sound plays, and rest
// as dots when it is paused. They move at a gentle 15 frames a second, so
// music playing in the background costs almost nothing.
func (a *App) soundWaves(r ui.Rect, playing bool, c ui.Color) {
	g := a.u.G
	const n = 4
	bw := float32(2.6)
	gap := (r.W - n*bw) / (n - 1)
	now := a.now()
	for i := 0; i < n; i++ {
		h := bw
		if playing && !a.u.NoMotion {
			p := float64(i) * 1.7
			s := 0.5 + 0.5*math.Sin(now*(5.2+float64(i)*1.3)+p)*math.Sin(now*2.1+p*0.7)
			h = bw + (r.H-bw)*float32(math.Abs(s))
		}
		x := r.X + float32(i)*(bw+gap)
		ui.FillRound(g, ui.Rect{X: x, Y: r.CY() - h/2, W: bw, H: h}, bw/2, c)
	}
	if playing && !a.u.NoMotion {
		a.later(1.0 / 15)
	}
}
