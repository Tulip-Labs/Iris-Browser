package shell

import (
	"time"

	"litego/core"
	"litego/link"
	"litego/ui"
)

// Sync with Lite for Android: history, open tabs and the palette, traded
// directly on the local network whenever the phone is there (see link/sync.go).

func (a *App) startSync() {
	s := &a.set.Sync
	if !s.On || a.syncSrv != nil {
		return
	}
	if s.Key == "" || s.Device == "" {
		s.Key, s.Device = link.NewKey(), link.NewKey()[:16]
		a.set.Save()
	}
	srv, err := link.StartSync(s.Key, s.Device, func(in link.State) link.State {
		// the phone is talking to a server goroutine: answer from the loop
		reply := make(chan link.State, 1)
		a.post(func() { reply <- a.exchange(in) })
		select {
		case out := <-reply:
			return out
		case <-time.After(5 * time.Second):
			return link.State{Device: s.Device}
		}
	})
	if err != nil {
		a.syncErr = "Sync could not start: " + err.Error() + "."
		return
	}
	a.syncSrv, a.syncErr = srv, ""
	a.pairing()
}

func (a *App) stopSync() {
	if a.syncSrv != nil {
		a.syncSrv.Stop()
		a.syncSrv = nil
	}
	a.pairing()
}

// pairing puts (or takes away) the "Pair with Lite" button on the phone's page.
func (a *App) pairing() {
	if a.phone.srv == nil {
		return
	}
	if a.syncSrv != nil {
		a.phone.srv.SetPairing(link.PairURL(a.syncSrv.Port(), a.set.Sync.Key, a.set.Sync.Device))
	} else {
		a.phone.srv.SetPairing("")
	}
}

// exchange takes what the phone knows and answers with what this computer knows.
func (a *App) exchange(in link.State) link.State {
	s := &a.set.Sync
	for _, v := range in.History {
		a.hist.Merge(v.URL, v.Title, v.Visits, time.Unix(v.Last, 0))
	}
	a.histFor = "\x00" // the history list is read again
	var peer *core.Peer
	for i := range s.Peers {
		if s.Peers[i].ID == in.Device {
			peer = &s.Peers[i]
		}
	}
	if peer == nil {
		s.Peers = append(s.Peers, core.Peer{ID: in.Device})
		peer = &s.Peers[len(s.Peers)-1]
		a.notify(in.Name + " is now in sync with this computer.")
	}
	peer.Name, peer.Seen, peer.Tabs = in.Name, time.Now().Unix(), nil
	for i, t := range in.Tabs {
		if i < 100 && t.URL != "" {
			peer.Tabs = append(peer.Tabs, core.SessionTab{URL: t.URL, Title: t.Title})
		}
	}
	if in.ThemeAt > a.set.ThemeAt && ui.ThemeByID(in.Theme).ID == in.Theme {
		a.set.Theme, a.set.ThemeAt = in.Theme, in.ThemeAt
	}
	a.set.Save()

	out := link.State{Device: s.Device, Theme: a.set.Theme, ThemeAt: a.set.ThemeAt}
	for _, t := range a.tabs {
		if !t.private() && t.URL != "" && t.search == nil {
			out.Tabs = append(out.Tabs, link.Tab{URL: t.URL, Title: t.Title})
		}
	}
	for _, e := range a.hist.Recent(500, "") {
		out.History = append(out.History, link.Visit{URL: e.URL, Title: e.Title, Visits: e.Visits, Last: e.Last.Unix()})
	}
	return out
}

// drawSync is the sync part of the phone panel; it returns the new y.
func (a *App) drawSync(x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	s := &a.set.Sync
	g.Text("Sync with Lite for Android", x, y+14, ui.FSmallBold, th.Primary)
	y += 24
	if v := u.Checkbox(ID("syncon"), ui.Rect{X: x, Y: y, W: w, H: 36}, "Keep history, tabs and palette in sync", s.On); v != s.On {
		s.On = v
		a.set.Save()
		if v {
			a.startSync()
		} else {
			a.stopSync()
			s.Key, s.Peers = "", nil // the next time is a new key: phones pair again
			a.set.Save()
		}
	}
	y += 38
	note := func(t string, c ui.Color) {
		for _, ln := range wrap(g, t, ui.FSmall, w) {
			g.Text(ln, x, y+14, ui.FSmall, c)
			y += 18
		}
	}
	if !s.On {
		note("Nothing passes through a server: the phone and this computer trade directly, sealed with a key only they have, whenever both are on the same network.", th.OnSurfaceVariant)
		return y + 8
	}
	if a.syncErr != "" {
		note(a.syncErr, th.Danger)
		return y + 8
	}
	if len(s.Peers) == 0 {
		note("To pair: install Lite on the phone, scan the code above with the phone's camera, and tap \"Pair with Lite\" on the page that opens.", th.OnSurfaceVariant)
		return y + 8
	}
	drop := -1
	for i, p := range s.Peers {
		row := ui.Rect{X: x, Y: y, W: w, H: 46}
		ui.FillRound(g, row, 14, th.SurfaceHigh)
		ui.DrawIcon(g, ui.IPhone, row.X+12, row.CY()-9, 18, th.Primary)
		ui.TextFit(g, p.Name, row.X+40, row.Y+19, ui.FBodyBold, th.OnSurface, row.W-82)
		ui.TextFit(g, "Synced "+ago(time.Unix(p.Seen, 0)), row.X+40, row.Y+36, ui.FSmall, th.OnSurfaceVariant, row.W-82)
		if u.IconButton(ui.IdN("syncx", i), ui.Rect{X: row.R() - 38, Y: row.CY() - 16, W: 32, H: 32}, ui.IClose, "Forget this phone's tabs", ui.IconOpt{}) {
			drop = i
		}
		y += 52
		for j, t := range p.Tabs {
			if j >= 12 {
				break
			}
			tr := ui.Rect{X: x, Y: y, W: w, H: 30}
			if u.Hover(tr) {
				ui.FillRound(g, tr, 10, th.Ink.Alpha(0.06))
			}
			label := t.Title
			if label == "" {
				label = core.Host(t.URL)
			}
			ui.DrawIcon(g, ui.IGlobe, tr.X+10, tr.CY()-8, 16, th.OnSurfaceVariant)
			ui.TextFit(g, label, tr.X+34, ui.Mid(g, tr.Y, tr.H, ui.FSmall), ui.FSmall, th.OnSurface, tr.W-44)
			u.Tooltip(t.URL, tr)
			if u.Clickable(ui.IdN("synctab", i*1000+j), tr) {
				a.newTab(KNormal, "", t.URL, true)
			}
			y += 30
		}
		y += 6
	}
	if drop >= 0 {
		s.Peers = append(s.Peers[:drop], s.Peers[drop+1:]...)
		a.set.Save()
	}
	note("To stop a phone from syncing, turn sync off here and on again: that makes a new key, and phones must pair again.", th.OnSurfaceVariant)
	return y + 8
}
