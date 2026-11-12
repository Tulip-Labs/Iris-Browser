package shell

import (
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
	"litego/webview"
)

// Kind is where a tab keeps its cookies and storage.
type Kind uint8

const (
	KNormal    Kind = iota // the default container
	KContainer             // a named container with its own sign-ins
	KPrivate               // all private tabs share one session, never written to disk
	KTemp                  // a fresh session for this tab alone, gone when it closes
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

	view    webview.View
	bind    *binding
	making  bool
	asleep  bool
	shown   bool
	bounds  [4]int
	pending string
	popup   *webview.Popup
	last    float64 // when it was last the current tab
	closed  bool
}

// binding routes a view's events to its tab (a spare view gets its tab later).
type binding struct{ t *Tab }

// spare is a view made ahead of time, so the first page of a tab opens without waiting.
type spare struct {
	view   webview.View
	bind   *binding
	making bool
}

func (t *Tab) private() bool { return t.Kind == KPrivate || t.Kind == KTemp }

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
		if k == KNormal {
			a.makeSpare() // made while the user types, so the page opens at once
		}
	}
	return t
}

// ID is a widget id.
func ID(s string) ui.ID { return ui.Id(s) }

func (a *App) selectTab(i int) {
	if i < 0 || i >= len(a.tabs) {
		return
	}
	if old := a.tab(); old != nil {
		old.last = a.now()
	}
	a.cur = i
	t := a.tabs[i]
	t.last = a.now()
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
	t.closed = true
	if t.view != nil {
		v := t.view
		a.web(v.Close)
		t.view = nil
	}
	a.tabs = append(a.tabs[:i], a.tabs[i+1:]...)
	if len(a.tabs) == 0 {
		a.cur = 0
		a.newTab(KNormal, "", "", true)
		return
	}
	if i < a.cur || a.cur >= len(a.tabs) {
		a.cur--
	}
	a.cur = max(0, min(a.cur, len(a.tabs)-1))
	a.selectTab(a.cur)
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
	if up := core.HTTPSUpgrade(url); up != "" && a.set.HTTPSOnly && !a.allowedInsecure(url) {
		url = up
	}
	t.URL, t.Loading, t.Crashed, t.Blocked = url, true, false, 0
	if t.Title == "" {
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

// ensureView gives t a page: the spare view when it fits, or a new one.
func (a *App) ensureView(t *Tab) {
	if t.view != nil || t.making || !a.ready || a.eng == nil {
		return
	}
	if t.Kind == KNormal && t.popup == nil && a.spare != nil && a.spare.view != nil {
		s := a.spare
		a.spare = nil
		s.bind.t = t
		t.bind = s.bind
		a.attach(t, s.view)
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
	t.view, t.shown, t.asleep, t.bounds = v, false, false, [4]int{}
	if t.Muted {
		a.web(func() { v.SetMuted(true) })
	}
	if p := t.pending; p != "" {
		t.pending = ""
		a.web(func() { v.Navigate(p) })
	}
	if t == a.tab() && a.st.Focus != ID("addr") {
		a.web(v.Focus)
	}
}

// makeSpare prepares a default-container view in the background while a new tab
// page waits for typing. Only one is ever kept, and Free memory closes it.
func (a *App) makeSpare() {
	if a.spare != nil || !a.ready || a.eng == nil {
		return
	}
	s := &spare{bind: &binding{}, making: true}
	a.spare = s
	eng, ev := a.eng, a.events(s.bind)
	a.web(func() {
		eng.NewView(webview.Options{}, ev, func(v webview.View, err error) {
			if err == nil {
				v.SetVisible(false)
			}
			a.post(func() {
				s.making = false
				if err != nil {
					if a.spare == s {
						a.spare = nil
					}
					return
				}
				if a.spare != s {
					a.web(v.Close)
					return
				}
				s.view = v
			})
		})
	})
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
		URL: func(url string) {
			on(func(t *Tab) {
				if url == "about:blank" && t.URL == "" {
					return
				}
				t.URL = url
				if !t.private() {
					a.hist.Add(url, "", true)
				}
				if t == a.tab() && a.st.Focus != ID("addr") {
					a.addr.Set(url)
				}
			})
		},
		Title: func(title string) {
			on(func(t *Tab) {
				t.Title = title
				if !t.private() {
					a.hist.Add(t.URL, title, false)
				}
			})
		},
		Loading: func(l bool) {
			on(func(t *Tab) {
				t.Loading = l
				if l {
					t.Blocked = 0
				}
			})
		},
		History:  func(b, f bool) { on(func(t *Tab) { t.CanBack, t.CanFwd = b, f }) },
		Audio:    func(p bool) { on(func(t *Tab) { t.Audio = p }) },
		Blocked:  func(string) { on(func(t *Tab) { t.Blocked++; a.blockedTotal++ }) },
		Crashed:  func() { on(func(t *Tab) { t.Crashed = true; t.Loading = false }) },
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

func (a *App) insecure(t *Tab, url string) {
	host := core.Host(url)
	t.Loading = false
	a.bar = infobar{warn: true, text: host + " does not offer a secure connection. HTTPS-only stopped it.", action: "Open anyway",
		do: func() {
			a.insecureMu.Lock()
			a.insecureOK[host] = true
			a.insecureMu.Unlock()
			a.navigate(t, url)
		}}
}

// tick applies the memory plan to background tabs and refreshes the memory readout.
func (a *App) tick() {
	now := a.now()
	if now-a.lastMem >= 2 && a.ready && a.eng != nil {
		a.lastMem = now
		eng, self := a.eng, a.cfg.SelfMB
		a.web(func() { // runs on the window thread while the loop waits
			a.memMB = eng.MemoryMB()
			if self != nil {
				a.appMB = self()
			}
		})
	}
	if now-a.lastTick < 4 {
		return
	}
	a.lastTick = now
	cur := a.tab()
	live := 0
	for _, t := range a.tabs {
		if t.view == nil || t == cur {
			continue
		}
		live++
		idle := now - t.last
		if !t.asleep && !t.Audio && idle > a.plan.SleepAfter {
			v := t.view
			a.web(v.Sleep)
			t.asleep, t.shown = true, false
		}
		if idle > a.plan.UnloadAfter && !t.Audio && !t.private() {
			a.unload(t)
			live--
		}
	}
	for live+1 > a.plan.Live {
		var lru *Tab
		for _, t := range a.tabs {
			if t.view != nil && t != cur && !t.Audio && !t.private() && (lru == nil || t.last < lru.last) {
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

// unload closes a background page, keeping its address and title.
func (a *App) unload(t *Tab) {
	if t.view == nil {
		return
	}
	v := t.view
	a.web(v.Close)
	t.view, t.asleep, t.shown, t.Loading = nil, false, false, false
}

// FreeMemory puts every background tab to sleep now and unloads the ones that can be reopened.
func (a *App) FreeMemory() {
	cur := a.tab()
	n := 0
	for _, t := range a.tabs {
		if t.view == nil || t == cur || t.Audio {
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
	if a.spare != nil && a.spare.view != nil {
		v := a.spare.view
		a.web(v.Close)
		a.spare = nil
	}
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

// sync shows the current page in rect r and hides the others.
func (a *App) sync(r ui.Rect) {
	cur := a.tab()
	for _, t := range a.tabs {
		if t.view == nil {
			continue
		}
		want := t == cur && t.URL != "" && !t.Crashed && !r.Empty()
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
