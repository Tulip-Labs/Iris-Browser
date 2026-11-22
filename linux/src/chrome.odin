// The chrome's Odin side: the HTML view that draws the tabs, the address
// bar, menus and dialogs, what Iris tells it (the state, as one JSON
// object, and calls such as toast()), and what it tells Iris (where its
// glass goes, where it takes the pointer, and what you chose).
//
// The chrome view is its own world: a web context of its own, no network
// (its page allows nothing but its own inline code and data: pictures),
// and no navigation after it loads.
package iris

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import plat "../plat"

@(private="file") queue: [dynamic]string
@(private="file") loaded: bool
@(private="file") find_hooked: map[^WebKitFindController]bool

chrome_start :: proc() {
	ucm := webkit_user_content_manager_new()
	webkit_user_content_manager_register_script_message_handler(ucm, "iris", nil)
	on(ucm, "script-message-received::iris", rawptr(proc "c" (m: rawptr, v: ^JSCValue, d: rawptr) {
		context = main_context
		s := jsc_value_to_json(v, 0)
		if s == nil do return
		chrome_message(string(s))
		g_free(rawptr(s))
	}), nil)
	b.chrome_ucm = ucm
	st := cast(^WebKitSettings)gnew(webkit_settings_get_type(),
		{name = "enable-developer-extras", value = false},
		{name = "enable-write-console-messages-to-stdout", value = true},
		{name = "enable-smooth-scrolling", value = false})
	defer unref(st)
	ctx := cast(^WebKitWebContext)gnew(webkit_web_context_get_type())
	w := cast(^WebKitWebView)gnew(webkit_web_view_get_type(),
		{name = "display", value = rawptr(display()), type = wpe_display_get_type()},
		{name = "user-content-manager", value = rawptr(ucm), type = webkit_user_content_manager_get_type()},
		{name = "settings", value = rawptr(st), type = webkit_settings_get_type()},
		{name = "web-context", value = rawptr(ctx), type = webkit_web_context_get_type()},
		{name = "network-session", value = rawptr(webkit_network_session_new_ephemeral()), type = webkit_network_session_get_type()})
	g_object_ref_sink(w)
	clear_color := WebKitColor{0, 0, 0, 0}
	webkit_web_view_set_background_color(w, &clear_color)
	b.chrome_web = w
	// the chrome goes nowhere and has no menu of its own
	on(w, "decide-policy", rawptr(proc "c" (w: rawptr, d: ^WebKitPolicyDecision, kind: u32, data: rawptr) -> gboolean {
		if !loaded do return 0
		webkit_policy_decision_ignore(d)
		return 1
	}), nil)
	on(w, "context-menu", rawptr(proc "c" (w: rawptr, m, e, h: rawptr, data: rawptr) -> gboolean { return 1 }), nil)
	on(w, "web-process-terminated", rawptr(proc "c" (w: ^WebKitWebView, reason: u32, data: rawptr) {
		context = main_context
		// the chrome starts again where it was
		b.chrome_ready = false
		loaded = false
		chrome_load()
	}), nil)
	p := page_new(w)
	p.on_frame = proc(p: ^Page) { plat.invalidate(&b.win) }
	p.on_cursor = proc(p: ^Page) { if b.hover == .Chrome do plat.set_cursor(&b.win, p.cursor) }
	b.chrome = p
	page_set_visible(p, true)
	page_set_active(p, true)
	downloads_changed = proc(d: ^Download) {
		if d != nil && d.done && !d.failed do b.unseen_downloads += 1
		chrome_push()
	}
	chrome_load()
}

@(private="file") chrome_load :: proc() {
	html, _ := strings.replace(CHROME_HTML, "/*CSS*/", CHROME_CSS, 1, context.temp_allocator)
	html, _ = strings.replace(html, "//JS", CHROME_JS, 1, context.temp_allocator)
	webkit_web_view_load_html(b.chrome_web, cstr(html), "about:blank")
}

/// runs JS in the chrome (queued until it is ready)
chrome_call :: proc(js: string) {
	if !b.chrome_ready || b.chrome_web == nil {
		append(&queue, strings.clone(js))
		return
	}
	webkit_web_view_evaluate_javascript(b.chrome_web, cstr(js), -1, nil, nil, nil, nil, nil)
}

/// the keyboard goes to the chrome (an address, a menu) or to the page
chrome_set_focus :: proc(on: bool) {
	if b.chrome_focus == on do return
	b.chrome_focus = on
	if b.chrome != nil do page_focus(b.chrome, on)
	if t := b.current; t != nil && t.page != nil do page_focus(t.page, !on)
	if !on do chrome_call("blurAll()")
}

/// the chrome draws the state again (once per turn of the loop, however
/// many changes there were)
chrome_push :: proc() {
	if b.push_pending do return
	b.push_pending = true
	idle(proc(_: rawptr) {
		b.push_pending = false
		chrome_call(strings.concatenate({"setState(", chrome_state(), ")"}, context.temp_allocator))
	}, nil)
}

@(private="file") js :: proc(s: string) -> string { return json_str(s, context.temp_allocator) }

@(private="file") container_json :: proc(sb: ^strings.Builder, k: Container) {
	fmt.sbprintf(sb, `{{"id":%s,"name":%s,"color":%s,"icon":%s}}`, js(k.id), js(k.name), js(k.color), js(k.icon))
}

@(private="file") chrome_state :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"tabs":[`)
	for t, i in b.tabs {
		if i > 0 do strings.write_byte(&sb, ',')
		k, has := container_get(t.container)
		title := t.title
		if len(title) == 0 do title = is_ai_mode(t.url) ? "Google AI Mode" : display_url(t.url, context.temp_allocator)
		if len(title) == 0 do title = "New Tab"
		fmt.sbprintf(&sb, `{{"id":%d,"title":%s,"favicon":%s,"loading":%v,"sandboxed":%v,"private":%v,"color":%s,"icon":%s,"current":%v,"ai":%v}}`,
			t.id, js(title), js(t.favicon), t.loading, t.sandboxed, tab_is_private(t),
			js(has ? k.color : ""), js(has ? k.icon : ""), t == b.current, is_ai_mode(t.url))
	}
	strings.write_string(&sb, `],"containers":[`)
	containers_ensure()
	for k, i in containers {
		if i > 0 do strings.write_byte(&sb, ',')
		container_json(&sb, k)
	}
	strings.write_byte(&sb, ']')
	s := settings()
	fmt.sbprintf(&sb, `,"shields":%v,"level":%s,"ready":%v`, s.shields, js(fmt.tprint(s.shieldLevel)), shields_ready())
	if t := b.current; t != nil {
		host, _ := host_of(t.url, context.temp_allocator)
		site := site_of(host)
		q, ai := ai_query(t.url, context.temp_allocator)
		addr := ai ? q : editable_url(t.url, context.temp_allocator)
		if is_ai_mode(t.url) && !ai do addr = ""
		fmt.sbprintf(&sb, `,"address":%s,"display":%s,"ai":%v,"site":%s,"shieldOn":%v,"canBack":%v,"canForward":%v,"loading":%v,"progress":%f,"sandboxed":%v,"private":%v,"container":%s,"zoom":%f`,
			js(addr), js(display_url(t.url, context.temp_allocator)), is_ai_mode(t.url), js(site),
			s.shields && shields_on_for(host), t.can_back, t.can_forward, t.loading, t.progress, t.sandboxed,
			tab_is_private(t), js(t.container), t.zoom)
	}
	fmt.sbprintf(&sb, `,"fullscreen":%v,"ownFrame":%v,"maximized":%v,"downloads":{{"active":%d,"unseen":%d,"items":[`,
		b.page_fullscreen || b.fullscreen, !b.win.server_frame, b.win.maximized, downloads_active(), b.unseen_downloads)
	n := 0
	#reverse for d in downloads {
		if n == 12 do break
		if n > 0 do strings.write_byte(&sb, ',')
		fmt.sbprintf(&sb, `{{"id":%d,"name":%s,"status":%s,"progress":%f,"done":%v,"failed":%v}}`,
			d.id, js(d.name), js(download_status(d)), d.progress, d.done, d.failed)
		n += 1
	}
	strings.write_string(&sb, "]}}")
	return strings.to_string(sb)
}

// ---------------------------------------------------------------- messages

@(private="file") str_of :: proc(o: json.Object, k: string) -> string {
	if v, ok := o[k].(json.String); ok do return v
	return ""
}
@(private="file") num_of :: proc(o: json.Object, k: string) -> f64 {
	#partial switch v in o[k] {
	case json.Float: return v
	case json.Integer: return f64(v)
	}
	return 0
}
@(private="file") bool_of :: proc(o: json.Object, k: string) -> bool {
	if v, ok := o[k].(json.Boolean); ok do return v
	return false
}

@(private="file") tab_by_id :: proc(id: int) -> ^Tab {
	for t in b.tabs do if t.id == id do return t
	return nil
}

@(private="file") rect_of :: proc(v: json.Value) -> (r: [4]f32, ok: bool) {
	a := v.(json.Array) or_return
	if len(a) < 4 do return
	for i in 0 ..< 4 {
		#partial switch x in a[i] {
		case json.Float: r[i] = f32(x)
		case json.Integer: r[i] = f32(x)
		case: return
		}
	}
	return r, true
}

chrome_message :: proc(text: string) {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil do return
	o, ok := v.(json.Object)
	if !ok do return
	t := b.current
	switch str_of(o, "op") {
	case "ready":
		loaded = true
		b.chrome_ready = true
		for q in queue {
			webkit_web_view_evaluate_javascript(b.chrome_web, cstr(q), -1, nil, nil, nil, nil, nil)
			delete(q)
		}
		clear(&queue)
		chrome_push()
	case "layout": chrome_layout(o)
	case "focus": chrome_set_focus(bool_of(o, "on"))
	case "go": browser_go(str_of(o, "text"))
	case "newTab":
		u := str_of(o, "url")
		browser_new_tab({url = u, container = str_of(o, "container"), select = true})
		if len(u) == 0 do chrome_call("focusAddress()")
	case "select": if x := tab_by_id(int(num_of(o, "id"))); x != nil do browser_select(x)
	case "close": if x := tab_by_id(int(num_of(o, "id"))); x != nil do browser_close(x)
	case "move":
		// a tab dragged to a new place in the strip
		x := tab_by_id(int(num_of(o, "id")))
		to := int(num_of(o, "to"))
		if x == nil do break
		for y, i in b.tabs do if y == x {
			ordered_remove(&b.tabs, i)
			break
		}
		inject_at(&b.tabs, clamp(to, 0, len(b.tabs)), x)
		chrome_push()
	case "back": if t != nil do tab_back(t)
	case "forward": if t != nil do tab_forward(t)
	case "reload": if t != nil do tab_reload(t)
	case "stop": if t != nil do tab_stop(t)
	case "home": browser_go(HOME)
	case "reopen": browser_reopen()
	case "duplicate":
		if x := tab_by_id(int(num_of(o, "id"))); x != nil do browser_new_tab({url = x.url, container = x.container, after = x, select = true})
	case "closeOthers":
		keep := tab_by_id(int(num_of(o, "id")))
		for i := 0; i < len(b.tabs); {
			if b.tabs[i] != keep { browser_close(b.tabs[i]) } else { i += 1 }
		}
	case "reloadTab": if x := tab_by_id(int(num_of(o, "id"))); x != nil do tab_reload(x)
	case "openIn":
		// a tab's page (or the current one) in another container
		x := tab_by_id(int(num_of(o, "id")))
		if x == nil do x = t
		if x != nil && len(x.url) > 0 do browser_new_tab({url = x.url, container = str_of(o, "container"), after = x, select = true})
	case "suggest": chrome_suggest(str_of(o, "text"))
	case "find": chrome_find(str_of(o, "text"), str_of(o, "dir"))
	case "findClose":
		if t != nil && t.web != nil do webkit_find_controller_search_finish(webkit_web_view_get_find_controller(t.web))
	case "shieldSite":
		if t == nil do break
		host, _ := host_of(t.url, context.temp_allocator)
		toggle_site(site_of(host))
		shields_apply(t.ucm, host)
		tab_reload(t)
		chrome_push()
	case "shieldAll":
		s := settings()
		s.shields = !s.shields
		settings_save()
		browser_reapply_shields()
		if t != nil do tab_reload(t)
		chrome_push()
	case "level":
		l: Level
		switch str_of(o, "level") {
		case "moderate": l = .moderate
		case "ultra": l = .ultra
		case: l = .aggressive
		}
		s := settings()
		if l != s.shieldLevel {
			s.shieldLevel = l
			settings_save()
			shields_level_changed()
			browser_toast(fmt.tprintf("Shields: %s. Pages pick it up as they load.", level_title(l)))
		}
		chrome_push()
	case "dlCancel", "dlOpen", "dlShow":
		id := int(num_of(o, "id"))
		for d in downloads do if d.id == id {
			switch str_of(o, "op") {
			case "dlCancel": download_cancel(d)
			case "dlOpen": if d.done do download_open(d)
			case "dlShow": download_show(d)
			}
		}
	case "dlClear":
		downloads_clear_finished()
		chrome_push()
	case "dlFolder": spawn({"xdg-open", downloads_dir()})
	case "dlSeen":
		b.unseen_downloads = 0
		chrome_push()
	case "containerNew":
		name := strings.trim_space(str_of(o, "name"))
		if len(name) == 0 do break
		icon := str_of(o, "icon")
		if len(icon) == 0 do icon = "star"
		k := container_add(name, icon)
		browser_new_tab({container = k.id, select = true})
	case "containerRemove":
		id := str_of(o, "id")
		for i := 0; i < len(b.tabs); {
			if b.tabs[i].container == id { browser_close(b.tabs[i]) } else { i += 1 }
		}
		container_remove(id)
		chrome_push()
	case "ctx": chrome_context_action(o)
	case "option":
		id := int(num_of(o, "id"))
		if m, ok := b.options[id]; ok {
			i := int(num_of(o, "index"))
			if i >= 0 do webkit_option_menu_activate_item(m, u32(i))
			webkit_option_menu_close(m)
			unref(m)
			delete_key(&b.options, id)
		}
	case "dialog":
		id := int(num_of(o, "id"))
		if d, ok := b.dialogs[id]; ok {
			yes := bool_of(o, "ok")
			kind := webkit_script_dialog_get_dialog_type(d)
			if kind == WEBKIT_SCRIPT_DIALOG_CONFIRM || kind == WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM do webkit_script_dialog_confirm_set_confirmed(d, yes ? 1 : 0)
			if kind == WEBKIT_SCRIPT_DIALOG_PROMPT && yes do webkit_script_dialog_prompt_set_text(d, cstr(str_of(o, "text")))
			webkit_script_dialog_close(d)
			webkit_script_dialog_unref(d)
			delete_key(&b.dialogs, id)
		}
	case "permission":
		id := int(num_of(o, "id"))
		if r, ok := b.permissions[id]; ok {
			if bool_of(o, "allow") { webkit_permission_request_allow(r) } else { webkit_permission_request_deny(r) }
			unref(r)
			delete_key(&b.permissions, id)
		}
	case "copy": clipboard_offer(str_of(o, "text"))
	case "move-window": plat.begin_move(&b.win)
	case "fullscreen":
		b.fullscreen = !b.fullscreen
		plat.set_fullscreen(&b.win, b.fullscreen)
	case "close-window": browser_quit()
	case "minimize": plat.minimize(&b.win)
	case "maximize": plat.toggle_maximized(&b.win)
	}
}

/// where the chrome's glass goes, where it takes the pointer, and where
/// the page is
@(private="file") chrome_layout :: proc(o: json.Object) {
	clear(&b.glass)
	if a, ok := o["glass"].(json.Array); ok {
		for g in a {
			go := g.(json.Object) or_continue
			append(&b.glass, Glass_Rect{
				x = f32(num_of(go, "x")), y = f32(num_of(go, "y")), w = f32(num_of(go, "w")), h = f32(num_of(go, "h")),
				r = f32(num_of(go, "r")), kind = int(num_of(go, "k")),
			})
		}
	}
	clear(&b.hits)
	if a, ok := o["hits"].(json.Array); ok {
		for h in a do if r, ok := rect_of(h); ok do append(&b.hits, r)
	}
	b.chrome_modal = bool_of(o, "modal")
	if c, ok := rect_of(o["card"]); ok && !b.page_fullscreen && c != b.card {
		b.card = c
		browser_layout()
	}
	plat.invalidate(&b.win)
}

// ---------------------------------------------------------------- suggestions

@(private="file") chrome_suggest :: proc(text0: string) {
	text := strings.trim_space(text0)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '[')
	if len(text) > 0 {
		first := resolve(text, context.temp_allocator)
		if is_url_like(text) {
			fmt.sbprintf(&sb, `{{"kind":"go","title":%s,"sub":"","url":%s}}`, js(display_url(first, context.temp_allocator)), js(first))
		} else {
			fmt.sbprintf(&sb, `{{"kind":"ask","title":%s,"sub":"Ask Google AI Mode","url":%s}}`, js(text), js(first))
		}
		for v in history_suggest(text, 6) {
			if v.url == first do continue
			title := len(v.title) > 0 ? v.title : display_url(v.url, context.temp_allocator)
			fmt.sbprintf(&sb, `,{{"kind":"history","title":%s,"sub":%s,"url":%s}}`, js(title), js(display_url(v.url, context.temp_allocator)), js(v.url))
		}
	}
	strings.write_byte(&sb, ']')
	chrome_call(strings.concatenate({"suggestions(", strings.to_string(sb), ")"}, context.temp_allocator))
}

// ---------------------------------------------------------------- find in page

WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE :: u32(1 << 0)
WEBKIT_FIND_OPTIONS_BACKWARDS :: u32(1 << 3)
WEBKIT_FIND_OPTIONS_WRAP_AROUND :: u32(1 << 4)

@(private="file") chrome_find :: proc(text, dir: string) {
	t := b.current
	if t == nil || t.web == nil do return
	fc := webkit_web_view_get_find_controller(t.web)
	if fc not_in find_hooked {
		find_hooked[fc] = true
		on(fc, "counted-matches", rawptr(proc "c" (fc: rawptr, n: u32, d: rawptr) {
			context = main_context
			chrome_call(fmt.tprintf("findCount(%d)", n))
		}), nil)
		on(fc, "failed-to-find-text", rawptr(proc "c" (fc: rawptr, d: rawptr) {
			context = main_context
			chrome_call("findCount(0)")
		}), nil)
	}
	switch dir {
	case "next": webkit_find_controller_search_next(fc)
	case "prev": webkit_find_controller_search_previous(fc)
	case:
		if len(text) == 0 {
			webkit_find_controller_search_finish(fc)
			chrome_call("findCount(-1)")
			return
		}
		opts := WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE | WEBKIT_FIND_OPTIONS_WRAP_AROUND
		webkit_find_controller_search(fc, cstr(text), opts, 1000)
		webkit_find_controller_count_matches(fc, cstr(text), opts, 1000)
	}
}

// ---------------------------------------------------------------- the page's right-click menu

@(private="file") chrome_context_action :: proc(o: json.Object) {
	t := b.context_tab
	if t == nil || !browser_has_tab(t) do return
	ci := &b.context_info
	value := str_of(o, "value")
	switch str_of(o, "do") {
	case "tab": browser_new_tab({url = value, container = t.container, after = t})
	case "in": browser_new_tab({url = value, container = str_of(o, "container"), after = t, select = true})
	case "copy": clipboard_offer(value)
	case "save":
		if t.web != nil {
			d := webkit_web_view_download_uri(t.web, cstr(value))
			if d != nil do unref(d)
		}
	case "edit":
		cmd := value
		switch cmd {
		case "cut": cmd = WEBKIT_EDITING_COMMAND_CUT
		case "copy": cmd = WEBKIT_EDITING_COMMAND_COPY
		case "paste": cmd = WEBKIT_EDITING_COMMAND_PASTE
		case "selectAll": cmd = WEBKIT_EDITING_COMMAND_SELECT_ALL
		case: return
		}
		if t.web != nil do webkit_web_view_execute_editing_command(t.web, cstr(cmd))
	case "back": tab_back(t)
	case "forward": tab_forward(t)
	case "reload": tab_reload(t)
	case "askAI":
		tab_run(t, "window.getSelection().toString()", proc(t: ^Tab, result: string) {
			q := strings.trim_space(result)
			if len(q) == 0 do return
			browser_new_tab({url = ai_url(q, context.temp_allocator), container = t.container, after = t, select = true})
		})
	}
	_ = ci
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

