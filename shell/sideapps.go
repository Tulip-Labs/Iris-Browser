package shell

import (
	"math"

	"litego/ui"
	"litego/webview"
)

// A side app is a website kept in the side panel, beside whatever page is
// open: it stays signed in and keeps its place while the panel is closed.
// Lite Go comes with two: Muse (Meta's AI agent) and Proton Pass (passwords).
// They are the sites themselves, shown in a narrow view; Lite Go adds nothing
// to them and reads nothing from them.
type sideApp struct {
	id, name, url, tip string
	icon               ui.Icon
	view               webview.View
	making, shown      bool
	started            bool
	bounds             [4]int
	hiddenAt           float64
}

func defaultSideApps() []*sideApp {
	return []*sideApp{
		{id: "muse", name: "Muse", url: "https://www.meta.ai/", icon: ui.IStar, tip: "Muse, Meta's AI agent, beside the page  Ctrl+Shift+M"},
		{id: "pass", name: "Proton Pass", url: "https://pass.proton.me/", icon: ui.ILock, tip: "Proton Pass, your passwords, beside the page"},
	}
}

func (a *App) openSideApp(i int) {
	if i < 0 || i >= len(a.apps) {
		return
	}
	if a.panel && a.panelMode == panelApp && a.appCur == i {
		a.panel = false
		return
	}
	a.panel, a.panelMode, a.appCur = true, panelApp, i
	a.ai.open = false
}

// drawSideApp lays out the panel of the current side app; the site itself is
// placed over a.appRect by syncApps.
func (a *App) drawSideApp(body ui.Rect, header ui.Rect) {
	u, th := &a.u, a.u.Th
	app := a.apps[a.appCur]
	bx := header.R() - 48 - 36
	if u.IconButton(ID("appopen"), ui.Rect{X: bx, Y: header.CY() - 18, W: 36, H: 36}, ui.IExternal, "Open in a tab", ui.IconOpt{}) {
		a.newTab(KNormal, "", app.url, true)
		a.panel = false
	}
	bx -= 38
	if u.IconButton(ID("appreload"), ui.Rect{X: bx, Y: header.CY() - 18, W: 36, H: 36}, ui.IReload, "Reload", ui.IconOpt{Disabled: app.view == nil}) {
		if v := app.view; v != nil {
			a.web(v.Reload)
		}
	}
	r := ui.Rect{X: body.X + 8, Y: body.Y, W: body.W - 16, H: body.H - 4}
	ui.FillRound(u.G, r, 12, pageColor(th))
	switch {
	case a.engErr != nil || a.eng == nil:
		ui.TextCenter(u.G, "The web view is not available.", ui.Rect{X: r.X, Y: r.CY() - 10, W: r.W, H: 20}, ui.FBody, th.OnSurfaceVariant)
	case app.view == nil:
		ph := float32(math.Mod(a.now()*360, 360))
		ui.Pen(u.G, ui.NewPath().Arc(r.CX(), r.CY(), 14, ph, ph+100, true), 3, th.Primary)
		u.Redraw = true
	}
	a.appRect = r
}

// syncApps shows the current side app over its place in the panel, hides
// the others, and closes one that has been out of sight for a long while.
func (a *App) syncApps() {
	for i, app := range a.apps {
		want := a.panel && a.panelMode == panelApp && a.appCur == i && !a.Fullscreen() && !a.appRect.Empty()
		if !want {
			if v := app.view; v != nil {
				if app.shown {
					app.shown, app.hiddenAt = false, a.now()
					a.web(func() { v.SetVisible(false) })
				}
				// kept for a while, so coming back is instant; then its memory is given back
				if a.now()-app.hiddenAt > 900 {
					a.web(v.Close)
					app.view, app.started = nil, false
				}
			}
			continue
		}
		if app.view == nil {
			if !app.making && a.ready && a.eng != nil {
				app.making = true
				app := app
				eng := a.eng
				ev := webview.Events{
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
					eng.NewView(webview.Options{}, ev, func(v webview.View, err error) {
						if err == nil {
							v.SetVisible(false)
						}
						a.post(func() {
							app.making = false
							if err == nil {
								app.view, app.shown, app.bounds, app.started = v, false, [4]int{}, false
							}
						})
					})
				})
			}
			continue
		}
		v := app.view
		if !app.started {
			app.started = true
			u := app.url
			a.web(func() { v.Navigate(u) })
		}
		r, sc := a.appRect, a.Scale
		b := [4]int{int(r.X*sc + 0.5), int(r.Y*sc + 0.5), int(r.W*sc + 0.5), int(r.H*sc + 0.5)}
		if b != app.bounds {
			app.bounds = b
			a.web(func() { v.SetBounds(b[0], b[1], b[2], b[3]) })
		}
		if !app.shown {
			app.shown = true
			a.web(func() { v.SetVisible(true); v.Focus() })
		}
	}
	a.appRect = ui.Rect{}
}

func (a *App) closeApps() {
	for _, app := range a.apps {
		if v := app.view; v != nil {
			a.web(v.Close)
			app.view = nil
		}
	}
}
