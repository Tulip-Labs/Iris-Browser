package shell

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"time"

	"litego/core"
	"litego/link"
	"litego/ui"
	"litego/webview"
)

// phoneLink is the link with a phone: a page served on the local network
// that the phone opens by scanning a QR code (see package link).
type phoneLink struct {
	srv     *link.Server
	err     string
	qr      [][]bool
	seq     int // links opened in this session (keeps the ids of received files apart)
	picking bool
	sent    int
	sc      ui.Scroll
}

func (a *App) startLink() {
	p := &a.phone
	if p.srv != nil {
		return
	}
	dir := "Downloads"
	if home, err := os.UserHomeDir(); err == nil {
		dir = filepath.Join(home, "Downloads")
	}
	p.seq++
	seq := p.seq
	srv, err := link.Start(dir, func(e link.Event) { a.post(func() { a.linkEvent(seq, e) }) })
	if err != nil {
		p.err = "The link could not start: " + err.Error() + "."
		return
	}
	p.srv, p.err, p.qr, p.sent = srv, "", core.QR(srv.URL()), 0
	a.pairing()
}

func (a *App) stopLink() {
	if s := a.phone.srv; s != nil {
		s.Stop()
		a.phone.srv, a.phone.qr = nil, nil
	}
}

// linkEvent shows what the phone does: files it sends go to the downloads list.
func (a *App) linkEvent(seq int, e link.Event) {
	switch e.Kind {
	case link.Connected:
		a.notify("A phone opened the link.")
	case link.Fetched:
		a.phone.sent++
	case link.Receiving, link.Received, link.Failed:
		d := webview.Download{ID: -(seq*100000 + e.ID), URL: "phone://phone/" + e.Name, Path: e.Path, Total: e.Size, Received: e.Got}
		switch e.Kind {
		case link.Received:
			d.State = webview.DownloadDone
		case link.Failed:
			d.State = webview.DownloadFailed
		}
		a.onDownload(d)
	}
}

// sharePick lets the reader choose files to offer to the phone.
func (a *App) sharePick() {
	pick := a.cfg.Sys.PickFiles
	if pick == nil || a.phone.picking {
		return
	}
	a.phone.picking = true
	go func() { // the system's file box waits for the reader
		files := pick()
		a.post(func() {
			a.phone.picking = false
			if a.phone.srv == nil {
				return
			}
			for _, f := range files {
				if err := a.phone.srv.Share(f); err != nil {
					a.notify(filepath.Base(f) + ": " + err.Error())
				}
			}
		})
	}()
}

// linkTick closes a link nobody has used for a while.
func (a *App) linkTick() {
	if s := a.phone.srv; s != nil && s.Idle() > 30*time.Minute && !(a.panel && a.panelMode == panelPhone) {
		a.stopLink()
		a.notify("The phone link was closed after 30 minutes without use.")
	}
}

func (a *App) drawPhone(body ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	p := &a.phone
	sc := &p.sc
	u.Scroll(ID("phsc"), body, sc)
	g.Save()
	g.Clip(body)
	u.PushHit(body)
	defer func() {
		u.PopHit()
		g.Restore()
	}()
	x, w := body.X+18, body.W-36
	y := body.Y + 6 - sc.Y
	note := func(s string, c ui.Color) {
		for _, ln := range wrap(g, s, ui.FSmall, w) {
			g.Text(ln, x, y+14, ui.FSmall, c)
			y += 18
		}
	}
	if p.srv == nil {
		ui.DrawIcon(g, ui.IPhone, body.CX()-20, y+18, 40, th.Primary)
		y += 74
		for _, ln := range wrap(g, "Move photos and files between this computer and your phone. Nothing to install on the phone: it scans a code and uses its own browser.", ui.FBody, w) {
			ui.TextCenter(g, ln, ui.Rect{X: x, Y: y, W: w, H: 22}, ui.FBody, th.OnSurface)
			y += 22
		}
		y += 12
		if u.Button(ID("phstart"), ui.Rect{X: x, Y: y, W: w, H: 42}, "Show the code", ui.ButtonOpt{Icon: ui.IPhone, HasIcon: true, Primary: true}) {
			a.startLink()
		}
		y += 54
		if p.err != "" {
			note(p.err, th.Danger)
			y += 6
		}
		note("Both must be on the same Wi-Fi (or the phone's hotspot). Files travel inside that network only, not over the internet; the connection is not encrypted, so use a network you trust.", th.OnSurfaceVariant)
		y = a.drawSync(x, y+14, w)
		sc.Content = y + sc.Y - body.Y + 12
		return
	}
	// the code, always dark on white so every camera reads it
	n := len(p.qr)
	side := min(w, 264)
	card := ui.Rect{X: body.CX() - side/2, Y: y, W: side, H: side}
	ui.FillRound(g, card, 22, ui.Hex("#ffffff"))
	if n > 0 {
		m := float32(int((side - 28) / float32(n+2)))
		if m < 2 {
			m = (side - 28) / float32(n+2)
		}
		// whole pixels, so the modules touch
		ox, oy := float32(int(card.CX()-m*float32(n)/2)), float32(int(card.CY()-m*float32(n)/2))
		ink := ui.Hex("#17131d")
		for yy := 0; yy < n; yy++ {
			for xx := 0; xx < n; xx++ {
				if !p.qr[yy][xx] {
					continue
				}
				run := 1
				for xx+run < n && p.qr[yy][xx+run] {
					run++
				}
				g.FillRect(ui.Rect{X: ox + float32(xx)*m, Y: oy + float32(yy)*m, W: m * float32(run), H: m}, ink)
				xx += run - 1
			}
		}
	}
	y += side + 12
	ui.TextCenter(g, "Scan with the phone's camera", ui.Rect{X: x, Y: y, W: w, H: 22}, ui.FBodyBold, th.OnSurface)
	y += 24
	status, col := "Waiting for the phone", th.OnSurfaceVariant
	if k := p.srv.Phones(); k == 1 {
		status, col = "A phone is connected", th.Primary
	} else if k > 1 {
		status, col = strconv.Itoa(k)+" devices are connected", th.Primary
	}
	ui.TextCenter(g, status, ui.Rect{X: x, Y: y, W: w, H: 18}, ui.FSmallBold, col)
	y += 24
	ur := ui.Rect{X: x, Y: y, W: w, H: 34}
	ui.FillRound(g, ur, 17, th.SurfaceHigh)
	ui.TextFit(g, p.srv.URL(), ur.X+14, ui.Mid(g, ur.Y, ur.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant, ur.W-58)
	if u.IconButton(ID("phcopy"), ui.Rect{X: ur.R() - 36, Y: ur.Y + 1, W: 32, H: 32}, ui.ICopy, "Copy the address", ui.IconOpt{}) {
		u.Clip.Set(p.srv.URL())
		a.notify("Address copied.")
	}
	y += 46

	g.Text("Send to the phone", x, y+14, ui.FSmallBold, th.Primary)
	y += 26
	bw := (w - 8) / 2
	if u.Button(ID("phpick"), ui.Rect{X: x, Y: y, W: bw, H: 38}, "Files", ui.ButtonOpt{Icon: ui.IFolder, HasIcon: true, Disabled: a.cfg.Sys.PickFiles == nil || p.picking}) {
		a.sharePick()
	}
	t := a.tab()
	if u.Button(ID("phpage"), ui.Rect{X: x + bw + 8, Y: y, W: bw, H: 38}, "This page", ui.ButtonOpt{Icon: ui.ISend, HasIcon: true, Disabled: !a.livePage(t), Tip: "Send this page's address"}) {
		title := t.Title
		if title == "" {
			title = core.Host(t.URL)
		}
		p.srv.ShareText(title, t.URL)
	}
	y += 46
	for _, it := range p.srv.Items() {
		row := ui.Rect{X: x, Y: y, W: w, H: 46}
		ui.FillRound(g, row, 14, th.SurfaceHigh)
		ic, sub := ui.IFolder, bytesText(it.Size)
		if it.Text != "" {
			ic, sub = ui.IGlobe, it.Text
		}
		ui.DrawIcon(g, ic, row.X+12, row.CY()-9, 18, th.Primary)
		ui.TextFit(g, it.Name, row.X+40, row.Y+19, ui.FBodyBold, th.OnSurface, row.W-82)
		ui.TextFit(g, sub, row.X+40, row.Y+36, ui.FSmall, th.OnSurfaceVariant, row.W-82)
		if u.IconButton(ui.IdN("phx", it.ID), ui.Rect{X: row.R() - 38, Y: row.CY() - 16, W: 32, H: 32}, ui.IClose, "Stop offering it", ui.IconOpt{}) {
			p.srv.Unshare(it.ID)
		}
		y += 52
	}
	if runtime.GOOS == "linux" {
		note("Choosing files uses the system's file box (zenity or kdialog).", th.OnSurfaceVariant)
	}
	y += 6
	g.Text("From the phone", x, y+14, ui.FSmallBold, th.Primary)
	y += 26
	note("What the phone sends is saved in your Downloads folder and listed with the downloads.", th.OnSurfaceVariant)
	y += 8
	if u.Button(ID("phdl"), ui.Rect{X: x, Y: y, W: w, H: 36}, "Open the downloads list", ui.ButtonOpt{Icon: ui.IDownload, HasIcon: true}) {
		a.togglePanel(panelDownloads)
	}
	y += 50
	y = a.drawSync(x, y, w)
	note("Both must be on the same Wi-Fi (or the phone's hotspot). The first time, Windows may ask whether Lite Go may be reached on the network: allow private networks. Files stay inside your network; the connection is not encrypted.", th.OnSurfaceVariant)
	y += 10
	if u.Button(ID("phstop"), ui.Rect{X: x, Y: y, W: w, H: 38}, "Close the link", ui.ButtonOpt{Icon: ui.IClose, HasIcon: true}) {
		a.stopLink()
	}
	y += 50
	sc.Content = y + sc.Y - body.Y + 8
}
