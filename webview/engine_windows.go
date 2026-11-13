//go:build windows

package webview

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

type rect struct{ left, top, right, bottom int32 }

type popupImpl struct{ args, deferral uintptr }

var (
	user32          = windows.NewLazySystemDLL("user32.dll")
	procGetKeyState = user32.NewProc("GetKeyState")
	kernel32        = windows.NewLazySystemDLL("kernel32.dll")
	procGetProcMem  = kernel32.NewProc("K32GetProcessMemoryInfo")
)

type engine struct {
	hwnd    uintptr
	env     uintptr
	env8    uintptr
	env10   uintptr
	policy  Policy
	version string
	memMB   float64
	memAt   time.Time
}

var downloadID int

// New returns the Windows engine (WebView2).
func New() Engine { return &engine{} }

func (e *engine) Version() string { return e.version }

func (e *engine) SetPolicy(p Policy) { e.policy = p }

// runtimeDLL finds the installed WebView2 runtime (stable channel first), per machine or per user.
func runtimeDLL() (string, error) {
	arch := map[string]string{"amd64": "x64", "arm64": "arm64", "386": "x86"}[runtime.GOARCH]
	channels := []string{
		"{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", // stable
		"{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}", // beta
		"{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}", // dev
		"{65C35B14-6C1D-4122-AC46-7148CC9D6497}", // canary
	}
	for _, ch := range channels {
		for _, root := range []registry.Key{registry.LOCAL_MACHINE, registry.CURRENT_USER} {
			k, err := registry.OpenKey(root, `Software\Microsoft\EdgeUpdate\ClientState\`+ch, registry.READ|registry.WOW64_32KEY)
			if err != nil {
				continue
			}
			dir, _, err := k.GetStringValue("EBWebView")
			k.Close()
			if err != nil || dir == "" {
				continue
			}
			dll := filepath.Join(dir, "EBWebView", arch, "EmbeddedBrowserWebView.dll")
			if _, err := os.Stat(dll); err == nil {
				return dll, nil
			}
		}
	}
	return "", errors.New("WebView2 runtime not found: install it from https://go.microsoft.com/fwlink/p/?LinkId=2124703")
}

// Installed reports whether the WebView2 runtime is present (the installer checks this).
func Installed() bool { _, err := runtimeDLL(); return err == nil }

func browserArgs(low bool) string {
	args := []string{
		"--process-per-site",              // tabs of one site share a renderer
		"--disable-background-networking", // no speculative background traffic
		// Edge extras a browser shell does not need: SmartScreen reputation
		// lookups, the out-of-process PDF and UI helpers
		"--disable-features=msSmartScreenProtection,msWebOOUI,msPdfOOUI,msEdgeEnhanceSecurityMode",
		"--disable-component-update",
	}
	if low {
		// fewer renderer processes; not Chromium's low-end mode, which draws
		// with fewer colors and leaves pages grainy on large screens
		args = append(args, "--renderer-process-limit=3")
	} else {
		args = append(args, "--renderer-process-limit=8")
	}
	return strings.Join(args, " ")
}

func (e *engine) Start(window uintptr, dataDir string, low bool, ready func(error)) {
	e.hwnd = window
	procCoInitializeEx.Call(0, 2) // apartment threaded; S_FALSE when already initialized
	dllPath, err := runtimeDLL()
	if err != nil {
		ready(err)
		return
	}
	dll, err := windows.LoadDLL(dllPath)
	if err != nil {
		ready(fmt.Errorf("loading WebView2: %w", err))
		return
	}
	create, err := dll.FindProc("CreateWebViewEnvironmentWithOptionsInternal")
	if err != nil {
		ready(fmt.Errorf("WebView2 entry point: %w", err))
		return
	}
	_ = os.MkdirAll(dataDir, 0o755)
	opts := newEnvOptions(browserArgs(low))
	var h uintptr
	h = newHandler(iidICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, func(code, env uintptr) uintptr {
		defer release(h)
		defer release(opts)
		if failed(code) || env == 0 {
			ready(fmt.Errorf("WebView2 did not start (0x%08x)", uint32(code)))
			return sOK
		}
		addRef(env)
		e.env = env
		e.env8 = query(env, &iidICoreWebView2Environment8)
		e.env10 = query(env, &iidICoreWebView2Environment10)
		e.version = getString(env, slotICoreWebView2Environment_BrowserVersionString)
		ready(nil)
		return sOK
	})
	hr, _, _ := create.Call(1, 0, uintptr(unsafe.Pointer(wstr(dataDir))), opts, h)
	if failed(hr) {
		release(h)
		release(opts)
		ready(fmt.Errorf("WebView2 did not start (0x%08x)", uint32(hr)))
	}
}

func (e *engine) NewView(o Options, ev Events, done func(View, error)) {
	if e.env == 0 {
		done(nil, ErrUnavailable)
		return
	}
	var h uintptr
	h = newHandler(iidICoreWebView2CreateCoreWebView2ControllerCompletedHandler, func(code, ctrl uintptr) uintptr {
		defer release(h)
		if failed(code) || ctrl == 0 {
			if o.Popup != nil {
				o.Popup.finish(0)
			}
			done(nil, fmt.Errorf("could not open the page (0x%08x)", uint32(code)))
			return sOK
		}
		addRef(ctrl)
		v := &view{e: e, ctrl: ctrl, ev: ev, sandbox: o.Sandbox}
		v.core = getPtr(ctrl, slotICoreWebView2Controller_CoreWebView2)
		v.setup()
		if o.Popup != nil {
			o.Popup.finish(v.core)
		}
		done(v, nil)
		return sOK
	})
	if e.env10 != 0 && (o.Profile != "" || o.Private) {
		opts := getPtr(e.env10, slotICoreWebView2Environment10_CreateCoreWebView2ControllerOptions)
		if opts != 0 {
			name := o.Profile
			if name == "" {
				name = "Default"
			}
			call(opts, slotICoreWebView2ControllerOptions_SetProfileName, uintptr(unsafe.Pointer(wstr(name))))
			call(opts, slotICoreWebView2ControllerOptions_SetIsInPrivateModeEnabled, boolArg(o.Private))
			hr := call(e.env10, slotICoreWebView2Environment10_CreateCoreWebView2ControllerWithOptions, e.hwnd, opts, h)
			release(opts)
			if !failed(hr) {
				return
			}
		}
	}
	if hr := call(e.env, slotICoreWebView2Environment_CreateCoreWebView2Controller, e.hwnd, h); failed(hr) {
		release(h)
		done(nil, fmt.Errorf("could not open the page (0x%08x)", uint32(hr)))
	}
}

// finish attaches the new view to the opener's request (window.opener keeps working), or
// lets the request go when the view could not be made.
func (p *Popup) finish(core uintptr) {
	if p.impl.args == 0 {
		return
	}
	if core != 0 {
		call(p.impl.args, slotICoreWebView2NewWindowRequestedEventArgs_SetNewWindow, core)
	}
	call(p.impl.args, slotICoreWebView2NewWindowRequestedEventArgs_SetHandled, 1)
	if p.impl.deferral != 0 {
		call(p.impl.deferral, slotICoreWebView2Deferral_Complete)
		release(p.impl.deferral)
	}
	release(p.impl.args)
	p.impl = popupImpl{}
}

// MemoryMB sums the private memory of every WebView2 process (refreshed at most every 2 s).
func (e *engine) MemoryMB() float64 {
	if e.env8 == 0 || time.Since(e.memAt) < 2*time.Second {
		return e.memMB
	}
	e.memAt = time.Now()
	coll := getPtr(e.env8, slotICoreWebView2Environment8_GetProcessInfos)
	if coll == 0 {
		return e.memMB
	}
	defer release(coll)
	var n uint32
	call(coll, slotICoreWebView2ProcessInfoCollection_Count, uintptr(unsafe.Pointer(&n)))
	total := 0.0
	for i := uint32(0); i < n; i++ {
		var info uintptr
		if failed(call(coll, slotICoreWebView2ProcessInfoCollection_GetValueAtIndex, uintptr(i), uintptr(unsafe.Pointer(&info)))) || info == 0 {
			continue
		}
		pid := getInt(info, slotICoreWebView2ProcessInfo_ProcessId)
		release(info)
		total += privateMB(uint32(pid))
	}
	e.memMB = total
	return total
}

type memCounters struct {
	cb                                                           uint32
	pageFaultCount                                               uint32
	peakWorkingSet, workingSet                                   uintptr
	quotaPeakPaged, quotaPaged, quotaPeakNonPaged, quotaNonPaged uintptr
	pagefile, peakPagefile, private                              uintptr
}

func privateMB(pid uint32) float64 {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_VM_READ, false, pid)
	if err != nil {
		return 0
	}
	defer windows.CloseHandle(h)
	var m memCounters
	m.cb = uint32(unsafe.Sizeof(m))
	if r, _, _ := procGetProcMem.Call(uintptr(h), uintptr(unsafe.Pointer(&m)), uintptr(m.cb)); r == 0 {
		return 0
	}
	return float64(m.private) / (1 << 20)
}

// SelfMB is this process's own private memory.
func SelfMB() float64 { return privateMB(windows.GetCurrentProcessId()) }

// ---- a view ----

type view struct {
	e        *engine
	ctrl     uintptr
	core     uintptr
	core3    uintptr
	core8    uintptr
	core19   uintptr
	ev       Events
	url      string
	handlers []uintptr
	closed   bool
	sandbox  bool
	filters  bool      // the shield is listening to this view's requests
	held     []uintptr // interfaces released when the view closes
}

// the kinds of request the shield checks: scripts, XHR, fetch, pings and
// others. That is where ads and trackers start. Pictures, video, style
// sheets and fonts are never sent to the shield: they are most of what a
// page asks for, each check costs a trip between two processes, and a page
// must not lose its pictures to a list's mistake. The boxes ads leave are
// hidden by the hiding rules, and the engine's own tracking prevention
// still covers tracking pictures.
var shieldContexts = []uintptr{6, 7, 8, 14, 16}

// setFilters starts or stops sending this view's requests to the shield.
// Without the filters the requests never leave the engine, which is as fast
// as a page can load (adaptive shields use this for sites found clean).
func (v *view) setFilters(on bool) {
	if v.filters == on || v.closed {
		return
	}
	v.filters = on
	star := wstr("*")
	defer runtime.KeepAlive(star)
	all := uintptr(unsafe.Pointer(star))
	c22 := query(v.core, &iidICoreWebView2_22)
	for _, c := range shieldContexts {
		switch {
		case c22 != 0 && on:
			call(c22, slotICoreWebView2_22_AddWebResourceRequestedFilterWithRequestSourceKinds, all, c, 0xFFFFFFFF)
		case c22 != 0:
			call(c22, slotICoreWebView2_22_RemoveWebResourceRequestedFilterWithRequestSourceKinds, all, c, 0xFFFFFFFF)
		case on:
			call(v.core, slotICoreWebView2_AddWebResourceRequestedFilter, all, c)
		default:
			call(v.core, slotICoreWebView2_RemoveWebResourceRequestedFilter, all, c)
		}
	}
	release(c22)
}

// scan asks adaptive shields whether the page at url needs the shield.
func (v *view) scan(url string) bool {
	s := v.e.policy.Scan
	return s == nil || url == "" || s(url)
}

func (v *view) on(slot int, iid guid, obj uintptr, fn func(sender, args uintptr)) {
	var token int64
	h := newHandler(iid, func(a, b uintptr) uintptr {
		if !v.closed {
			fn(a, b)
		}
		return sOK
	})
	call(obj, slot, h, uintptr(unsafe.Pointer(&token)))
	v.handlers = append(v.handlers, h)
}

func keyDown(vk int) bool {
	r, _, _ := procGetKeyState.Call(uintptr(vk))
	return int16(r) < 0
}

func (v *view) setup() {
	e, core, ev := v.e, v.core, v.ev
	v.core3 = query(core, &iidICoreWebView2_3)
	v.core8 = query(core, &iidICoreWebView2_8)
	v.core19 = query(core, &iidICoreWebView2_19)
	if s := getPtr(core, slotICoreWebView2_Settings); s != 0 {
		call(s, slotICoreWebView2Settings_SetIsStatusBarEnabled, 1)
		call(s, slotICoreWebView2Settings_SetAreDefaultContextMenusEnabled, 1)
		call(s, slotICoreWebView2Settings_SetAreDevToolsEnabled, 1)
		if s3 := query(s, &iidICoreWebView2Settings3); s3 != 0 {
			call(s3, slotICoreWebView2Settings3_SetAreBrowserAcceleratorKeysEnabled, 1)
			release(s3)
		}
		if s4 := query(s, &iidICoreWebView2Settings4); s4 != 0 {
			call(s4, slotICoreWebView2Settings4_SetIsPasswordAutosaveEnabled, boolArg(!v.sandbox))
			call(s4, slotICoreWebView2Settings4_SetIsGeneralAutofillEnabled, boolArg(!v.sandbox))
			release(s4)
		}
		if v.sandbox {
			call(s, slotICoreWebView2Settings_SetAreHostObjectsAllowed, 0)
			call(s, slotICoreWebView2Settings_SetIsWebMessageEnabled, 0)
		}
		if s8 := query(s, &iidICoreWebView2Settings8); s8 != 0 {
			// no SmartScreen lookup for every page (the shield and HTTPS-only stay on)
			call(s8, slotICoreWebView2Settings8_SetIsReputationCheckingRequired, 0)
			release(s8)
		}
		release(s)
	}
	if e.policy.Strict {
		if c13 := query(core, &iidICoreWebView2_13); c13 != 0 {
			if prof := getPtr(c13, slotICoreWebView2_13_Profile); prof != 0 {
				if p3 := query(prof, &iidICoreWebView2Profile3); p3 != 0 {
					call(p3, slotICoreWebView2Profile3_SetPreferredTrackingPreventionLevel, 3) // strict
					release(p3)
				}
				release(prof)
			}
			release(c13)
		}
	}
	for _, js := range e.policy.Scripts {
		h := newHandler(iidICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, func(a, b uintptr) uintptr { return sOK })
		call(core, slotICoreWebView2_AddScriptToExecuteOnDocumentCreated, uintptr(unsafe.Pointer(wstr(js))), h)
		release(h)
	}
	// the shield: subresources only (scripts, images, requests, media, frames' content)
	if allow := e.policy.Allow; allow != nil {
		v.setFilters(true)
		v.on(slotICoreWebView2_add_WebResourceRequested, iidICoreWebView2WebResourceRequestedEventHandler, core, func(_, args uintptr) {
			req := getPtr(args, slotICoreWebView2WebResourceRequestedEventArgs_Request)
			if req == 0 {
				return
			}
			uri := getString(req, slotICoreWebView2WebResourceRequest_Uri)
			release(req)
			kind := "other"
			switch getInt(args, slotICoreWebView2WebResourceRequestedEventArgs_ResourceContext) {
			case 3:
				kind = "image"
			case 4:
				kind = "media"
			case 6:
				kind = "script"
			case 7, 8:
				kind = "xmlhttprequest"
			case 14:
				kind = "ping"
			}
			if allow(uri, v.url, kind) {
				return
			}
			var resp uintptr
			call(e.env, slotICoreWebView2Environment_CreateWebResourceResponse, 0, 403, uintptr(unsafe.Pointer(wstr("Blocked"))), uintptr(unsafe.Pointer(wstr(""))), uintptr(unsafe.Pointer(&resp)))
			if resp != 0 {
				call(args, slotICoreWebView2WebResourceRequestedEventArgs_SetResponse, resp)
				release(resp)
			}
			if ev.Blocked != nil {
				ev.Blocked(uri)
			}
		})
	}
	v.on(slotICoreWebView2_add_NavigationStarting, iidICoreWebView2NavigationStartingEventHandler, core, func(_, args uintptr) {
		uri := getString(args, slotICoreWebView2NavigationStartingEventArgs_Uri)
		if rw := e.policy.Rewrite; rw != nil {
			if clean := rw(uri); clean != "" && clean != uri {
				// open the clean address instead (links without tracking)
				call(args, slotICoreWebView2NavigationStartingEventArgs_SetCancel, 1)
				call(core, slotICoreWebView2_Navigate, uintptr(unsafe.Pointer(wstr(clean))))
				return
			}
		}
		stop := e.policy.HTTPSOnly && strings.HasPrefix(strings.ToLower(uri), "http://") && (e.policy.AllowInsecure == nil || !e.policy.AllowInsecure(uri))
		if !stop && e.policy.Unsafe != nil {
			stop = e.policy.Unsafe(uri)
		}
		if stop && !v.sandbox { // a sandbox is where such a page may open
			call(args, slotICoreWebView2NavigationStartingEventArgs_SetCancel, 1)
			if ev.Insecure != nil {
				ev.Insecure(uri)
			}
			return
		}
		if e.policy.Allow != nil {
			// between two pages both may still ask for things
			v.setFilters(v.scan(v.url) || v.scan(uri))
		}
		if ev.Loading != nil {
			ev.Loading(true)
		}
	})
	v.on(slotICoreWebView2_add_SourceChanged, iidICoreWebView2SourceChangedEventHandler, core, func(_, _ uintptr) {
		v.url = getString(core, slotICoreWebView2_Source)
		if e.policy.Allow != nil {
			v.setFilters(v.scan(v.url))
		}
		if ev.URL != nil {
			ev.URL(v.url)
		}
	})
	v.on(slotICoreWebView2_add_DocumentTitleChanged, iidICoreWebView2DocumentTitleChangedEventHandler, core, func(_, _ uintptr) {
		if ev.Title != nil {
			ev.Title(getString(core, slotICoreWebView2_DocumentTitle))
		}
	})
	v.on(slotICoreWebView2_add_NavigationCompleted, iidICoreWebView2NavigationCompletedEventHandler, core, func(_, args uintptr) {
		ok := getBool(args, slotICoreWebView2NavigationCompletedEventArgs_IsSuccess)
		status := getInt(args, slotICoreWebView2NavigationCompletedEventArgs_WebErrorStatus)
		if ev.Loading != nil {
			ev.Loading(false)
		}
		// 14 = operation canceled (a new navigation replaced this one): not an error
		if !ok && status != 14 && ev.Failed != nil {
			ev.Failed(v.url, int(status))
		}
	})
	v.on(slotICoreWebView2_add_HistoryChanged, iidICoreWebView2HistoryChangedEventHandler, core, func(_, _ uintptr) {
		if ev.History != nil {
			ev.History(getBool(core, slotICoreWebView2_CanGoBack), getBool(core, slotICoreWebView2_CanGoForward))
		}
	})
	v.on(slotICoreWebView2_add_NewWindowRequested, iidICoreWebView2NewWindowRequestedEventHandler, core, func(_, args uintptr) {
		uri := getString(args, slotICoreWebView2NewWindowRequestedEventArgs_Uri)
		if ev.NewTab == nil {
			return // let the engine open its own window
		}
		addRef(args)
		p := &Popup{URL: uri, impl: popupImpl{args: args, deferral: getPtr(args, slotICoreWebView2NewWindowRequestedEventArgs_GetDeferral)}}
		ev.NewTab(uri, p)
	})
	v.on(slotICoreWebView2_add_ContainsFullScreenElementChanged, iidICoreWebView2ContainsFullScreenElementChangedEventHandler, core, func(_, _ uintptr) {
		if ev.Fullscreen != nil {
			ev.Fullscreen(getBool(core, slotICoreWebView2_ContainsFullScreenElement))
		}
	})
	v.on(slotICoreWebView2_add_ProcessFailed, iidICoreWebView2ProcessFailedEventHandler, core, func(_, args uintptr) {
		// only the page's own process (or the browser) ending loses the page;
		// GPU, utility and frame processes restart by themselves
		kind := getInt(args, slotICoreWebView2ProcessFailedEventArgs_ProcessFailedKind)
		if (kind == 0 || kind == 1) && ev.Crashed != nil {
			ev.Crashed()
		}
	})
	if ev.Focus != nil {
		v.on(slotICoreWebView2Controller_add_GotFocus, iidICoreWebView2FocusChangedEventHandler, v.ctrl, func(_, _ uintptr) { ev.Focus() })
	}
	if v.sandbox {
		// no camera, microphone, location, notifications or clipboard
		v.on(slotICoreWebView2_add_PermissionRequested, iidICoreWebView2PermissionRequestedEventHandler, core, func(_, args uintptr) {
			call(args, slotICoreWebView2PermissionRequestedEventArgs_SetState, 2) // deny
		})
	}
	if c4 := query(core, &iidICoreWebView2_4); c4 != 0 {
		v.held = append(v.held, c4)
		v.on(slotICoreWebView2_4_add_DownloadStarting, iidICoreWebView2DownloadStartingEventHandler, c4, func(_, args uintptr) {
			if v.sandbox {
				call(args, slotICoreWebView2DownloadStartingEventArgs_SetCancel, 1)
				return
			}
			report := e.policy.Download
			if report == nil {
				return // the engine shows its own download box
			}
			op := getPtr(args, slotICoreWebView2DownloadStartingEventArgs_DownloadOperation)
			if op == 0 {
				return
			}
			call(args, slotICoreWebView2DownloadStartingEventArgs_SetHandled, 1) // Lite Go lists it itself
			trackDownload(op, getString(args, slotICoreWebView2DownloadStartingEventArgs_ResultFilePath), report)
		})
	}
	if v.core8 != 0 && ev.Audio != nil {
		c8 := v.core8
		v.on(slotICoreWebView2_8_add_IsDocumentPlayingAudioChanged, iidICoreWebView2IsDocumentPlayingAudioChangedEventHandler, c8, func(_, _ uintptr) {
			ev.Audio(getBool(c8, slotICoreWebView2_8_IsDocumentPlayingAudio))
		})
	}
	v.on(slotICoreWebView2Controller_add_AcceleratorKeyPressed, iidICoreWebView2AcceleratorKeyPressedEventHandler, v.ctrl, func(_, args uintptr) {
		kind := getInt(args, slotICoreWebView2AcceleratorKeyPressedEventArgs_KeyEventKind)
		if kind != 0 && kind != 2 { // key down / system key down
			return
		}
		var vk uint32
		call(args, slotICoreWebView2AcceleratorKeyPressedEventArgs_VirtualKey, uintptr(unsafe.Pointer(&vk)))
		k := Key{VK: vk, Ctrl: keyDown(0x11), Shift: keyDown(0x10), Alt: keyDown(0x12)}
		if ev.Key != nil && ev.Key(k) {
			call(args, slotICoreWebView2AcceleratorKeyPressedEventArgs_SetHandled, 1)
		}
	})
}

func (v *view) Navigate(url string) {
	if !v.closed {
		call(v.core, slotICoreWebView2_Navigate, uintptr(unsafe.Pointer(wstr(url))))
	}
}
func (v *view) Back()    { call(v.core, slotICoreWebView2_GoBack) }
func (v *view) Forward() { call(v.core, slotICoreWebView2_GoForward) }
func (v *view) Reload()  { call(v.core, slotICoreWebView2_Reload) }
func (v *view) Stop()    { call(v.core, slotICoreWebView2_Stop) }

func (v *view) SetBounds(x, y, w, h int) {
	if !v.closed {
		setBounds(v.ctrl, rect{int32(x), int32(y), int32(x + w), int32(y + h)})
	}
}

func (v *view) SetVisible(on bool) {
	if !v.closed {
		call(v.ctrl, slotICoreWebView2Controller_SetIsVisible, boolArg(on))
	}
}

// Sleep hides the page, asks the engine to use little memory and suspends its scripts.
func (v *view) Sleep() {
	if v.closed {
		return
	}
	call(v.ctrl, slotICoreWebView2Controller_SetIsVisible, 0)
	if v.core19 != 0 {
		call(v.core19, slotICoreWebView2_19_SetMemoryUsageTargetLevel, 1) // low
	}
	if v.core3 != 0 {
		var h uintptr
		h = newHandler(iidICoreWebView2TrySuspendCompletedHandler, func(a, b uintptr) uintptr { release(h); return sOK })
		if failed(call(v.core3, slotICoreWebView2_3_TrySuspend, h)) {
			release(h)
		}
	}
}

func (v *view) Wake() {
	if v.closed {
		return
	}
	if v.core3 != 0 && getBool(v.core3, slotICoreWebView2_3_IsSuspended) {
		call(v.core3, slotICoreWebView2_3_Resume)
	}
	if v.core19 != 0 {
		call(v.core19, slotICoreWebView2_19_SetMemoryUsageTargetLevel, 0) // normal
	}
}

func (v *view) Focus() { call(v.ctrl, slotICoreWebView2Controller_MoveFocus, 0) }

func (v *view) Eval(js string) {
	var h uintptr
	h = newHandler(iidICoreWebView2ExecuteScriptCompletedHandler, func(a, b uintptr) uintptr { release(h); return sOK })
	if failed(call(v.core, slotICoreWebView2_ExecuteScript, uintptr(unsafe.Pointer(wstr(js))), h)) {
		release(h)
	}
}

func (v *view) Run(js string, done func(string)) {
	if v.closed {
		done("null")
		return
	}
	var h uintptr
	h = newHandler(iidICoreWebView2ExecuteScriptCompletedHandler, func(code, res uintptr) uintptr {
		release(h)
		out := "null"
		if !failed(code) && res != 0 {
			out = windows.UTF16PtrToString((*uint16)(unsafe.Pointer(res)))
		}
		done(out)
		return sOK
	})
	if failed(call(v.core, slotICoreWebView2_ExecuteScript, uintptr(unsafe.Pointer(wstr(js))), h)) {
		release(h)
		done("null")
	}
}

// trackDownload follows one download (op is owned here) and reports its changes.
func trackDownload(op uintptr, path string, report func(Download)) {
	downloadID++
	d := Download{ID: downloadID, URL: getString(op, slotICoreWebView2DownloadOperation_Uri), Path: path, Total: -1}
	paused, canceled, ended := false, false, false
	var last time.Time
	var hBytes, hState uintptr
	read := func() {
		var total, got int64
		if !failed(call(op, slotICoreWebView2DownloadOperation_TotalBytesToReceive, uintptr(unsafe.Pointer(&total)))) && total > 0 {
			d.Total = total
		}
		if !failed(call(op, slotICoreWebView2DownloadOperation_BytesReceived, uintptr(unsafe.Pointer(&got)))) {
			d.Received = got
		}
		if p := getString(op, slotICoreWebView2DownloadOperation_ResultFilePath); p != "" {
			d.Path = p
		}
	}
	finish := func() {
		if ended {
			return
		}
		ended = true
		d.Cancel, d.Pause, d.Resume = nil, nil, nil
		release(hBytes)
		release(hState)
		release(op)
	}
	d.Cancel = func() {
		if !ended {
			canceled = true
			call(op, slotICoreWebView2DownloadOperation_Cancel)
		}
	}
	d.Pause = func() {
		if !ended && !paused {
			paused = true
			call(op, slotICoreWebView2DownloadOperation_Pause)
			d.State = DownloadPaused
			report(d)
		}
	}
	d.Resume = func() {
		if !ended && paused {
			paused = false
			call(op, slotICoreWebView2DownloadOperation_Resume)
			d.State = DownloadActive
			report(d)
		}
	}
	var token int64
	hBytes = newHandler(iidICoreWebView2BytesReceivedChangedEventHandler, func(_, _ uintptr) uintptr {
		if !ended && time.Since(last) > 200*time.Millisecond {
			last = time.Now()
			read()
			report(d)
		}
		return sOK
	})
	call(op, slotICoreWebView2DownloadOperation_add_BytesReceivedChanged, hBytes, uintptr(unsafe.Pointer(&token)))
	hState = newHandler(iidICoreWebView2StateChangedEventHandler, func(_, _ uintptr) uintptr {
		if ended {
			return sOK
		}
		read()
		switch getInt(op, slotICoreWebView2DownloadOperation_State) {
		case 2:
			d.State = DownloadDone
			if d.Total < 0 {
				d.Total = d.Received
			}
		case 1: // interrupted: paused by us, canceled, or failed
			switch {
			case canceled:
				d.State = DownloadCanceled
			case paused:
				d.State = DownloadPaused
				report(d)
				return sOK
			default:
				d.State = DownloadFailed
			}
		default:
			d.State = DownloadActive
			report(d)
			return sOK
		}
		out := d
		finish()
		out.Cancel, out.Pause, out.Resume = nil, nil, nil
		report(out)
		return sOK
	})
	call(op, slotICoreWebView2DownloadOperation_add_StateChanged, hState, uintptr(unsafe.Pointer(&token)))
	read()
	report(d)
}

// SetZoom scales the page; where the factor cannot be passed to the engine
// (see setZoom) the page's own CSS zoom is used.
func (v *view) SetZoom(f float64) {
	if v.closed {
		return
	}
	if !setZoom(v.ctrl, f) {
		v.Eval("document.documentElement.style.zoom=" + strconv.FormatFloat(f, 'f', 2, 64))
	}
}

// SetBackground lowers the page's memory target without suspending it.
func (v *view) SetBackground(on bool) {
	if v.closed || v.core19 == 0 {
		return
	}
	call(v.core19, slotICoreWebView2_19_SetMemoryUsageTargetLevel, boolArg(on))
}

func (v *view) SetMuted(on bool) {
	if v.core8 != 0 {
		call(v.core8, slotICoreWebView2_8_SetIsMuted, boolArg(on))
	}
}

func (v *view) Close() {
	if v.closed {
		return
	}
	v.closed = true
	call(v.ctrl, slotICoreWebView2Controller_Close)
	for _, p := range v.held {
		release(p)
	}
	for _, p := range []uintptr{v.core3, v.core8, v.core19, v.core, v.ctrl} {
		release(p)
	}
	for _, h := range v.handlers {
		release(h)
	}
	v.handlers = nil
}
