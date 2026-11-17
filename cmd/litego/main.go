// Command litego is Lite Go: a light browser whose interface is drawn with Gio
// and whose pages are shown by the system web view: WebView2 on Windows,
// Chromium (CEF) on Linux.
package main

import (
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"

	"litego/giox"
	"litego/shell"
)

const version = "1.0.10"

func main() {
	// a small, steady footprint: collect garbage sooner and keep the Go heap
	// under a soft ceiling (pages live in WebView2's own processes)
	debug.SetGCPercent(50)
	debug.SetMemoryLimit(128 << 20)
	background := false
	var urls []string
	for _, a := range os.Args[1:] {
		switch {
		case a == "--background":
			background = true
		case !strings.HasPrefix(a, "-"):
			urls = append(urls, a)
		}
	}
	conf, webDir := dirs()
	// Lite Go runs once: a second launch hands its addresses to the running one,
	// whose window then appears at once (it is already loaded).
	if background && running(conf) {
		return // already ready
	}
	if !background && handOff(conf, urls) {
		return
	}
	reqs := listen(conf)
	r := &resident{conf: conf, webDir: webDir, core: shell.LoadCore(conf), gfx: giox.NewGfx()}
	if r.core.Settings.Boost {
		// nothing runs in the background any more: undo "Open instantly"
		r.core.Settings.Boost = false
		r.core.Settings.Save()
		setStartup(false)
	}
	if background {
		return
	}
	go func() {
		if !background {
			r.open(urls)
		}
		for req := range reqs {
			if len(req) == 1 && req[0] == "--quit" { // the setup is updating Lite Go
				r.core.Settings.Flush()
				os.Exit(0)
			}
			r.open(req)
		}
	}()
	runMain()
}

// resident is the running Lite Go: what stays loaded between windows.
type resident struct {
	conf, webDir string
	core         *shell.Core
	gfx          *giox.Gfx
	mu           sync.Mutex
	cur          *shell.App
	host         *host
	opening      bool
}

// open shows the window (making it if needed) with urls in new tabs.
func (r *resident) open(urls []string) {
	r.mu.Lock()
	a, h := r.cur, r.host
	if a == nil && r.opening {
		r.mu.Unlock()
		return // the window is being made
	}
	r.opening = a == nil
	r.mu.Unlock()
	if a != nil {
		a.Do(func() {
			if len(urls) == 0 {
				a.NewTab()
			}
			for _, u := range urls {
				a.OpenURL(u)
			}
			h.raise()
		})
		return
	}
	r.window(urls)
}

// shown records the window's app once it exists.
func (r *resident) shown(a *shell.App, h *host) {
	r.mu.Lock()
	r.cur, r.host, r.opening = a, h, false
	r.mu.Unlock()
}

// closed runs when the window is gone: Lite Go exits, or stays resident
// (Open instantly) with only its small loaded part.
func (r *resident) closed() {
	r.mu.Lock()
	r.cur, r.host, r.opening = nil, nil, false
	r.mu.Unlock()
	r.core.Settings.Flush()
	os.Exit(0) // Lite Go keeps nothing running once its window closes
}

type pendingClip struct{ text *string }

func (c *pendingClip) Set(s string) { c.text = &s }

// dirs: settings and history in the config folder, the web engine's cache in the local cache folder.
func dirs() (conf, web string) {
	base, err := os.UserConfigDir()
	if err != nil {
		base = "."
	}
	conf = filepath.Join(base, "Lite Go")
	cache, err := os.UserCacheDir()
	if err != nil {
		cache = base
	}
	web = filepath.Join(cache, "Lite Go", "Web")
	_ = os.MkdirAll(conf, 0o755)
	_ = os.MkdirAll(web, 0o755)
	return
}
