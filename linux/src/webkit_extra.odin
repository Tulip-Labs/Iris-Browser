// The WebKit calls Iris 2.3's features make (sound, the reader, the peek,
// the privacy report, https first), each in one small proc here, so the
// features themselves (features.odin, reader.odin, peek.odin, privacy.odin,
// palette.odin, spaces.odin) never touch the engine and can be routed
// through another one later.
package iris

import "core:strings"

// ---------------------------------------------------------------- signals

/// the signals 2.3 listens to on a tab's view: sound starting and stopping,
/// a page committed or finished, a load that failed (WebKit tells; nothing
/// is polled)
tab_connect_extra :: proc(t: ^Tab, w: ^WebKitWebView) {
	on(w, "notify::is-playing-audio", rawptr(proc "c" (w: ^WebKitWebView, spec: rawptr, t: ^Tab) {
		context = main_context
		t.audio = webkit_web_view_is_playing_audio(w) != 0
		browser_tab_changed(t)
	}), t)
	on(w, "load-changed", rawptr(proc "c" (w: ^WebKitWebView, e: u32, t: ^Tab) {
		context = main_context
		switch e {
		case WEBKIT_LOAD_COMMITTED: page_committed(t)
		case WEBKIT_LOAD_FINISHED: page_finished(t)
		}
	}), t, after = true)
	on(w, "load-failed", rawptr(proc "c" (w: ^WebKitWebView, e: u32, uri: cstring, err: ^GError, t: ^Tab) -> gboolean {
		context = main_context
		code := err != nil ? err.code : 0
		page_failed(t, string(uri), code)
		return 0 // WebKit shows its own error page
	}), t)
	if t.muted do engine_set_muted(t, true)
}

/// what a tab leaves behind that 2.3 added
tab_free_extra :: proc(t: ^Tab) {
	for h in t.trackers do delete(h)
	delete(t.trackers)
	delete(t.space)
	delete(t.upgraded_from)
	if t.own_context != nil {
		unref(t.own_context)
		t.own_context = nil
	}
}

// ---------------------------------------------------------------- calls

/// the tab's sound off or on
engine_set_muted :: proc(t: ^Tab, on: bool) {
	if t.web != nil do webkit_web_view_set_is_muted(t.web, on ? 1 : 0)
}

/// the web process of a view with a context of its own ends now (a peek
/// closing: nothing of it stays behind)
engine_end_process :: proc(t: ^Tab) {
	if t.web != nil do webkit_web_view_terminate_web_process(t.web)
}

/// a web context for one view alone (a peek): its own web processes, gone
/// with it; the same memory limits as every other
engine_new_context :: proc() -> ^WebKitWebContext {
	ctx := cast(^WebKitWebContext)gnew(webkit_web_context_get_type(), {name = "memory-pressure-settings", value = rawptr(pressure()), type = webkit_memory_pressure_settings_get_type(), boxed = true})
	webkit_web_context_set_cache_model(ctx, 0) // document viewer: no cache of its own to keep
	return ctx
}

/// a page Iris made (the reader's), shown in the tab with the address it came from
engine_load_html :: proc(t: ^Tab, html, base: string) {
	if t.web != nil do webkit_web_view_load_html(t.web, cstr(html), cstr(base))
}

/// a whole-text copy of the view's address, as WebKit has it
engine_uri :: proc(t: ^Tab) -> string {
	if t.web == nil do return ""
	u := webkit_web_view_get_uri(t.web)
	return u != nil ? string(u) : ""
}

/// runs a script in a world of Iris's own beside the page's (the page's
/// scripts cannot see or change it); done gets its result as text
engine_run_isolated :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
	if t.web == nil do return
	Job :: struct {
		t:    ^Tab,
		id:   int,
		done: proc(t: ^Tab, result: string),
	}
	j := new(Job)
	j^ = {t, t.id, done}
	webkit_web_view_evaluate_javascript(t.web, cstr(js), -1, "iris", nil, nil, rawptr(proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
		context = main_context
		j := cast(^Job)d
		defer free(j)
		v := webkit_web_view_evaluate_javascript_finish(cast(^WebKitWebView)o, res, nil)
		if v == nil do return
		defer unref(v)
		// the tab may have closed while the page answered
		if !browser_tab_alive(j.t) || j.t.id != j.id do return
		s := jsc_value_to_string(v)
		if s == nil do return
		j.done(j.t, string(s))
		g_free(rawptr(s))
	}), j)
}

// ---------------------------------------------------------------- what the signals mean

/// a new page is in the tab: what Iris knew of the last one goes
@(private="file") page_committed :: proc(t: ^Tab) {
	t.article = false
	for h in t.trackers do delete(h)
	clear(&t.trackers)
	if t.reader_pending {
		t.reader, t.reader_pending = true, false
	} else {
		t.reader = false
	}
	// over https at last: an upgrade that worked is forgotten
	if len(t.upgraded_from) > 0 && strings.has_prefix(engine_uri(t), "https://") {
		delete(t.upgraded_from)
		t.upgraded_from = ""
	}
	browser_tab_changed(t)
}

@(private="file") page_finished :: proc(t: ^Tab) {
	if t.reader do return
	survey_page(t)
}

@(private="file") page_failed :: proc(t: ^Tab, uri: string, code: i32) {
	// a load that was stopped or replaced is no failure
	WEBKIT_NETWORK_ERROR_CANCELLED :: 302
	WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE :: 102
	if code == WEBKIT_NETWORK_ERROR_CANCELLED || code == WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE do return
	https_failed(t, uri)
}
