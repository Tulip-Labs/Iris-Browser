// Package webview embeds the web engines under Iris's own Gio interface:
// Electron on Windows; WebKitGTK and Electron on Linux. Every method must be
// called on the window's UI thread; events arrive on that thread too.
package webview

import "errors"

// SleepFreesMemory says whether putting a page to sleep gives its memory
// back (Electron does; on Linux a hidden page keeps its memory, so under
// memory pressure Iris unloads pages there instead).
var SleepFreesMemory = true

// Options choose a tab's storage: a named container (its own cookies,
// storage and cache) or a private session that is never written to disk.
type Options struct {
	Profile string // "" is the default container
	Private bool
	// Popup is set when the engine asked for a new window (sign-in, payment):
	// the view is attached to the opener so window.opener keeps working.
	Popup *Popup
	// Sandbox is for pages that may be unsafe: the engine refuses their
	// downloads and every permission (camera, microphone, location,
	// notifications, clipboard), and keeps no passwords or form data for them.
	Sandbox bool
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
	Focus      func() // the page took the keyboard (a click inside it)
	// Menu is a right click in the page (Linux): Iris draws the menu itself.
	// nil, or a view that cannot, leaves the engine's own.
	Menu func(m *Menu)
}

// Menu is a page's right-click menu, for the interface to show. X and Y are
// where it opened, in the window's units (the interface's own). Choose
// takes an item's Cmd, or -1 when the menu closed without a choice; it is
// called once, on the window thread.
type Menu struct {
	X, Y   float32
	Items  []MenuItem
	Choose func(cmd int)
}

// MenuItem is one line of a Menu; Sep is a separator line.
type MenuItem struct {
	Cmd     int
	Label   string
	Enabled bool
	Sep     bool
}

// DownloadState is where a download stands.
type DownloadState uint8

const (
	DownloadActive DownloadState = iota
	DownloadPaused
	DownloadDone
	DownloadFailed
	DownloadCanceled
)

// Download is a snapshot of one download; the engine reports a new one each
// time it changes. Cancel, Pause and Resume must be called on the window's
// thread (Pause and Resume are nil where the engine cannot pause).
type Download struct {
	ID              int
	URL, Path       string
	Total, Received int64 // Total is -1 when the size is not known
	State           DownloadState
	// View is the page that started it (nil when unknown). That page must
	// stay open until the download ends: closing it can stop the download.
	View          View
	Cancel        func()
	Pause, Resume func()
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
	// Rewrite may change the address of a page about to open (links cleaned of
	// tracking); it returns the address unchanged when there is nothing to do.
	Rewrite func(url string) string
	// NewTabFor says whether a link the reader clicked, from page from to
	// address to, opens in a new tab instead (another website). nil = never.
	NewTabFor func(from, to string) bool
	// HTTPSOnly stops plain http:// pages unless AllowInsecure says yes.
	HTTPSOnly     bool
	AllowInsecure func(url string) bool
	// Scripts run in every page before its own scripts.
	Scripts []string
	// Strict turns on the engine's own strict tracking prevention.
	Strict bool
	// Scan says whether the requests of the page at url need checking with
	// Allow. Adaptive shields answer no for sites already scanned and found
	// clean, and their requests then go straight to the network. nil = always.
	Scan func(url string) bool
	// Unsafe stops a page that looks dangerous before it loads; the view
	// reports it through Insecure. Sandbox views are not asked.
	Unsafe func(url string) bool
	// Download reports every download as it starts and as it changes.
	Download func(d Download)
	// ContentRules is the shield for an engine that matches requests itself
	// (WebKit's content blockers, shields.ContentRules): the rules as JSON.
	// It may take a moment; engines call it off the window's thread.
	ContentRules func() []byte
	// MemoryBudgetMB is how much memory the engine's processes may hold
	// together (the memory setting's budget; 0 = a quarter of the computer's).
	// Iris's balancer rests background tabs first; an engine that can (Linux,
	// Electron) restarts itself when it stays over with nothing left to rest.
	MemoryBudgetMB int
}

// Popup is a pending new window that must be attached to its view.
type Popup struct {
	URL  string
	impl popupImpl
}

// FromWebKit says whether the pop-up is a WebKit page (Linux): it opens in
// WebKit, beside its opener.
func (p *Popup) FromWebKit() bool { return p != nil && p.impl.kitPage() }

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
	// SetZoom scales the page (1 = its normal size).
	SetZoom(f float64)
	// SetBackground tells the engine the page is not being looked at: it may
	// give memory back, but the page keeps running (unlike Sleep).
	SetBackground(on bool)
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

// Extension is a browser extension installed in the engine.
type Extension struct {
	ID, Name string
	Enabled  bool
}

// ExtensionHost is an engine that runs browser extensions (Electron, on
// Windows and Linux). Extensions
// live in the default container; private, sandbox and container tabs run
// without them. Every callback arrives on the window's thread.
type ExtensionHost interface {
	// AddExtension loads the unpacked extension in dir (it must stay there).
	AddExtension(dir string, done func(Extension, error))
	Extensions(done func([]Extension, error))
	RemoveExtension(id string, done func(error))
	EnableExtension(id string, on bool, done func(error))
}
