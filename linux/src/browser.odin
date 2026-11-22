// The browser: one window, its tabs, and the chrome around them.
//
// The chrome (tabs, address bar, menus, dialogs) is HTML in a WPE view of
// its own, as wide as the window and transparent around what it draws. It
// tells Iris where its glass goes and which parts of the window it takes
// the pointer in; Iris draws the glass under it, over the live page, and
// sends each pointer event and key to the chrome or to the page.
package iris

import "core:fmt"
import "core:strings"
import plat "../plat"

Glass_Rect :: struct {
	x, y, w, h, r: f32,
	kind:          int, // 0 bar, 1 panel (frosted), 2 pill, 3 button
}

Target :: enum { None, Chrome, Page }

Browser :: struct {
	win:           plat.Window,
	tabs:          [dynamic]^Tab,
	current:       ^Tab,
	/// a tab already on Google AI Mode, for the next new tab
	spare:         ^Tab,
	closed:        [dynamic]Saved_Tab,
	fullscreen:    bool,
	page_fullscreen: bool,
	// the keyboard goes to the chrome (a field, a menu) rather than the page
	chrome_focus:  bool,
	/// where the page is (logical pixels)
	card:          [4]f32,
	// input
	hover:         Target,
	grab:          Target,
	// what pages asked for, until answered
	options:       map[int]^WebKitOptionMenu,
	dialogs:       map[int]^WebKitScriptDialog,
	choosers:      map[int]^WebKitFileChooserRequest,
	permissions:   map[int]^WebKitPermissionRequest,
	context_tab:   ^Tab,
	context_info:  Context_Info,
	asks:          int,
	unseen_downloads: int,
}

Context_Info :: struct {
	link, image, media: string,
	editable, selection: bool,
}

b: Browser


// ---------------------------------------------------------------- start

browser_start :: proc() -> bool {
	w := &b.win
	if !plat.open(w, {app_id = APP_ID, title = "Iris", width = 1280, height = 820, min_width = 480, min_height = 360}) do return false
	renderer_init(w.egl_display)
	text_init()
	clipboard_init(w)
	w.keymap = proc(w: ^plat.Window, format: u32, fd: i32, size: u32) { set_keymap(format, fd, size) }
	w.pointer = proc(w: ^plat.Window, e: plat.Pointer_Event) { browser_pointer(e) }
	w.key = proc(w: ^plat.Window, e: plat.Key_Event) { browser_key(e) }
	w.focus = proc(w: ^plat.Window, on: bool) {
		if b.current != nil && b.current.page != nil do page_set_active(b.current.page, on)
	}
	w.resized = proc(w: ^plat.Window) { browser_layout() }
	w.close = proc(w: ^plat.Window) { browser_quit() }
	w.presented = proc(w: ^plat.Window) {
		if b.current != nil && b.current.page != nil do flush_rendered(b.current.page)
	}
	w.draw = browser_draw
	chrome_start()
	browser_layout()
	return true
}

browser_quit :: proc() {
	browser_save_session()
	history_flush()
	b.win.closed = true
	g_main_loop_quit(main_loop)
}

// ---------------------------------------------------------------- drawing

browser_draw :: proc(w: ^plat.Window) {
	frame_begin(w.pixel_w, w.pixel_h, w.scale)
	draw_dawn()
	if t := b.current; t != nil && t.page != nil {
		p := t.page
		page_latch(p)
		c := b.card
		r: f32 = b.page_fullscreen ? 0 : 14
		draw_fill(c.x, c.y + 4, c.z, c.w, r, {0.14, 0.11, 0.25, 0.16}, soft = 12)
		draw_fill(c.x, c.y, c.z, c.w, r, {1, 1, 1, 1})
		draw_texture(p.tex, c.x, c.y, c.z, c.w, r)
	}
	frame_scene_done()
	chrome_draw(f32(w.width), f32(w.height))
}

/// Iris's glass for each kind the chrome asks for
glass_style :: proc(g: Glass_Rect) -> Glass {
	switch g.kind {
	case 1: // panels, menus, notes: frosted, for reading
		return {radius = g.r, tint = {0.99, 0.99, 1, 0.8}, bend = 3.5, rim = 10, lens = 0.01, frost = 1, shadow = 1.2, rim_light = 1, dispersion = true}
	case 2: // the selected tab's pill
		return {radius = g.r, tint = {1, 1, 1, 0.42}, bend = 6, rim = 12, lens = 0.02, shadow = 0.5, rim_light = 1}
	case 3: // a hovered button
		return {radius = g.r, tint = {1, 1, 1, 0.3}, bend = 4, rim = 9, lens = 0.02, rim_light = 0.8}
	}
	// bars: clear glass that bends the page
	return {radius = g.r, tint = {1, 1, 1, 0.22}, bend = 8, rim = 16, lens = 0.03, shadow = 0.8, rim_light = 1, dispersion = true}
}

browser_layout :: proc() {
	w := &b.win
	b.card = chrome_card(f32(w.width), f32(w.height))
	if t := b.current; t != nil && t.page != nil {
		c := b.card
		if c.z > 0 && c.w > 0 do page_place(t.page, f64(c.x), f64(c.y), f64(c.z), f64(c.w), w.scale)
	}
	plat.invalidate(w)
}

browser_page_frame :: proc(t: ^Tab) {
	if t == b.current {
		plat.invalidate(&b.win)
		return
	}
	// a page out of sight: its frame is taken and given back at once
	page_latch(t.page)
	flush_rendered(t.page)
}

browser_page_cursor :: proc(t: ^Tab) {
	if t == b.current && b.hover == .Page do plat.set_cursor(&b.win, t.page.cursor)
}

browser_fullscreen :: proc(on: bool) {
	b.page_fullscreen = on
	plat.set_fullscreen(&b.win, on || b.fullscreen)
	chrome_push()
	browser_layout()
}

// ---------------------------------------------------------------- tabs

New_Tab :: struct {
	url:       string,
	container: string,
	after:     ^Tab,
	select:    bool,
	related:   ^WebKitWebView,
	lazy:      bool,
}

/// a new tab; a plain one is Google AI Mode (the spare one, already loaded)
browser_new_tab :: proc(o: New_Tab) -> ^Tab {
	plain := len(o.url) == 0 && o.related == nil
	t: ^Tab
	if plain && o.container == "" && b.spare != nil {
		t = b.spare
		b.spare = nil
	} else {
		t = tab_new(o.container)
	}
	at := len(b.tabs)
	if o.after != nil {
		for x, i in b.tabs do if x == o.after do at = i + 1
	}
	inject_at(&b.tabs, at, t)
	if o.related != nil {
		tab_ensure_web(t, o.related)
		t.held = true
	} else if plain {
		if t.web == nil do tab_load(t, HOME)
	} else if o.lazy {
		set_str(&t.url, o.url)
	} else {
		tab_load(t, o.url)
	}
	if o.select do browser_select(t)
	chrome_push()
	after(800, proc(_: rawptr) { browser_prepare_spare() }, nil)
	return t
}

/// the next new tab is ready before it is asked for
browser_prepare_spare :: proc() {
	if b.spare != nil do return
	t := tab_new("")
	tab_load(t, HOME)
	if t.page != nil do page_set_visible(t.page, false)
	b.spare = t
}

browser_attach :: proc(t: ^Tab) {
	if t.page == nil do return
	page_set_visible(t.page, t == b.current)
	if t == b.current do browser_layout()
}

browser_detach :: proc(t: ^Tab) {
	if t.page != nil do page_set_visible(t.page, false)
}

browser_has_tab :: proc(t: ^Tab) -> bool {
	for x in b.tabs do if x == t do return true
	return t == b.spare
}

browser_tab_of_web :: proc(w: ^WebKitWebView) -> ^Tab {
	for t in b.tabs do if t.web == w do return t
	return nil
}

browser_select :: proc(t: ^Tab) {
	if !browser_has_tab(t) do return
	old := b.current
	if old == t do return
	if old != nil && old.page != nil {
		page_set_visible(old.page, false)
		page_focus(old.page, false)
	}
	b.current = t
	if t.web == nil && len(t.url) > 0 {
		u := strings.clone(t.url, context.temp_allocator)
		tab_load(t, u)
	} else if t.web == nil {
		tab_load(t, HOME)
	}
	if t.page != nil {
		page_set_visible(t.page, true)
		if !b.chrome_focus do page_focus(t.page, true)
	}
	b.hover = .None
	browser_layout()
	chrome_push()
}

browser_close :: proc(t: ^Tab) {
	idx := -1
	for x, i in b.tabs do if x == t do idx = i
	if idx < 0 do return
	if !tab_is_private(t) && !t.sandboxed && len(t.url) > 0 {
		append(&b.closed, Saved_Tab{url = strings.clone(t.url), container = strings.clone(t.container)})
	}
	ordered_remove(&b.tabs, idx)
	if b.current == t {
		b.current = nil
		if len(b.tabs) > 0 do browser_select(b.tabs[min(idx, len(b.tabs) - 1)])
	}
	private_left := false
	for x in b.tabs do if tab_is_private(x) do private_left = true
	tab_free(t)
	if !private_left do end_private()
	if len(b.tabs) == 0 {
		browser_new_tab({select = true})
		return
	}
	chrome_push()
}

browser_close_later :: proc(t: ^Tab) {
	idle(proc(d: rawptr) {
		t := cast(^Tab)d
		if browser_has_tab(t) do browser_close(t)
	}, t)
}

browser_reopen :: proc() {
	if len(b.closed) == 0 do return
	s := pop(&b.closed)
	browser_new_tab({url = s.url, container = s.container, select = true})
}

browser_cycle :: proc(d: int) {
	if len(b.tabs) < 2 || b.current == nil do return
	for x, i in b.tabs do if x == b.current {
		browser_select(b.tabs[(i + d + len(b.tabs)) % len(b.tabs)])
		return
	}
}

browser_go :: proc(text: string) {
	u := resolve(text, context.temp_allocator)
	if len(u) == 0 do return
	if b.current == nil {
		browser_new_tab({url = u, select = true})
		return
	}
	tab_load(b.current, u)
	chrome_set_focus(false)
}

browser_tab_changed :: proc(t: ^Tab) {
	if t == b.spare do return
	chrome_push()
}

browser_zoom :: proc(d: int) {
	t := b.current
	if t == nil do return
	steps := [?]f64{0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3}
	if d == 0 {
		tab_set_zoom(t, 1)
		return
	}
	i := 4
	for s, k in steps do if s >= t.zoom - 0.001 {
		i = k
		break
	}
	tab_set_zoom(t, steps[clamp(i + d, 0, len(steps) - 1)])
	browser_toast(fmt.tprintf("Zoom %d%%", int(t.zoom * 100 + 0.5)))
}

// ---------------------------------------------------------------- pop-ups

/// a link that opens a new window opens as a tab next to yours; a
/// script's pop-up needs your click and goes only to the same site or a
/// sign-in page; ad domains open nothing
browser_new_window_action :: proc(t: ^Tab, d: ^WebKitPolicyDecision) -> bool {
	nav := webkit_navigation_policy_decision_get_navigation_action(cast(^WebKitNavigationPolicyDecision)d)
	req := webkit_navigation_action_get_request(nav)
	if req == nil do return false
	u := string(webkit_uri_request_get_uri(req))
	host, _ := host_of(u, context.temp_allocator)
	page_host, _ := host_of(t.url, context.temp_allocator)
	shield := shields_on_for(page_host)
	if shield && host_blocked(host) {
		webkit_policy_decision_ignore(d)
		return true
	}
	if webkit_navigation_action_get_navigation_type(nav) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED {
		webkit_policy_decision_ignore(d)
		background := webkit_navigation_action_get_mouse_button(nav) == 2
		browser_new_tab({url = u, container = t.container, after = t, select = !background})
		return true
	}
	if t.sandboxed {
		webkit_policy_decision_ignore(d)
		return true
	}
	gesture := webkit_navigation_action_is_user_gesture(nav) != 0
	if gesture && (site_of(host) == site_of(page_host) || is_sign_in(host) || u == "about:blank") {
		return false // WebKit goes on and asks for the view ("create")
	}
	webkit_policy_decision_ignore(d)
	if shield {
		browser_toast("Pop-up blocked")
	} else {
		browser_new_tab({url = u, container = t.container, after = t})
	}
	return true
}

browser_popup :: proc(t: ^Tab, nav: ^WebKitNavigationAction) -> ^WebKitWebView {
	if t.web == nil do return nil
	p := browser_new_tab({container = t.container, after = t, related = t.web})
	return p.web
}

// ---------------------------------------------------------------- input

@(private="file") inside :: proc(r: [4]f32, x, y: f64) -> bool {
	return f32(x) >= r.x && f32(x) < r.x + r.z && f32(y) >= r.y && f32(y) < r.y + r.w
}

@(private="file") target_at :: proc(x, y: f64) -> Target {
	if chrome_modal() do return .Chrome
	if _, ok := chrome_hit_at({f32(x), f32(y)}); ok do return .Chrome
	if b.current != nil && b.current.page != nil && inside(b.card, x, y) do return .Page
	return .Chrome
}

@(private="file") send_to :: proc(t: Target, e: plat.Pointer_Event) {
	switch t {
	case .Chrome: chrome_pointer(e)
	case .Page: if b.current != nil && b.current.page != nil do page_pointer(b.current.page, e)
	case .None:
	}
}

browser_pointer :: proc(e: plat.Pointer_Event) {
	rnd.pointer = e.kind == .Leave ? {-1, -1} : {f32(e.x), f32(e.y)}
	t := b.grab != .None ? b.grab : target_at(e.x, e.y)
	if e.kind == .Leave {
		send_to(b.hover, e)
		b.hover = .None
		return
	}
	if t != b.hover {
		if b.hover != .None do send_to(b.hover, {kind = .Leave, x = e.x, y = e.y, time = e.time, mods = e.mods})
		b.hover = t
		send_to(t, {kind = .Enter, x = e.x, y = e.y, time = e.time, mods = e.mods})
		cursor := plat.Cursor_Shape.Default
		if t == .Page && b.current != nil && b.current.page != nil do cursor = b.current.page.cursor
		plat.set_cursor(&b.win, cursor)
	}
	if t == .Chrome {
		h, _ := chrome_hit_at({f32(e.x), f32(e.y)})
		plat.set_cursor(&b.win, h.cursor)
	}
	if e.kind == .Enter do return
	if e.kind == .Button {
		if e.pressed {
			b.grab = t
			// a press in the page gives it the keyboard; in the chrome, the chrome decides
			if t == .Page do chrome_set_focus(false)
		} else {
			b.grab = .None
		}
	}
	send_to(t, e)
	if e.kind == .Motion do plat.invalidate(&b.win) // the pointer's light on the glass
}

/// Iris's own keys first; the rest go to the chrome or the page
browser_key :: proc(e: plat.Key_Event) {
	if e.pressed && browser_shortcut(e) do return
	if chrome_wants_keys() {
		chrome_key(e)
	} else if b.current != nil && b.current.page != nil {
		page_key(b.current.page, e)
	}
}

@(private="file") browser_shortcut :: proc(e: plat.Key_Event) -> bool {
	ctrl := .Ctrl in e.mods
	shift := .Shift in e.mods
	alt := .Alt in e.mods
	if ctrl && !alt {
		switch e.sym {
		case 't': if shift { browser_reopen() } else { browser_new_tab({select = true}); chrome_focus_address() }
		case 'n': browser_new_tab({container = shift ? PRIVATE_ID : "", select = true})
		case 'w': if b.current != nil do browser_close(b.current)
		case 'q': browser_quit()
		case 'l', 'k': chrome_focus_address()
		case 'r':
			if b.current != nil && b.current.web != nil {
				if shift { webkit_web_view_reload_bypass_cache(b.current.web) } else { tab_reload(b.current) }
			}
		case 'f': chrome_open_find()
		case 'j': chrome_open_downloads()
		case 'y': if !shift do return false; chrome_open_downloads()
		case plat.KEY_plus, plat.KEY_equal, plat.KEY_KP_Add: browser_zoom(1)
		case plat.KEY_minus, plat.KEY_KP_Subtract: browser_zoom(-1)
		case plat.KEY_0, plat.KEY_KP_0: browser_zoom(0)
		case plat.KEY_Tab: browser_cycle(shift ? -1 : 1)
		case plat.KEY_ISO_Left_Tab: browser_cycle(-1)
		case plat.KEY_Page_Down: browser_cycle(1)
		case plat.KEY_Page_Up: browser_cycle(-1)
		case plat.KEY_1 ..= plat.KEY_9:
			i := int(e.sym - plat.KEY_1)
			if i < len(b.tabs) do browser_select(b.tabs[i])
		case: return false
		}
		return true
	}
	if alt && !ctrl {
		switch e.sym {
		case plat.KEY_Left: if b.current != nil do tab_back(b.current)
		case plat.KEY_Right: if b.current != nil do tab_forward(b.current)
		case plat.KEY_Home: browser_go(HOME)
		case: return false
		}
		return true
	}
	switch e.sym {
	case plat.KEY_F5: if b.current != nil do tab_reload(b.current)
	case plat.KEY_F6: chrome_focus_address()
	case plat.KEY_F11:
		b.fullscreen = !b.fullscreen
		plat.set_fullscreen(&b.win, b.fullscreen)
	case plat.KEY_Escape:
		if chrome_modal() || ui.find_open {
			chrome_close_all()
			return true
		}
		if b.fullscreen || b.page_fullscreen {
			b.fullscreen = false
			plat.set_fullscreen(&b.win, false)
			return b.page_fullscreen == false
		}
		return false
	case: return false
	}
	return true
}

// ---------------------------------------------------------------- what pages ask for

browser_toast :: proc(text: string) {
	chrome_toast(text)
}

browser_hover_link :: proc(t: ^Tab, link: string) {
	if t != b.current do return
	if len(link) > 0 {
		// the link's site is looked up while the pointer rests on it
		if h, ok := host_of(link, context.temp_allocator); ok && t.web != nil do warm_dns(webkit_web_view_get_network_session(t.web), h)
	}
	chrome_status(link)
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
	ci := &b.context_info
	delete(ci.link)
	delete(ci.image)
	delete(ci.media)
	ci^ = {}
	if webkit_hit_test_result_context_is_link(hit) != 0 do ci.link = strings.clone(string(webkit_hit_test_result_get_link_uri(hit)))
	if webkit_hit_test_result_context_is_image(hit) != 0 do ci.image = strings.clone(string(webkit_hit_test_result_get_image_uri(hit)))
	if webkit_hit_test_result_context_is_media(hit) != 0 do ci.media = strings.clone(string(webkit_hit_test_result_get_media_uri(hit)))
	ci.editable = webkit_hit_test_result_context_is_editable(hit) != 0
	ci.selection = webkit_hit_test_result_context_is_selection(hit) != 0
	b.context_tab = t
	if strings.has_prefix(ci.link, "javascript:") {
		delete(ci.link)
		ci.link = ""
	}
	chrome_context_menu(b.card.x + f32(x), b.card.y + f32(y))
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
	b.asks += 1
	b.dialogs[b.asks] = webkit_script_dialog_ref(d)
	host := display_url(t.url, context.temp_allocator)
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
	portal_open_file(cast(^WebKitFileChooserRequest)g_object_ref(req), webkit_file_chooser_request_get_select_multiple(req) != 0)
}

// ---------------------------------------------------------------- the session

browser_save_session :: proc() {
	s := settings()
	clear(&s.session)
	for t in b.tabs {
		if tab_is_private(t) || t.sandboxed || len(t.url) == 0 || is_ai_mode(t.url) do continue
		append(&s.session, Saved_Tab{url = strings.clone(t.url), title = strings.clone(t.title), container = strings.clone(t.container)})
	}
	settings_save()
}

/// the tabs open last time come back (only the first loads; the others
/// wait until you go to them)
browser_restore :: proc() {
	saved := settings().session
	for s, i in saved {
		k := s.container
		if _, ok := container_get(k); !ok do k = ""
		t := browser_new_tab({url = s.url, container = k, select = i == 0, lazy = i != 0})
		if i != 0 do set_str(&t.title, s.title)
	}
}

