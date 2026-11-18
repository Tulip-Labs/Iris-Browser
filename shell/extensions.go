package shell

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"iris/ext"
	"iris/ui"
	"iris/webview"
)

// Browser extensions, from the Chrome Web Store. On a store page Iris offers
// to add the extension: it downloads the package from Google, checks its
// signature (ext.Verify), unpacks it into the settings folder and loads it
// into the engine. Only engines that run extensions offer this (WebView2 on
// Windows); on Linux the menu says why it is not there yet.

const storeHome = "https://chromewebstore.google.com/category/extensions"

type extState struct {
	list    []webview.Extension
	loaded  bool
	loading bool
	busy    string // the id being added or removed
	offered string // the store page last offered (asked once per page)
}

func (a *App) extHost() webview.ExtensionHost {
	if h, ok := a.eng.(webview.ExtensionHost); ok {
		return h
	}
	return nil
}

func (a *App) extDir(id string) string {
	if a.cfg.DataDir == "" || !ext.ValidID(id) {
		return ""
	}
	return filepath.Join(a.cfg.DataDir, "Extensions", id)
}

// loadExtensions asks the engine for its extensions (once, and after changes).
func (a *App) loadExtensions() {
	h := a.extHost()
	if h == nil || a.ext.loading {
		return
	}
	a.ext.loading = true
	a.web(func() {
		h.Extensions(func(list []webview.Extension, err error) {
			a.post(func() {
				a.ext.loading, a.ext.loaded = false, true
				if err == nil {
					a.ext.list = list
				}
			})
		})
	})
}

func (a *App) hasExtension(id string) bool {
	for _, x := range a.ext.list {
		if x.ID == id {
			return true
		}
	}
	return false
}

// offerExtension shows "Add to Iris" on a Chrome Web Store extension page.
func (a *App) offerExtension(t *Tab, url string) {
	id := ext.StoreID(url)
	if id == "" || t != a.tab() || t.private() || a.extHost() == nil || a.ext.offered == url {
		return
	}
	a.ext.offered = url
	if !a.ext.loaded {
		a.loadExtensions()
	}
	if a.hasExtension(id) {
		a.bar = infobar{text: "This extension is in Iris.", action: "Manage", until: a.now() + 6, do: func() { a.openSettings("extensions") }}
		return
	}
	a.bar = infobar{text: "Add this extension to Iris? It will see and change the pages it asks for.", action: "Add to Iris",
		do: func() { a.installExtension(id) }}
}

// installExtension fetches, checks, unpacks and loads extension id.
func (a *App) installExtension(id string) {
	h, dir := a.extHost(), a.extDir(id)
	if h == nil || dir == "" || a.ext.busy != "" {
		return
	}
	a.ext.busy = id
	a.notify("Adding the extension…")
	ver := chromeVersion(a.eng.Version())
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		zip, err := ext.Fetch(ctx, &http.Client{Timeout: 90 * time.Second}, id, ver)
		var m ext.Manifest
		if err == nil {
			m, err = ext.Unpack(zip, dir)
		}
		a.post(func() {
			if err != nil {
				a.ext.busy = ""
				a.notify("Could not add the extension: " + err.Error())
				return
			}
			a.web(func() {
				h.AddExtension(dir, func(x webview.Extension, err error) {
					a.post(func() {
						a.ext.busy = ""
						if err != nil {
							os.RemoveAll(dir)
							a.notify("Could not add " + m.Name + ": " + err.Error())
							return
						}
						a.notify(m.Name + " is added. Reload a page for it to work there.")
						a.loadExtensions()
					})
				})
			})
		})
	}()
}

func (a *App) removeExtension(x webview.Extension) {
	h := a.extHost()
	if h == nil || a.ext.busy != "" {
		return
	}
	a.ext.busy = x.ID
	a.web(func() {
		h.RemoveExtension(x.ID, func(err error) {
			a.post(func() {
				a.ext.busy = ""
				if err != nil {
					a.notify("Could not remove " + x.Name + ": " + err.Error())
					return
				}
				if d := a.extDir(x.ID); d != "" {
					os.RemoveAll(d)
				}
				a.notify(x.Name + " is removed.")
				a.loadExtensions()
			})
		})
	})
}

func (a *App) enableExtension(x webview.Extension, on bool) {
	h := a.extHost()
	if h == nil {
		return
	}
	for i := range a.ext.list {
		if a.ext.list[i].ID == x.ID {
			a.ext.list[i].Enabled = on // at once; the engine follows
		}
	}
	a.web(func() {
		h.EnableExtension(x.ID, on, func(err error) {
			a.post(func() {
				if err != nil {
					a.notify("Could not change " + x.Name + ": " + err.Error())
					a.loadExtensions()
				}
			})
		})
	})
}

// chromeVersion is the Chromium version the store is told (WebView2 reports
// Edge's, which shares Chromium's major version).
func chromeVersion(v string) string {
	if i := strings.IndexByte(v, '.'); i > 0 && i < 4 {
		return v[:i] + ".0.0.0"
	}
	return "140.0.0.0"
}

// extensionSettings is the Extensions section of the menu.
func (a *App) extensionSettings(x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	note := func(s string) {
		for _, ln := range wrap(g, s, ui.FSmall, w) {
			g.Text(ln, x, y+14, ui.FSmall, th.OnSurfaceVariant)
			y += 18
		}
	}
	y += 6
	if a.extHost() == nil {
		note("Extensions run in Iris on Windows. On Linux, Iris draws pages with Chromium off screen (sharp and light on Wayland), and Chromium's extension system does not run that way yet. Iris's shield blocks ads and trackers meanwhile.")
		return y + 6
	}
	if !a.ext.loaded {
		a.loadExtensions()
	}
	if u.Button(ID("extstore"), ui.Rect{X: x, Y: y, W: w, H: 38}, "Get extensions from the Chrome Web Store", ui.ButtonOpt{Icon: ui.IPuzzle, HasIcon: true}) {
		a.newTab(KNormal, "", storeHome, true)
	}
	y += 46
	switch {
	case !a.ext.loaded:
		note("Loading…")
	case len(a.ext.list) == 0:
		note("No extensions yet. On an extension's page in the store, Iris offers to add it.")
	}
	for i, xt := range a.ext.list {
		row := ui.Rect{X: x, Y: y, W: w, H: 40}
		nv := u.Checkbox(ui.IdN("extOn", i), ui.Rect{X: row.X, Y: row.Y, W: row.W - 44, H: row.H}, xt.Name, xt.Enabled)
		if nv != xt.Enabled {
			a.enableExtension(xt, nv)
		}
		if u.IconButton(ui.IdN("extDel", i), ui.Rect{X: row.R() - 38, Y: row.CY() - 17, W: 34, H: 34}, ui.IClose, "Remove "+xt.Name, ui.IconOpt{Disabled: a.ext.busy != ""}) {
			a.removeExtension(xt)
		}
		y += 42
	}
	note("Extensions work in normal tabs. Private, sandbox and container tabs run without them.")
	return y + 6
}
