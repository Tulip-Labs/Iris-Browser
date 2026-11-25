// The WPE engine's tab view (IRIS_ENGINE=wpe, see engine_api.odin): one
// WebKitWebView per tab, sharing one web context; WebKit's memory limits
// keep them light.
package iris

import "core:strings"

// (not indented: the whole file is this engine's)
when !ENGINE_CEF {

Tab_View :: struct {
	web:             ^WebKitWebView,
	ucm:             ^WebKitUserContentManager,
	sandbox_session: ^WebKitNetworkSession,
	/// a web context of the tab's own (a peek's: tab_isolate)
	own_context:     ^WebKitWebContext,
	/// views that may share a web process have the same number: a pop-up
	/// and its opener (WebKit puts a related view in its opener's process)
	process_group:   int,
}

@(private="file") next_process_group := 1

/// another open tab's view may be in t's web process
@(private="file") tab_shares_process :: proc(t: ^Tab) -> bool {
	for x in b.tabs do if x != t && x.web != nil && x.process_group == t.process_group do return true
	if p := b.peek; p != nil && p != t && p.web != nil && p.process_group == t.process_group do return true
	return false
}

tab_has_view :: proc(t: ^Tab) -> bool { return t.web != nil }

/// the web view, made on first use (related: a pop-up shares its opener's
/// web process, as the web requires)
tab_ensure_web :: proc(t: ^Tab, related: rawptr = nil) -> ^WebKitWebView {
	if t.web != nil do return t.web
	t.ucm = webkit_user_content_manager_new()
	add_page_scripts(t.ucm)
	st := t.sandboxed ? sandbox_settings() : normal_settings()
	defer unref(st)
	color_scheme_sync()
	d := display()
	disp := Prop{name = "display", value = rawptr(d), type = wpe_display_get_type()}
	ucm := Prop{name = "user-content-manager", value = rawptr(t.ucm), type = webkit_user_content_manager_get_type()}
	set := Prop{name = "settings", value = rawptr(st), type = webkit_settings_get_type()}
	w: ^WebKitWebView
	if related != nil {
		// the opener's display, web context and session come with it (WebKit
		// refuses a display given beside a related view)
		w = cast(^WebKitWebView)gnew(webkit_web_view_get_type(), ucm, set, {name = "related-view", value = rawptr(related), type = webkit_web_view_get_type()})
	} else if t.sandboxed {
		t.sandbox_session = sandbox_session()
		w = cast(^WebKitWebView)gnew(webkit_web_view_get_type(), disp, ucm, set,
			{name = "network-session", value = rawptr(t.sandbox_session), type = webkit_network_session_get_type()},
			{name = "web-context", value = rawptr(t.own_context != nil ? t.own_context : sandbox_context()), type = webkit_web_context_get_type()})
	} else {
		w = cast(^WebKitWebView)gnew(webkit_web_view_get_type(), disp, ucm, set,
			{name = "network-session", value = rawptr(container_session(t.container)), type = webkit_network_session_get_type()},
			{name = "web-context", value = rawptr(t.own_context != nil ? t.own_context : web_context()), type = webkit_web_context_get_type()})
	}
	// WPE's WebKitWebView is a plain GObject, born with the one reference
	// Iris owns. (g_object_ref_sink on it added a second one, so the unref in
	// tab_release_web never freed it: a closed tab's page lived on, playing
	// its video and keeping its memory.)
	if g_object_is_floating(w) != 0 do g_object_ref_sink(w)
	t.web = w
	t.process_group = next_process_group
	next_process_group += 1
	if related != nil {
		for x in b.tabs do if x.web == cast(^WebKitWebView)related do t.process_group = x.process_group
		if p := b.peek; p != nil && p.web == cast(^WebKitWebView)related do t.process_group = p.process_group
	}
	shields_apply(t.ucm, "")
	tab_connect(t, w)
	tab_connect_extra(t, w)
	t.page = page_new(w)
	t.page.user = t
	t.page.on_frame = proc(p: ^Page) { browser_page_frame(cast(^Tab)p.user) }
	t.page.on_cursor = proc(p: ^Page) { browser_page_cursor(cast(^Tab)p.user) }
	t.page.on_fullscreen = proc(p: ^Page, on: bool) { browser_fullscreen(on) }
	browser_attach(t)
	return w
}

/// the web view goes (to be made again, in or out of the sandbox)
tab_release_web :: proc(t: ^Tab) {
	if t.web == nil do return
	// a dialog the page left open goes with it
	browser_forget_dialog(t)
	browser_detach(t)
	if t.ucm != nil do shields_forget(t.ucm)
	disconnect_all(t.web, t)
	delete_key(&find_hooked, t.id)
	page_free(t.page)
	t.page = nil
	// a context of its own (a peek's): its web process ends with the view
	tab_end_isolated(t)
	if len(find_hooked) > 0 do delete_key(&find_hooked, webkit_web_view_get_find_controller(t.web))
	webkit_web_view_try_close(t.web)
	// WebKit keeps a closed page's web process for five minutes (its
	// process cache, for a page opened again), memory and all: a process
	// only this view uses ends now. One a pop-up or its opener still uses
	// stays, and ends with the last of them.
	if t.own_context == nil && !tab_shares_process(t) do webkit_web_view_terminate_web_process(t.web)
	unref(t.web)
	unref(t.ucm)
	t.web, t.ucm = nil, nil
	t.audio, t.article, t.reader, t.reader_pending = false, false, false, false
	if t.sandbox_session != nil {
		unref(t.sandbox_session)
		t.sandbox_session = nil
	}
	forget_certs(t)
}

/// opens an address; a site Iris does not trust goes to the sandbox, and
/// a trusted one comes out of it
tab_load :: proc(t: ^Tab, u0: string) {
	if len(u0) == 0 do return
	// https first (features.odin), then without tracking parameters
	u := shields_clean_url(https_first(t, u0))
	want := untrusted(u)
	if t.web == nil {
		t.sandboxed = want
	} else if want != t.sandboxed {
		tab_release_web(t)
		t.sandboxed = want
	}
	w := tab_ensure_web(t)
	set_str(&t.url, u)
	// an address you open gives the tab its dialogs back
	t.dialogs_blocked, t.dialogs_n = false, 0
	h, _ := host_of(u, context.temp_allocator)
	shields_apply(t.ucm, h)
	webkit_web_view_load_uri(w, cstr(u))
	browser_tab_changed(t)
}

tab_back :: proc(t: ^Tab) { if t.web != nil do webkit_web_view_go_back(t.web) }
tab_forward :: proc(t: ^Tab) { if t.web != nil do webkit_web_view_go_forward(t.web) }
tab_reload :: proc(t: ^Tab) { if t.web != nil do webkit_web_view_reload(t.web) }
tab_stop :: proc(t: ^Tab) { if t.web != nil do webkit_web_view_stop_loading(t.web) }

tab_set_zoom :: proc(t: ^Tab, z: f64) {
	t.zoom = z
	if t.web != nil do webkit_web_view_set_zoom_level(t.web, z)
}

/// runs a script in the page; done gets its result as text
tab_run :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
	if t.web == nil do return
	Job :: struct {
		t:    ^Tab,
		id:   int,
		done: proc(t: ^Tab, result: string),
	}
	j := new(Job)
	j^ = {t, t.id, done}
	webkit_web_view_evaluate_javascript(t.web, cstr(js), -1, nil, nil, nil, rawptr(proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
		context = main_context
		j := cast(^Job)d
		defer free(j)
		v := webkit_web_view_evaluate_javascript_finish(cast(^WebKitWebView)o, res, nil)
		if v == nil do return
		defer unref(v)
		// the tab may have closed while the page answered
		if !browser_tab_alive(j.t) || j.t.id != j.id do return
		s := jsc_value_to_string(v)
		j.done(j.t, string(s))
		g_free(rawptr(s))
	}), j)
}

// ---------------------------------------------------------------- signals

@(private="file") tab_of :: proc "contextless" (d: rawptr) -> ^Tab { return cast(^Tab)d }

@(private="file") tab_connect :: proc(t: ^Tab, w: ^WebKitWebView) {
	on(w, "notify::uri", rawptr(proc "c" (w: ^WebKitWebView, spec: rawptr, t: ^Tab) {
		context = main_context
		set_str(&t.url, string(webkit_web_view_get_uri(w)))
		browser_tab_changed(t)
	}), t)
	on(w, "notify::title", rawptr(proc "c" (w: ^WebKitWebView, spec: rawptr, t: ^Tab) {
		context = main_context
		// a title is a line in a tab: a page that writes megabytes into it
		// does not make Iris shape them all on every frame
		set_str(&t.title, clip(string(webkit_web_view_get_title(w)), TITLE_MAX))
		if !tab_is_private(t) && !t.sandboxed do history_title(t.url, t.title)
		browser_tab_changed(t)
	}), t)
	on(w, "notify::estimated-load-progress", rawptr(proc "c" (w: ^WebKitWebView, spec: rawptr, t: ^Tab) {
		context = main_context
		t.progress = webkit_web_view_get_estimated_load_progress(w)
		browser_tab_changed(t)
	}), t)
	on(w, "notify::is-loading", rawptr(proc "c" (w: ^WebKitWebView, spec: rawptr, t: ^Tab) {
		context = main_context
		t.loading = webkit_web_view_is_loading(w) != 0
		browser_tab_changed(t)
	}), t)
	on(w, "load-changed", rawptr(proc "c" (w: ^WebKitWebView, e: u32, t: ^Tab) {
		context = main_context
		t.can_back = webkit_web_view_can_go_back(w) != 0
		t.can_forward = webkit_web_view_can_go_forward(w) != 0
		if e == WEBKIT_LOAD_COMMITTED && !tab_is_private(t) && !t.sandboxed do history_record(t.url, t.title)
		if e == WEBKIT_LOAD_FINISHED do tab_favicon(t)
		browser_tab_changed(t)
	}), t)
	on(w, "decide-policy", rawptr(proc "c" (w: ^WebKitWebView, d: ^WebKitPolicyDecision, kind: u32, t: ^Tab) -> gboolean {
		context = main_context
		return tab_decide(t, d, kind) ? 1 : 0
	}), t)
	on(w, "create", rawptr(proc "c" (w: ^WebKitWebView, nav: ^WebKitNavigationAction, t: ^Tab) -> ^WebKitWebView {
		context = main_context
		return browser_popup(t, nav)
	}), t)
	on(w, "load-failed-with-tls-errors", rawptr(proc "c" (w: ^WebKitWebView, uri: cstring, cert: ^GTlsCertificate, errors: u32, t: ^Tab) -> gboolean {
		context = main_context
		return tab_certificate_failed(t, string(uri), cert, errors) ? 1 : 0
	}), t)
	on(w, "ready-to-show", rawptr(proc "c" (w: ^WebKitWebView, t: ^Tab) {
		context = main_context
		if !t.held do browser_select(t)
	}), t)
	on(w, "close", rawptr(proc "c" (w: ^WebKitWebView, t: ^Tab) {
		context = main_context
		browser_close_later(t)
	}), t)
	on(w, "context-menu", rawptr(proc "c" (w: ^WebKitWebView, menu: ^WebKitContextMenu, hit: ^WebKitHitTestResult, t: ^Tab) -> gboolean {
		context = main_context
		browser_context_menu(t, menu, hit)
		return 1
	}), t)
	on(w, "mouse-target-changed", rawptr(proc "c" (w: ^WebKitWebView, hit: ^WebKitHitTestResult, mods: u32, t: ^Tab) {
		context = main_context
		link := webkit_hit_test_result_context_is_link(hit) != 0 ? string(webkit_hit_test_result_get_link_uri(hit)) : ""
		browser_hover_link(t, link)
	}), t)
	on(w, "permission-request", rawptr(proc "c" (w: ^WebKitWebView, req: ^WebKitPermissionRequest, t: ^Tab) -> gboolean {
		context = main_context
		browser_permission(t, req)
		return 1
	}), t)
	on(w, "web-process-terminated", rawptr(proc "c" (w: ^WebKitWebView, reason: i32, t: ^Tab) {
		context = main_context
		browser_toast("This page stopped working: reload it to go on")
	}), t)
	on(w, "show-option-menu", rawptr(proc "c" (w: ^WebKitWebView, menu: ^WebKitOptionMenu, rect: ^WPERectangle, t: ^Tab) -> gboolean {
		context = main_context
		browser_option_menu(t, menu, rect)
		return 1
	}), t)
	on(w, "script-dialog", rawptr(proc "c" (w: ^WebKitWebView, dialog: ^WebKitScriptDialog, t: ^Tab) -> gboolean {
		context = main_context
		browser_script_dialog(t, dialog)
		return 1
	}), t)
	on(w, "run-file-chooser", rawptr(proc "c" (w: ^WebKitWebView, req: ^WebKitFileChooserRequest, t: ^Tab) -> gboolean {
		context = main_context
		browser_file_chooser(t, req)
		return 1
	}), t)
}

/// the site's icon, from the session's favicon database (the size nearest
/// 32 px), for the chrome as a data: URL
@(private="file") tab_favicon :: proc(t: ^Tab) {
	if t.web == nil do return
	s := webkit_web_view_get_network_session(t.web)
	if s == nil do return
	db := webkit_website_data_manager_get_favicon_database(webkit_network_session_get_website_data_manager(s))
	u := webkit_web_view_get_uri(t.web)
	if db == nil || u == nil do return
	webkit_favicon_database_get_page_icons(db, u, nil, rawptr(proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
		context = main_context
		w := cast(^WebKitWebView)d
		defer unref(w)
		list := webkit_favicon_database_get_page_icons_finish(cast(^WebKitFaviconDatabase)o, res, nil)
		if list == nil do return
		defer webkit_image_list_unref(list)
		t := browser_tab_of_web(w)
		if t == nil do return
		best: ^WebKitImage
		gap := max(i32)
		for i in 0 ..< webkit_image_list_get_length(list) {
			img := webkit_image_list_get(list, i)
			if img == nil do continue
			g := abs(webkit_image_get_width(img) - 32)
			if g < gap do best, gap = img, g
		}
		if best == nil do return
		b := webkit_image_as_bytes(best)
		if b == nil do return
		defer g_bytes_unref(b)
		n: uint
		p := g_bytes_get_data(b, &n)
		if p == nil do return
		// the icon shows at 16 px: a site's 512 px one is kept at most
		// FAVICON_MAX a side, and pixels that do not cover the sizes the
		// image claims are never read past their end
		px, fw, fh, ok := favicon_fit(([^]u8)(p)[:n], int(webkit_image_get_width(best)), int(webkit_image_get_height(best)), int(webkit_image_get_stride(best)))
		if !ok do return
		delete(t.favicon_px)
		t.favicon_px = px
		t.favicon_w, t.favicon_h, t.favicon_stride = i32(fw), i32(fh), i32(fw * 4)
		t.favicon_dirty = true
		browser_tab_changed(t)
	}), g_object_ref(t.web))
}

// ---------------------------------------------------------------- policy

@(private="file") tab_decide :: proc(t: ^Tab, d: ^WebKitPolicyDecision, kind: u32) -> bool {
	switch kind {
	case WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION:
		nav := webkit_navigation_policy_decision_get_navigation_action(cast(^WebKitNavigationPolicyDecision)d)
		req := webkit_navigation_action_get_request(nav)
		if req == nil do return false
		u := string(webkit_uri_request_get_uri(req))
		// a form sent (POST): Iris never loads it again itself, which would
		// lose what it sends (its load would be a GET)
		body := request_has_body(req)
		// a pop-up's first real address: it is shown now (about:blank, the
		// page writing into it, waits), before any of the turns below
		if t.held && u != "about:blank" && len(u) > 0 {
			t.held = false
			browser_select(t)
		}
		// an http address goes over https first, where it can (features.odin)
		if !body && https_wanted(t, u) {
			webkit_policy_decision_ignore(d)
			tab_load_later(t, strings.clone(u))
			return true
		}
		// a middle click or Ctrl+click opens the link in a new tab (WebKit
		// leaves that to the browser: it asks to navigate this tab)
		if webkit_navigation_action_get_navigation_type(nav) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED && link_wants_new_tab(webkit_navigation_action_get_mouse_button(nav), webkit_navigation_action_get_modifiers(nav)) {
			if page_may_open(u, t.url) {
				webkit_policy_decision_ignore(d)
				browser_open_link(t, u, (webkit_navigation_action_get_modifiers(nav) & u32(WPE_MODIFIER_KEYBOARD_SHIFT)) == 0)
				return true
			}
		}
		if webkit_navigation_action_get_frame_name(nav) != nil do return false
		// a Google result goes straight to the site
		if target, ok := unwrap_redirect(u); ok && !body {
			webkit_policy_decision_ignore(d)
			tab_load_later(t, target)
			return true
		}
		// a link you click loses its tracking parameters (utm_*, fbclid...)
		if !body && webkit_navigation_action_get_navigation_type(nav) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED && webkit_navigation_action_is_user_gesture(nav) != 0 {
			if clean := shields_clean_url(u); clean != u {
				webkit_policy_decision_ignore(d)
				tab_load_later(t, strings.clone(clean))
				return true
			}
		}
		// into or out of the sandbox: the tab is made again
		if strings.has_prefix(u, "http") && untrusted(u) != t.sandboxed {
			switch sandbox_move_for(t.sandboxed, body) {
			case .Reload:
				webkit_policy_decision_ignore(d)
				tab_load_later(t, strings.clone(u))
				return true
			case .Stay:
				// a form a sandboxed page sends to a site Iris trusts: it goes
				// from the sandbox (no cookies of yours go with it)
			case .Refuse:
				webkit_policy_decision_ignore(d)
				browser_toast(strings.concatenate({"Iris did not send this form to ", display_url(u, context.temp_allocator), ": the site is not secure"}, context.temp_allocator))
				return true
			}
		}
		h, _ := host_of(u, context.temp_allocator)
		shields_apply(t.ucm, h)
		return false
	case WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION:
		return browser_new_window_action(t, d)
	case WEBKIT_POLICY_DECISION_TYPE_RESPONSE:
		r := cast(^WebKitResponsePolicyDecision)d
		if webkit_response_policy_decision_is_mime_type_supported(r) == 0 && webkit_response_policy_decision_is_main_frame_main_resource(r) != 0 {
			if t.sandboxed {
				webkit_policy_decision_ignore(d)
				browser_toast("Downloads are off for sites in the sandbox")
				return true
			}
			webkit_policy_decision_download(d)
			return true
		}
	}
	return false
}

/// a certificate that fails: Iris's page over the tab (interstitial.odin),
/// and nothing of the site; an https try of an http address offers http
@(private="file") tab_certificate_failed :: proc(t: ^Tab, uri: string, cert: ^GTlsCertificate, errors: u32) -> bool {
	switch cert_decide(t, uri) {
	case .Upgrade_Failed:
		// WebKit's error page, and the toast that opens the http address
		https_failed(t, uri)
		return false
	case .Allowed, .Block:
		// (a certificate you allowed is not asked about again: one that
		// fails now is another, and asks you again)
	}
	reason, code := tls_flags_text(errors)
	cert_block(t, uri, reason, code, g_object_ref(cert))
	return true
}

/// "Show anyway": the tab in the sandbox (a world of its own), the
/// certificate let through there for its host, and the page loaded
tab_cert_proceed :: proc(t: ^Tab, url, host: string, engine: rawptr) {
	if t.web != nil && (!t.sandboxed || t.sandbox_session == nil) do tab_release_web(t)
	t.sandboxed = true
	w := tab_ensure_web(t)
	cert := cast(^GTlsCertificate)engine
	if t.sandbox_session != nil && cert != nil && len(host) > 0 do webkit_network_session_allow_tls_certificate_for_host(t.sandbox_session, cert, cstr(host))
	if len(host) > 0 && host not_in t.allowed_certs do t.allowed_certs[strings.clone(host)] = true
	set_str(&t.url, url)
	shields_apply(t.ucm, host)
	webkit_web_view_load_uri(w, cstr(url))
	browser_tab_changed(t)
}

tab_cert_release :: proc(engine: rawptr) {
	if engine != nil do unref(engine)
}

/// the request sends a body (a form's POST): not a plain GET or HEAD
request_has_body :: proc(req: ^WebKitURIRequest) -> bool {
	m := webkit_uri_request_get_http_method(req)
	if m == nil do return false
	s := string(m)
	return len(s) > 0 && !strings.equal_fold(s, "GET") && !strings.equal_fold(s, "HEAD")
}

tab_reload_bypass :: proc(t: ^Tab) { if t.web != nil do webkit_web_view_reload_bypass_cache(t.web) }

tab_shields_apply :: proc(t: ^Tab, host: string) { if t.ucm != nil do shields_apply(t.ucm, host) }

/// the link's site is looked up while the pointer rests on it
tab_warm_dns :: proc(t: ^Tab, host: string) { if t.web != nil do warm_dns(webkit_web_view_get_network_session(t.web), host) }

tab_download :: proc(t: ^Tab, url: string) {
	if t.web == nil do return
	d := webkit_web_view_download_uri(t.web, cstr(url))
	if d != nil do unref(d)
}

tab_edit :: proc(t: ^Tab, cmd: string) { if t.web != nil do webkit_web_view_execute_editing_command(t.web, cstr(cmd)) }

// ---------------------------------------------------------------- find in page

WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE :: u32(1 << 0)
WEBKIT_FIND_OPTIONS_WRAP_AROUND :: u32(1 << 4)

/// the tabs whose view's find controller Iris listens to, by tab id (a
/// controller's address can come back for another view once one is freed;
/// a tab's entry goes with its view: tab_release_web)
@(private="file") find_hooked: map[int]bool

tab_find :: proc(t: ^Tab, text: string, dir: string) {
	if t.web == nil do return
	fc := webkit_web_view_get_find_controller(t.web)
	if t.id not_in find_hooked {
		find_hooked[t.id] = true
		on(fc, "counted-matches", rawptr(proc "c" (fc: rawptr, n: u32, d: rawptr) {
			context = main_context
			ui.find_count = int(n)
			chrome_push()
		}), nil)
		on(fc, "failed-to-find-text", rawptr(proc "c" (fc: rawptr, d: rawptr) {
			context = main_context
			ui.find_count = 0
			chrome_push()
		}), nil)
	}
	switch dir {
	case "next": webkit_find_controller_search_next(fc)
	case "prev": webkit_find_controller_search_previous(fc)
	case:
		opts := WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE | WEBKIT_FIND_OPTIONS_WRAP_AROUND
		webkit_find_controller_search(fc, cstr(text), opts, 1000)
		webkit_find_controller_count_matches(fc, cstr(text), opts, 1000)
	}
}

tab_find_stop :: proc(t: ^Tab) {
	if t.web != nil do webkit_find_controller_search_finish(webkit_web_view_get_find_controller(t.web))
}

} // when !ENGINE_CEF
