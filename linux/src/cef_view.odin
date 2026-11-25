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
	/// the renderer processes it reported (cef_engine.odin's reaper)
	pids:        [dynamic]i32,
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
	delete(v.pids)
	delete(v.pending)
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

views_unreported :: proc() -> bool {
	for v in all_views do if v.tab != nil && len(v.pids) == 0 do return true
	return false
}

views_use_pid :: proc(pid: i32) -> bool {
	for v in all_views do if v.tab != nil do for p in v.pids do if p == pid do return true
	return false
}

/// Iris quits: every browser closes (CEF must see them close before it
/// shuts down)
views_close_all :: proc() {
	for t in b.tabs do tab_release_web(t)
	for i := 0; i < 200 && len(all_views) > 0; i += 1 {
		cef_do_message_loop_work()
		time.sleep(10 * time.Millisecond)
	}
}

tab_has_view :: proc(t: ^Tab) -> bool { return t.cv != nil }

// ---------------------------------------------------------------- making one

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

	wi := cef_window_info_t{size = size_of(cef_window_info_t)}
	wi.windowless_rendering_enabled = 1
	wi.shared_texture_enabled = 0 // frames come through OnPaint (no shared textures on Linux)
	wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY
	bs := cef_browser_settings_t{size = size_of(cef_browser_settings_t)}
	bs.windowless_frame_rate = CEF_FPS
	bs.background_color = 0xFFFFFFFF
	if t.sandboxed {
		// a site Iris does not trust: no clipboard, no WebGL
		bs.javascript_access_clipboard = STATE_DISABLED
		bs.javascript_dom_paste = STATE_DISABLED
		bs.webgl = STATE_DISABLED
	}
	ctx := tab_context(t) // its reference goes to CEF
	url := cef_str("")
	if cef_browser_host_create_browser(&wi, give(&v.client), &url, &bs, nil, ctx) == 0 {
		browser_toast("The page could not be made (CEF)")
	}

	t.page = page_new(v)
	v.page = t.page
	t.page.user = t
	t.page.on_frame = proc(p: ^Page) { browser_page_frame(cast(^Tab)p.user) }
	t.page.on_cursor = proc(p: ^Page) { browser_page_cursor(cast(^Tab)p.user) }
	t.page.on_fullscreen = proc(p: ^Page, on: bool) { browser_fullscreen(on) }
	browser_attach(t)
	return v
}

/// the view goes (to be made again, in or out of the sandbox): the browser
/// closes now, and nothing of Iris's keeps it
tab_release_web :: proc(t: ^Tab) {
	v := t.cv
	if v == nil do return
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

@(private="file") main_frame :: proc(v: ^View) -> ^cef_frame_t {
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

/// opens an address; a site Iris does not trust goes to the sandbox, and
/// a trusted one comes out of it
tab_load :: proc(t: ^Tab, u0: string) {
	if len(u0) == 0 do return
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

/// the selected text, in a field too (getSelection() leaves fields out)
@(private="file") SELECTION_JS :: `(() => { const e = document.activeElement; if (e && (e.tagName === 'INPUT' || e.tagName === 'TEXTAREA') && typeof e.selectionStart === 'number') return e.value.substring(e.selectionStart, e.selectionEnd); return window.getSelection().toString(); })()`

tab_edit :: proc(t: ^Tab, cmd: string) {
	v := t.cv
	if v == nil do return
	switch cmd {
	case EDIT_COPY, EDIT_CUT:
		// the selection goes to the desktop's clipboard (CEF's has none)
		cut := cmd == EDIT_CUT
		tab_run(t, SELECTION_JS, cut ? proc(t: ^Tab, s: string) {
			if len(s) > 0 do clipboard_offer(s)
			if v := t.cv; v != nil do if f := main_frame(v); f != nil {
				f.cut(f)
				rel(f)
			}
		} : proc(t: ^Tab, s: string) {
			if len(s) > 0 do clipboard_offer(s)
		})
	case EDIT_PASTE:
		if t.page != nil do page_commit_text(t.page, clipboard_text)
	case EDIT_SELECT_ALL:
		if f := main_frame(v); f != nil {
			f.select_all(f)
			rel(f)
		}
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

// A script's answer comes back as a console message with a token only Iris
// knows (one per answer): CEF's C API has no result for ExecuteJavaScript.

@(private="file") Job :: struct {
	tab_id: int,
	token:  string,
	done:   proc(t: ^Tab, result: string),
}

@(private="file") jobs: [dynamic]Job
@(private="file") ANSWER :: "\x01iris:"
@(private="file") MEDIA :: "\x01iris-media:"
@(private="file") media_token: string

@(private="file") token :: proc() -> string {
	id := new_id()
	return id
}

@(private="file") run_in :: proc(f: ^cef_frame_t, js: string) {
	if f == nil do return
	s := cef_str(js)
	url := cef_str("iris://script")
	f.execute_java_script(f, &s, &url, 0)
}

/// runs a script (an expression) in the page; done gets its result as text
tab_run :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
	v := t.cv
	if v == nil do return
	f := main_frame(v)
	if f == nil do return
	defer rel(f)
	tk := token()
	append(&jobs, Job{t.id, tk, done})
	run_in(f, fmt.tprintf("(() => { let r; try { r = String((() => (%s))()); } catch (e) { r = ''; } console.info(%s + r); })();", js, json_str(fmt.tprintf("%s%s:", ANSWER, tk), context.temp_allocator)))
}

/// a page's sound and video, told to Iris (so a tab that plays is never
/// put to sleep)
@(private="file") media_watch :: proc() -> string {
	if media_token == "" do media_token = token()
	tag := json_str(fmt.tprintf("%s%s:", MEDIA, media_token), context.temp_allocator)
	return fmt.tprintf(`(() => {
  if (window.__irisMedia) return; window.__irisMedia = true;
  const tell = () => { const on = [...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.ended && !m.muted); console.info(%s + (on ? '1' : '0')); };
  for (const e of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) document.addEventListener(e, tell, true);
})();`, tag)
}

@(private="file") console_message :: proc(v: ^View, msg: string) -> bool {
	if strings.has_prefix(msg, MEDIA) {
		rest := msg[len(MEDIA):]
		if len(media_token) == 0 || !strings.has_prefix(rest, media_token) do return true
		p := v.page
		if p == nil do return true
		on := strings.has_suffix(rest, ":1")
		if on != p.media {
			p.media = on
			page_apply_hidden(p)
		}
		if t := v.tab; t != nil do browser_page_audio(t, on)
		return true
	}
	if !strings.has_prefix(msg, ANSWER) do return false
	rest := msg[len(ANSWER):]
	for j, i in jobs {
		if !strings.has_prefix(rest, j.token) || len(rest) <= len(j.token) || rest[len(j.token)] != ':' do continue
		ordered_remove(&jobs, i)
		defer delete(j.token)
		// the tab may have closed while the page answered
		for t in b.tabs do if t.id == j.tab_id && t.cv == v {
			j.done(t, rest[len(j.token) + 1:])
			break
		}
		if p := b.peek; p != nil && p.id == j.tab_id && p.cv == v do j.done(p, rest[len(j.token) + 1:])
		return true
	}
	return true
}

/// the scripts a page gets, once it has loaded (frame: the one that did)
@(private="file") page_scripts :: proc(t: ^Tab, f: ^cef_frame_t) {
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
	run_in(f, media_watch())
}

/// what Shields hides on this page, as a style sheet (early: at load start)
@(private="file") page_hiding :: proc(t: ^Tab, v: ^View, f: ^cef_frame_t) {
	if intrinsics.atomic_load(&v.shield_on) == 0 do return
	h, _ := host_of(t.url, context.temp_allocator)
	css := matcher_css(cef_matcher(), t.url, h, context.temp_allocator)
	if len(css) == 0 do return
	run_in(f, fmt.tprintf(`(() => { const add = () => { const s = document.createElement('style'); s.textContent = %s; (document.head || document.documentElement).appendChild(s); }; if (document.documentElement) add(); else document.addEventListener('readystatechange', add, { once: true }); })();`, json_str(css, context.temp_allocator)))
}

// ---------------------------------------------------------------- pop-ups and new tabs

/// a page asks for a new window (OnBeforePopup) or a link wants a tab of its
/// own (OnOpenURLFromTab): the same choice as the WPE engine's
/// (new_window_choice), and always a tab Iris makes itself with the address,
/// never a window CEF fills (so never a blank tab)
@(private="file") new_window :: proc(t: ^Tab, u: string, disposition: i32, gesture: bool, from_link: bool) {
	page_host, _ := host_of(t.url, context.temp_allocator)
	shield := shields_on_for(page_host)
	tabby := disposition == CEF_WOD_NEW_FOREGROUND_TAB || disposition == CEF_WOD_NEW_BACKGROUND_TAB
	link := from_link || (tabby && gesture)
	background := disposition == CEF_WOD_NEW_BACKGROUND_TAB || !gesture
	real := len(u) > 0 && u != "about:blank"
	switch new_window_choice(u, t.url, link, gesture, t.sandboxed, shield) {
	case .Own_Tab, .Related:
		// (Related: the WPE engine gives the page a window it fills; here the
		// address opens in a tab of its own: the opener link is lost)
		if real do open_later(t, u, background)
	case .Block:
		if !link && shield && !t.sandboxed do browser_toast("Pop-up blocked")
	}
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
		if !browser_has_tab(o.t) || o.t.id != o.id do return
		browser_open_link(o.t, o.url, o.background)
	}, o)
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
		if args == nil do return 1
		pid := args.get_int(args, 0)
		rel(args)
		if pid > 0 {
			known := false
			for p in v.pids do if p == pid do known = true
			if !known do append(&v.pids, pid)
		}
		return 1
	}

	l := &v.life.c
	l.on_before_popup = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, popup_id: i32, target_url: ^cef_string_t, target_frame_name: ^cef_string_t, disposition: i32, user_gesture: i32, features: ^cef_popup_features_t, wi: ^cef_window_info_t, client: ^^cef_client_t, settings: ^cef_browser_settings_t, extra_info: ^rawptr, no_javascript_access: ^i32) -> i32 {
		context = main_context
		defer { rel(browser); rel(frame) }
		if t := vw(self).tab; t != nil do new_window(t, from_cef(target_url), disposition, user_gesture != 0, false)
		return 1 // CEF makes no window: Iris made a tab, or nothing
	}
	l.on_after_created = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t) {
		context = main_context
		v := vw(self)
		v.browser = browser // the reference CEF gave is kept, until OnBeforeClose
		v.host = browser.get_host(browser)
		v.id = browser.get_identifier(browser)
		by_id[v.id] = v
		if v.closing || v.tab == nil {
			v.host.close_browser(v.host, 1)
			return
		}
		if p := v.page; p != nil {
			v.host.notify_screen_info_changed(v.host)
			v.host.was_resized(v.host)
			page_apply_hidden(p)
			if v.tab == b.current && !b.chrome_focus do page_focus(p, true)
		}
		if len(v.pending) > 0 {
			u := strings.clone(v.pending, context.temp_allocator)
			set_str(&v.pending, "")
			load_url(v, u)
		}
	}
	l.do_close = proc "c" (self: ^cef_life_span_handler_t, browser: ^cef_browser_t) -> i32 {
		rel(browser)
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
		cef_reap_later(v.pids[:])
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
		if t := v.tab; t != nil && frame.is_main(frame) != 0 {
			page_hiding(t, v, frame)
			browser_page_committed(t, from_userfree(frame.get_url(frame)))
		}
	}
	ld.on_load_end = proc "c" (self: ^cef_load_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, status: i32) {
		context = main_context
		defer { rel(browser); rel(frame) }
		t := vw(self).tab
		if t == nil do return
		page_scripts(t, frame)
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
		if p := vw(self).page; p != nil do page_paint(p, kind, ([^]cef_rect_t)(rects)[:n], buffer, w, h)
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
		t := vw(self).tab
		if t == nil || frame.is_main(frame) == 0 do return 0
		u := from_userfree(request.get_url(request))
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
		set_str(&t.url, u)
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
