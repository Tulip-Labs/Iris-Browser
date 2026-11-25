// A tab: one WPE web view and what it is doing. Every tab stays awake
// (Iris has no sleeping tabs): WebKit's memory limits keep them light.
package iris

import "core:strings"
import cef "cef"

Tab :: struct {
	id:             int,
	container:      string, // "" none, PRIVATE_ID, or a container's id
	url:            string,
	title:          string,
	progress:       f64,
	loading:        bool,
	can_back:       bool,
	can_forward:    bool,
	zoom:           f64,
	web:            ^WebKitWebView,
	/// which engine this tab runs (WPE by default, CEF with --engine=cef)
	engine:         Engine_Kind,
	ucm:            ^WebKitUserContentManager,
	page:           ^Page,
	/// a site Iris does not trust: its own processes and a throwaway world
	sandboxed:      bool,
	sandbox_session: ^WebKitNetworkSession,
	/// hosts whose failing certificate the sandbox let through, once each
	allowed_certs:  map[string]bool,
	/// a pop-up waiting for its first address (the page wrote it into a
	/// blank window: Iris shows it only once it knows where it goes)
	held:           bool,
	/// the site's icon, premultiplied BGRA, uploaded when next drawn
	favicon_px:     []u8,
	favicon_w, favicon_h, favicon_stride: i32,
	favicon_tex:    Texture,
	favicon_dirty:  bool,
}

@(private="file") next_tab_id := 1

tab_new :: proc(container: string) -> ^Tab {
	t := new(Tab)
	t^ = {id = next_tab_id, container = strings.clone(container), zoom = 1, engine = engine_kind}
	next_tab_id += 1
	return t
}

tab_is_private :: proc(t: ^Tab) -> bool {
	return t.container == PRIVATE_ID
}

/// whether the tab's page engine exists yet (a WPE web view, or a CEF
/// page with a browser behind it). A CEF tab has no web view, so
/// t.web == nil must never be read as "no engine".
tab_has_engine :: proc(t: ^Tab) -> bool {
	if t.engine == .CEF do return t.page != nil && t.page.cef != nil
	return t.web != nil
}

/// the web view, made on first use (related: a pop-up shares its opener's
/// web process, as the web requires)
tab_ensure_web :: proc(t: ^Tab, related: ^WebKitWebView = nil) -> ^WebKitWebView {
	if t.engine == .CEF {
		tab_ensure_cef(t)
		return nil
	}
	if t.web != nil do return t.web
	t.ucm = webkit_user_content_manager_new()
	add_page_scripts(t.ucm)
	st := t.sandboxed ? sandbox_settings() : normal_settings()
	defer unref(st)
	d := display()
	disp := Prop{name = "display", value = rawptr(d), type = wpe_display_get_type()}
	ucm := Prop{name = "user-content-manager", value = rawptr(t.ucm), type = webkit_user_content_manager_get_type()}
	set := Prop{name = "settings", value = rawptr(st), type = webkit_settings_get_type()}
	w: ^WebKitWebView
	if related != nil {
		w = cast(^WebKitWebView)gnew(webkit_web_view_get_type(), disp, ucm, set, {name = "related-view", value = rawptr(related), type = webkit_web_view_get_type()})
	} else if t.sandboxed {
		t.sandbox_session = sandbox_session()
		w = cast(^WebKitWebView)gnew(webkit_web_view_get_type(), disp, ucm, set,
			{name = "network-session", value = rawptr(t.sandbox_session), type = webkit_network_session_get_type()},
			{name = "web-context", value = rawptr(sandbox_context()), type = webkit_web_context_get_type()})
	} else {
		w = cast(^WebKitWebView)gnew(webkit_web_view_get_type(), disp, ucm, set,
			{name = "network-session", value = rawptr(container_session(t.container)), type = webkit_network_session_get_type()},
			{name = "web-context", value = rawptr(web_context()), type = webkit_web_context_get_type()})
	}
	// WPE's WebKitWebView is a plain GObject, born with the one reference
	// Iris owns. (g_object_ref_sink on it added a second one, so the unref in
	// tab_release_web never freed it: a closed tab's page lived on, playing
	// its video and keeping its memory.)
	if g_object_is_floating(w) != 0 do g_object_ref_sink(w)
	t.web = w
	shields_apply(t.ucm, "")
	tab_connect(t, w)
	t.page = page_new(w)
	t.page.user = t
	t.page.on_frame = proc(p: ^Page) { browser_page_frame(cast(^Tab)p.user) }
	t.page.on_cursor = proc(p: ^Page) { browser_page_cursor(cast(^Tab)p.user) }
	t.page.on_fullscreen = proc(p: ^Page, on: bool) { browser_fullscreen(on) }
	browser_attach(t)
	return w
}

/// a CEF tab, made on first use: the Page is made now and the engine
/// creates the tab at the page's size (or a default the layout corrects
/// with a resize). A CEF tab is already isolated by its own request
/// context, so it never needs the sandbox rebuild a WPE tab gets when a
/// site's trust changes. When creation is refused, the Page stays
/// without an engine; a later load retries.
tab_ensure_cef :: proc(t: ^Tab) {
	if t.page != nil && t.page.cef != nil do return
	if t.page == nil {
		t.page = page_new_cef()
		t.page.user = t
		t.page.on_frame = proc(p: ^Page) { browser_page_frame(cast(^Tab)p.user) }
		t.page.on_cursor = proc(p: ^Page) { browser_page_cursor(cast(^Tab)p.user) }
		t.page.on_fullscreen = proc(p: ^Page, on: bool) { browser_fullscreen(on) }
		t.page.on_title = proc(p: ^Page) {
			t := cast(^Tab)p.user
			set_str(&t.title, p.cef.title)
			if !tab_is_private(t) && !t.sandboxed do history_title(t.url, t.title)
			browser_tab_changed(t)
		}
		t.page.on_url = proc(p: ^Page) {
			t := cast(^Tab)p.user
			set_str(&t.url, p.cef.url)
			browser_tab_changed(t)
		}
		t.page.on_loading = proc(p: ^Page) {
			t := cast(^Tab)p.user
			t.loading = p.cef.loading
			t.progress = p.cef.progress
			t.can_back = p.cef.can_back
			t.can_forward = p.cef.can_forward
			browser_tab_changed(t)
		}
		t.page.on_favicon = proc(p: ^Page) {
			t := cast(^Tab)p.user
			cef_favicon_fetch(t.id, p.cef.favicon_url)
		}
		t.page.on_close = proc(p: ^Page) {
			t := cast(^Tab)p.user
			if browser_has_tab(t) {
				// the page closed itself: close it the normal way
				browser_close_later(t)
			} else {
				// already out of b.tabs (the user closed it, and the
				// free was deferred until now): free it directly
				idle(proc(d: rawptr) {
					t := cast(^Tab)d
					tab_free(t)
				}, t)
			}
		}
	}
	w, h := i32(800), i32(600)
	if t.page.w > 0 && t.page.h > 0 {
		w, h = i32(t.page.w * t.page.scale), i32(t.page.h * t.page.scale)
	}
	b := cef.new_browser(t.url, w, h)
	if b == nil do return
	page_cef_created(t.page, b)
	browser_attach(t)
}

/// the web view goes (to be made again, in or out of the sandbox)
tab_release_web :: proc(t: ^Tab) {
	if t.engine == .CEF {
		tab_release_cef(t)
		return
	}
	if t.web == nil do return
	browser_detach(t)
	if t.ucm != nil do shields_forget(t.ucm)
	disconnect_all(t.web, t)
	page_free(t.page)
	t.page = nil
	webkit_web_view_try_close(t.web)
	unref(t.web)
	unref(t.ucm)
	t.web, t.ucm = nil, nil
	if t.sandbox_session != nil {
		unref(t.sandbox_session)
		t.sandbox_session = nil
	}
	clear(&t.allowed_certs)
}

/// the CEF tab goes: the Page asks the engine to close it. The Page
/// itself is freed only once the engine has destroyed the tab (its
/// on_close), so a tab whose close is still in flight keeps its Page
/// until then — tab_free defers the real free the same way.
tab_release_cef :: proc(t: ^Tab) {
	if t.page == nil do return
	browser_detach(t)
	page_free(t.page)
	if t.page.cef_closed {
		t.page = nil
	}
}

/// opens an address; a site Iris does not trust goes to the sandbox, and
/// a trusted one comes out of it
tab_load :: proc(t: ^Tab, u: string) {
	if len(u) == 0 do return
	if t.engine == .CEF {
		// A CEF tab is already isolated by its own request context,
		// so a site's trust never rebuilds it; the sandbox flag is
		// only the label the chrome shows. The URL is set before
		// the tab is made, so the engine loads it at creation.
		t.sandboxed = untrusted(u)
		set_str(&t.url, u)
		tab_ensure_cef(t)
		if t.page != nil && t.page.cef != nil && t.page.cef.created {
			cef.load(t.page.cef, u)
		}
		// not created yet: the initial URL is already loading (the
		// engine was given it at creation); a second load that
		// early is dropped — the user cannot type that fast, and
		// the URL is stored in t.url for the next load
		browser_tab_changed(t)
		return
	}
	want := untrusted(u)
	if t.web == nil {
		t.sandboxed = want
	} else if want != t.sandboxed {
		tab_release_web(t)
		t.sandboxed = want
	}
	w := tab_ensure_web(t)
	set_str(&t.url, u)
	h, _ := host_of(u, context.temp_allocator)
	shields_apply(t.ucm, h)
	webkit_web_view_load_uri(w, cstr(u))
	browser_tab_changed(t)
}

tab_free :: proc(t: ^Tab) {
	if t.engine == .CEF && t.page != nil && t.page.cef != nil && !t.page.cef_closed {
		// A live CEF tab: the engine destroys it asynchronously.
		// Ask for the close now; the engine's on_close frees the
		// Tab then (see the on_close callback in tab_ensure_cef).
		// The Tab is already out of b.tabs by now (browser_close
		// removed it before calling here), so nothing else may
		// touch it after this returns.
		tab_release_cef(t)
		return
	}
	tab_release_web(t)
	delete(t.container)
	delete(t.url)
	delete(t.title)
	delete(t.favicon_px)
	if t.favicon_tex.owned do texture_free(&t.favicon_tex)
	delete(t.allowed_certs)
	free(t)
}

set_str :: proc(s: ^string, v: string) {
	if s^ == v do return
	delete(s^)
	s^ = strings.clone(v)
}

tab_back :: proc(t: ^Tab) {
	if t.engine == .CEF {
		if t.page != nil && t.page.cef != nil do cef.go_back(t.page.cef)
		return
	}
	if t.web != nil do webkit_web_view_go_back(t.web)
}
tab_forward :: proc(t: ^Tab) {
	if t.engine == .CEF {
		if t.page != nil && t.page.cef != nil do cef.go_forward(t.page.cef)
		return
	}
	if t.web != nil do webkit_web_view_go_forward(t.web)
}
tab_reload :: proc(t: ^Tab) {
	if t.engine == .CEF {
		if t.page != nil && t.page.cef != nil do cef.reload(t.page.cef)
		return
	}
	if t.web != nil do webkit_web_view_reload(t.web)
}
tab_reload_bypass_cache :: proc(t: ^Tab) {
	if t.engine == .CEF {
		if t.page != nil && t.page.cef != nil do cef.reload_ignore_cache(t.page.cef)
		return
	}
	if t.web != nil do webkit_web_view_reload_bypass_cache(t.web)
}
tab_stop :: proc(t: ^Tab) {
	if t.engine == .CEF {
		if t.page != nil && t.page.cef != nil do cef.stop_load(t.page.cef)
		return
	}
	if t.web != nil do webkit_web_view_stop_loading(t.web)
}

tab_set_zoom :: proc(t: ^Tab, z: f64) {
	t.zoom = z
	if t.engine == .CEF {
		if t.page != nil && t.page.cef != nil do cef.set_zoom_factor(t.page.cef, z)
		return
	}
	if t.web != nil do webkit_web_view_set_zoom_level(t.web, z)
}

/// runs a script in the page; done gets its result as text
tab_run :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
	Job :: struct {
		t:    ^Tab,
		id:   int,
		done: proc(t: ^Tab, result: string),
	}
	if t.engine == .CEF {
		if t.page == nil || t.page.cef == nil do return
		j := new(Job)
		j^ = {t, t.id, done}
		if cef.eval_js(t.page.cef, js, proc(result: string, user: rawptr) {
			j := cast(^Job)user
			defer free(j)
			// the tab may have closed while the page answered
			if !browser_has_tab(j.t) || j.t.id != j.id do return
			j.done(j.t, result)
		}, j) < 0 {
			// the tab is not created yet: the eval never answers
			free(j)
		}
		return
	}
	if t.web == nil do return
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
		if !browser_has_tab(j.t) || j.t.id != j.id do return
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
		set_str(&t.title, string(webkit_web_view_get_title(w)))
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
		return tab_certificate_failed(t, string(uri), cert) ? 1 : 0
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
			g := abs(webkit_image_get_width(img) - 32)
			if img != nil && g < gap do best, gap = img, g
		}
		if best == nil do return
		b := webkit_image_as_bytes(best)
		defer g_bytes_unref(b)
		n: uint
		p := g_bytes_get_data(b, &n)
		delete(t.favicon_px)
		t.favicon_px = make([]u8, int(n))
		copy(t.favicon_px, ([^]u8)(p)[:n])
		t.favicon_w, t.favicon_h, t.favicon_stride = webkit_image_get_width(best), webkit_image_get_height(best), i32(webkit_image_get_stride(best))
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
		if webkit_navigation_action_get_frame_name(nav) != nil do return false
		// a Google result goes straight to the site
		if target, ok := unwrap_redirect(u); ok {
			webkit_policy_decision_ignore(d)
			tab_load_later(t, target)
			return true
		}
		// into or out of the sandbox: the tab is made again
		if strings.has_prefix(u, "http") && untrusted(u) != t.sandboxed {
			webkit_policy_decision_ignore(d)
			tab_load_later(t, strings.clone(u))
			return true
		}
		if t.held {
			t.held = false
			browser_select(t)
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

@(private="file") Later :: struct {
	t:   ^Tab,
	url: string,
}

@(private="file") tab_load_later :: proc(t: ^Tab, u: string) {
	l := new(Later)
	l^ = {t, u}
	idle(proc(d: rawptr) {
		l := cast(^Later)d
		if browser_has_tab(l.t) do tab_load(l.t, l.url)
		delete(l.url)
		free(l)
	}, l)
}

/// a certificate that fails: the site opens in the sandbox, its certificate
/// let through there once (never in a normal tab)
@(private="file") tab_certificate_failed :: proc(t: ^Tab, uri: string, cert: ^GTlsCertificate) -> bool {
	h, ok := host_of(uri)
	if !ok do return false
	if h in t.allowed_certs {
		delete(h)
		return false
	}
	Job :: struct {
		t:         ^Tab,
		uri, host: string,
		cert:      ^GTlsCertificate,
	}
	j := new(Job)
	j^ = {t, strings.clone(uri), h, cast(^GTlsCertificate)g_object_ref(cert)}
	idle(proc(d: rawptr) {
		j := cast(^Job)d
		defer {
			unref(j.cert)
			delete(j.uri)
			free(j)
		}
		t := j.t
		if !browser_has_tab(t) do return
		if !t.sandboxed {
			tab_release_web(t)
			t.sandboxed = true
		}
		w := tab_ensure_web(t)
		t.allowed_certs[j.host] = true
		if t.sandbox_session != nil do webkit_network_session_allow_tls_certificate_for_host(t.sandbox_session, j.cert, cstr(j.host))
		set_str(&t.url, j.uri)
		webkit_web_view_load_uri(w, cstr(j.uri))
		browser_toast(strings.concatenate({display_url(j.uri, context.temp_allocator), " has a certificate that fails: it is open in the sandbox"}, context.temp_allocator))
		browser_tab_changed(t)
	}, j)
	return true
}
