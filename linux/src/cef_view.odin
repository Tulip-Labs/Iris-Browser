// The CEF engine's tab view (IRIS_ENGINE=cef, see engine_api.odin): one
// windowless CefBrowser per tab and every handler CEF calls for it.
//
// A View is Iris's object for one browser: the client and all its
// handlers live inside it (each followed by a pointer back to the View),
// and it is counted as CEF counts it. Iris holds one reference from the
// tab's start to OnBeforeClose; CEF holds the others. A tab closing calls
// CloseBrowser(force) and lets go of the View at once (view.tab = nil);
// OnBeforeClose then drops the browser, its host and every map entry, and
// the View frees itself when CEF lets go of its last reference. Browsers
// are matched by their identifier, never by pointer (CEF hands each
// callback a wrapper of its own).
package iris

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

// (not indented: the whole file is this engine's)
when ENGINE_CEF {

Tab_View :: struct {
	cv: ^View,
}

/// a CEF struct of Iris's, with the View it belongs to right after it
H :: struct($T: typeid) {
	c:    T,
	view: ^View,
}

View :: struct {
	refs:        i32, // atomic
	tab:         ^Tab, // nil once the tab let go
	browser:     ^cef_browser_t,
	host:        ^cef_browser_host_t,
	id:          i32,
	/// the closing came before CEF made the browser
	closing:     bool,
	/// what to open once the browser exists
	pending:     string,
	/// which renderer process each of its frames is in (frame id -> the
	/// process), as the render process handler reports it for every frame
	/// and document (cef_engine.odin's reaper)
	frames:      map[string]Renderer_Proc,
	/// a pop-up CEF makes for its opener (OnBeforePopup gave CEF this
	/// View's client): its id there, until OnAfterCreated or the abort
	popup_id:    i32,
	popup_opener: i32,
	popup_t0:    f64,
	/// the opener's address, for judging the pop-up's first real one
	popup_from:  string,
	/// its browser was made with shared textures (GPU frames)
	gpu_frames:  bool,
	/// the main frame's document came from a form (POST): never put to
	/// sleep (waking it would send the form again)
	posted:      bool,
	/// the reader's page, written into the fresh blank document the tab is
	/// navigating to (cef_extra.odin's tab_show_html)
	reader_html: string,
	/// the tokens of the watchers in its frames (media, copy)
	watch_tokens: [dynamic]string,
	/// when Iris last saw a copy or cut asked for in it (a key, the menu)
	copy_intent: f64,
	/// read on CEF's IO thread (atomic)
	shield_on:   i32,
	page_ignore: i32,
	page:        ^Page,
	client:      H(cef_client_t),
	life:        H(cef_life_span_handler_t),
	load:        H(cef_load_handler_t),
	display:     H(cef_display_handler_t),
	render:      H(cef_render_handler_t),
	request:     H(cef_request_handler_t),
	resource:    H(cef_resource_request_handler_t),
	menu:        H(cef_context_menu_handler_t),
	jsdialog:    H(cef_jsdialog_handler_t),
	permission:  H(cef_permission_handler_t),
	download:    H(cef_download_handler_t),
	find:        H(cef_find_handler_t),
	dialog:      H(cef_dialog_handler_t),
	icon:        H(cef_download_image_callback_t),
}

/// the live views (made, not yet past OnBeforeClose), and those by browser id
@(private="file") all_views: [dynamic]^View
@(private="file") by_id: map[i32]^View

// ---------------------------------------------------------------- counting

@(private="file") view_of :: proc "contextless" (self: ^cef_base_ref_counted_t) -> ^View {
	return (cast(^^View)(uintptr(self) + uintptr(self.size)))^
}

@(private="file") v_add_ref :: proc "c" (self: ^cef_base_ref_counted_t) {
	intrinsics.atomic_add(&view_of(self).refs, 1)
}

@(private="file") v_release :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 {
	v := view_of(self)
	if intrinsics.atomic_sub(&v.refs, 1) != 1 do return 0
	context = runtime.default_context()
	context.allocator = runtime.heap_allocator()
	for k in v.frames do delete(k)
	delete(v.frames)
	delete(v.pending)
	delete(v.reader_html)
	delete(v.popup_from)
	for x in v.watch_tokens do delete(x)
	delete(v.watch_tokens)
	free(v)
	return 1
}

@(private="file") v_one :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 {
	return intrinsics.atomic_load(&view_of(self).refs) == 1 ? 1 : 0
}

@(private="file") v_some :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 {
	return intrinsics.atomic_load(&view_of(self).refs) >= 1 ? 1 : 0
}

@(private="file") hinit :: proc(h: ^H($T), v: ^View) {
	#assert(offset_of(H(T), view) == size_of(T), "the View pointer must follow the struct")
	base := cast(^cef_base_ref_counted_t)&h.c
	base.size = size_of(T)
	base.add_ref = v_add_ref
	base.release = v_release
	base.has_one_ref = v_one
	base.has_at_least_one_ref = v_some
	h.view = v
}

/// the View a handler belongs to
@(private="file") vw :: #force_inline proc "contextless" (self: ^$T) -> ^View {
	return (cast(^H(T))self).view
}

/// a handler handed to CEF: it takes a reference
@(private="file") give :: proc "contextless" (h: ^H($T)) -> ^T {
	intrinsics.atomic_add(&h.view.refs, 1)
	return &h.c
}

// ---------------------------------------------------------------- the views

/// a live view (a tab's, the peek's, a pop-up's) has not said yet which
/// renderer it is in
views_unreported :: proc() -> bool {
	for v in all_views do if v.tab != nil && len(v.frames) == 0 do return true
	return false
}

/// a frame of a live view is in this renderer
views_use_pid :: proc(pid: i32) -> bool {
	for v in all_views do if v.tab != nil do for _, r in v.frames do if r.pid == pid do return true
	return false
}

/// each live browser's request context (a sandboxed tab has its own)
views_each_context :: proc(f: proc(c: ^cef_request_context_t)) {
	for v in all_views do if v.host != nil {
		c := v.host.get_request_context(v.host)
		if c == nil do continue
		f(c)
		rel(c)
	}
}

/// Iris quits: every browser closes, the peek's and a pop-up's being made
/// too (CEF must see them all close before it shuts down); false if one
/// did not in time
views_close_all :: proc() -> bool {
	for t in b.tabs do tab_release_web(t)
	if b.peek != nil do tab_release_web(b.peek)
	for len(all_views) > 0 {
		rest: ^Tab
		for v in all_views do if v.tab != nil do rest = v.tab
		if rest == nil do break
		tab_release_web(rest)
	}
	for i := 0; i < 300 && len(all_views) > 0; i += 1 {
		cef_do_message_loop_work()
		time.sleep(10 * time.Millisecond)
	}
	return len(all_views) == 0
}

/// a tab Iris still has (in the strip, or the peek)
@(private="file") alive :: proc(t: ^Tab) -> bool { return browser_tab_alive(t) }

tab_has_view :: proc(t: ^Tab) -> bool { return t.cv != nil }

// ---------------------------------------------------------------- making one

/// the tab's view; related (a pop-up's opener View, from OnBeforePopup):
/// CEF makes the browser itself, with this View's client, so the pop-up
/// keeps its window.opener
tab_ensure_web :: proc(t: ^Tab, related: rawptr = nil) -> ^View {
	if t.cv != nil do return t.cv
	v := new(View, runtime.heap_allocator())
	v.refs = 1 // Iris's, until OnBeforeClose
	v.tab = t
	v.page_ignore = -1
	hinit(&v.client, v)
	hinit(&v.life, v)
	hinit(&v.load, v)
	hinit(&v.display, v)
	hinit(&v.render, v)
	hinit(&v.request, v)
	hinit(&v.resource, v)
	hinit(&v.menu, v)
	hinit(&v.jsdialog, v)
	hinit(&v.permission, v)
	hinit(&v.download, v)
	hinit(&v.find, v)
	hinit(&v.dialog, v)
	hinit(&v.icon, v)
	handlers_fill(v)
	append(&all_views, v)
	t.cv = v

	v.gpu_frames = cef_gpu_frames
	if related == nil {
		wi := cef_window_info_t{size = size_of(cef_window_info_t)}
		windowless(&wi)
		bs := cef_browser_settings_t{size = size_of(cef_browser_settings_t)}
		browser_settings(&bs, t.sandboxed)
		ctx := tab_context(t) // its reference goes to CEF
		url := cef_str("")
		if cef_browser_host_create_browser(&wi, give(&v.client), &url, &bs, nil, ctx) == 0 {
			browser_toast("The page could not be made (CEF)")
		}
	}

	if p := t.page; p != nil && p.view == nil {
		// a tab waking from sleep: its last frame stays on screen until the
		// page has loaded again (cef_sleep.odin)
		p.view = v
		p.hold, p.hold_until = true, now_s() + SLEEP_HOLD_S
	} else {
		t.page = page_new(v)
	}
	v.page = t.page
	t.page.user = t
	t.page.on_frame = proc(p: ^Page) { browser_page_frame(cast(^Tab)p.user) }
	t.page.on_cursor = proc(p: ^Page) { browser_page_cursor(cast(^Tab)p.user) }
	t.page.on_fullscreen = proc(p: ^Page, on: bool) { browser_fullscreen(on) }
	browser_attach(t)
	return v
}

/// a browser drawn off-screen: its frames as DMA-BUFs from Chromium's GPU
/// compositor (OnAcceleratedPaint, cef_osr.odin) when GPU frames are on,
/// else as pixels (OnPaint)
@(private="file") windowless :: proc(wi: ^cef_window_info_t) {
	wi.windowless_rendering_enabled = 1
	wi.shared_texture_enabled = cef_gpu_frames ? 1 : 0
	wi.external_begin_frame_enabled = 0
	wi.parent_window = 0
	wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY
}

@(private="file") browser_settings :: proc(bs: ^cef_browser_settings_t, sandboxed: bool) {
	bs.windowless_frame_rate = cef_frame_rate()
	bs.background_color = 0xFFFFFFFF
	if sandboxed {
		// a site Iris does not trust: no clipboard, no WebGL
		bs.javascript_access_clipboard = STATE_DISABLED
		bs.javascript_dom_paste = STATE_DISABLED
		bs.webgl = STATE_DISABLED
	}
}

/// the view goes (to be made again, in or out of the sandbox): the browser
/// closes now, and nothing of Iris's keeps it
tab_release_web :: proc(t: ^Tab) {
	v := t.cv
	if v == nil {
		// a tab asleep: its last frame goes
		if p := t.page; p != nil && p.view == nil {
			t.page = nil
			page_free(p)
		}
		return
	}
	browser_forget_dialog(t)
	browser_detach(t)
	forget_asks(t)
	v.tab = nil
	if v.host != nil {
		v.host.close_browser(v.host, 1)
	} else {
		v.closing = true // closed as soon as CEF has made it
	}
	page_free(t.page)
	t.page = nil
	v.page = nil
	t.cv = nil
	forget_certs(t)
}

main_frame :: proc(v: ^View) -> ^cef_frame_t {
	if v.browser == nil do return nil
	return v.browser.get_main_frame(v.browser)
}

@(private="file") load_url :: proc(v: ^View, u: string) {
	f := main_frame(v)
	if f == nil {
		set_str(&v.pending, u)
		return
	}
	s := cef_str(u)
	f.load_url(f, &s)
	rel(f)
}

/// the tab's browser made again with frames through OnPaint (its GPU
/// frames could not be imported): after this turn of CEF's loop
cef_view_remake_software :: proc(t: ^Tab) {
	cef_gpu_frames = false
	Remake :: struct { t: ^Tab, id: int }
	idle(proc(d: rawptr) {
		r := cast(^Remake)d
		defer free(r)
		t := r.t
		if !alive(t) || t.id != r.id || t.cv == nil || !t.cv.gpu_frames do return
		u := strings.clone(t.url, context.temp_allocator)
		tab_release_web(t)
		if len(u) > 0 do tab_load(t, u)
	}, boxed(Remake{t, t.id}))
}

/// opens an address in the view as it is (no https-first, no sandbox turn)
cef_load :: proc(v: ^View, u: string) { load_url(v, u) }

/// opens an address; a site Iris does not trust goes to the sandbox, and
/// a trusted one comes out of it
tab_load :: proc(t: ^Tab, u0: string) {
	if len(u0) == 0 do return
	if internal_url(u0) {
		browser_toast("Chromium's internal pages are not part of Iris")
		return
	}
	// https first (features.odin), then without tracking parameters
	u := shields_clean_url(https_first(t, u0))
	want := untrusted(u)
	if t.cv == nil {
		t.sandboxed = want
	} else if want != t.sandboxed {
		tab_release_web(t)
		t.sandboxed = want
	}
	v := tab_ensure_web(t)
	set_str(&v.reader_html, "") // a new address: no reader's page waits
	set_str(&t.url, u)
	t.dialogs_blocked, t.dialogs_n = false, 0
	h, _ := host_of(u, context.temp_allocator)
	tab_shields_apply(t, h)
	load_url(v, u)
	browser_tab_changed(t)
}

tab_back :: proc(t: ^Tab) { if v := t.cv; v != nil && v.browser != nil do v.browser.go_back(v.browser) }
tab_forward :: proc(t: ^Tab) { if v := t.cv; v != nil && v.browser != nil do v.browser.go_forward(v.browser) }
tab_reload :: proc(t: ^Tab) { if v := t.cv; v != nil && v.browser != nil do v.browser.reload(v.browser) }
tab_reload_bypass :: proc(t: ^Tab) { if v := t.cv; v != nil && v.browser != nil do v.browser.reload_ignore_cache(v.browser) }
tab_stop :: proc(t: ^Tab) { if v := t.cv; v != nil && v.browser != nil do v.browser.stop_load(v.browser) }

/// Chromium's zoom is a level: each step 20% (1.2^level)
tab_set_zoom :: proc(t: ^Tab, z: f64) {
	t.zoom = z
	if v := t.cv; v != nil && v.host != nil do v.host.set_zoom_level(v.host, math.ln(z) / math.ln(1.2))
}

tab_warm_dns :: proc(t: ^Tab, host: string) {}

tab_download :: proc(t: ^Tab, url: string) {
	if v := t.cv; v != nil && v.host != nil {
		s := cef_str(url)
		v.host.start_download(v.host, &s)
	}
}

// ---------------------------------------------------------------- editing, and the clipboard

// Chromium's clipboard here is its own (the headless ozone platform has no
// desktop behind it), so Iris keeps it in step with the desktop's
// (clipboard.odin) both ways, and the page's own copy, cut and paste events
// always fire: Ctrl+C / X / V / A / Z go to Chromium as keys, and the menu's
// actions are the focused frame's own copy(), cut(), paste().
//   page -> desktop: a watcher in every frame (COPY_WATCH) tells Iris the
//   text a copy or cut put on Chromium's clipboard (what the page set in its
//   copy event, or else the selection); Iris offers it to the desktop.
//   desktop -> page: before a paste, if the desktop's text is not what
//   Chromium's clipboard holds, it is written there first
//   (navigator.clipboard.writeText in the focused frame), then the paste
//   goes on; if that fails, the text is typed in as before.

/// the text Chromium's clipboard is known to hold (a page copied it, or Iris
/// wrote it there)
@(private="file") chromium_clip: string

@(private="file") Edit_Op :: enum u8 { Copy, Cut, Paste, Select_All, Undo, Redo }

/// the frame editing goes to: the focused one (an iframe's field too)
@(private="file") edit_frame :: proc(v: ^View) -> ^cef_frame_t {
	if v == nil || v.browser == nil do return nil
	if f := v.browser.get_focused_frame(v.browser); f != nil do return f
	return v.browser.get_main_frame(v.browser)
}

@(private="file") frame_do :: proc(v: ^View, op: Edit_Op) {
	f := edit_frame(v)
	if f == nil do return
	defer rel(f)
	switch op {
	case .Copy: f.copy(f)
	case .Cut: f.cut(f)
	case .Paste: f.paste(f)
	case .Select_All: f.select_all(f)
	case .Undo: f.undo(f)
	case .Redo: f.redo(f)
	}
}

/// Chromium's clipboard gets the desktop's text (if it does not hold it
/// already), then then(t) runs; failed(t) if it could not (the text is
/// then typed in)
@(private="file") clipboard_to_chromium :: proc(t: ^Tab, then: proc(t: ^Tab)) {
	text := clipboard_text
	// the sandbox has no clipboard of its own: the text is typed in
	if t.sandboxed {
		if t.page != nil && len(text) > 0 do page_commit_text(t.page, text)
		return
	}
	// in step already (or nothing from the desktop): Chromium's own
	// clipboard is pasted, what the page copied there with all its formats
	if text == chromium_clip || len(text) == 0 {
		then(t)
		return
	}
	Sync :: struct {
		then: proc(t: ^Tab),
		text: string,
	}
	js := fmt.tprintf("navigator.clipboard.writeText(%s).then(() => '1', () => '0')", json_str(text, context.temp_allocator))
	run_job(t, edit_frame(t.cv), js, proc(t: ^Tab, result: string, data: rawptr) {
		s := cast(^Sync)data
		defer { delete(s.text); free(s) }
		if result == "1" {
			set_str(&chromium_clip, s.text)
			s.then(t)
		} else if t.page != nil {
			page_commit_text(t.page, s.text)
		}
	}, boxed(Sync{then, strings.clone(text)}), PASTE_TIMEOUT_S, proc(t: ^Tab, data: rawptr) {
		s := cast(^Sync)data
		if t != nil && t.page != nil do page_commit_text(t.page, s.text)
		delete(s.text)
		free(s)
	})
}

PASTE_TIMEOUT_S :: 1.0

@(private="file") boxed :: proc(x: $T) -> ^T {
	p := new(T)
	p^ = x
	return p
}

/// a key Iris presses in the page itself (after the clipboard is in step)
@(private="file") press :: proc(t: ^Tab, vk: i32, native: i32, mods: u32) {
	v := t.cv
	if v == nil || v.host == nil do return
	ev := cef_key_event_t{size = size_of(cef_key_event_t), modifiers = mods, windows_key_code = vk, native_key_code = native}
	ev.type = KEYEVENT_RAWKEYDOWN
	v.host.send_key_event(v.host, &ev)
	ev.type = KEYEVENT_KEYUP
	v.host.send_key_event(v.host, &ev)
}

/// Ctrl+V in the page: the clipboard in step first, then the key itself
cef_paste_key :: proc(t: ^Tab, native: i32, mods: u32) {
	if t.sandboxed {
		clipboard_to_chromium(t, nil) // typed in
		return
	}
	if clipboard_text == chromium_clip || len(clipboard_text) == 0 {
		press(t, 'V', native, mods)
		return
	}
	pending_key = {native, mods}
	clipboard_to_chromium(t, proc(t: ^Tab) { press(t, 'V', pending_key.native, pending_key.mods) })
}

@(private="file") pending_key: struct { native: i32, mods: u32 }

tab_edit :: proc(t: ^Tab, cmd: string) {
	v := t.cv
	if v == nil do return
	switch cmd {
	case EDIT_COPY:
		cef_copy_intent(t)
		frame_do(v, .Copy) // the watcher tells Iris what it copied
	case EDIT_CUT:
		cef_copy_intent(t)
		frame_do(v, .Cut)
	case EDIT_PASTE: clipboard_to_chromium(t, proc(t: ^Tab) { frame_do(t.cv, .Paste) })
	case EDIT_SELECT_ALL: frame_do(v, .Select_All)
	}
}

tab_find :: proc(t: ^Tab, text: string, dir: string) {
	v := t.cv
	if v == nil || v.host == nil do return
	s := cef_str(text)
	v.host.find(v.host, &s, dir == "prev" ? 0 : 1, 0, dir != "" ? 1 : 0)
}

tab_find_stop :: proc(t: ^Tab) {
	if v := t.cv; v != nil && v.host != nil do v.host.stop_finding(v.host, 1)
}

// ---------------------------------------------------------------- scripts, and what they say back

// A script's answer comes back as a console message (CEF's C API has no
// result for ExecuteJavaScript, and a process message from the page would
// need V8 bindings: the render process handler's V8 context and a native
// function, not in Iris's CEF bindings yet). What makes it Iris's:
//   - a token only Iris knows: fresh random for each job, used once, and
//     one per installed watcher (media, copy), kept by its view; compared
//     in constant time. Tokens live in the injected script's closure only,
//     never on window.
//   - the message goes through a console.info the page never touched: the
//     injected script makes a hidden about:blank iframe of the page's own
//     origin (IFRAME_NAME) and calls that realm's console.info, so a page
//     that wraps its own console (Sentry, Datadog, LogRocket) neither sees
//     the tokens nor drops the answers. If no such frame can be made (a
//     policy, a broken DOM), the console.info captured at injection is used.
// The message's source is not looked at (a page can name its own scripts
// anything with //# sourceURL). A job whose answer never comes is dropped
// after its time (JOB_TIMEOUT_S), so jobs never pile up.

@(private="file") Job :: struct {
	tab_id:   int,
	view:     ^View, // compared, never followed
	token:    string,
	done:     proc(t: ^Tab, result: string, data: rawptr),
	plain:    proc(t: ^Tab, result: string),
	data:     rawptr,
	/// the answer did not come in time (the tab may be gone: nil)
	failed:   proc(t: ^Tab, data: rawptr),
	deadline: f64,
}

@(private="file") jobs: [dynamic]Job
@(private="file") jobs_timer: bool
@(private="file") ANSWER :: "\x01iris:"
@(private="file") MEDIA :: "\x01iris-media:"
@(private="file") COPY :: "\x01iris-copy:"
@(private="file") SCRIPT_URL :: "iris://script"
/// the hidden frame Iris's scripts speak through (page_scripts skips it)
@(private="file") IFRAME_NAME :: "__iris_console"
JOB_TIMEOUT_S :: 30.0
/// a view's watcher tokens kept at most (one per frame and document)
WATCH_TOKENS_MAX :: 64
/// a copy reaches the desktop only this soon after Iris saw you copy
COPY_INTENT_S :: 1.0

@(private="file") token :: proc() -> string {
	id := new_id()
	return id
}

/// two tokens, compared in time that does not depend on where they differ
@(private="file") token_eq :: proc(a, b: string) -> bool {
	if len(a) != len(b) || len(a) == 0 do return false
	d: u8
	for i in 0 ..< len(a) do d |= a[i] ~ b[i]
	return d == 0
}

/// "TOKEN:payload" -> the token and the payload
@(private="file") split_token :: proc(rest: string) -> (tok, payload: string, ok: bool) {
	i := strings.index_byte(rest, ':')
	if i <= 0 do return
	return rest[:i], rest[i + 1:], true
}

/// JS: `say(message)` through a console.info the page never touched (see
/// above); `say_done()` lets the frame go (a job's, once it answered)
@(private="file") SAY_JS :: `const fallback = console.info.bind(console);
  let pristine = null;
  const fresh = () => { try { const i = document.createElement('iframe'); i.name = '` + IFRAME_NAME + `'; i.setAttribute('aria-hidden', 'true'); i.tabIndex = -1; i.style.cssText = 'display:none !important'; (document.documentElement || document.body).appendChild(i); const w = i.contentWindow; const f = w && w.console && w.console.info; if (typeof f === 'function') return { i, f }; i.remove(); } catch (e) {} return null; };
  const say = m => { if (!pristine || !pristine.i.isConnected) pristine = fresh(); try { if (pristine) { pristine.f(m); return; } } catch (e) {} fallback(m); };
  const say_done = () => { if (pristine) { try { pristine.i.remove(); } catch (e) {} pristine = null; } };`

run_in :: proc(f: ^cef_frame_t, js: string) {
	if f == nil do return
	s := cef_str(js)
	url := cef_str(SCRIPT_URL)
	f.execute_java_script(f, &s, &url, 0)
}

/// the tab a job was for, if it is still there with the same view
@(private="file") job_tab :: proc(j: Job) -> ^Tab {
	for t in b.tabs do if t.id == j.tab_id && t.cv == j.view do return t
	if p := b.peek; p != nil && p.id == j.tab_id && p.cv == j.view do return p
	return nil
}

/// jobs past their time are dropped (their failed proc told)
@(private="file") jobs_prune :: proc() {
	now := now_s()
	for i := 0; i < len(jobs); {
		j := jobs[i]
		if now < j.deadline {
			i += 1
			continue
		}
		ordered_remove(&jobs, i)
		if j.failed != nil do j.failed(job_tab(j), j.data)
		delete(j.token)
	}
	if len(jobs) > 0 && !jobs_timer {
		jobs_timer = true
		after(1000, proc(d: rawptr) {
			jobs_timer = false
			jobs_prune()
		}, nil)
	}
}

/// runs js (an expression; a promise is waited for) in frame f of t's page
run_job :: proc(t: ^Tab, f: ^cef_frame_t, js: string, done: proc(t: ^Tab, result: string, data: rawptr), data: rawptr = nil, timeout := JOB_TIMEOUT_S, failed: proc(t: ^Tab, data: rawptr) = nil, plain: proc(t: ^Tab, result: string) = nil) {
	if f == nil {
		if failed != nil do failed(t, data)
		return
	}
	defer rel(f)
	tk := token()
	append(&jobs, Job{t.id, t.cv, tk, done, plain, data, failed, now_s() + timeout})
	tag := json_str(fmt.tprintf("%s%s:", ANSWER, tk), context.temp_allocator)
	run_in(f, fmt.tprintf("(() => { %s\n  const tag = %s; let p; try { p = Promise.resolve((() => (%s))()); } catch (e) { p = Promise.resolve(''); } p.then(r => String(r), () => '').then(r => { say(tag + r); say_done(); }); })();", SAY_JS, tag, js))
	jobs_prune()
}

/// runs a script (an expression) in the page; done gets its result as text
tab_run :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
	v := t.cv
	if v == nil do return
	run_job(t, main_frame(v), js, nil, plain = done)
}

/// a fresh token for a watcher about to be installed in one of v's frames
@(private="file") watch_token :: proc(v: ^View) -> string {
	if len(v.watch_tokens) >= WATCH_TOKENS_MAX {
		delete(v.watch_tokens[0])
		ordered_remove(&v.watch_tokens, 0)
	}
	tk := token()
	append(&v.watch_tokens, tk)
	return tk
}

/// a watcher's token is one of the view's
@(private="file") watch_known :: proc(v: ^View, tok: string) -> bool {
	found := false
	for x in v.watch_tokens do if token_eq(x, tok) do found = true
	return found
}

/// the frames of the document before are gone: their watchers' tokens too
@(private="file") watch_forget :: proc(v: ^View) {
	for x in v.watch_tokens do delete(x)
	clear(&v.watch_tokens)
}

/// a page's sound and video, told to Iris (so a tab that plays is never
/// put to sleep)
@(private="file") media_watch :: proc(v: ^View) -> string {
	tag := json_str(fmt.tprintf("%s%s:", MEDIA, watch_token(v)), context.temp_allocator)
	return fmt.tprintf(`(() => {
  if (window.__irisMedia) return; window.__irisMedia = true;
  %s
  const tag = %s;
  const tell = () => { const on = [...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.ended && !m.muted); say(tag + (on ? '1' : '0')); };
  for (const e of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) document.addEventListener(e, tell, true);
})();`, SAY_JS, tag)
}

/// what a copy or cut put on Chromium's clipboard, told to Iris: the text
/// the page set in its copy event (read while the event is still being
/// handled, after the page's own handlers), or else the selection (in a
/// field too: getSelection() leaves fields out). Only a real copy (the
/// event is trusted: a page's own `new Event('copy')` is not), and Iris
/// takes it only right after it saw you copy (COPY_INTENT_S).
@(private="file") copy_watch :: proc(v: ^View) -> string {
	tag := json_str(fmt.tprintf("%s%s:", COPY, watch_token(v)), context.temp_allocator)
	return fmt.tprintf(`(() => {
  if (window.__irisCopy) return; window.__irisCopy = true;
  %s
  const tag = %s;
  const sel = () => { const e = document.activeElement; if (e && (e.tagName === 'INPUT' || e.tagName === 'TEXTAREA') && typeof e.selectionStart === 'number') return e.value.substring(e.selectionStart, e.selectionEnd); const s = window.getSelection(); return s ? s.toString() : ''; };
  const tell = t => { if (t) say(tag + t); };
  const watch = ev => {
    if (!ev.isTrusted) return;
    const text = sel(); let told = false;
    const late = e => { if (e !== ev) return; told = true; window.removeEventListener(ev.type, late, false); tell(ev.defaultPrevented ? (ev.clipboardData ? ev.clipboardData.getData('text/plain') : '') : text); };
    window.addEventListener(ev.type, late, false);
    setTimeout(() => { window.removeEventListener(ev.type, late, false); if (!told && !ev.defaultPrevented) tell(text); }, 0);
  };
  window.addEventListener('copy', watch, true);
  window.addEventListener('cut', watch, true);
})();`, SAY_JS, tag)
}

/// Iris saw you copy or cut in this tab's page (a key, or the menu): the
/// page's copy may reach the desktop for a moment
cef_copy_intent :: proc(t: ^Tab) {
	if t != nil && t.cv != nil do t.cv.copy_intent = now_s()
}

@(private="file") console_message :: proc(v: ^View, msg: string) -> bool {
	if strings.has_prefix(msg, MEDIA) {
		tok, payload, ok := split_token(msg[len(MEDIA):])
		if !ok || !watch_known(v, tok) do return true
		p := v.page
		if p == nil do return true
		on := payload == "1"
		if on != p.media {
			p.media = on
			page_apply_hidden(p)
		}
		if t := v.tab; t != nil do browser_page_audio(t, on)
		return true
	}
	if strings.has_prefix(msg, COPY) {
		tok, text, ok := split_token(msg[len(COPY):])
		if !ok || !watch_known(v, tok) || v.tab == nil || len(text) == 0 do return true
		// set_str first: Chromium's clipboard holds it either way
		set_str(&chromium_clip, text)
		// a copy you did not ask for (a page's script) never reaches the desktop
		if now := now_s(); now - v.copy_intent > COPY_INTENT_S || now < v.copy_intent do return true
		clipboard_offer(text)
		return true
	}
	if !strings.has_prefix(msg, ANSWER) do return false
	tok, result, ok := split_token(msg[len(ANSWER):])
	if !ok do return true
	for j, i in jobs {
		if !token_eq(j.token, tok) do continue
		ordered_remove(&jobs, i)
		defer delete(j.token)
		// the tab may have closed while the page answered (the peek too)
		t := job_tab(j)
		if t == nil || t.cv != v {
			if j.failed != nil do j.failed(nil, j.data)
			return true
		}
		if j.plain != nil do j.plain(t, result)
		if j.done != nil do j.done(t, result, j.data)
		return true
	}
	return true
}

/// the scripts a page gets, once it has loaded (frame: the one that did)
@(private="file") page_scripts :: proc(t: ^Tab, f: ^cef_frame_t) {
	// the hidden frame Iris's own scripts speak through gets none (it
	// would make one of its own, and so on)
	if from_userfree(f.get_name(f)) == IFRAME_NAME do return
	u := from_userfree(f.get_url(f))
	h, _ := host_of(u, context.temp_allocator)
	top := f.is_main(f) != 0
	yt := h == "youtube.com" || strings.has_suffix(h, ".youtube.com") || strings.has_suffix(h, ".youtube-nocookie.com")
	if top && (h == "www.google.com" || h == "google.com") do run_in(f, AI_GLASS)
	if yt {
		run_in(f, YOUTUBE)
		if settings().lightVideo do run_in(f, LIGHT_VIDEO)
	}
	if top && strings.has_prefix(u, "http") && !(h == "www.google.com" || strings.has_suffix(h, ".youtube.com") || h == "mail.google.com" || h == "docs.google.com") {
		run_in(f, SCROLL_UNLOCK)
	}
	v := t.cv
	if v == nil do return
	run_in(f, media_watch(v))
	run_in(f, copy_watch(v))
}

/// what Shields hides on this page, as a style sheet (early: at load start;
/// u: the frame's own address, the one committing, not the tab's)
@(private="file") page_hiding :: proc(t: ^Tab, v: ^View, f: ^cef_frame_t, u: string) {
	if intrinsics.atomic_load(&v.shield_on) == 0 do return
	h, _ := host_of(u, context.temp_allocator)
	css := matcher_css(cef_matcher(), u, h, context.temp_allocator)
	if len(css) == 0 do return
	run_in(f, fmt.tprintf(`(() => { const add = () => { const s = document.createElement('style'); s.textContent = %s; (document.head || document.documentElement).appendChild(s); }; if (document.documentElement) add(); else document.addEventListener('readystatechange', add, { once: true }); })();`, json_str(css, context.temp_allocator)))
}

// ---------------------------------------------------------------- pop-ups and new tabs

/// a page asks for a new window (OnBeforePopup) or a link wants a tab of its
/// own (OnOpenURLFromTab): the same choice as the WPE engine's
/// (new_window_choice). A link, or a page's own tab: a tab Iris makes
/// itself with the address. A pop-up that talks to its opener (a sign-in,
/// the same site's, a blank one the page writes into: Google, GitHub and
/// Microsoft sign-in, 3-D Secure, print previews): Related, a tab whose
/// browser CEF makes (OnBeforePopup gives it the tab's client), so
/// window.opener and postMessage work; it shows once it has a real address
/// or has painted (held until then).
@(private="file") new_window :: proc(t: ^Tab, u: string, disposition: i32, gesture: bool, from_link: bool) -> Window_Choice {
	page_host, _ := host_of(t.url, context.temp_allocator)
	shield := shields_on_for(page_host)
	tabby := disposition == CEF_WOD_NEW_FOREGROUND_TAB || disposition == CEF_WOD_NEW_BACKGROUND_TAB
	link := from_link || (tabby && gesture)
	background := disposition == CEF_WOD_NEW_BACKGROUND_TAB || !gesture
	real := len(u) > 0 && u != "about:blank"
	// never a tab for Chromium's own pages, a script, or an address that is
	// not one (a drag's data, a garbled string)
	if len(u) > 0 && (internal_url(u) || !url_plausible(u)) {
		if !link && shield && !t.sandboxed do browser_toast("Pop-up blocked")
		return .Block
	}
	choice := new_window_choice(u, t.url, link, gesture, t.sandboxed, shield)
	switch choice {
	case .Own_Tab:
		if real do open_later(t, u, background)
	case .Related:
		// a link wants a tab, never a pop-up that CEF fills
		if from_link {
			if real do open_later(t, u, background)
			return .Own_Tab
		}
	case .Block:
		if !link && shield && !t.sandboxed do browser_toast("Pop-up blocked")
	}
	return choice
}

@(private="file") Open :: struct {
	t:          ^Tab,
	id:         int,
	url:        string,
	background: bool,
}

/// the tab is made after CEF's callback returns (CEF must not be re-entered)
@(private="file") open_later :: proc(t: ^Tab, u: string, background: bool) {
	o := new(Open)
	o^ = {t, t.id, strings.clone(u), background}
	idle(proc(d: rawptr) {
		o := cast(^Open)d
		defer {
			delete(o.url)
			free(o)
		}
		if !alive(o.t) || o.t.id != o.id do return
		browser_open_link(o.t, o.url, o.background)
	}, o)
}

/// the pop-up's tab (Related): made now, in OnBeforePopup (its View's client
/// goes back to CEF, which makes the browser); held, not shown, until it
/// has somewhere to be (popup_reveal)
@(private="file") popup_tab :: proc(opener: ^Tab, ov: ^View, u: string, popup_id: i32) -> ^View {
	p := browser_new_tab({container = opener.container, after = opener, related = rawptr(ov)})
	if p == nil || p.cv == nil do return nil
	p.sandboxed = opener.sandboxed // (never: Related is not given in the sandbox)
	if strings.has_prefix(u, "http") do set_str(&p.url, u)
	p.cv.popup_id = popup_id
	p.cv.popup_opener = ov.id
	p.cv.popup_t0 = now_s()
	set_str(&p.cv.popup_from, opener.url)
	// a window the page only writes into (a print preview, a payment
	// form): shown once something is in it; one that stays blank (an ad's
	// pop-under waiting for its address) is never shown, and goes
	Check :: struct { t: ^Tab, id: int, n: int }
	after(POPUP_LOOK_MS, popup_look, boxed(Check{p, p.id, 0}))
	return p.cv
}

POPUP_LOOK_MS :: 1200
POPUP_LOOKS :: 6

/// a held pop-up with no address of its own: is anything in it yet?
@(private="file") popup_look :: proc(d: rawptr) {
	Check :: struct { t: ^Tab, id: int, n: int }
	c := cast(^Check)d
	t := c.t
	if !browser_has_tab(t) || t.id != c.id || !t.held || t.cv == nil {
		free(c)
		return
	}
	if c.n >= POPUP_LOOKS {
		// blank all along: nobody asked for it to stay
		free(c)
		browser_close_later(t)
		return
	}
	c.n += 1
	run_job(t, main_frame(t.cv), `(() => { const b = document.body; return b && ((b.innerText || '').trim().length > 0 || document.images.length > 0 || b.querySelector('canvas,embed,object,iframe,form,svg')) ? '1' : '0'; })()`, proc(t: ^Tab, result: string, data: rawptr) {
		c := cast(^Check)data
		if result == "1" {
			free(c)
			popup_reveal(t)
			return
		}
		after(POPUP_LOOK_MS, popup_look, c)
	}, c, failed = proc(t: ^Tab, data: rawptr) {
		c := cast(^Check)data
		if t != nil && t.held {
			after(POPUP_LOOK_MS, popup_look, c)
		} else {
			free(c)
		}
	})
}

/// a held pop-up reached its first real address: shown if a pop-up from
/// its opener may go there (the same choice as when it was asked for),
/// else closed (a pop-under sent on to an ad)
@(private="file") popup_arrived :: proc(t: ^Tab, v: ^View, u: string) -> (shown: bool) {
	page_host, _ := host_of(v.popup_from, context.temp_allocator)
	shield := shields_on_for(page_host)
	choice := internal_url(u) || !url_plausible(u) ? Window_Choice.Block : new_window_choice(u, v.popup_from, false, true, t.sandboxed, shield)
	if choice == .Block {
		t.held = false
		browser_close_later(t)
		if shield do browser_toast("Pop-up blocked")
		return false
	}
	popup_reveal(t)
	return true
}

/// a held pop-up shows (a real address, or its first paint)
popup_reveal :: proc(t: ^Tab) {
	if t == nil || !t.held || !browser_has_tab(t) do return
	t.held = false
	browser_select(t)
}

// ---------------------------------------------------------------- what pages ask for

Dialog_Ask :: struct {
	tab:  ^Tab,
	cb:   ^cef_jsdialog_callback_t,
	kind: int, // 0 alert, 1 confirm, 2 prompt, 3 leaving the page
}

Perm_Ask :: struct {
	tab:    ^Tab,
	media:  ^cef_media_access_callback_t,
	prompt: ^cef_permission_prompt_callback_t,
	perms:  u32,
	id:     u64,
}

Browser_Asks :: struct {
	dialogs:     map[int]Dialog_Ask,
	permissions: map[int]Perm_Ask,
}

/// a tab going away: what its page asked and was not answered is answered no
@(private="file") forget_asks :: proc(t: ^Tab) {
	ids := make([dynamic]int, context.temp_allocator)
	for id, a in b.dialogs do if a.tab == t do append(&ids, id)
	for id in ids {
		a := b.dialogs[id]
		a.cb.cont(a.cb, a.kind == 3 ? 1 : 0, nil)
		rel(a.cb)
		delete_key(&b.dialogs, id)
	}
	clear(&ids)
	for id, a in b.permissions do if a.tab == t do append(&ids, id)
	for id in ids {
		answer_perm(b.permissions[id], false)
		delete_key(&b.permissions, id)
	}
}

@(private="file") answer_perm :: proc(a: Perm_Ask, allow: bool) {
	if a.media != nil {
		a.media.cont(a.media, allow ? a.perms : CEF_MEDIA_PERMISSION_NONE)
		rel(a.media)
	}
	if a.prompt != nil {
		a.prompt.cont(a.prompt, allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY)
		rel(a.prompt)
	}
}

engine_answer_option :: proc(id, index: int) {} // CEF draws <select> lists itself (a popup)

engine_answer_permission :: proc(id: int, allow: bool) {
	if a, ok := b.permissions[id]; ok {
		answer_perm(a, allow)
		delete_key(&b.permissions, id)
	}
}

engine_answer_dialog :: proc(id: int, yes: bool, text: string) {
	if a, ok := b.dialogs[id]; ok {
		ok_ := yes || a.kind == 0
		s := cef_str(text)
		a.cb.cont(a.cb, ok_ ? 1 : 0, a.kind == 2 && ok_ ? &s : nil)
		rel(a.cb)
		delete_key(&b.dialogs, id)
	}
}

@(private="file") ask_permission :: proc(t: ^Tab, a: Perm_Ask, what: string) {
	b.asks += 1
	b.permissions[b.asks] = a
	site := display_url(t.url, context.temp_allocator)
	chrome_permission(b.asks, strings.concatenate({len(site) > 0 ? site : "This page", " wants to ", what}, context.temp_allocator))
}

@(private="file") permission_words :: proc(p: u32) -> string {
	switch {
	case p & (CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM) != 0: return "use your camera or microphone"
	case p & CEF_PERMISSION_TYPE_GEOLOCATION != 0: return "know your location"
	case p & CEF_PERMISSION_TYPE_NOTIFICATIONS != 0: return "show notifications"
	case p & CEF_PERMISSION_TYPE_CLIPBOARD != 0: return "read your clipboard"
	}
	return "use a feature of your computer"
}

// ---------------------------------------------------------------- the handlers

@(private="file") handlers_fill :: proc(v: ^View) {
	c := &v.client.c
	c.get_life_span_handler = proc "c" (self: ^cef_client_t) -> ^cef_life_span_handler_t { return give(&vw(self).life) }
	c.get_load_handler = proc "c" (self: ^cef_client_t) -> ^cef_load_handler_t { return give(&vw(self).load) }
	c.get_display_handler = proc "c" (self: ^cef_client_t) -> ^cef_display_handler_t { return give(&vw(self).display) }
	c.get_render_handler = proc "c" (self: ^cef_client_t) -> ^cef_render_handler_t { return give(&vw(self).render) }
	c.get_request_handler = proc "c" (self: ^cef_client_t) -> ^cef_request_handler_t { return give(&vw(self).request) }
	c.get_context_menu_handler = proc "c" (self: ^cef_client_t) -> ^cef_context_menu_handler_t { return give(&vw(self).menu) }
	c.get_jsdialog_handler = proc "c" (self: ^cef_client_t) -> ^cef_jsdialog_handler_t { return give(&vw(self).jsdialog) }
	c.get_permission_handler = proc "c" (self: ^cef_client_t) -> ^cef_permission_handler_t { return give(&vw(self).permission) }
	c.get_download_handler = proc "c" (self: ^cef_client_t) -> ^cef_download_handler_t { return give(&vw(self).download) }
	c.get_find_handler = proc "c" (self: ^cef_client_t) -> ^cef_find_handler_t { return give(&vw(self).find) }
	c.get_dialog_handler = proc "c" (self: ^cef_client_t) -> ^cef_dialog_handler_t { return give(&vw(self).dialog) }
	c.on_process_message_received = proc "c" (self: ^cef_client_t, browser: ^cef_browser_t, frame: ^cef_frame_t, source: i32, msg: ^cef_process_message_t) -> i32 {
		context = main_context
		defer { rel(browser); rel(frame); rel(msg) }
		if msg == nil || from_userfree(msg.get_name(msg)) != PID_MESSAGE do return 0
		v := vw(self)
		args := msg.get_argument_list(msg)
		if args == nil || frame == nil do return 1
		pid := args.get_int(args, 0)
		start := u64(max(0, args.get_double(args, 1)))
		rel(args)
		// a report Iris can hold the process to: its start time is still
		// the one reported (the pid not used again since)
		if pid <= 0 || !renderer_check(pid, start) do return 1
		id := from_userfree(frame.get_identifier(frame))
		if len(id) == 0 do return 1
		if id in v.frames {
			v.frames[id] = {pid, start}
		} else {
			v.frames[strings.clone(id)] = {pid, start}
		}
		if v.tab != nil do renderer_seen(pid)
		return 1
	}

	l := &v.life.c
	l.on_before_popup = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, popup_id: i32, target_url: ^cef_string_t, target_frame_name: ^cef_string_t, disposition: i32, user_gesture: i32, features: ^cef_popup_features_t, wi: ^cef_window_info_t, client: ^^cef_client_t, settings: ^cef_browser_settings_t, extra_info: ^rawptr, no_javascript_access: ^i32) -> i32 {
		context = main_context
		// *client comes with a reference to the opener's client that is
		// Iris's to let go (CEF's C-to-C++ glue adds one when it hands a
		// struct of Iris's back across); a pop-up's own goes to CEF instead
		orig := client != nil ? client^ : nil
		defer { rel(browser); rel(frame); rel(orig) }
		v := vw(self)
		t := v.tab
		if t == nil || !alive(t) || v.host == nil || client == nil do return 1
		u := from_cef(target_url)
		if new_window(t, u, disposition, user_gesture != 0, false) != .Related do return 1 // CEF makes no window: Iris made a tab, or nothing
		// a pop-up that talks to its opener: CEF makes it, windowless, for a
		// tab of Iris's (its View's client); it shares the opener's request
		// context (its container, its cookies)
		pv := popup_tab(t, v, u, popup_id)
		if pv == nil do return 1
		windowless(wi)
		if settings != nil do browser_settings(settings, t.sandboxed)
		client^ = give(&pv.client)
		return 0
	}
	l.on_before_popup_aborted = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t, popup_id: i32) {
		context = main_context
		defer rel(browser)
		opener := browser.get_identifier(browser)
		for x, i in all_views do if x.popup_id == popup_id && x.popup_opener == opener && x.browser == nil {
			// CEF will not make the pop-up after all: its View goes (CEF never
			// calls OnAfterCreated or OnBeforeClose for it), and its tab
			x.popup_id = 0
			if t := x.tab; t != nil {
				if t.cv == x do tab_release_web(t)
				browser_close_later(t)
			}
			unordered_remove(&all_views, i)
			rel(&x.client.c) // Iris's own reference
			break
		}
	}
	l.on_after_created = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t) {
		context = main_context
		v := vw(self)
		v.browser = browser // the reference CEF gave is kept, until OnBeforeClose
		v.host = browser.get_host(browser)
		v.id = browser.get_identifier(browser)
		v.popup_id = 0
		by_id[v.id] = v
		if v.closing || v.tab == nil {
			v.host.close_browser(v.host, 1)
			return
		}
		if p := v.page; p != nil {
			v.host.notify_screen_info_changed(v.host)
			v.host.was_resized(v.host)
			page_apply_hidden(p)
			// a held pop-up paints while held (out of sight), so it can show
			// once it has painted (popup_reveal)
			if v.tab.held do v.host.was_hidden(v.host, 0)
			if v.tab == b.current && !b.chrome_focus do page_focus(p, true)
		}
		if len(v.pending) > 0 {
			u := strings.clone(v.pending, context.temp_allocator)
			set_str(&v.pending, "")
			load_url(v, u)
		}
	}
	l.do_close = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t) -> i32 {
		context = main_context
		rel(browser)
		// the page closed itself (window.close() in a pop-up): its tab goes
		if t := vw(self).tab; t != nil && alive(t) do browser_close_later(t)
		return 0 // windowless: the browser is destroyed now
	}
	l.on_before_close = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t) {
		context = main_context
		v := vw(self)
		id := browser.get_identifier(browser)
		rel(browser)
		// every reference Iris holds goes now, or the page (and its
		// renderer) would live on: matched by id, not by pointer
		if by_id[id] == v do delete_key(&by_id, id)
		for x, i in all_views do if x == v {
			unordered_remove(&all_views, i)
			break
		}
		if t := v.tab; t != nil && t.cv == v {
			// CEF closed it itself (a renderer that died for good)
			t.cv = nil
			page_free(t.page)
			t.page = nil
			v.tab = nil
		}
		rel(v.host)
		rel(v.browser)
		v.host, v.browser = nil, nil
		procs := make([dynamic]Renderer_Proc, context.temp_allocator)
		for _, r in v.frames {
			known := false
			for x in procs do if x == r do known = true
			if !known do append(&procs, r)
		}
		cef_reap_later(procs[:])
		rel(&v.client.c) // Iris's own reference
	}

	ld := &v.load.c
	ld.on_loading_state_change = proc "c" (self: ^cef_load_handler_t, browser: ^cef_browser_t, loading, back, fwd: i32) {
		context = main_context
		defer rel(browser)
		t := vw(self).tab
		if t == nil do return
		t.loading, t.can_back, t.can_forward = loading != 0, back != 0, fwd != 0
		if !t.loading do t.progress = 1
		browser_tab_changed(t)
	}
	ld.on_load_start = proc "c" (self: ^cef_load_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, transition: i32) {
		context = main_context
		defer { rel(browser); rel(frame) }
		v := vw(self)
		if frame.is_main(frame) != 0 {
			// a new document in the main frame: the frames of the one before
			// are gone (the renderers they were in no longer this view's);
			// the new main frame's report may have come first, so it stays
			keep := from_userfree(frame.get_identifier(frame))
			drop := make([dynamic]string, context.temp_allocator)
			for k in v.frames do if k != keep do append(&drop, k)
			for k in drop {
				delete_key(&v.frames, k)
				delete(k)
			}
			watch_forget(v)
			// the reader's page waits only for the blank page it asked for
			if from_userfree(frame.get_url(frame)) != "about:blank" do set_str(&v.reader_html, "")
		}
		if t := v.tab; t != nil && frame.is_main(frame) != 0 {
			u := from_userfree(frame.get_url(frame))
			page_hiding(t, v, frame, u)
			// what cef_sleep.odin asks before a tab may sleep (live
			// connections, typing), counted from the document's start
			if strings.has_prefix(u, "http") do run_in(frame, SLEEP_WATCH_JS)
			browser_page_committed(t, u)
		}
	}
	ld.on_load_end = proc "c" (self: ^cef_load_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, status: i32) {
		context = main_context
		defer { rel(browser); rel(frame) }
		v := vw(self)
		t := v.tab
		if t == nil do return
		// the reader's page into the fresh blank document (cef_extra.odin)
		if frame.is_main(frame) != 0 && len(v.reader_html) > 0 && from_userfree(frame.get_url(frame)) == "about:blank" {
			run_in(frame, fmt.tprintf("document.open(); document.write(%s); document.close();", json_str(v.reader_html, context.temp_allocator)))
			delete(v.reader_html)
			v.reader_html = ""
		}
		page_scripts(t, frame)
		if frame.is_main(frame) != 0 do cef_sleep_woke(t, frame)
		if frame.is_main(frame) != 0 && !tab_is_private(t) && !t.sandboxed do history_record(t.url, t.title)
		if frame.is_main(frame) != 0 do browser_page_finished(t)
	}
	ld.on_load_error = proc "c" (self: ^cef_load_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, code: i32, text: ^cef_string_t, failed: ^cef_string_t) {
		context = main_context
		defer { rel(browser); rel(frame) }
		t := vw(self).tab
		// -3 aborted (a new address came), -20 blocked by Shields
		if t == nil || frame.is_main(frame) == 0 || code == -3 || code == -20 do return
		// an http address tried over https: Iris offers the http one
		if https_is_upgrade(t, from_cef(failed)) {
			browser_load_failed(t, from_cef(failed), false)
			return
		}
		// -200..-299 are certificate errors: the interstitial already says it
		if code <= -200 && code >= -299 do return
		host := display_url(from_cef(failed), context.temp_allocator)
		browser_toast(fmt.tprintf("%s could not be opened (%s)", len(host) > 0 ? host : "The page", from_cef(text)))
	}

	d := &v.display.c
	d.on_address_change = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, url: ^cef_string_t) {
		context = main_context
		defer { rel(browser); rel(frame) }
		t := vw(self).tab
		if t == nil || frame.is_main(frame) == 0 do return
		u := from_cef(url)
		if u == "about:blank" && len(t.url) > 0 do return
		set_str(&t.url, u)
		// a pop-up's first real address: shown now, or closed
		if t.held && u != "about:blank" && len(u) > 0 && !popup_arrived(t, vw(self), u) do return
		h, _ := host_of(u, context.temp_allocator)
		tab_shields_apply(t, h)
		browser_tab_changed(t)
	}
	d.on_title_change = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, title: ^cef_string_t) {
		context = main_context
		defer rel(browser)
		t := vw(self).tab
		if t == nil do return
		set_str(&t.title, clip(from_cef(title), TITLE_MAX))
		if !tab_is_private(t) && !t.sandboxed do history_title(t.url, t.title)
		browser_tab_changed(t)
	}
	d.on_loading_progress_change = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, progress: f64) {
		context = main_context
		defer rel(browser)
		if t := vw(self).tab; t != nil {
			t.progress = progress
			browser_tab_changed(t)
		}
	}
	d.on_fullscreen_mode_change = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, on: i32) {
		context = main_context
		defer rel(browser)
		if p := vw(self).page; p != nil && p.on_fullscreen != nil do p.on_fullscreen(p, on != 0)
	}
	d.on_status_message = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, value: ^cef_string_t) {
		context = main_context
		defer rel(browser)
		if t := vw(self).tab; t != nil do browser_hover_link(t, from_cef(value))
	}
	d.on_cursor_change = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, cursor: uint, type: i32, info: ^cef_cursor_info_t) -> i32 {
		context = main_context
		defer rel(browser)
		if p := vw(self).page; p != nil {
			p.cursor = cursor_of_cef(type)
			if p.on_cursor != nil do p.on_cursor(p)
		}
		return 1
	}
	d.on_console_message = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, level: i32, message: ^cef_string_t, source: ^cef_string_t, line: i32) -> i32 {
		context = main_context
		defer rel(browser)
		return console_message(vw(self), from_cef(message)) ? 1 : 0
	}
	d.on_favicon_urlchange = proc "c" (self: ^cef_display_handler_t, browser: ^cef_browser_t, urls: rawptr) {
		context = main_context
		defer rel(browser)
		v := vw(self)
		if v.tab == nil || v.host == nil || urls == nil || cef_string_list_size(urls) == 0 do return
		s: cef_string_t
		if cef_string_list_value(urls, 0, &s) == 0 do return
		v.host.download_image(v.host, &s, 1, 64, 0, give(&v.icon))
		cef_string_utf16_clear(&s)
	}

	v.icon.c.on_download_image_finished = proc "c" (self: ^cef_download_image_callback_t, url: ^cef_string_t, status: i32, image: ^cef_image_t) {
		context = main_context
		defer rel(image)
		t := vw(self).tab
		if t == nil || image == nil do return
		w, h: i32
		bin := image.get_as_bitmap(image, 1, CEF_COLOR_TYPE_BGRA_8888, CEF_ALPHA_TYPE_PREMULTIPLIED, &w, &h)
		if bin == nil do return
		defer rel(bin)
		n := bin.get_size(bin)
		px := make([]u8, n, context.temp_allocator)
		bin.get_data(bin, raw_data(px), n, 0)
		fitted, fw, fh, ok := favicon_fit(px, int(w), int(h), int(w) * 4)
		if !ok do return
		delete(t.favicon_px)
		t.favicon_px = fitted
		t.favicon_w, t.favicon_h, t.favicon_stride = i32(fw), i32(fh), i32(fw * 4)
		t.favicon_dirty = true
		browser_tab_changed(t)
	}

	r := &v.render.c
	r.get_view_rect = proc "c" (self: ^cef_render_handler_t, browser: ^cef_browser_t, rect: ^cef_rect_t) {
		context = main_context
		defer rel(browser)
		p := vw(self).page
		rect^ = p != nil ? page_view_rect(p) : cef_rect_t{0, 0, 800, 600}
	}
	r.get_screen_info = proc "c" (self: ^cef_render_handler_t, browser: ^cef_browser_t, info: ^cef_screen_info_t) -> i32 {
		context = main_context
		defer rel(browser)
		p := vw(self).page
		if p == nil do return 0
		info.device_scale_factor = f32(p.scale)
		info.depth, info.depth_per_component = 24, 8
		info.rect = page_view_rect(p)
		info.available_rect = info.rect
		return 1
	}
	r.on_paint = proc "c" (self: ^cef_render_handler_t, browser: ^cef_browser_t, kind: i32, n: uint, rects: ^cef_rect_t, buffer: rawptr, w, h: i32) {
		context = main_context
		defer rel(browser)
		v := vw(self)
		if p := v.page; p != nil do page_paint(p, kind, ([^]cef_rect_t)(rects)[:n], buffer, w, h)
	}
	r.on_accelerated_paint = proc "c" (self: ^cef_render_handler_t, browser: ^cef_browser_t, kind: i32, n: uint, rects: ^cef_rect_t, info: rawptr) {
		context = main_context
		defer rel(browser)
		v := vw(self)
		p := v.page
		if p == nil do return
		// a woken tab shows its last frame until it has loaded again
		if p.hold && now_s() < p.hold_until do return
		if !page_paint_gpu(p, kind, cast(^cef_accelerated_paint_info_t)info) {
			// the DMA-BUF could not be imported here: this browser is made
			// again with frames through OnPaint (and so is every later one)
			if t := v.tab; t != nil do cef_view_remake_software(t)
		}
	}
	// a drag from the page (a link, an image, selected text): Iris has no
	// drag and drop into or out of its pages yet, so it is refused here,
	// and Chromium ends it at once; nothing of the drag's data is ever
	// opened (no tab, no navigation)
	r.start_dragging = proc "c" (self: ^cef_render_handler_t, browser: ^cef_browser_t, drag_data: rawptr, allowed_ops: i32, x, y: i32) -> i32 {
		rel(browser)
		rel(drag_data)
		return 0
	}
	r.on_popup_show = proc "c" (self: ^cef_render_handler_t, browser: ^cef_browser_t, show: i32) {
		context = main_context
		defer rel(browser)
		if p := vw(self).page; p != nil do page_popup_show(p, show != 0)
	}
	r.on_popup_size = proc "c" (self: ^cef_render_handler_t, browser: ^cef_browser_t, rect: ^cef_rect_t) {
		context = main_context
		defer rel(browser)
		if p := vw(self).page; p != nil do p.popup = rect^
	}

	q := &v.request.c
	q.on_before_browse = proc "c" (self: ^cef_request_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, request: ^cef_request_t, gesture: i32, redirect: i32) -> i32 {
		context = main_context
		defer { rel(browser); rel(frame); rel(request) }
		v := vw(self)
		t := v.tab
		if t == nil do return 0
		u := from_userfree(request.get_url(request))
		// Chromium's own pages (chrome://, devtools://, about:flags...) are
		// not part of Iris, in no frame
		if internal_url(u) do return 1
		if frame.is_main(frame) == 0 do return 0
		method := from_userfree(request.get_method(request))
		v.posted = method != "GET" && method != ""
		// a form sent (POST): never turned into another address (its body
		// would be lost, or sent twice); across the sandbox's edge only from
		// inside the sandbox (sandbox_move_for): a normal tab never sends a
		// form, with your cookies, to a site Iris does not trust
		if v.posted {
			if strings.has_prefix(u, "http") && untrusted(u) != t.sandboxed {
				switch sandbox_move_for(t.sandboxed, true) {
				case .Reload, .Stay:
					// (Reload is never given for a body; Stay: a sandboxed
					// page's form to a trusted site goes from the sandbox)
				case .Refuse:
					browser_toast(strings.concatenate({"Iris did not send this form to ", display_url(u, context.temp_allocator), ": the site is not secure"}, context.temp_allocator))
					return 1
				}
			}
			h, _ := host_of(u, context.temp_allocator)
			tab_shields_apply(t, h)
			return 0
		}
		// an http address goes over https first, where it can (features.odin)
		if https_wanted(t, u) {
			tab_load_later(t, strings.clone(u))
			return 1
		}
		// a Google result goes straight to the site
		if target, ok := unwrap_redirect(u); ok {
			tab_load_later(t, target)
			return 1
		}
		// a link you click loses its tracking parameters
		if gesture != 0 && redirect == 0 {
			if clean := shields_clean_url(u); clean != u {
				tab_load_later(t, strings.clone(clean))
				return 1
			}
		}
		// into or out of the sandbox: the tab is made again
		if strings.has_prefix(u, "http") && untrusted(u) != t.sandboxed {
			tab_load_later(t, strings.clone(u))
			return 1
		}
		// (the address shown changes when the page commits:
		// OnAddressChange; a navigation not yet committed is not where the
		// tab is)
		h, _ := host_of(u, context.temp_allocator)
		tab_shields_apply(t, h)
		return 0
	}
	q.on_open_urlfrom_tab = proc "c" (self: ^cef_request_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, target: ^cef_string_t, disposition: i32, gesture: i32) -> i32 {
		context = main_context
		defer { rel(browser); rel(frame) }
		t := vw(self).tab
		// a middle click, Ctrl+click or Shift+click on a link
		if t == nil || disposition == CEF_WOD_CURRENT_TAB do return 0
		new_window(t, from_cef(target), disposition, gesture != 0, true)
		return 1
	}
	q.get_resource_request_handler = proc "c" (self: ^cef_request_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, request: ^cef_request_t, nav, download: i32, initiator: ^cef_string_t, disable: ^i32) -> ^cef_resource_request_handler_t {
		defer { rel(browser); rel(frame); rel(request) }
		v := vw(self)
		if intrinsics.atomic_load(&v.shield_on) == 0 do return nil
		return give(&v.resource)
	}
	q.on_certificate_error = proc "c" (self: ^cef_request_handler_t, browser: ^cef_browser_t, cert_error: i32, url: ^cef_string_t, ssl: rawptr, cb: ^cef_callback_t) -> i32 {
		context = main_context
		defer { rel(browser); rel(ssl) }
		t := vw(self).tab
		u := from_cef(url)
		if t == nil {
			rel(cb)
			return 0
		}
		switch cert_decide(t, u) {
		case .Upgrade_Failed:
			// an https try of an http address: it fails, and Iris offers
			// http (on_load_error, https_failed)
			rel(cb)
			return 0
		case .Allowed:
			// you chose to see it, in this sandboxed tab (interstitial.odin)
			cb.cont(cb)
			rel(cb)
			return 1
		case .Block:
		}
		// a certificate that fails: never let through on its own; Iris's
		// page over the tab says so, and "Show anyway" waits behind Details
		rel(cb)
		reason, code := cef_cert_error_text(cert_error)
		cert_block(t, u, reason, code, nil)
		return 0
	}
	q.on_render_process_terminated = proc "c" (self: ^cef_request_handler_t, browser: ^cef_browser_t, status: i32, code: i32, text: ^cef_string_t) {
		context = main_context
		defer rel(browser)
		if vw(self).tab != nil do browser_toast("This page stopped working: reload it to go on")
	}

	// on CEF's IO thread: only the View's atomics and the matcher are read
	v.resource.c.on_before_resource_load = proc "c" (self: ^cef_resource_request_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, request: ^cef_request_t, cb: ^cef_callback_t) -> i32 {
		context = runtime.default_context()
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		defer { rel(browser); rel(frame); rel(request); rel(cb) }
		v := vw(self)
		m := cef_matcher()
		if m == nil || intrinsics.atomic_load(&v.shield_on) == 0 do return RV_CONTINUE
		rt := request.get_resource_type(request)
		if rt == RT_MAIN_FRAME do return RV_CONTINUE
		url := from_userfree(request.get_url(request))
		page := from_userfree(request.get_first_party_for_cookies(request))
		host, _ := host_of(url, context.temp_allocator)
		page_host, _ := host_of(page, context.temp_allocator)
		if len(page_host) == 0 do page_host = host
		blocked := matcher_blocks(m, url, host, page_host, intrinsics.atomic_load(&v.page_ignore), req_type_of(rt), rt == RT_SUB_FRAME)
		return blocked ? RV_CANCEL : RV_CONTINUE
	}

	v.menu.c.on_before_context_menu = proc "c" (self: ^cef_context_menu_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, params: ^cef_context_menu_params_t, model: ^cef_menu_model_t) {
		context = main_context
		defer { rel(browser); rel(frame); rel(params); rel(model) }
		// Iris draws its own menu: CEF's stays empty
		model.clear(model)
		t := vw(self).tab
		if t == nil do return
		flags := params.get_type_flags(params)
		info: Context_Info
		info.link = from_userfree(params.get_link_url(params))
		if params.get_media_type(params) == CM_MEDIATYPE_IMAGE do info.image = from_userfree(params.get_source_url(params))
		if mt := params.get_media_type(params); mt == CM_MEDIATYPE_VIDEO || mt == CM_MEDIATYPE_AUDIO do info.media = from_userfree(params.get_source_url(params))
		info.editable = flags & CM_TYPEFLAG_EDITABLE != 0
		info.selection = flags & CM_TYPEFLAG_SELECTION != 0
		browser_context_menu_at(t, f32(params.get_xcoord(params)), f32(params.get_ycoord(params)), info)
	}

	j := &v.jsdialog.c
	j.on_jsdialog = proc "c" (self: ^cef_jsdialog_handler_t, browser: ^cef_browser_t, origin: ^cef_string_t, type: i32, message: ^cef_string_t, default_text: ^cef_string_t, cb: ^cef_jsdialog_callback_t, suppress: ^i32) -> i32 {
		context = main_context
		defer rel(browser)
		t := vw(self).tab
		// a dialog shows over its own page only, one at a time; the others
		// are answered at once (no to a question), so no page waits forever
		if t == nil || !browser_dialog_admit(t) {
			if type == JSDIALOGTYPE_ALERT {
				suppress^ = 1
				rel(cb)
				return 0
			}
			cb.cont(cb, 0, nil)
			rel(cb)
			return 1
		}
		b.dialog_tab = t
		b.asks += 1
		b.dialogs[b.asks] = {t, cb, int(type)}
		host := display_url(t.url, context.temp_allocator)
		chrome_dialog(b.asks, int(type), len(host) > 0 ? host : "This page", from_cef(message), type == JSDIALOGTYPE_PROMPT ? from_cef(default_text) : "")
		return 1
	}
	j.on_before_unload_dialog = proc "c" (self: ^cef_jsdialog_handler_t, browser: ^cef_browser_t, message: ^cef_string_t, is_reload: i32, cb: ^cef_jsdialog_callback_t) -> i32 {
		context = main_context
		defer rel(browser)
		t := vw(self).tab
		if t == nil || !browser_dialog_admit(t) {
			cb.cont(cb, 1, nil) // yes to leaving the page
			rel(cb)
			return 1
		}
		b.dialog_tab = t
		b.asks += 1
		b.dialogs[b.asks] = {t, cb, 3}
		host := display_url(t.url, context.temp_allocator)
		chrome_dialog(b.asks, 3, len(host) > 0 ? host : "This page", from_cef(message), "")
		return 1
	}
	j.on_reset_dialog_state = proc "c" (self: ^cef_jsdialog_handler_t, browser: ^cef_browser_t) {
		context = main_context
		defer rel(browser)
		if t := vw(self).tab; t != nil && b.dialog_tab == t do chrome_dismiss_dialog()
	}

	pm := &v.permission.c
	pm.on_request_media_access_permission = proc "c" (self: ^cef_permission_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, origin: ^cef_string_t, perms: u32, cb: ^cef_media_access_callback_t) -> i32 {
		context = main_context
		defer { rel(browser); rel(frame) }
		t := vw(self).tab
		// nothing of your computer for a site in the sandbox
		if t == nil || t.sandboxed {
			cb.cont(cb, CEF_MEDIA_PERMISSION_NONE)
			rel(cb)
			return 1
		}
		ask_permission(t, {tab = t, media = cb, perms = perms}, "use your camera or microphone")
		return 1
	}
	pm.on_show_permission_prompt = proc "c" (self: ^cef_permission_handler_t, browser: ^cef_browser_t, id: u64, origin: ^cef_string_t, perms: u32, cb: ^cef_permission_prompt_callback_t) -> i32 {
		context = main_context
		defer rel(browser)
		t := vw(self).tab
		if t == nil || t.sandboxed {
			cb.cont(cb, CEF_PERMISSION_RESULT_DENY)
			rel(cb)
			return 1
		}
		if perms == CEF_PERMISSION_TYPE_POINTER_LOCK {
			cb.cont(cb, CEF_PERMISSION_RESULT_ACCEPT)
			rel(cb)
			return 1
		}
		ask_permission(t, {tab = t, prompt = cb, perms = perms, id = id}, permission_words(perms))
		return 1
	}
	pm.on_dismiss_permission_prompt = proc "c" (self: ^cef_permission_handler_t, browser: ^cef_browser_t, id: u64, result: i32) {
		context = main_context
		defer rel(browser)
		for k, a in b.permissions do if a.prompt != nil && a.id == id {
			rel(a.prompt)
			delete_key(&b.permissions, k)
			break
		}
	}

	dl := &v.download.c
	dl.can_download = proc "c" (self: ^cef_download_handler_t, browser: ^cef_browser_t, url: ^cef_string_t, method: ^cef_string_t) -> i32 {
		context = main_context
		defer rel(browser)
		t := vw(self).tab
		if t != nil && t.sandboxed {
			browser_toast("Downloads are off for sites in the sandbox")
			return 0
		}
		return 1
	}
	dl.on_before_download = proc "c" (self: ^cef_download_handler_t, browser: ^cef_browser_t, item: ^cef_download_item_t, suggested: ^cef_string_t, cb: ^cef_before_download_callback_t) -> i32 {
		context = main_context
		defer { rel(browser); rel(item); rel(cb) }
		cef_download_start(item, from_cef(suggested), cb)
		return 1
	}
	dl.on_download_updated = proc "c" (self: ^cef_download_handler_t, browser: ^cef_browser_t, item: ^cef_download_item_t, cb: ^cef_download_item_callback_t) {
		context = main_context
		defer { rel(browser); rel(item) }
		cef_download_update(item, cb) // keeps cb
	}

	v.find.c.on_find_result = proc "c" (self: ^cef_find_handler_t, browser: ^cef_browser_t, id: i32, count: i32, rect: ^cef_rect_t, active: i32, final: i32) {
		context = main_context
		defer rel(browser)
		if final != 0 {
			ui.find_count = int(count)
			chrome_push()
		}
	}

	v.dialog.c.on_file_dialog = proc "c" (self: ^cef_dialog_handler_t, browser: ^cef_browser_t, mode: i32, title: ^cef_string_t, default_path: ^cef_string_t, filters: rawptr, extensions: rawptr, descriptions: rawptr, cb: ^cef_file_dialog_callback_t) -> i32 {
		context = main_context
		defer rel(browser)
		t := vw(self).tab
		if t == nil || t.sandboxed || (mode != FILE_DIALOG_OPEN && mode != FILE_DIALOG_OPEN_MULTIPLE) {
			// the sandbox reads no files of yours; saving and folders: not asked
			if t != nil && t.sandboxed do browser_toast("Files can't be uploaded to sites in the sandbox")
			cb.cancel(cb)
			rel(cb)
			return 1
		}
		portal_open_file(mode == FILE_DIALOG_OPEN_MULTIPLE, proc(d: rawptr, files: []cstring) {
			cb := cast(^cef_file_dialog_callback_t)d
			defer rel(cb)
			if len(files) < 2 {
				cb.cancel(cb)
				return
			}
			list := cef_string_list_alloc()
			for f in files do if f != nil {
				s := cef_str(string(f))
				cef_string_list_append(list, &s)
			}
			cb.cont(cb, list)
			cef_string_list_free(list)
		}, cb)
		return 1
	}
}

} // when ENGINE_CEF
