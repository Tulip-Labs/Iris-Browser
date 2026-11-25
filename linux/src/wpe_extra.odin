// The WPE engine's side of Iris 2.3's features (engine_api.odin): muting,
// a script in a world of Iris's own, the reader's page, a peek's own
// processes, and the signals page_events.odin acts on.
package iris

// (not indented: the whole file is this engine's)
when !ENGINE_CEF {

/// the signals 2.3 listens to on a view (WebKit tells; nothing is polled)
tab_connect_extra :: proc(t: ^Tab, w: ^WebKitWebView) {
	on(w, "notify::is-playing-audio", rawptr(proc "c" (w: ^WebKitWebView, spec: rawptr, t: ^Tab) {
		context = main_context
		browser_page_audio(t, webkit_web_view_is_playing_audio(w) != 0)
	}), t)
	on(w, "load-changed", rawptr(proc "c" (w: ^WebKitWebView, e: u32, t: ^Tab) {
		context = main_context
		switch e {
		case WEBKIT_LOAD_COMMITTED:
			u := webkit_web_view_get_uri(w)
			browser_page_committed(t, u != nil ? string(u) : "")
		case WEBKIT_LOAD_FINISHED: browser_page_finished(t)
		}
	}), t, after = true)
	on(w, "load-failed", rawptr(proc "c" (w: ^WebKitWebView, e: u32, uri: cstring, err: ^GError, t: ^Tab) -> gboolean {
		context = main_context
		WEBKIT_NETWORK_ERROR_CANCELLED :: 302
		WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE :: 102
		code := err != nil ? err.code : 0
		browser_load_failed(t, string(uri), code == WEBKIT_NETWORK_ERROR_CANCELLED || code == WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE)
		return 0 // WebKit shows its own error page
	}), t)
	if t.muted do tab_set_muted(t, true)
}

/// the tab's sound off or on
tab_set_muted :: proc(t: ^Tab, on: bool) {
	if t.web != nil do webkit_web_view_set_is_muted(t.web, on ? 1 : 0)
}

/// the tab's next view gets a web context of its own (a peek): its web
/// processes end with it
tab_isolate :: proc(t: ^Tab) {
	t.isolated = true
	if t.own_context == nil {
		ctx := cast(^WebKitWebContext)gnew(webkit_web_context_get_type(), {name = "memory-pressure-settings", value = rawptr(pressure()), type = webkit_memory_pressure_settings_get_type(), boxed = true})
		webkit_web_context_set_cache_model(ctx, 0) // document viewer: no cache of its own to keep
		t.own_context = ctx
	}
}

/// a view with a context of its own going: its process ends now, and the
/// context with the tab (tab_view_free)
tab_end_isolated :: proc(t: ^Tab) {
	if t.web != nil && t.own_context != nil do webkit_web_view_terminate_web_process(t.web)
}

tab_view_free :: proc(t: ^Tab) {
	if t.own_context != nil {
		unref(t.own_context)
		t.own_context = nil
	}
}

/// a page Iris made (the reader's), in the tab, with the address it came
/// from; it commits as a page of its own (reader_pending becomes reader)
tab_show_html :: proc(t: ^Tab, html, base: string) {
	if t.web == nil do return
	t.reader_pending = true
	webkit_web_view_load_html(t.web, cstr(html), cstr(base))
}

/// out of the reader: the article's own page, as it was (back)
tab_reader_exit :: proc(t: ^Tab) {
	if t.can_back {
		tab_back(t)
	} else {
		tab_load(t, t.url)
	}
}

/// runs a script in a world of Iris's own beside the page's (the page's
/// scripts cannot see or change it); done gets its result as text
tab_run_isolated :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
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

// ---------------------------------------------------------------- light or dark

WPE_SETTING_DARK_MODE :: "/wpe-platform/dark-mode"
WPE_SETTINGS_SOURCE_APPLICATION :: 1

@(private="file") pages_dark: Maybe(bool)
@(private="file") display_dark: Maybe(bool)
/// the first view made the display (Iris does not make it earlier)
@(private="file") display_made: bool

/// pages follow Iris's light or dark (prefers-color-scheme): WPE's
/// platform setting on Iris's display, every view on it at once
engine_set_color_scheme :: proc(dark: bool) {
	pages_dark = dark
	// the display is made with the first view (tab_ensure_web): not before
	if display_made do color_scheme_sync()
}

/// the display told, if it does not know yet (before each new view)
color_scheme_sync :: proc() {
	display_made = true
	want, ok := pages_dark.?
	if !ok do return
	if have, told := display_dark.?; told && have == want do return
	d := display()
	if d == nil do return
	st := wpe_display_get_settings(d)
	if st == nil do return
	// (an older WPE without the setting refuses it: pages stay light)
	err: ^GError
	if wpe_settings_set_boolean(st, WPE_SETTING_DARK_MODE, want ? 1 : 0, WPE_SETTINGS_SOURCE_APPLICATION, &err) == 0 {
		if err != nil do g_error_free(err)
	}
	display_dark = want
}

} // when !ENGINE_CEF
