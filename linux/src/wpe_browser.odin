// The WPE engine's side of the browser (IRIS_ENGINE=wpe, see
// engine_api.odin): pop-ups and new windows, and what pages ask for
// (permissions, context menus, option menus, dialogs, files).
package iris

import "core:strings"

// (not indented: the whole file is this engine's)
when !ENGINE_CEF {

Browser_Asks :: struct {
	options:     map[int]^WebKitOptionMenu,
	dialogs:     map[int]^WebKitScriptDialog,
	choosers:    map[int]^WebKitFileChooserRequest,
	permissions: map[int]^WebKitPermissionRequest,
}

browser_tab_of_web :: proc(w: ^WebKitWebView) -> ^Tab {
	for t in b.tabs do if t.web == w do return t
	return nil
}

// ---------------------------------------------------------------- pop-ups

/// a middle click, or Ctrl+click, on a link
link_wants_new_tab :: proc(button, mods: u32) -> bool {
	return button == 2 || (button == 1 && (mods & u32(WPE_MODIFIER_KEYBOARD_CONTROL)) != 0)
}

/// a link that opens a new window opens as a tab next to yours; a
/// script's pop-up needs your click and goes only to the same site or a
/// sign-in page; ad domains open nothing
browser_new_window_action :: proc(t: ^Tab, d: ^WebKitPolicyDecision) -> bool {
	nav := webkit_navigation_policy_decision_get_navigation_action(cast(^WebKitNavigationPolicyDecision)d)
	req := webkit_navigation_action_get_request(nav)
	if req == nil do return false
	// copied first: the request's own string goes with the decision
	u := strings.clone(string(webkit_uri_request_get_uri(req)), context.temp_allocator)
	page_host, _ := host_of(t.url, context.temp_allocator)
	shield := shields_on_for(page_host)
	link := webkit_navigation_action_get_navigation_type(nav) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED
	gesture := webkit_navigation_action_is_user_gesture(nav) != 0
	switch new_window_choice(u, t.url, link, gesture, t.sandboxed, shield) {
	case .Related:
		return false // WebKit goes on and asks for the view ("create")
	case .Own_Tab:
		webkit_policy_decision_ignore(d)
		// a middle click, or a script's tab you did not click for, stays behind yours
		background := (link && webkit_navigation_action_get_mouse_button(nav) == 2) || !gesture
		browser_open_link(t, u, background)
	case .Block:
		webkit_policy_decision_ignore(d)
		if !link && shield && !t.sandboxed do browser_toast("Pop-up blocked")
	}
	return true
}

/// a view for window.open() (no new-window decision comes before it):
/// the same choice, and a tab that never stays blank
browser_popup :: proc(t: ^Tab, nav: ^WebKitNavigationAction) -> ^WebKitWebView {
	if t.web == nil do return nil
	req := webkit_navigation_action_get_request(nav)
	u := req != nil ? strings.clone(string(webkit_uri_request_get_uri(req)), context.temp_allocator) : ""
	page_host, _ := host_of(t.url, context.temp_allocator)
	shield := shields_on_for(page_host)
	gesture := webkit_navigation_action_is_user_gesture(nav) != 0
	switch new_window_choice(u, t.url, false, gesture, t.sandboxed, shield) {
	case .Block:
		if shield && !t.sandboxed do browser_toast("Pop-up blocked")
		return nil
	case .Own_Tab:
		browser_open_link(t, u, !gesture)
		return nil
	case .Related:
	}
	p := browser_new_tab({container = t.container, after = t, related = t.web})
	if strings.has_prefix(u, "http") do set_str(&p.url, u)
	// WebKit loads the address into the view itself; if it has not begun
	// to soon, Iris loads it, and a window the page only wrote into shows
	Check :: struct {
		t:  ^Tab,
		id: int,
	}
	c := new(Check)
	c^ = {p, p.id}
	after(1200, proc(d: rawptr) {
		c := cast(^Check)d
		defer free(c)
		t := c.t
		if !browser_has_tab(t) || t.id != c.id do return
		started := t.web != nil && (t.loading || (webkit_web_view_get_uri(t.web) != nil && string(webkit_web_view_get_uri(t.web)) != "about:blank" && len(string(webkit_web_view_get_uri(t.web))) > 0))
		if !started && strings.has_prefix(t.url, "http") {
			u := strings.clone(t.url, context.temp_allocator)
			tab_load(t, u)
		}
		if t.held {
			t.held = false
			browser_select(t)
		}
	}, c)
	return p.web
}

browser_permission :: proc(t: ^Tab, req: ^WebKitPermissionRequest) {
	// nothing of your computer for a site in the sandbox
	if t.sandboxed {
		webkit_permission_request_deny(req)
		return
	}
	name := type_name(req)
	what: string
	switch name {
	case "WebKitUserMediaPermissionRequest": what = "use your camera or microphone"
	case "WebKitGeolocationPermissionRequest": what = "know your location"
	case "WebKitNotificationPermissionRequest": what = "show notifications"
	case "WebKitClipboardPermissionRequest": what = "read your clipboard"
	case "WebKitPointerLockPermissionRequest":
		webkit_permission_request_allow(req)
		return
	case: what = "use a feature of your computer"
	}
	b.asks += 1
	b.permissions[b.asks] = cast(^WebKitPermissionRequest)g_object_ref(req)
	site := display_url(t.url, context.temp_allocator)
	chrome_permission(b.asks, strings.concatenate({len(site) > 0 ? site : "This page", " wants to ", what}, context.temp_allocator))
}

browser_context_menu :: proc(t: ^Tab, menu: ^WebKitContextMenu, hit: ^WebKitHitTestResult) {
	x, y: i32
	webkit_context_menu_get_position(menu, &x, &y)
	info: Context_Info
	if webkit_hit_test_result_context_is_link(hit) != 0 do info.link = string(webkit_hit_test_result_get_link_uri(hit))
	if webkit_hit_test_result_context_is_image(hit) != 0 do info.image = string(webkit_hit_test_result_get_image_uri(hit))
	if webkit_hit_test_result_context_is_media(hit) != 0 do info.media = string(webkit_hit_test_result_get_media_uri(hit))
	info.editable = webkit_hit_test_result_context_is_editable(hit) != 0
	info.selection = webkit_hit_test_result_context_is_selection(hit) != 0
	browser_context_menu_at(t, f32(x), f32(y), info)
}

browser_option_menu :: proc(t: ^Tab, menu: ^WebKitOptionMenu, rect: ^WPERectangle) {
	b.asks += 1
	id := b.asks
	b.options[id] = cast(^WebKitOptionMenu)g_object_ref(menu)
	items := make([dynamic]Option_Item, context.temp_allocator)
	for i in 0 ..< webkit_option_menu_get_n_items(menu) {
		it := webkit_option_menu_get_item(menu, i)
		append(&items, Option_Item{string(webkit_option_menu_item_get_label(it)), webkit_option_menu_item_is_group_label(it) != 0,
			webkit_option_menu_item_is_selected(it) != 0, webkit_option_menu_item_is_enabled(it) != 0})
	}
	r := rect != nil ? rect^ : WPERectangle{}
	chrome_option_menu(id, b.card.x + f32(r.x), b.card.y + f32(r.y + r.height), f32(r.width), items[:])
	on(menu, "close", rawptr(proc "c" (m: ^WebKitOptionMenu, d: rawptr) {
		context = main_context
		chrome_close_option()
	}), nil)
}

browser_script_dialog :: proc(t: ^Tab, d: ^WebKitScriptDialog) {
	// a dialog shows over its own page only, one at a time, and a page that
	// keeps opening them is stopped; the others are answered at once (no to
	// a question, yes to leaving the page), so no page waits forever
	host := display_url(t.url, context.temp_allocator)
	if !browser_dialog_admit(t) {
		kind := webkit_script_dialog_get_dialog_type(d)
		if kind == WEBKIT_SCRIPT_DIALOG_CONFIRM do webkit_script_dialog_confirm_set_confirmed(d, 0)
		if kind == WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM do webkit_script_dialog_confirm_set_confirmed(d, 1)
		return
	}
	b.dialog_tab = t
	b.asks += 1
	b.dialogs[b.asks] = webkit_script_dialog_ref(d)
	kind := webkit_script_dialog_get_dialog_type(d)
	default_text := kind == WEBKIT_SCRIPT_DIALOG_PROMPT ? string(webkit_script_dialog_prompt_get_default_text(d)) : ""
	chrome_dialog(b.asks, int(kind), len(host) > 0 ? host : "This page", string(webkit_script_dialog_get_message(d)), default_text)
}

browser_file_chooser :: proc(t: ^Tab, req: ^WebKitFileChooserRequest) {
	if t.sandboxed {
		// the sandbox reads no files of yours
		webkit_file_chooser_request_cancel(req)
		browser_toast("Files can't be uploaded to sites in the sandbox")
		return
	}
	portal_open_file(webkit_file_chooser_request_get_select_multiple(req) != 0, proc(d: rawptr, files: []cstring) {
		req := cast(^WebKitFileChooserRequest)d
		if len(files) > 1 {
			webkit_file_chooser_request_select_files(req, &files[0])
		} else {
			webkit_file_chooser_request_cancel(req)
		}
		unref(req)
	}, g_object_ref(req))
}

engine_answer_option :: proc(id, index: int) {
	if m, ok := b.options[id]; ok {
		if index >= 0 do webkit_option_menu_activate_item(m, u32(index))
		webkit_option_menu_close(m)
		unref(m)
		delete_key(&b.options, id)
	}
}

engine_answer_permission :: proc(id: int, allow: bool) {
	if r, ok := b.permissions[id]; ok {
		if allow { webkit_permission_request_allow(r) } else { webkit_permission_request_deny(r) }
		unref(r)
		delete_key(&b.permissions, id)
	}
}

engine_answer_dialog :: proc(id: int, yes: bool, text: string) {
	if d, ok := b.dialogs[id]; ok {
		kind := webkit_script_dialog_get_dialog_type(d)
		ok_ := yes || kind == WEBKIT_SCRIPT_DIALOG_ALERT
		if kind == WEBKIT_SCRIPT_DIALOG_CONFIRM || kind == WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM do webkit_script_dialog_confirm_set_confirmed(d, ok_ ? 1 : 0)
		if kind == WEBKIT_SCRIPT_DIALOG_PROMPT && ok_ do webkit_script_dialog_prompt_set_text(d, cstr(text))
		webkit_script_dialog_close(d)
		webkit_script_dialog_unref(d)
		delete_key(&b.dialogs, id)
	}
}

// ---------------------------------------------------------------- shields everywhere

/// new rules or the switch changed: every open page takes them
browser_reapply_shields :: proc() {
	for t in b.tabs {
		if t.ucm == nil do continue
		h, _ := host_of(t.url, context.temp_allocator)
		shields_apply(t.ucm, h)
	}
}

} // when !ENGINE_CEF
