// Package webview embeds the operating system's web engine under Lite Go's
// own Gio interface: WebView2 (Chromium) on Windows, WKWebView (WebKit) on
// macOS and WebKitGTK on Linux. Every method must be
// called on the window's UI thread; events arrive on that thread too.
package webview

import "errors"

// Options choose a tab's storage: a named container (its own cookies,
// storage and cache) or a private session that is never written to disk.
type Options struct {
	Profile string // "" is the default container
	Private bool
	// Popup is set when WebView2 asked for a new window (sign-in, payment):
	// the view is attached to the opener so window.opener keeps working.
	Popup *Popup
}

// Events are what a view reports; any may be nil.
type Events struct {
	URL        func(url string)
	Title      func(title string)
	Loading    func(loading bool)
	History    func(canBack, canForward bool)
	NewTab     func(url string, popup *Popup) // a link or script asked for a new window
	Fullscreen func(on bool)
	Key        func(k Key) bool // a browser shortcut pressed inside the page; true = handled
	Blocked    func(url string) // the shield blocked a request
	Insecure   func(url string) // an http:// navigation was stopped (HTTPS-only)
	Crashed    func()
	Failed     func(url string, status int)
	Audio      func(playing bool)
}

// Key is a shortcut seen while the page has focus.
type Key struct {
	VK               uint32
	Ctrl, Shift, Alt bool
}

// Policy decides on requests; set by the browser core.
type Policy struct {
	// Allow says whether a subresource may load (the shield). kind is what it
	// loads: "script", "image", "media", "xmlhttprequest", "ping" or "other".
	// nil = allow all.
	Allow func(url, page, kind string) bool
	// Blocklist returns the shield as a Safari content-blocker list, for the
	// engines that cannot ask about each request (WebKit on macOS and Linux).
	Blocklist func() string
	// Rewrite may change the address of a page about to open (links cleaned of
	// tracking); it returns the address unchanged when there is nothing to do.
	Rewrite func(url string) string
	// HTTPSOnly stops plain http:// pages unless AllowInsecure says yes.
	HTTPSOnly     bool
	AllowInsecure func(url string) bool
	// Scripts run in every page before its own scripts.
	Scripts []string
	// Strict turns on the engine's own strict tracking prevention.
	Strict bool
}

// Popup is a pending new window that must be attached to its view.
type Popup struct {
	URL  string
	impl popupImpl
}

// View is one tab's page.
type View interface {
	Navigate(url string)
	Back()
	Forward()
	Reload()
	Stop()
	// SetBounds places the page in the window, in physical pixels.
	SetBounds(x, y, w, h int)
	SetVisible(on bool)
	// Sleep lowers memory use for a background tab; Wake restores it.
	Sleep()
	Wake()
	Focus()
	Eval(js string)
	// Run evaluates js and reports its result as JSON ("null" when it failed).
	Run(js string, done func(result string))
	SetMuted(on bool)
	Close()
}

// Engine creates views. Start must be called once with the native window.
type Engine interface {
	Start(window uintptr, dataDir string, low bool, ready func(err error))
	NewView(o Options, ev Events, done func(View, error))
	SetPolicy(p Policy)
	// MemoryMB is the web engine's private memory (all its processes).
	MemoryMB() float64
	Version() string
}

// ErrUnavailable is returned where the platform's web engine is not supported yet.
var ErrUnavailable = errors.New("the web engine is not available on this system")
