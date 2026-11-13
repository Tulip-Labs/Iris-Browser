package shell

import (
	"encoding/json"
	"time"

	"litego/core"
	"litego/shields"
)

// Hiding what ads leave behind (Lite Shields' cosmetic filtering): a page gets
// its site's rules as it starts, then the generic rules that match its own
// classes and ids once it has loaded, and again a little later for what it
// added by itself.

func (a *App) shieldsOn(url string) bool {
	return a.shield.On && !a.siteOff(core.Host(url)) && (a.set.Lists || a.set.Cookies)
}

func (a *App) hideSite(t *Tab, url string) {
	f := a.core.Filters.Load()
	v := t.view
	if f == nil || v == nil || !a.shieldsOn(url) {
		return
	}
	if sels := f.SiteSelectors(url); len(sels) > 0 {
		t.hidden += len(sels)
		js := shields.InjectCSS(shields.HideCSS(sels))
		a.web(func() { v.Eval(js) })
	}
}

// hideGeneric reads the page's classes and ids and hides the matching ads;
// round counts the later passes.
func (a *App) hideGeneric(t *Tab, round int) {
	f := a.core.Filters.Load()
	v, url := t.view, t.URL
	if f == nil || v == nil || !a.shieldsOn(url) {
		return
	}
	if !t.scanning && a.set.Adaptive && !a.scan.Need(url) {
		return // adaptive shields: this site was scanned and has nothing to hide
	}
	a.web(func() {
		v.Run(shields.CollectScript, func(js string) {
			var got struct{ C, I []string }
			if json.Unmarshal([]byte(js), &got) != nil {
				return
			}
			sels := f.GenericSelectors(url, got.C, got.I)
			a.post(func() {
				if t.closed || t.view != v || t.URL != url {
					return
				}
				if len(sels) > 0 {
					t.hidden += len(sels)
					css := shields.InjectCSS(shields.HideCSS(sels))
					a.web(func() { v.Eval(css) })
				}
				if round < 2 {
					// pages keep adding things after they load
					time.AfterFunc(time.Duration(2+round*4)*time.Second, func() {
						a.post(func() {
							if !t.closed && t.view == v && t.URL == url {
								a.hideGeneric(t, round+1)
							}
						})
					})
				}
			})
		})
	})
}
