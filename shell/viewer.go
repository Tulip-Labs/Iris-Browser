package shell

import (
	"strings"

	"iris/core"
	"iris/webview"
)

// The side view: a page (a side app, a video) in a small web view of its own
// beside the tab; and Google sign-in.

// sideView is the web view shown beside the tab.
type sideView struct {
	view    webview.View
	making  bool
	url     string
	private bool
	shown   bool
	bounds  [4]int
	idle    float64
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

const signInURL = "https://accounts.google.com/ServiceLogin?hl=en&continue=https%3A%2F%2Fwww.google.com%2F%3Fhl%3Den%26iris%3Dsignedin"

// signIn opens Google's sign-in in tab t (the default container, which the
// results and the AI answers use).
func (a *App) signIn(t *Tab) {
	if t == nil || t.Kind != KNormal {
		t = a.newTab(KNormal, "", "", true)
	}
	t.Title = "Sign in to Google"
	a.navigate(t, signInURL)
}

// signedIn notices the end of the sign-in and turns the tab back into a new tab page.
func (a *App) signedIn(t *Tab, url string) bool {
	if !strings.Contains(url, "iris=signedin") || !strings.Contains(core.Host(url), "google.") {
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
