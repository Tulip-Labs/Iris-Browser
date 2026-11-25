// The CEF engine: one Browser per tab, windowless, software-painted.
//
// This is the engine the Iris browser runs on Linux when it is built with
// CEF. The browser talks to a page only through the Browser value here:
// load and navigation, zoom, resize/hide/focus, mouse/key/wheel input,
// fire-and-forget JavaScript, find, and the BGRA frame the renderer
// paints. The frame is handed to the caller as bytes; the caller owns the
// texture (the same split as WPE's software-frame path, which also feeds
// BGRA bytes into a texture).
//
// The engine is one per process: CEF is initialized once, the handlers
// are package globals, and every browser is a separate tab with its own
// request context. A Browser is freed by the engine in OnBeforeClose,
// after its on_close callback returns — the caller must not use it after
// that. (If creation never completes, destroy_browser frees it.)
//
// The tab-close guarantee (Cesar's hard requirement, proven in the smoke
// test) is built into this file, not bolted on: a separate
// CefRequestContext per tab forces a separate renderer process; closing
// is CloseBrowser with force; every reference the engine owns is dropped
// in OnBeforeClose; tabs are matched by browser identifier, never by
// pointer (CEF hands OnBeforeClose a different wrapper than
// OnAfterCreated); there is no --process-per-tab switch in CEF 156.
//
// Ownership, as the C API does it (and as a segfault proved): a
// refcounted object PASSED to a CEF function belongs to CEF afterwards —
// the request context given to CefBrowserHostCreateBrowser is released
// by CEF as the tab dies, and releasing it again touches freed memory.
// A refcounted object RETURNED by a CEF function belongs to the caller —
// the host from get_host is released by the engine in OnBeforeClose.
//
// What is NOT here yet (slice 2): the Tab seam in the browser, dialogs,
// pop-ups as related tabs, downloads, permissions, and find results
// (slice 2b): pop-ups are blocked in `on_before_popup` for now, and the
// find handler is nil, so searches run but nothing reports the matches.
// JS eval with a result (eval_js, via a console-message round-trip) and
// the favicon URL (on_favicon_urlchange) are here now.
package cef

import "core:fmt"
import "core:math"
import "core:mem"
import "base:runtime"
import "core:strings"
import "core:time"

// The CEF API version the bindings are written against. CEF 133+
// requires cef_api_hash(CEF_API_VERSION, 0) to be called first in every
// process, including subprocesses (they re-enter main, so the call goes
// at the top of the process entry point, in startup).
CEF_API_VERSION :: 999999

// ---------------------------------------------------------------------------
// The browser: one tab.
//
// The callbacks are the page's events; the engine calls them on the CEF
// UI thread (which, with the external message pump, is the thread that
// calls pump). They must not call back into the engine in a way that
// re-enters the pump; setting a flag and acting on it after pump returns
// is the safe shape.
Browser :: struct {
	// CEF objects. browser/host are nil until OnAfterCreated; ctx is
	// the tab's own request context, released in OnBeforeClose.
	browser: ^cef_browser_t,
	host:    ^cef_browser_host_t,
	ctx:     rawptr,
	id:      i32,

	// Creation/close state. created flips in OnAfterCreated; closed is
	// set by close_browser; close_pending means close was asked for
	// before creation finished.
	created:       bool,
	closed:        bool,
	close_pending: bool,

	// The page, as the UI sees it. width/height are the view size in
	// device pixels; frame is the last painted BGRA buffer (width*height
	// * 4 bytes, frame_w x frame_h), frame_dirty set by on_paint and
	// cleared by the caller when it uploads the frame.
	width:       i32,
	height:      i32,
	frame:       []u8,
	frame_w:     i32,
	frame_h:     i32,
	frame_dirty: bool,

	// Page state, updated by the handlers.
	url:          string,
	title:        string,
	loading:      bool,
	can_back:     bool,
	can_forward:  bool,
	progress:     f64,
	fullscreen:   bool,
	cursor:       i32, // a cef_cursor_type_t value; the caller maps it
	load_error:   i32, // 0 unless on_load_error fired

	// Callbacks. on_close is called with the Browser still valid; the
	// engine frees it when the callback returns.
	on_frame:      proc(b: ^Browser),
	on_title:      proc(b: ^Browser),
	on_url:        proc(b: ^Browser),
	on_loading:    proc(b: ^Browser),
	on_cursor:     proc(b: ^Browser),
	on_fullscreen: proc(b: ^Browser),
	on_load_error: proc(b: ^Browser),
	on_close:      proc(b: ^Browser),
	/// the page's icon URL, from on_favicon_urlchange; on_favicon fires
	/// when it changes (the caller fetches the bytes itself)
	favicon_url:   string,
	on_favicon:    proc(b: ^Browser),
	/// the caller's own pointer (the Page), for the callbacks above
	user:          rawptr,

	// JS evals waiting for their answer (eval_js). A tab that closes
	// answers its pending evals with "" in OnBeforeClose, so no eval
	// is ever left hanging.
	evals:     map[int]Eval_Job,
	next_eval: int,
}

// One JS eval with a result, waiting for its console-message answer.
Eval_Job :: struct {
	done: proc(result: string, user: rawptr),
	user: rawptr,
}

// Options for init. cache_dir is the CEF profile root (root_cache_path);
// the per-tab contexts are in-memory regardless, so tabs never share
// storage. resources_dir / locales_dir default to CEF's own resolution
// (next to the binary) when empty.
Init_Options :: struct {
	cache_dir:     string,
	resources_dir: string,
	locales_dir:   string,
}

// ---------------------------------------------------------------------------
// Process entry: subprocesses and the API hash.
//
// startup must be called at the very top of main, before anything else.
// It returns the subprocess exit code and true when this process IS a CEF
// subprocess (the caller then exits with the code); it returns (-1, false)
// for the browser process, which then calls init.
startup :: proc(args: []string) -> (code: int, is_subprocess: bool) {
	cef_api_hash(CEF_API_VERSION, 0)

	// Keep the argv cstrings alive for the process lifetime: CEF reads
	// them during init.
	g_args = make([dynamic]cstring, len(args))
	for a, i in args {
		g_args[i] = strings.clone_to_cstring(a)
	}
	main_args := cef_main_args_t{
		argc = i32(len(args)),
		argv = raw_data(g_args),
	}
	code32 := cef_execute_process(&main_args, nil, nil)
	if code32 >= 0 {
		return int(code32), true
	}
	return -1, false
}

@(private)
g_args: [dynamic]cstring

// init initializes CEF for the browser process. It must be called after
// startup returns (-1, false), on the thread that will pump. It returns
// false when CEF refuses to start (missing ICU data next to libcef.so is
// the usual cause: Resources/icudtl.dat + *.pak must sit in the libcef.so
// directory).
init :: proc(opts: Init_Options) -> bool {
	handlers_init()

	settings := cef_settings_t{size = size_of(cef_settings_t)}
	settings.no_sandbox = 1
	settings.multi_threaded_message_loop = 0
	settings.external_message_pump = 1
	settings.windowless_rendering_enabled = 1
	// The browser is quiet by default; the harness and slice 2 can turn
	// this up by adding an option.
	settings.log_severity = LOGSEVERITY_WARNING
	settings.background_color = 0xFFFFFFFF // opaque white
	// The strings are freed explicitly after CefInitialize returns.
	// (Not with defer inside the if-blocks: in Odin a defer runs at the
	// end of its enclosing scope, so a defer inside an if-block would
	// free the string before CefInitialize ever reads it — which is
	// exactly how this init once trapped with empty paths.)
	if len(opts.cache_dir) > 0 {
		settings.root_cache_path = to_cef_string(opts.cache_dir)
	}
	if len(opts.resources_dir) > 0 {
		settings.resources_dir_path = to_cef_string(opts.resources_dir)
	}
	if len(opts.locales_dir) > 0 {
		settings.locales_dir_path = to_cef_string(opts.locales_dir)
	}
	main_args := cef_main_args_t{
		argc = i32(len(g_args)),
		argv = raw_data(g_args),
	}
	ok := cef_initialize(&main_args, &settings, nil, nil) != 0
	cef_string_utf16_clear(&settings.root_cache_path)
	cef_string_utf16_clear(&settings.resources_dir_path)
	cef_string_utf16_clear(&settings.locales_dir_path)
	return ok
}

// shutdown shuts CEF down. Call it after the last browser is closed, on
// the pump thread.
shutdown :: proc() {
	cef_shutdown()
}

// pump runs one iteration of CEF's message loop. The caller owns the
// loop: call pump regularly (a timer, or the UI toolkit's idle source)
// and never block the pump thread for long.
pump :: proc() {
	cef_do_message_loop_work()
}

// wait_created pumps until the browser's OnAfterCreated fired, or the
// timeout (milliseconds) passes. A browser is usable for load/navigation
// only after it is created.
wait_created :: proc(b: ^Browser, timeout_ms: int) -> bool {
	deadline := time.time_add(time.now(), time.Duration(timeout_ms) * time.Millisecond)
	for !b.created {
		if time.since(deadline) >= 0 {
			return false
		}
		pump()
		time.sleep(10 * time.Millisecond)
	}
	return true
}

// ---------------------------------------------------------------------------
// Tabs.

@(private)
browsers: [dynamic]^Browser // created tabs, by browser id
@(private)
pending: [dynamic]^Browser // created, waiting for OnAfterCreated

// new_browser creates a tab loading url at the given view size. It
// returns nil when CEF refuses to create the browser. The tab is usable
// for load/navigation once wait_created returns true; the initial URL is
// already loading by then.
new_browser :: proc(url: string, w, h: i32) -> ^Browser {
	b := new(Browser)
	b.width = w
	b.height = h
	b.url = strings.clone(url)

	// One request context per tab, in-memory (empty cache_path): the
	// tab gets its own storage partition, which is what forces its own
	// renderer process.
	ctx_settings := cef_request_context_settings_t{size = size_of(cef_request_context_settings_t)}
	b.ctx = cef_request_context_create_context(&ctx_settings, nil)

	win_info := cef_window_info_t{size = size_of(cef_window_info_t)}
	win_info.bounds = cef_rect_t{0, 0, w, h}
	win_info.windowless_rendering_enabled = 1
	win_info.shared_texture_enabled = 0 // software OnPaint frames
	win_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY

	browser_settings := cef_browser_settings_t{size = size_of(cef_browser_settings_t)}
	browser_settings.windowless_frame_rate = 30
	browser_settings.background_color = 0xFFFFFFFF

	u := to_cef_string(url)
	defer cef_string_utf16_clear(&u)
	if cef_browser_host_create_browser(&win_info, &client, &u, &browser_settings, nil, b.ctx) == 0 {
		// Creation refused, so CEF never took ownership of the
		// context: the engine releases it here. (Once creation is
		// accepted, the context is CEF's — see OnBeforeClose.)
		release_ref(b.ctx)
		delete(b.url)
		free(b)
		return nil
	}
	append(&pending, b)
	return b
}

// close_browser closes the tab. The tab really dies in OnBeforeClose:
// its renderer process goes with it, the request context is released,
// on_close fires, and the engine frees the Browser. Closing is
// asynchronous — the Browser stays valid until on_close returns.
close_browser :: proc(b: ^Browser) {
	if b.closed {
		return
	}
	b.closed = true
	if b.host != nil {
		b.host.close_browser(b.host, 1)
	} else {
		// Not created yet: close as soon as OnAfterCreated fires.
		b.close_pending = true
	}
}

// destroy_browser frees a Browser whose creation never completed (its
// OnAfterCreated never fired, so OnBeforeClose never will). Do not call
// it on a created tab — that path is close_browser + OnBeforeClose.
destroy_browser :: proc(b: ^Browser) {
	if b.created {
		return // created tabs die through OnBeforeClose only
	}
	for p, i in pending {
		if p == b {
			unordered_remove(&pending, i)
			break
		}
	}
	// The request context is not released here: once
	// CefBrowserHostCreateBrowser accepted it, CEF owns it (see
	// OnBeforeClose). Releasing it would touch freed memory.
	delete(b.url)
	delete(b.title)
	delete(b.frame)
	delete(b.favicon_url)
	for _, job in b.evals {
		job.done("", job.user)
	}
	delete(b.evals)
	free(b)
}

// load navigates the tab's main frame to url. False when the tab is not
// created yet.
load :: proc(b: ^Browser, url: string) -> bool {
	if b.browser == nil {
		return false
	}
	frame := b.browser.get_main_frame(b.browser)
	if frame == nil {
		return false
	}
	u := to_cef_string(url)
	defer cef_string_utf16_clear(&u)
	frame.load_url(frame, &u)
	return true
}

// Navigation. Back/forward return false when there is nowhere to go (or
// the tab is not created yet); reload/stop return false only when the
// tab is not created yet.
go_back :: proc(b: ^Browser) -> bool {
	if b.browser == nil || b.browser.can_go_back(b.browser) == 0 {
		return false
	}
	b.browser.go_back(b.browser)
	return true
}

go_forward :: proc(b: ^Browser) -> bool {
	if b.browser == nil || b.browser.can_go_forward(b.browser) == 0 {
		return false
	}
	b.browser.go_forward(b.browser)
	return true
}

reload :: proc(b: ^Browser) -> bool {
	if b.browser == nil {
		return false
	}
	b.browser.reload(b.browser)
	return true
}

reload_ignore_cache :: proc(b: ^Browser) -> bool {
	if b.browser == nil {
		return false
	}
	b.browser.reload_ignore_cache(b.browser)
	return true
}

stop_load :: proc(b: ^Browser) -> bool {
	if b.browser == nil {
		return false
	}
	b.browser.stop_load(b.browser)
	return true
}

// The cached page state, updated by on_loading_state_change. Reading the
// fields directly is the same thing; these are here so callers do not
// have to remember which field is which.
is_loading :: proc(b: ^Browser) -> bool { return b.loading }
can_go_back :: proc(b: ^Browser) -> bool { return b.can_back }
can_go_forward :: proc(b: ^Browser) -> bool { return b.can_forward }

// ---------------------------------------------------------------------------
// Zoom. CEF stores zoom as a level; Chromium's factor is 1.2 ^ level, so
// the conversion is a logarithm in base 1.2, not a percentage.

zoom_level_from_factor :: proc(factor: f64) -> f64 {
	return math.ln(factor) / math.ln(1.2)
}

zoom_factor_from_level :: proc(level: f64) -> f64 {
	return math.pow(1.2, level)
}

set_zoom_factor :: proc(b: ^Browser, factor: f64) -> bool {
	if b.host == nil {
		return false
	}
	b.host.set_zoom_level(b.host, zoom_level_from_factor(factor))
	return true
}

get_zoom_factor :: proc(b: ^Browser) -> (f64, bool) {
	if b.host == nil {
		return 1.0, false
	}
	return zoom_factor_from_level(b.host.get_zoom_level(b.host)), true
}

// ---------------------------------------------------------------------------
// View state and input. Coordinates are in device pixels, relative to
// the upper-left corner of the view; modifiers are cef_event_flags_t
// (EVENTFLAG_SHIFT_DOWN, EVENTFLAG_CONTROL_DOWN, EVENTFLAG_ALT_DOWN,
// EVENTFLAG_LEFT_MOUSE_BUTTON, and so on — the caller maps the platform
// modifiers onto these).

set_size :: proc(b: ^Browser, w, h: i32) {
	b.width = w
	b.height = h
	// CEF reads the new size through get_view_rect on the next paint;
	// was_resized tells it to ask.
	if b.host != nil {
		b.host.was_resized(b.host)
	}
}

set_visible :: proc(b: ^Browser, visible: bool) {
	if b.host == nil {
		return
	}
	b.host.was_hidden(b.host, 0 if visible else 1)
}

set_focus :: proc(b: ^Browser, focused: bool) {
	if b.host == nil {
		return
	}
	b.host.set_focus(b.host, 1 if focused else 0)
}

// send_mouse_click sends one button transition: pressed is true for the
// button-down event, false for button-up. A click is a down followed by
// an up with the same button and click_count. button is MBT_LEFT,
// MBT_MIDDLE or MBT_RIGHT.
send_mouse_click :: proc(b: ^Browser, x, y: i32, button: i32, pressed: bool, click_count: i32, modifiers: u32) -> bool {
	if b.host == nil {
		return false
	}
	ev := cef_mouse_event_t{x = x, y = y, modifiers = modifiers}
	b.host.send_mouse_click_event(b.host, &ev, button, 0 if pressed else 1, click_count)
	return true
}

send_mouse_move :: proc(b: ^Browser, x, y: i32, mouse_leave: bool, modifiers: u32) -> bool {
	if b.host == nil {
		return false
	}
	ev := cef_mouse_event_t{x = x, y = y, modifiers = modifiers}
	b.host.send_mouse_move_event(b.host, &ev, 1 if mouse_leave else 0)
	return true
}

send_mouse_wheel :: proc(b: ^Browser, x, y: i32, delta_x, delta_y: i32, modifiers: u32) -> bool {
	if b.host == nil {
		return false
	}
	ev := cef_mouse_event_t{x = x, y = y, modifiers = modifiers}
	b.host.send_mouse_wheel_event(b.host, &ev, delta_x, delta_y)
	return true
}

// send_key sends one key event. type is KEYEVENT_RAWKEYDOWN,
// KEYEVENT_KEYDOWN, KEYEVENT_KEYUP or KEYEVENT_CHAR; windows_key_code is
// the DOM key code, native_key_code the platform key code, character /
// unmodified_character the UTF-16 code unit produced (0 for
// non-character keys). A full key press is RAWKEYDOWN + KEYDOWN (+ CHAR
// for a character key) + KEYUP.
send_key :: proc(b: ^Browser, type: i32, windows_key_code, native_key_code: i32, modifiers: u32, character, unmodified_character: u16) -> bool {
	if b.host == nil {
		return false
	}
	ev := cef_key_event_t{
		size                 = size_of(cef_key_event_t),
		type                 = type,
		modifiers            = modifiers,
		windows_key_code     = windows_key_code,
		native_key_code      = native_key_code,
		is_system_key        = 0,
		character            = character,
		unmodified_character = unmodified_character,
		// CEF fills focus_on_editable_field in itself; callers pass 0.
		focus_on_editable_field = 0,
	}
	b.host.send_key_event(b.host, &ev)
	return true
}

// run_js runs code in the main frame and returns immediately; there is
// no result. The result round-trip (a console-message or DevTools
// round-trip) is a slice-2 design item, not assumed here.
run_js :: proc(b: ^Browser, code: string) -> bool {
	if b.browser == nil {
		return false
	}
	frame := b.browser.get_main_frame(b.browser)
	if frame == nil {
		return false
	}
	c := to_cef_string(code)
	defer cef_string_utf16_clear(&c)
	u := to_cef_string("")
	defer cef_string_utf16_clear(&u)
	frame.execute_java_script(frame, &c, &u, 0)
	return true
}

// eval_js runs code as an expression in the main frame and calls
// done(result, user) with its value as text — a string comes back as
// itself, anything else as JSON, an error as {"error": "..."} (the same
// shape as the WPE tab_run callback). The result is only valid during
// the callback; clone it to keep it. The answer comes back through a
// console message, so it arrives on the pump thread like every other
// callback. Returns the eval id, or -1 when the tab is not created yet.
// A tab that closes answers its pending evals with "".
//
// The code must be an expression, not statements: it is embedded as
// (code) in the wrapper, and a syntax error in it means the wrapper
// never runs and the eval never answers. That is the price of not using
// eval(), which a page's content-security policy can block; the
// embedder-injected wrapper itself is not subject to CSP.
eval_js :: proc(b: ^Browser, code: string, done: proc(result: string, user: rawptr), user: rawptr) -> int {
	if b.browser == nil {
		return -1
	}
	if b.evals == nil {
		b.evals = make(map[int]Eval_Job)
	}
	id := b.next_eval
	b.next_eval += 1
	b.evals[id] = Eval_Job{done = done, user = user}
	if !run_js(b, eval_wrapper(code, id)) {
		delete_key(&b.evals, id)
		return -1
	}
	return id
}

// eval_wrapper is the code eval_js runs: the expression's value (or its
// error) is printed as one console message carrying the eval id.
@(private)
eval_wrapper :: proc(code: string, id: int) -> string {
	return strings.concatenate({
		`(function(){var __r;try{__r=(`,
		code,
		`)}catch(__e){__r={error:String(__e)}};var __s;try{__s=(typeof __r==="string")?__r:JSON.stringify(__r===undefined?null:__r)}catch(__e2){__s=JSON.stringify({error:"unserializable"})};console.log("[iris-eval:`,
		fmt.tprintf("%d", id),
		`]"+__s)})();`,
	}, context.temp_allocator)
}

// find starts (or continues, with find_next) a text search in the page.
// Results come through a find handler, which is nil in slice 1 — the
// search runs, but nothing reports the matches yet.
find :: proc(b: ^Browser, text: string, forward, match_case, find_next: bool) -> bool {
	if b.host == nil {
		return false
	}
	t := to_cef_string(text)
	defer cef_string_utf16_clear(&t)
	b.host.find(b.host, &t, 1 if forward else 0, 1 if match_case else 0, 1 if find_next else 0)
	return true
}

stop_finding :: proc(b: ^Browser, clear_selection: bool) -> bool {
	if b.host == nil {
		return false
	}
	b.host.stop_finding(b.host, 1 if clear_selection else 0)
	return true
}

// release_ref drops one reference on a refcounted CEF object. The
// object is a struct whose first field is its base refcount, so any
// CEF object pointer can be released this way.
release_ref :: proc(p: rawptr) {
	if p == nil {
		return
	}
	base := cast(^cef_base_ref_counted_t)p
	base.release(base)
}

// ---------------------------------------------------------------------------
// Strings. CEF strings are UTF-16 and heap-owned; to_cef_string hands
// the caller a value it must free with cef_string_utf16_clear, and
// from_cef_string copies the value into an Odin string the caller owns.

to_cef_string :: proc(s: string) -> cef_string_utf16_t {
	str: cef_string_utf16_t
	c := strings.clone_to_cstring(s)
	defer delete(c)
	cef_string_utf8_to_utf16(c, uint(len(s)), &str)
	return str
}

from_cef_string :: proc(s: ^cef_string_t) -> string {
	out: cef_string_utf8_t
	if cef_string_utf16_to_utf8(s.str, s.length, &out) == 0 {
		return ""
	}
	defer cef_string_utf8_clear(&out)
	return strings.clone(string(out.str[:out.length]))
}

// ---------------------------------------------------------------------------
// Handlers. The client and the four handlers are package globals with
// no-op refcounting: CEF never frees them, so add_ref/release are stubs.
// The base.size of each handler is the size of the handler struct itself,
// which CEF uses to validate the struct it was given.

@(private)
ref_counted_add_ref :: proc "c" (self: ^cef_base_ref_counted_t) {}

@(private)
ref_counted_release :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 {
	return 1
}

@(private)
ref_counted_has_one_ref :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 {
	return 1
}

@(private)
ref_counted_has_at_least_one_ref :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 {
	return 1
}

@(private)
base_of :: proc(size: uint) -> cef_base_ref_counted_t {
	return {
		size = size,
		add_ref = ref_counted_add_ref,
		release = ref_counted_release,
		has_one_ref = ref_counted_has_one_ref,
		has_at_least_one_ref = ref_counted_has_at_least_one_ref,
	}
}

@(private)
client: cef_client_t

@(private)
render_handler: cef_render_handler_t

@(private)
life_span_handler: cef_life_span_handler_t

@(private)
display_handler: cef_display_handler_t

@(private)
load_handler: cef_load_handler_t

@(private)
handlers_init :: proc() {
	client = {
		base = base_of(size_of(cef_client_t)),
		get_display_handler = client_get_display_handler,
		get_render_handler = client_get_render_handler,
		get_life_span_handler = client_get_life_span_handler,
		get_load_handler = client_get_load_handler,
	}
	render_handler = {
		base = base_of(size_of(cef_render_handler_t)),
		get_root_screen_rect = render_get_root_screen_rect,
		get_view_rect = render_get_view_rect,
		get_screen_point = render_get_screen_point,
		get_screen_info = render_get_screen_info,
		on_paint = render_on_paint,
	}
	life_span_handler = {
		base = base_of(size_of(cef_life_span_handler_t)),
		on_before_popup = life_on_before_popup,
		on_after_created = life_on_after_created,
		do_close = life_do_close,
		on_before_close = life_on_before_close,
	}
	display_handler = {
		base = base_of(size_of(cef_display_handler_t)),
		on_address_change = display_on_address_change,
		on_title_change = display_on_title_change,
		on_favicon_urlchange = display_on_favicon_urlchange,
		on_fullscreen_mode_change = display_on_fullscreen_mode_change,
		on_loading_progress_change = display_on_loading_progress_change,
		on_console_message = display_on_console_message,
		on_cursor_change = display_on_cursor_change,
	}
	load_handler = {
		base = base_of(size_of(cef_load_handler_t)),
		on_loading_state_change = load_on_loading_state_change,
		on_load_error = load_on_load_error,
	}
}

// The browser behind a raw CEF browser pointer, matched by identifier —
// never by pointer, because CEF hands OnBeforeClose a different wrapper
// than OnAfterCreated.
@(private)
browser_from_ptr :: proc(raw: rawptr) -> ^Browser {
	b := cast(^cef_browser_t)raw
	if b == nil {
		return nil
	}
	id := b.get_identifier(b)
	for tab in browsers {
		if tab.id == id {
			return tab
		}
	}
	return nil
}

@(private)
client_get_display_handler :: proc "c" (self: ^cef_client_t) -> rawptr {
	return &display_handler
}

@(private)
client_get_render_handler :: proc "c" (self: ^cef_client_t) -> ^cef_render_handler_t {
	return &render_handler
}

@(private)
client_get_life_span_handler :: proc "c" (self: ^cef_client_t) -> ^cef_life_span_handler_t {
	return &life_span_handler
}

@(private)
client_get_load_handler :: proc "c" (self: ^cef_client_t) -> ^cef_load_handler_t {
	return &load_handler
}

// --- render handler ---

@(private)
render_get_root_screen_rect :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t) -> i32 {
	return 0 // CEF falls back to the view rect
}

@(private)
render_get_view_rect :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t) {
	context = runtime.default_context()
	// The view size is the tab's size; an unknown browser gets the
	// default rather than a zero rect (a zero rect stops painting).
	rect.x, rect.y = 0, 0
	rect.width, rect.height = 800, 600
	if b := browser_from_ptr(browser); b != nil {
		rect.width, rect.height = b.width, b.height
	}
}

@(private)
render_get_screen_point :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, view_x, view_y: i32, screen_x, screen_y: ^i32) -> i32 {
	return 0
}

@(private)
render_get_screen_info :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, screen_info: rawptr) -> i32 {
	return 0
}

@(private)
render_on_paint :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, type: i32, dirty_rects_count: uint, dirty_rects: ^cef_rect_t, buffer: rawptr, width, height: i32) {
	context = runtime.default_context()
	// The buffer is only valid for this call, so the frame is copied
	// now. Only the view (not popups) is kept; a popup is blocked
	// anyway by on_before_popup.
	if type != PET_VIEW {
		return
	}
	b := browser_from_ptr(browser)
	if b == nil || buffer == nil {
		return
	}
	n := int(width * height * 4)
	if len(b.frame) != n {
		delete(b.frame)
		b.frame = make([]u8, n)
	}
	copy(b.frame, mem.slice_ptr(cast([^]u8)buffer, n))
	b.frame_w, b.frame_h = width, height
	b.frame_dirty = true
	if b.on_frame != nil {
		b.on_frame(b)
	}
}

// --- life span handler ---

@(private)
life_on_before_popup :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr, frame: rawptr, popup_id: i32, target_url: ^cef_string_t, target_frame_name: ^cef_string_t, target_disposition: i32, user_gesture: i32, popup_features: rawptr, window_info: ^cef_window_info_t, client: ^^cef_client_t, settings: ^cef_browser_settings_t, extra_info: rawptr, no_javascript_access: ^i32) -> i32 {
	// Pop-ups are blocked in slice 1. Slice 2 opens them as related
	// tabs (the browser's new-window action) instead of letting CEF
	// create a window nobody owns.
	return 1
}

@(private)
life_on_after_created :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr) {
	context = runtime.default_context()
	b := cast(^cef_browser_t)browser
	if b == nil || len(pending) == 0 {
		return
	}
	// Creation order is pending order: the first tab still waiting is
	// this one.
	tab := pending[0]
	unordered_remove(&pending, 0)
	tab.browser = b
	tab.host = b.get_host(b)
	tab.id = b.get_identifier(b)
	tab.created = true
	append(&browsers, tab)
	if tab.close_pending {
		tab.host.close_browser(tab.host, 1)
	}
}

@(private)
life_do_close :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr) -> i32 {
	return 0 // let the close proceed; on_before_close does the cleanup
}

@(private)
life_on_before_close :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil {
		return
	}
	for tab, i in browsers {
		if tab == b {
			unordered_remove(&browsers, i)
			break
		}
	}
	// Drop the references the engine owns. The request context is NOT
	// one of them: passing it to CefBrowserHostCreateBrowser transfers
	// ownership to CEF (the browser owns it, and releases it as the tab
	// dies), so releasing it here touches freed memory — it segfaults.
	// The host IS owned by the engine: get_host returns a new reference,
	// so it is released here, while the browser is still alive.
	if b.host != nil {
		release_ref(b.host)
		b.host = nil
	}
	b.ctx = nil // CEF's now; do not release (see above)
	b.browser = nil
	// A closing tab answers its pending evals with "": their callers
	// must not be left hanging, and their done procs own their jobs.
	for _, job in b.evals {
		job.done("", job.user)
	}
	delete(b.evals)
	delete(b.favicon_url)
	if b.on_close != nil {
		b.on_close(b)
	}
	delete(b.url)
	delete(b.title)
	delete(b.frame)
	free(b)
}

// --- display handler ---

@(private)
display_on_address_change :: proc "c" (self: ^cef_display_handler_t, browser: rawptr, frame: rawptr, url: ^cef_string_t) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil || frame == nil {
		return
	}
	// Only the main frame's address is the tab's URL; subframes change
	// it too, and their URLs are not the tab's.
	f := cast(^cef_frame_t)frame
	if f.is_main(f) == 0 {
		return
	}
	delete(b.url)
	b.url = from_cef_string(url)
	if b.on_url != nil {
		b.on_url(b)
	}
}

@(private)
display_on_title_change :: proc "c" (self: ^cef_display_handler_t, browser: rawptr, title: ^cef_string_t) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil {
		return
	}
	delete(b.title)
	b.title = from_cef_string(title)
	if b.on_title != nil {
		b.on_title(b)
	}
}

@(private)
display_on_favicon_urlchange :: proc "c" (self: ^cef_display_handler_t, browser: rawptr, icon_urls: rawptr) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil || icon_urls == nil {
		return
	}
	// The first URL is the page's icon; the caller fetches the bytes.
	if cef_string_list_size(icon_urls) == 0 {
		return
	}
	value: cef_string_t
	if cef_string_list_value(icon_urls, 0, &value) == 0 {
		return
	}
	defer cef_string_utf16_clear(&value)
	delete(b.favicon_url)
	b.favicon_url = from_cef_string(&value)
	if b.on_favicon != nil {
		b.on_favicon(b)
	}
}

@(private)
display_on_console_message :: proc "c" (self: ^cef_display_handler_t, browser: rawptr, level: i32, message: ^cef_string_t, source: ^cef_string_t, line: i32) -> i32 {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil || message == nil {
		return 0
	}
	// Only the eval round-trip's messages are intercepted; everything
	// else is the page's own console, left alone. (A page that prints
	// "[iris-eval:N]..." itself would be misrouted — it would have to
	// print exactly that prefix.)
	m := from_cef_string(message)
	defer delete(m)
	if !strings.has_prefix(m, "[iris-eval:") {
		return 0
	}
	rest := m[len("[iris-eval:"):]
	end := strings.index_byte(rest, ']')
	if end < 0 {
		return 0
	}
	id_str := rest[:end]
	id := 0
	for c in transmute([]u8)id_str {
		if c < '0' || c > '9' {
			return 0
		}
		id = id * 10 + int(c - '0')
	}
	job, ok := b.evals[id]
	if !ok {
		return 0
	}
	delete_key(&b.evals, id)
	job.done(rest[end + 1:], job.user)
	return 0
}

@(private)
display_on_fullscreen_mode_change :: proc "c" (self: ^cef_display_handler_t, browser: rawptr, fullscreen: i32) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil {
		return
	}
	b.fullscreen = fullscreen != 0
	if b.on_fullscreen != nil {
		b.on_fullscreen(b)
	}
}

@(private)
display_on_loading_progress_change :: proc "c" (self: ^cef_display_handler_t, browser: rawptr, progress: f64) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil {
		return
	}
	b.progress = progress
}

@(private)
display_on_cursor_change :: proc "c" (self: ^cef_display_handler_t, browser: rawptr, cursor: rawptr, type: i32, custom_cursor_info: rawptr) -> i32 {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil {
		return 0
	}
	b.cursor = type
	if b.on_cursor != nil {
		b.on_cursor(b)
	}
	return 0
}

// --- load handler ---

@(private)
load_on_loading_state_change :: proc "c" (self: ^cef_load_handler_t, browser: rawptr, is_loading, can_go_back, can_go_forward: i32) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil {
		return
	}
	b.loading = is_loading != 0
	b.can_back = can_go_back != 0
	b.can_forward = can_go_forward != 0
	if b.on_loading != nil {
		b.on_loading(b)
	}
}

@(private)
load_on_load_error :: proc "c" (self: ^cef_load_handler_t, browser: rawptr, frame: rawptr, error_code: i32, error_text: ^cef_string_t, failed_url: ^cef_string_t) {
	context = runtime.default_context()
	b := browser_from_ptr(browser)
	if b == nil {
		return
	}
	b.load_error = error_code
	if b.on_load_error != nil {
		b.on_load_error(b)
	}
}
