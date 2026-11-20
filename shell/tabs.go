package shell

import (
	"iris/shields"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"

	"iris/core"
	"iris/ui"
	"iris/webview"
)

// Kind is where a tab keeps its cookies and storage.
type Kind uint8

const (
	KNormal    Kind = iota // the default container
	KContainer             // a named container with its own sign-ins
	KPrivate               // all private tabs share one session, never written to disk
	KTemp                  // a fresh session for this tab alone, gone when it closes
	KSandbox               // a page that may be unsafe: its own throwaway session, no downloads, no permissions
)

// Tab is one tab; its page may be live, asleep or unloaded.
type Tab struct {
	ID        int
	Kind      Kind
	Container string
	URL       string
	Title     string

	Loading, CanBack, CanFwd bool
	Audio, Muted, Crashed    bool
	Blocked                  int

	view         webview.View
	bind         *binding
	making       bool
	asleep       bool
	shown        bool
	bounds       [4]int
	pending      string
	popup        *webview.Popup
	landing      string
	awaitLanding bool
	last         float64 // when it was last the current tab
	closed       bool
	zoom         float64 // 0 or 1 = the page's normal size
	background   bool    // the engine was told nobody is looking at it
	// adaptive shields: whether this page is being scanned, and what was found
	scanning bool
	scanURL  string
	hidden   int     // what the hiding rules matched
	loadedAt float64 // when the page finished loading (0 = not yet)
	// opener is the tab this one was opened from (results, another site):
	// Back from the first page, and closing it, return there
	opener *Tab
	// hydration: where the page was scrolled when it was let go, to restore
	scrollY int
	hydrate bool
	// when its sound last stopped
	audioEnd float64
}

// binding routes a view's events to its tab.
type binding struct{ t *Tab }

func (t *Tab) private() bool { return t.Kind == KPrivate || t.Kind == KTemp || t.Kind == KSandbox }

// Live says whether the tab holds a page in memory.
func (t *Tab) Live() bool { return t.view != nil }

func (a *App) tab() *Tab {
	if a.cur < 0 || a.cur >= len(a.tabs) {
		return nil
	}
	return a.tabs[a.cur]
}

func (a *App) options(t *Tab) webview.Options {
	switch t.Kind {
	case KContainer:
		return webview.Options{Profile: "c-" + strings.ToLower(t.Container)}
	case KPrivate:
		return webview.Options{Profile: "private", Private: true}
	case KTemp:
		return webview.Options{Profile: "temp-" + strconv.Itoa(t.ID), Private: true}
	case KSandbox:
		return webview.Options{Profile: "sandbox-" + strconv.Itoa(t.ID), Private: true, Sandbox: true}
	}
	return webview.Options{}
}

// newTab opens a tab after the current one (url "" shows the new tab page).
func (a *App) newTab(k Kind, container, url string, activate bool) *Tab {
	a.nextID++
	t := &Tab{ID: a.nextID, Kind: k, Container: container, last: a.now()}
	t.bind = &binding{t: t}
	at := min(a.cur+1, len(a.tabs))
	if len(a.tabs) == 0 {
		at = 0
	}
	a.tabs = append(a.tabs, nil)
	copy(a.tabs[at+1:], a.tabs[at:])
	a.tabs[at] = t
	if at <= a.cur && !activate {
		a.cur++
	}
	if activate {
		a.selectTab(at)
	}
	if url != "" {
		a.navigate(t, url)
	} else if activate {
		a.ntpQ.Set("")
		a.st.Focus = ID("ntp")
	}
	return t
}

// ID is a widget id.
func ID(s string) ui.ID { return ui.Id(s) }

func (a *App) selectTab(i int) {
	if i < 0 || i >= len(a.tabs) {
		return
	}
	old := a.tab()
	if old != nil {
		old.last = a.now()
	}
	a.cur = i
	t := a.tabs[i]
	t.last = a.now()
	if old != t {
		a.closeFind()
	}
	if a.st.Focus == ID("addr") || a.st.Focus == ID("ntp") {
		a.st.Focus = ui.ID{}
	}
	a.sugg = nil
	if t.URL == "" {
		a.ntpQ.Set("")
		a.st.Focus = ID("ntp")
	}
	if t.view == nil && t.URL != "" && !t.making {
		t.pending = t.URL
		a.ensureView(t)
	}
	if t.asleep && t.view != nil {
		v := t.view
		a.web(v.Wake)
		t.asleep = false
	}
	if v := t.view; v != nil && t.URL != "" {
		a.web(v.Focus) // the keyboard follows the page
	}
	a.prioritize()
	if a.full {
		a.full = false
		a.h.SetFullscreen(a.winFull)
	}
}

func (a *App) closeTab(i int) {
	if i < 0 || i >= len(a.tabs) {
		return
	}
	t := a.tabs[i]
	if t.URL != "" && !t.private() {
		a.closed = append(a.closed, closedTab{t.URL, t.Title, t.Kind, t.Container})
		if len(a.closed) > 25 {
			a.closed = a.closed[1:]
		}
	}
	a.finishScan(t)
	t.closed = true
	if t.view != nil {
		v := t.view
		if a.downloadingIn(v) {
			// its download goes on: hide the page, close it when the download ends
			a.web(func() { v.SetVisible(false) })
			a.keptPages = append(a.keptPages, v)
		} else {
			a.web(v.Close)
		}
		t.view = nil
	}
	if t == a.split.a || t == a.split.b {
		a.split.a, a.split.b = nil, nil
	}
	wasCur := i == a.cur
	a.tabs = append(a.tabs[:i], a.tabs[i+1:]...)
	if len(a.tabs) == 0 {
		a.cur = 0
		a.newTab(KNormal, "", "", true)
		return
	}
	if o := t.opener; wasCur && o != nil && !o.closed {
		// back to the tab it came from
		for j, x := range a.tabs {
			if x == o {
				a.cur = j
				a.selectTab(j)
				go debug.FreeOSMemory()
				return
			}
		}
	}
	if i < a.cur || a.cur >= len(a.tabs) {
		a.cur--
	}
	a.cur = max(0, min(a.cur, len(a.tabs)-1))
	a.selectTab(a.cur)
	go debug.FreeOSMemory() // the closed page's memory goes back at once
}

func (a *App) reopen() {
	if n := len(a.closed); n > 0 {
		c := a.closed[n-1]
		a.closed = a.closed[:n-1]
		t := a.newTab(c.kind, c.container, c.url, true)
		t.Title = c.title
	}
}

// navigate opens url in tab t.
func (a *App) navigate(t *Tab, url string) {
	if url == "" {
		return
	}
	if a.set.CleanLinks {
		url = shields.Clean(url)
	}
	if t.Kind != KSandbox {
		if up := core.HTTPSUpgrade(url); up != "" && a.set.HTTPSOnly && !a.allowedInsecure(url) {
			url = up
		}
		if core.Risk(url) != "" && !a.allowedInsecure(url) {
			a.insecure(t, url) // stopped before it loads; a sandbox can open it
			return
		}
	}
	t.hydrate, t.scrollY = false, 0
	t.URL, t.Loading, t.Crashed, t.Blocked = url, true, false, 0
	if q, ok := core.AIQuery(url); ok {
		t.Title = q // a search's tab is named by its words
	} else if t.Title == "" {
		t.Title = core.Display(url)
	}
	if t.view != nil {
		v := t.view
		a.web(func() { v.Navigate(url) })
		return
	}
	t.pending = url
	a.ensureView(t)
}

// ensureView gives t a page (made when it is needed, never ahead of time).
func (a *App) ensureView(t *Tab) {
	if t.view != nil || t.making || !a.ready || a.eng == nil {
		return
	}
	t.making = true
	o := a.options(t)
	o.Popup = t.popup
	t.popup = nil
	b := t.bind
	eng := a.eng
	ev := a.events(b)
	a.web(func() {
		eng.NewView(o, ev, func(v webview.View, err error) {
			if err == nil {
				v.SetVisible(false) // sync shows it in place
			}
			a.post(func() {
				t.making = false
				if err != nil {
					a.notify("The page could not open: " + err.Error())
					return
				}
				if t.closed {
					a.web(v.Close)
					return
				}
				a.attach(t, v)
			})
		})
	})
}

func (a *App) attach(t *Tab, v webview.View) {
	t.view, t.shown, t.asleep, t.bounds, t.background = v, false, false, [4]int{}, false
	if t.Muted {
		a.web(func() { v.SetMuted(true) })
	}
	if z := t.zoom; z != 0 && z != 1 {
		a.web(func() { v.SetZoom(z) })
	}
	if p := t.pending; p != "" {
		t.pending = ""
		a.web(func() { v.Navigate(p) })
	}
	if t == a.tab() && a.st.Focus != ID("addr") {
		a.web(v.Focus)
	}
}

// events wires a view's events to whichever tab the binding names.
func (a *App) events(b *binding) webview.Events {
	on := func(f func(t *Tab)) {
		a.post(func() {
			if t := b.t; t != nil && !t.closed {
				f(t)
			}
		})
	}
	return webview.Events{
		Menu: func(m *webview.Menu) { a.post(func() { a.openMenu(m) }) },
		URL: func(url string) {
			on(func(t *Tab) {
				if url == "about:blank" && t.URL == "" {
					return
				}
				if a.signedIn(t, url) {
					return
				}
				t.URL = url
				if t.awaitLanding {
					t.landing, t.awaitLanding = url, false
				}
				if !t.private() {
					a.hist.Add(url, "", true)
				}
				a.startScan(t, url)
				a.hideSite(t, url)
				a.offerExtension(t, url)
				if t == a.tab() && a.st.Focus != ID("addr") {
					a.addr.Set(url)
				}
			})
		},
		Title: func(title string) {
			on(func(t *Tab) {
				if q, ok := core.AIQuery(t.URL); ok {
					title = q // Google's title repeats Iris's instruction
				}
				t.Title = title
				if !t.private() {
					a.hist.Add(t.URL, title, false)
				}
			})
		},
		Loading: func(l bool) {
			on(func(t *Tab) {
				if t.Loading && !l {
					t.loadedAt = a.now()
					a.startScan(t, t.URL) // when the address arrived before the load began
					a.hideGeneric(t, 0)
					if z, v := t.zoom, t.view; z != 0 && z != 1 && v != nil {
						a.web(func() { v.SetZoom(z) })
					}
					if t.hydrate {
						// back where it was before it rested
						t.hydrate = false
						if y, v := t.scrollY, t.view; y > 0 && v != nil {
							js := "window.scrollTo(0," + strconv.Itoa(y) + ")"
							a.web(func() { v.Eval(js) })
						}
					}
				}
				t.Loading = l
				if l {
					a.finishScan(t)
					t.Blocked, t.hidden, t.loadedAt = 0, 0, 0
				}
			})
		},
		History: func(b, f bool) { on(func(t *Tab) { t.CanBack, t.CanFwd = b, f }) },
		Audio: func(p bool) {
			on(func(t *Tab) {
				if t.Audio && !p {
					t.audioEnd = a.now() // paused: it may play on, so it stays a while
				}
				t.Audio = p
			})
		},
		Blocked:  func(string) { on(func(t *Tab) { t.Blocked++; a.blockedTotal++ }) },
		Crashed:  func() { on(func(t *Tab) { t.Crashed = true; t.Loading = false; t.scanning = false }) },
		Focus:    func() { on(func(t *Tab) { a.pageFocused(t) }) },
		Failed:   func(string, int) { on(func(t *Tab) { t.Loading = false }) },
		Insecure: func(url string) { on(func(t *Tab) { a.insecure(t, url) }) },
		Fullscreen: func(f bool) {
			on(func(t *Tab) {
				if t == a.tab() {
					a.full = f
					a.h.SetFullscreen(f || a.winFull)
				}
			})
		},
		NewTab: func(url string, p *webview.Popup) {
			on(func(t *Tab) {
				if p == nil { // a link to another website: a new tab of its own
					n := a.newTab(t.Kind, t.Container, url, true)
					n.opener = t
					return
				}
				n := a.newTab(t.Kind, t.Container, "", true)
				n.popup = p
				n.URL, n.Title, n.Loading = url, core.Display(url), true
				a.ensureView(n)
			})
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
}

func (a *App) allowedInsecure(url string) bool {
	a.insecureMu.Lock()
	defer a.insecureMu.Unlock()
	return a.insecureOK[core.Host(url)]
}

// insecure tells the reader a page was stopped (no secure connection, or an
// address that looks unsafe) and offers to open it in a sandbox: a throwaway
// session that can download nothing, is given no permission and keeps nothing.
func (a *App) insecure(t *Tab, url string) {
	host := core.Host(url)
	t.Loading = false
	text := host + " has no secure connection: what you send and read there can be seen and changed on the way."
	if why := core.Risk(url); why != "" {
		text = host + " looks unsafe: " + why + "."
	}
	a.bar = infobar{warn: true, text: text, action: "Open in a sandbox",
		do:      func() { a.openSandbox(t, url) },
		action2: "Trust it",
		do2: func() {
			a.insecureMu.Lock()
			a.insecureOK[host] = true
			a.insecureMu.Unlock()
			if !t.closed {
				a.navigate(t, url)
			}
		}}
}

// openSandbox opens url in a sandbox tab: tab t itself when it holds nothing
// else, or a new tab beside it.
func (a *App) openSandbox(t *Tab, url string) {
	if t.closed || t.view != nil && t.URL != url && t.URL != "" {
		a.newTab(KSandbox, "", url, true)
		return
	}
	a.unload(t)
	t.Kind, t.Container = KSandbox, ""
	t.URL, t.Title = "", ""
	a.navigate(t, url)
	if t == a.tab() {
		a.addr.Set(url)
		a.st.Focus = ui.ID{}
	}
}

// tick applies the memory plan to background tabs and refreshes the memory readout.
func (a *App) tick() {
	now := a.now()
	if now-a.lastMem >= 2 && a.ready && a.eng != nil {
		a.lastMem = now
		eng, self, free := a.eng, a.cfg.SelfMB, a.cfg.Sys.FreeMB
		a.web(func() { // runs on the window thread while the loop waits
			a.memMB = eng.MemoryMB()
			if self != nil {
				a.appMB = self()
			}
			if free != nil {
				a.balance.freeMB = free()
			}
		})
	}
	if now-a.lastTick < 4 {
		return
	}
	a.lastTick = now
	a.trimThumbs(45)
	if now-a.lastFree > 30 {
		// hand freed memory back to Windows (the heap is small; this is quick)
		a.lastFree = now
		go debug.FreeOSMemory()
	}
	cur := a.tab()
	other, _ := a.splitWith()
	a.settleScans()
	a.rebalance()
	a.updateTick()
	live := 0
	for _, t := range a.tabs {
		if t.view == nil || t == cur || t == other {
			continue
		}
		live++
		idle := now - t.last
		if !t.asleep && !a.keepAwake(t) && idle > a.plan.SleepAfter {
			v := t.view
			a.web(v.Sleep)
			t.asleep, t.shown = true, false
		}
		if idle > a.plan.UnloadAfter && !a.keepAwake(t) && !t.private() {
			a.unload(t)
			live--
		}
	}
	for live+1 > a.plan.Live {
		var lru *Tab
		for _, t := range a.tabs {
			if t.view != nil && t != cur && t != other && !a.keepAwake(t) && !t.private() && (lru == nil || t.last < lru.last) {
				lru = t
			}
		}
		if lru == nil {
			break
		}
		a.unload(lru)
		live--
	}
}

// unload lets a background page go (its memory goes back to the system),
// keeping what brings it back as it was: the address, the title and how far
// it was scrolled (hydration).
func (a *App) unload(t *Tab) {
	if t.view == nil || a.downloadingIn(t.view) {
		return
	}
	a.finishScan(t)
	v := t.view
	t.view, t.asleep, t.shown, t.Loading, t.background = nil, false, false, false, false
	if t.URL == "" || t.Crashed {
		a.web(v.Close)
		return
	}
	t.hydrate = true
	var once sync.Once
	closeIt := func() { once.Do(func() { a.post(func() { a.web(v.Close) }) }) }
	a.web(func() {
		v.Run("Math.round(window.scrollY)", func(res string) {
			if n, err := strconv.Atoi(strings.TrimSpace(res)); err == nil && n > 0 {
				a.post(func() { t.scrollY = n })
			}
			closeIt()
		})
		time.AfterFunc(1500*time.Millisecond, closeIt) // a page that does not answer still goes
	})
}

// FreeMemory puts every background tab to sleep now and unloads the ones that can be reopened.
func (a *App) FreeMemory() {
	cur := a.tab()
	other, _ := a.splitWith()
	n := 0
	for _, t := range a.tabs {
		if t.view == nil || t == cur || t == other || a.keepAwake(t) {
			continue
		}
		if t.private() {
			if !t.asleep {
				v := t.view
				a.web(v.Sleep)
				t.asleep, t.shown = true, false
			}
		} else {
			a.unload(t)
		}
		n++
	}
	for _, w := range a.workers {
		if w != nil && w.view != nil && w.cur == nil && len(w.queue) == 0 {
			v := w.view
			a.web(v.Close)
			w.view = nil
		}
	}
	a.trimThumbs(0)
	go debug.FreeOSMemory()
	if n == 0 {
		a.notify("Only the open tab holds a page right now.")
	} else {
		a.notify("Freed " + strconv.Itoa(n) + " background tab" + plural(n) + ". They reopen when you click them.")
	}
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// sync shows the current page in rect page (and, in split view, the page of
// other in rect beside) and hides the rest.
func (a *App) sync(page, beside ui.Rect, other *Tab) {
	cur := a.tab()
	for _, t := range a.tabs {
		if t.view == nil {
			continue
		}
		r := page
		if t == other {
			r = beside
		}
		want := (t == cur || t == other) && t.URL != "" && !t.Crashed && !r.Empty()
		if want {
			s := a.Scale
			b := [4]int{int(r.X*s + 0.5), int(r.Y*s + 0.5), int(r.W*s + 0.5), int(r.H*s + 0.5)}
			if b != t.bounds {
				t.bounds = b
				v := t.view
				a.web(func() { v.SetBounds(b[0], b[1], b[2], b[3]) })
			}
		}
		if t.shown != want {
			t.shown = want
			v := t.view
			a.web(func() { v.SetVisible(want) })
		}
	}
}

// Counts reports tabs holding a page, asleep, and unloaded.
func (a *App) Counts() (live, asleep, unloaded int) {
	for _, t := range a.tabs {
		switch {
		case t.view != nil && t.asleep:
			asleep++
		case t.view != nil:
			live++
		case t.URL != "":
			unloaded++
		}
	}
	return
}

// visitFromResults opens a link from the results in a new tab beside them
// (Ctrl keeps it in the background); the results stay where they are.
func (a *App) visitFromResults(url string) {
	t := a.tab()
	if t == nil {
		return
	}
	n := a.newTab(t.Kind, t.Container, url, !a.In.Ctrl)
	n.opener = t
}

// back goes back in the page, or from the first page of a tab opened from
// another to that one.
func (a *App) back(t *Tab) {
	if !t.CanBack && t.opener != nil && !t.opener.closed {
		// the first page of a tab opened from another: Back returns there
		for i, x := range a.tabs {
			if x == t {
				a.closeTab(i)
				break
			}
		}
		return
	}
	if v := t.view; v != nil {
		a.web(v.Back)
	}
}

// forward goes forward in the page.
func (a *App) forward(t *Tab) {
	if v := t.view; v != nil {
		a.web(v.Forward)
	}
}

func (t *Tab) canBack() bool {
	return t.CanBack || t.opener != nil && !t.opener.closed
}

func (t *Tab) canForward() bool { return t.CanFwd }

// addrText is what the address bar edits: the words of an AI Mode search, or
// the address.
func (t *Tab) addrText() string {
	if q, ok := core.AIQuery(t.URL); ok {
		return q
	}
	return t.URL
}
