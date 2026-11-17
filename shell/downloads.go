package shell

import (
	"path/filepath"
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
	"litego/webview"
)

// download is a file being fetched, or one that arrived this session.
type download struct {
	webview.Download
	name    string
	started float64
	speed   float64 // bytes a second, smoothed
	lastN   int64
	lastAt  float64
	seen    bool // the reader opened the list since it ended
}

func (d *download) active() bool {
	return d.State == webview.DownloadActive || d.State == webview.DownloadPaused
}

// onDownload takes a download's new state from the engine.
func (a *App) onDownload(n webview.Download) {
	now := a.now()
	var d *download
	for _, x := range a.downloads {
		if x.ID == n.ID {
			d = x
		}
	}
	if d == nil {
		d = &download{started: now, lastAt: now}
		a.downloads = append([]*download{d}, a.downloads...)
		if len(a.downloads) > 200 { // forget the oldest finished ones
			for i := len(a.downloads) - 1; i >= 0 && len(a.downloads) > 200; i-- {
				if !a.downloads[i].active() {
					a.downloads = append(a.downloads[:i], a.downloads[i+1:]...)
				}
			}
		}
		a.notify("Downloading " + fileName(n) + "…")
	}
	was := d.State
	if dt := now - d.lastAt; dt >= 0.5 && n.Received >= d.lastN {
		rate := float64(n.Received-d.lastN) / dt
		if d.speed == 0 {
			d.speed = rate
		} else {
			d.speed = d.speed*0.6 + rate*0.4
		}
		d.lastN, d.lastAt = n.Received, now
	}
	d.Download = n
	d.name = fileName(n)
	if d.active() || was == d.State {
		a.h.Invalidate()
		return
	}
	d.speed = 0
	d.seen = a.panel && a.panelMode == panelDownloads
	a.reapPages()
	switch d.State {
	case webview.DownloadDone:
		a.bar = infobar{text: d.name + " downloaded.", action: "Open", until: now + 6, do: func() { a.openFile(d, false) },
			action2: "Show in folder", do2: func() { a.openFile(d, true) }}
	case webview.DownloadFailed:
		a.bar = infobar{warn: true, text: d.name + " could not be downloaded.", until: now + 6}
	}
	a.h.Invalidate()
}

// downloadingIn says whether a page has a download running. Such a page is
// kept open until the download ends: it is not put to sleep or unloaded, and
// closing its tab only hides it (closing it could stop the download).
func (a *App) downloadingIn(v webview.View) bool {
	if v == nil {
		return false
	}
	for _, d := range a.downloads {
		if d.active() && d.View == v {
			return true
		}
	}
	return false
}

// keepAwake: tabs playing sound or downloading stay awake in the background.
// keepAwake says whether a tab must keep its page: it is playing sound or
// video (or paused it in the last ten minutes), it is YouTube, or it is
// downloading. Such tabs never rest.
func (a *App) keepAwake(t *Tab) bool {
	if t.Audio || t.audioEnd > 0 && a.now()-t.audioEnd < 600 || a.downloadingIn(t.view) {
		return true
	}
	switch strings.TrimPrefix(core.Host(t.URL), "www.") {
	case "youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "youtube-nocookie.com":
		return true
	}
	return false
}

// reapPages closes the pages of closed tabs whose downloads have ended.
func (a *App) reapPages() {
	w := 0
	for _, v := range a.keptPages {
		if a.downloadingIn(v) {
			a.keptPages[w] = v
			w++
			continue
		}
		a.web(v.Close)
	}
	clear(a.keptPages[w:])
	a.keptPages = a.keptPages[:w]
}

func fileName(d webview.Download) string {
	if d.Path != "" {
		return filepath.Base(d.Path)
	}
	u := d.URL
	if i := strings.IndexAny(u, "?#"); i >= 0 {
		u = u[:i]
	}
	if i := strings.LastIndexByte(u, '/'); i >= 0 && i+1 < len(u) {
		return u[i+1:]
	}
	return "download"
}

func (a *App) openFile(d *download, reveal bool) {
	f := a.cfg.Sys.Open
	if reveal {
		f = a.cfg.Sys.Reveal
	}
	if f == nil || d.Path == "" {
		a.notify("Saved to " + d.Path)
		return
	}
	p := d.Path
	go f(p)
}

// downloading reports how many downloads are running and their progress
// together (-1 when a size is unknown).
func (a *App) downloading() (n int, frac float32) {
	var got, total int64
	unknown := false
	for _, d := range a.downloads {
		if !d.active() {
			continue
		}
		n++
		if d.Total <= 0 {
			unknown = true
		}
		got += d.Received
		total += d.Total
	}
	if n == 0 {
		return 0, 0
	}
	if unknown || total <= 0 {
		return n, -1
	}
	return n, float32(float64(got) / float64(total))
}

// downloadButton is the toolbar's downloads icon: it appears with the first
// download, wears a ring that fills while files arrive, and a dot when one
// has finished and was not looked at yet.
func (a *App) downloadButton(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	n, frac := a.downloading()
	tip := "Downloads  Ctrl+Shift+D"
	if n == 1 {
		tip = "1 download running"
	} else if n > 1 {
		tip = strconv.Itoa(n) + " downloads running"
	}
	open := a.panel && a.panelMode == panelDownloads
	if u.IconButton(ID("dlbtn"), r, ui.IDownload, tip, ui.IconOpt{Toggled: open, Accent: th.Primary}) {
		a.togglePanel(panelDownloads)
	}
	cx, cy := r.CX(), r.CY()
	if n > 0 {
		ui.StrokeOval(g, ui.RectAround(cx, cy, 34, 34), 2.2, th.Primary.Alpha(0.22))
		if frac < 0 { // size unknown: a turning arc
			a0 := float32(int(a.now()*260) % 360)
			ui.Pen(g, ui.NewPath().Arc(cx, cy, 17, a0, a0+100, true), 2.2, th.Primary)
		} else {
			ui.Pen(g, ui.NewPath().Arc(cx, cy, 17, -90, -90+360*max(0.02, frac), true), 2.2, th.Primary)
		}
		u.Redraw = true
		return
	}
	for _, d := range a.downloads {
		if !d.seen && d.State == webview.DownloadDone {
			ui.FillOval(g, ui.RectAround(r.R()-9, r.Y+9, 9, 9), th.Primary)
			break
		}
	}
}

func bytesText(n int64) string {
	switch {
	case n < 0:
		return "?"
	case n < 1000:
		return strconv.FormatInt(n, 10) + " B"
	case n < 1000*1000:
		return strconv.FormatFloat(float64(n)/1e3, 'f', 0, 64) + " KB"
	case n < 1000*1000*1000:
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + " MB"
	}
	return strconv.FormatFloat(float64(n)/1e9, 'f', 2, 64) + " GB"
}

func timeLeft(sec float64) string {
	switch {
	case sec < 60:
		return strconv.Itoa(int(sec)+1) + " s left"
	case sec < 3600:
		return strconv.Itoa(int(sec/60)+1) + " min left"
	}
	return strconv.FormatFloat(sec/3600, 'f', 1, 64) + " h left"
}

// drawDownloads is the downloads list in the side panel.
func (a *App) drawDownloads(body ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	sc := &a.dlSc
	u.Scroll(ID("dlscroll"), body, sc)
	g.Save()
	g.Clip(body)
	u.PushHit(body)
	x, w := body.X+14, body.W-28
	y := body.Y + 4 - sc.Y
	if len(a.downloads) == 0 {
		ui.DrawIcon(g, ui.IDownload, body.CX()-16, body.Y+70, 32, th.OnSurfaceVariant.Alpha(0.5))
		ui.TextCenter(g, "Nothing downloaded in this session", ui.Rect{X: body.X, Y: body.Y + 112, W: body.W, H: 20}, ui.FBody, th.OnSurfaceVariant)
		for i, ln := range wrap(g, "Files go to your Downloads folder. The list is kept until Lite Go closes; the files stay.", ui.FSmall, w-20) {
			ui.TextCenter(g, ln, ui.Rect{X: body.X, Y: body.Y + 138 + float32(i)*18, W: body.W, H: 18}, ui.FSmall, th.OnSurfaceVariant)
		}
	}
	var drop *download
	for i, d := range a.downloads {
		d.seen = d.seen || !d.active()
		h := float32(74)
		card := ui.Rect{X: x, Y: y, W: w, H: h}
		if card.B() < body.Y || card.Y > body.B() {
			y += h + 8
			continue
		}
		ui.FillRound(g, card, 16, th.SurfaceHigh)
		tile := ui.Rect{X: card.X + 10, Y: card.Y + 10, W: 36, H: 36}
		col, ic := th.Primary, ui.IDownload
		switch d.State {
		case webview.DownloadDone:
			ic = ui.ICheck
		case webview.DownloadFailed:
			col, ic = th.Danger, ui.IWarning
		case webview.DownloadCanceled:
			col, ic = th.OnSurfaceVariant, ui.IClose
		case webview.DownloadPaused:
			ic = ui.IPause
		}
		ui.FillRound(g, tile, 12, col.Alpha(0.14))
		ui.DrawIcon(g, ic, tile.CX()-9, tile.CY()-9, 18, col)
		// buttons, right to left
		bx := card.R() - 40
		btn := func(id string, icon ui.Icon, tip string) bool {
			r := ui.Rect{X: bx, Y: card.Y + 8, W: 32, H: 32}
			bx -= 34
			return u.IconButton(ui.IdN(id, d.ID), r, icon, tip, ui.IconOpt{})
		}
		switch {
		case d.active():
			if btn("dlc", ui.IClose, "Cancel") && d.Cancel != nil {
				a.web(d.Cancel)
			}
			if d.State == webview.DownloadPaused && d.Resume != nil {
				if btn("dlr", ui.IPlay, "Resume") {
					a.web(d.Resume)
				}
			} else if d.Pause != nil && btn("dlp", ui.IPause, "Pause") {
				a.web(d.Pause)
			}
		default:
			if btn("dlx", ui.IClose, "Remove from the list (the file stays)") {
				drop = d
			}
			if d.State == webview.DownloadDone {
				if btn("dlf", ui.IFolder, "Show in folder") {
					a.openFile(d, true)
				}
				if btn("dlo", ui.IExternal, "Open") {
					a.openFile(d, false)
				}
			}
		}
		tw := bx + 30 - (tile.R() + 10)
		ui.TextFit(g, d.name, tile.R()+10, card.Y+26, ui.FBodyBold, th.OnSurface, tw)
		sub := strings.TrimPrefix(core.Host(d.URL), "www.")
		switch d.State {
		case webview.DownloadActive:
			sub = bytesText(d.Received)
			if d.Total > 0 {
				sub += " of " + bytesText(d.Total)
				if d.speed > 1 {
					sub += " · " + timeLeft(float64(d.Total-d.Received)/d.speed)
				}
			}
			if d.speed > 1 {
				sub += " · " + bytesText(int64(d.speed)) + "/s"
			}
		case webview.DownloadPaused:
			sub = "Paused · " + bytesText(d.Received)
		case webview.DownloadDone:
			sub = bytesText(d.Total) + " · " + sub
		case webview.DownloadFailed:
			sub = "Failed · " + sub
		case webview.DownloadCanceled:
			sub = "Canceled · " + sub
		}
		ui.TextFit(g, sub, tile.R()+10, card.Y+45, ui.FSmall, th.OnSurfaceVariant, card.R()-tile.R()-22)
		if d.active() {
			pr := ui.Rect{X: card.X + 12, Y: card.B() - 14, W: card.W - 24, H: 5}
			ui.FillRound(g, pr, 2.5, th.SurfaceHighest)
			switch {
			case d.Total > 0:
				f := min(1, float32(float64(d.Received)/float64(d.Total)))
				ui.FillRoundAccent(g, ui.Rect{X: pr.X, Y: pr.Y, W: max(5, pr.W*f), H: pr.H}, 2.5, th.Primary)
			case d.State == webview.DownloadActive:
				p := float32(a.now()*0.8 - float64(int(a.now()*0.8)))
				seg := pr.W * 0.3
				g.Save()
				g.Clip(pr)
				ui.FillRoundAccent(g, ui.Rect{X: pr.X + (pr.W+seg)*p - seg, Y: pr.Y, W: seg, H: pr.H}, 2.5, th.Primary)
				g.Restore()
			}
			if d.State == webview.DownloadActive {
				u.Redraw = true
			}
		} else if d.State == webview.DownloadDone && u.Clickable(ui.IdN("dlrow", i), ui.Rect{X: card.X, Y: card.Y, W: bx + 30 - card.X, H: card.H}) {
			a.openFile(d, false)
		}
		y += h + 8
	}
	done := 0
	for _, d := range a.downloads {
		if !d.active() {
			done++
		}
	}
	if done > 1 {
		if u.Button(ID("dlclear"), ui.Rect{X: x, Y: y + 2, W: w, H: 36}, "Clear the list", ui.ButtonOpt{Tip: "The files stay in your Downloads folder"}) {
			keep := a.downloads[:0]
			for _, d := range a.downloads {
				if d.active() {
					keep = append(keep, d)
				}
			}
			a.downloads = keep
		}
		y += 46
	}
	if drop != nil {
		for i, d := range a.downloads {
			if d == drop {
				a.downloads = append(a.downloads[:i], a.downloads[i+1:]...)
				break
			}
		}
	}
	sc.Content = y + sc.Y - body.Y + 8
	u.PopHit()
	g.Restore()
}
