// Iris's chrome, drawn by Iris: the tab strip, the bars, the address,
// panels, menus, notes and dialogs. Each frame lays them out from the
// browser's state and draws each one's glass and its words and icons in
// the same pass, so glass and content never part. What was drawn is kept
// as hit areas; the pointer and keys act on them until the next frame.
package iris

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import plat "../plat"

INK :: [4]f32{0.14, 0.11, 0.25, 1}
DIM :: [4]f32{0.14, 0.11, 0.25, 0.58}
FAINT :: [4]f32{0.14, 0.11, 0.25, 0.12}
ACCENT :: [4]f32{0.416, 0.298, 0.961, 1}
WARN :: [4]f32{0.91, 0.35, 0.05, 1}
WHITE :: [4]f32{1, 1, 1, 1}

// ---------------------------------------------------------------- what can be clicked

Wid :: enum u16 {
	None, Tab, Tab_Close, Plus, Back, Forward, Reload, Address, Shield, Downloads, Containers,
	Frame_Min, Frame_Max, Frame_Close, Drag, Row, Suggest, Find_Field, Find_Prev, Find_Next, Find_Close,
	Toast, Toast_Action, Dialog, Dialog_Ok, Dialog_Cancel, Prompt, Name, Icon_Choice, Panel, Pill, Download_Act, Download_Row, Scrim,
}

Id :: distinct u64
id :: proc(k: Wid, i: int = 0) -> Id { return Id(u64(k) << 32 | u64(u32(i32(i)))) }
wid_of :: proc(x: Id) -> Wid { return Wid(u64(x) >> 32) }

/// what a click does
Op :: enum u8 {
	None, Select_Tab, Close_Tab, New_Tab, New_Tab_In, Back, Forward, Reload, Stop, Go, Toggle_Panel,
	Shield_Site, Shield_All, Level, Dl_Cancel, Dl_Open, Dl_Show, Dl_Clear, Dl_Folder,
	Open_In, Duplicate, Close_Others, Reload_Tab, New_Container, Add_Container, Remove_Container_Panel, Remove_Container, Pick_Icon,
	Ctx_Tab, Ctx_In, Ctx_Copy, Ctx_Save, Ctx_Edit, Ctx_Back, Ctx_Forward, Ctx_Reload, Ctx_Ask_AI,
	Option, Find_Prev, Find_Next, Find_Close, Toast_Action, Dialog_Ok, Dialog_Cancel,
	Minimize, Maximize, Close_Window, Focus_Address,
}

Action :: struct {
	op: Op,
	n:  int,
	s:  string, // lives until the next frame (frame_strings)
	s2: string,
}

Hit :: struct {
	id:     Id,
	r:      [4]f32,
	act:    Action,
	cursor: plat.Cursor_Shape,
}

Panel :: enum u8 { None, Shields, Downloads, Containers, New_Container, Remove_Container, Tab_Menu, Context, Option }

Toast :: struct {
	text, action, url: string,
	perm:   int, // a permission asked for: Allow answers it
	show:   f32, // 0..1, springs in
	gone:   bool,
	timer:  u32,
	answered: bool,
}

Suggestion :: struct {
	icon:  Icon,
	title, sub, url: string,
}

Option_Item :: struct {
	label:    string,
	group, selected, enabled: bool,
}

Field :: enum u8 { None, Address, Find, Prompt, Name }

Ui :: struct {
	hits, next_hits: [dynamic]Hit,
	frame_strings:  [dynamic]string,
	hot, pressed:   Id,
	pressed_act:    Action,
	pointer:        [2]f32,
	focus:          Field,
	address, find, prompt, name: Line,
	panel:          Panel,
	panel_anchor:   [4]f32, // the button it opened from, or the point
	panel_right:    bool,
	panel_rect:     [4]f32,
	panel_scroll:   f32,
	panel_tab:      int,
	panel_show:     f32,
	sel:            int, // the row the keys are on (-1 none)
	rows:           [dynamic]Action, // the panel's rows that can be chosen, in order
	option_id:      int,
	options:        [dynamic]Option_Item,
	new_icon:       string,
	suggestions:    [dynamic]Suggestion,
	suggest_sel:    int,
	find_open:      bool,
	find_count:     int,
	toasts:         [dynamic]^Toast,
	status:         string,
	dialog_open:    bool,
	dialog_id:      int,
	dialog_kind:    i32,
	dialog_title, dialog_message: string,
	tab_x, tab_w:   map[int]f32, // the tabs' places, springing
	drag_id:        int,
	drag_x0, drag_dx: f32,
	dragging:       bool,
	hover:          map[Id]f32,
	last_frame:     time.Tick,
	animating:      bool,
	address_rect:   [4]f32,
	icons_cache:    [Icon]bool,
}

ui: Ui
/// a fixed time step for the springs (the render check), or 0
ui_test_dt: f32

@(private="file") keep :: proc(s: string) -> string {
	c := strings.clone(s)
	append(&ui.frame_strings, c)
	return c
}

@(private="file") hit :: proc(i: Id, r: [4]f32, act: Action = {}, cursor := plat.Cursor_Shape.Default) {
	append(&ui.next_hits, Hit{i, r, act, cursor})
}

@(private="file") inside :: proc(r: [4]f32, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.z && p.y >= r.y && p.y < r.y + r.w
}

/// the topmost chrome thing at a point, if any
chrome_hit_at :: proc(p: [2]f32) -> (Hit, bool) {
	#reverse for h in ui.hits do if inside(h.r, p) do return h, true
	return {}, false
}

/// anything open that takes every click (a menu, a dialog)
chrome_modal :: proc() -> bool { return ui.dialog_open || ui.panel != .None }

/// the keyboard goes to the chrome (a field, a menu, a dialog)
chrome_wants_keys :: proc() -> bool { return ui.focus != .None || chrome_modal() }

// ---------------------------------------------------------------- start

chrome_start :: proc() {
	ui.sel = -1
	ui.suggest_sel = -1
	ui.find_count = -1
	ui.new_icon = "star"
	downloads_changed = proc(d: ^Download) {
		if d != nil && d.done && !d.failed do b.unseen_downloads += 1
		chrome_push()
	}
}

/// something the chrome shows changed: it draws again
chrome_push :: proc() {
	plat.invalidate(&b.win)
}

/// the keyboard goes to the chrome (an address, a menu) or to the page
chrome_set_focus :: proc(on: bool) {
	if on == (ui.focus != .None) && b.chrome_focus == on do return
	b.chrome_focus = on
	if t := b.current; t != nil && t.page != nil do page_focus(t.page, !on)
	if !on {
		if ui.focus == .Address do line_set(&ui.address, "")
		ui.focus = .None
		clear_suggestions()
	}
	chrome_push()
}

@(private="file") focus_field :: proc(f: Field) {
	ui.focus = f
	b.chrome_focus = true
	if t := b.current; t != nil && t.page != nil do page_focus(t.page, false)
	chrome_push()
}

/// where the page goes, for a window of w × h
chrome_card :: proc(w, h: f32) -> [4]f32 {
	if b.page_fullscreen || b.fullscreen do return {0, 0, w, h}
	return {8, 100, w - 16, h - 108}
}

// ---------------------------------------------------------------- what the browser asks for

chrome_focus_address :: proc() {
	close_panel()
	t := b.current
	text := ""
	if t != nil {
		q, ai := ai_query(t.url, context.temp_allocator)
		text = ai ? q : (is_ai_mode(t.url) ? "" : editable_url(t.url, context.temp_allocator))
	}
	line_set(&ui.address, text)
	line_select_all(&ui.address)
	focus_field(.Address)
}

chrome_open_find :: proc() {
	ui.find_open = true
	line_select_all(&ui.find)
	focus_field(.Find)
}

chrome_open_downloads :: proc() { open_panel(.Downloads, button_rect(.Downloads), true) }

chrome_close_all :: proc() {
	if ui.dialog_open {
		answer_dialog(false)
		return
	}
	close_panel()
	clear_suggestions()
	if ui.focus == .Find do close_find()
}

chrome_toast :: proc(text: string, action := "", url := "", perm := 0, life_ms: u32 = 4500) {
	t := new(Toast)
	t^ = {text = strings.clone(text), action = strings.clone(action), url = strings.clone(url), perm = perm}
	append(&ui.toasts, t)
	t.timer = after(life_ms, proc(d: rawptr) { toast_gone(cast(^Toast)d) }, t)
	chrome_push()
}

@(private="file") toast_gone :: proc(t: ^Toast) {
	if t.gone do return
	t.gone = true
	if t.perm != 0 && !t.answered do answer_permission(t.perm, false)
	chrome_push()
	after(260, proc(d: rawptr) {
		t := cast(^Toast)d
		for x, i in ui.toasts do if x == t {
			ordered_remove(&ui.toasts, i)
			break
		}
		delete(t.text)
		delete(t.action)
		delete(t.url)
		free(t)
		chrome_push()
	}, t)
}

chrome_permission :: proc(id: int, text: string) {
	chrome_toast(text, "Allow", perm = id, life_ms = 6000)
}

chrome_status :: proc(link: string) {
	delete(ui.status)
	ui.status = strings.clone(link)
	chrome_push()
}

chrome_context_menu :: proc(x, y: f32) {
	open_panel(.Context, {x, y, 0, 0}, false)
}

chrome_option_menu :: proc(id: int, x, y, w: f32, items: []Option_Item) {
	for o in ui.options do delete(o.label)
	clear(&ui.options)
	for it in items do append(&ui.options, Option_Item{strings.clone(it.label), it.group, it.selected, it.enabled})
	ui.option_id = id
	open_panel(.Option, {x, y, max(w, 200), 0}, false)
	for it, i in ui.options do if it.selected do ui.sel = row_index_of_option(i)
}

chrome_close_option :: proc() {
	if ui.panel == .Option do close_panel()
}

chrome_dialog :: proc(id, kind: int, title, message, default_text: string) {
	ui.dialog_open = true
	ui.dialog_id, ui.dialog_kind = id, i32(kind)
	delete(ui.dialog_title)
	delete(ui.dialog_message)
	ui.dialog_title = strings.clone(title)
	ui.dialog_message = strings.clone(message)
	line_set(&ui.prompt, default_text)
	line_select_all(&ui.prompt)
	close_panel()
	focus_field(i32(kind) == WEBKIT_SCRIPT_DIALOG_PROMPT ? .Prompt : .None)
	b.chrome_focus = true
	chrome_push()
}

// ---------------------------------------------------------------- panels

@(private="file") open_panel :: proc(p: Panel, anchor: [4]f32, right: bool) {
	if ui.panel == .Option && p != .Option do answer_option(-1)
	ui.panel = p
	ui.panel_anchor = anchor
	ui.panel_right = right
	ui.panel_scroll = 0
	ui.panel_show = 0
	ui.sel = -1
	clear_suggestions()
	if p == .New_Container {
		line_set(&ui.name, "")
		focus_field(.Name)
	} else if ui.focus == .Name {
		ui.focus = .None
	}
	b.chrome_focus = true
	chrome_push()
}

@(private="file") close_panel :: proc() {
	if ui.panel == .None do return
	if ui.panel == .Option do answer_option(-1)
	if ui.panel == .Downloads {
		b.unseen_downloads = 0
	}
	if ui.focus == .Name do ui.focus = .None
	ui.panel = .None
	if ui.focus == .None do chrome_set_focus(false)
	chrome_push()
}

@(private="file") toggle_panel :: proc(p: Panel, anchor: [4]f32, right: bool) {
	if ui.panel == p {
		close_panel()
		return
	}
	open_panel(p, anchor, right)
}

@(private="file") button_rect :: proc(k: Wid) -> [4]f32 {
	for h in ui.hits do if wid_of(h.id) == k do return h.r
	return {f32(b.win.width) - 60, 50, 34, 34}
}

@(private="file") answer_option :: proc(index: int) {
	id := ui.option_id
	ui.option_id = 0
	engine_answer_option(id, index)
}

@(private="file") row_index_of_option :: proc(item: int) -> int {
	n := 0
	for it, i in ui.options {
		if it.group do continue
		if i == item do return n
		n += 1
	}
	return -1
}

answer_permission :: proc(id: int, allow: bool) {
	engine_answer_permission(id, allow)
}

/// the dialog showing goes, answered no (its page is closing)
chrome_dismiss_dialog :: proc() {
	answer_dialog(false)
}

@(private="file") answer_dialog :: proc(yes: bool) {
	b.dialog_tab = nil
	if !ui.dialog_open do return
	ui.dialog_open = false
	engine_answer_dialog(ui.dialog_id, yes, line_string(&ui.prompt))
	if ui.focus == .Prompt do ui.focus = .None
	chrome_set_focus(false)
}

@(private="file") close_find :: proc() {
	ui.find_open = false
	ui.find_count = -1
	if t := b.current; t != nil do tab_find_stop(t)
	if ui.focus == .Find do chrome_set_focus(false)
	chrome_push()
}

// ---------------------------------------------------------------- suggestions

@(private="file") clear_suggestions :: proc() {
	for s in ui.suggestions {
		delete(s.title)
		delete(s.sub)
		delete(s.url)
	}
	clear(&ui.suggestions)
	ui.suggest_sel = -1
}

@(private="file") suggest :: proc(text0: string) {
	clear_suggestions()
	text := strings.trim_space(text0)
	if len(text) == 0 do return
	first := resolve(text, context.temp_allocator)
	if is_url_like(text) {
		append(&ui.suggestions, Suggestion{.Open, strings.clone(display_url(first, context.temp_allocator)), strings.clone(""), strings.clone(first)})
	} else {
		append(&ui.suggestions, Suggestion{.Sparkle, strings.clone(text), strings.clone("Ask Google AI Mode"), strings.clone(first)})
	}
	for v in history_suggest(text, 6) {
		if v.url == first do continue
		title := len(v.title) > 0 ? v.title : display_url(v.url, context.temp_allocator)
		append(&ui.suggestions, Suggestion{.History, strings.clone(title), strings.clone(display_url(v.url, context.temp_allocator)), strings.clone(v.url)})
	}
}

// ---------------------------------------------------------------- find in page

/// dir: "next", "prev", or "" for a new search of the field's text (the
/// engine sets ui.find_count as it counts)
@(private="file") find :: proc(dir: string) {
	t := b.current
	if t == nil || !tab_has_view(t) do return
	text := line_string(&ui.find)
	if dir == "" && len(text) == 0 {
		tab_find_stop(t)
		ui.find_count = -1
		return
	}
	tab_find(t, text, dir)
}

// ---------------------------------------------------------------- doing what was clicked

@(private="file") tab_by_id :: proc(id: int) -> ^Tab {
	for t in b.tabs do if t.id == id do return t
	return nil
}

@(private="file") act :: proc(a: Action) {
	t := b.current
	#partial switch a.op {
	case .Select_Tab: if x := tab_by_id(a.n); x != nil do browser_select(x)
	case .Close_Tab: if x := tab_by_id(a.n); x != nil do browser_close(x)
	case .New_Tab:
		close_panel()
		browser_new_tab({select = true})
		chrome_focus_address()
	case .New_Tab_In:
		close_panel()
		browser_new_tab({container = a.s, select = true})
		chrome_focus_address()
	case .Back: if t != nil do tab_back(t)
	case .Forward: if t != nil do tab_forward(t)
	case .Reload: if t != nil do tab_reload(t)
	case .Stop: if t != nil do tab_stop(t)
	case .Go:
		close_panel()
		u := strings.clone(a.s, context.temp_allocator)
		chrome_set_focus(false)
		browser_go(u)
	case .Focus_Address: chrome_focus_address()
	case .Toggle_Panel: toggle_panel(Panel(a.n), button_rect(a.n == int(Panel.Shields) ? .Shield : a.n == int(Panel.Downloads) ? .Downloads : .Containers), true)
	case .Shield_Site:
		if t == nil do break
		host, _ := host_of(t.url, context.temp_allocator)
		toggle_site(site_of(host))
		tab_shields_apply(t, host)
		tab_reload(t)
	case .Shield_All:
		s := settings()
		s.shields = !s.shields
		settings_save()
		browser_reapply_shields()
		if t != nil do tab_reload(t)
	case .Level:
		s := settings()
		l := Level(a.n)
		if l != s.shieldLevel {
			s.shieldLevel = l
			settings_save()
			engine_shields_level_changed()
			chrome_toast(fmt.tprintf("Shields: %s. Pages pick it up as they load.", level_title(l)))
		}
	case .Dl_Cancel, .Dl_Open, .Dl_Show:
		for d in downloads do if d.id == a.n {
			#partial switch a.op {
			case .Dl_Cancel: download_cancel(d)
			case .Dl_Open: if d.done do download_open(d)
			case .Dl_Show: download_show(d)
			}
		}
	case .Dl_Clear: downloads_clear_finished()
	case .Dl_Folder: spawn({"xdg-open", downloads_dir()})
	case .Open_In:
		close_panel()
		x := tab_by_id(a.n)
		if x == nil do x = t
		if x != nil && len(x.url) > 0 do browser_new_tab({url = x.url, container = a.s, after = x, select = true})
	case .Duplicate:
		close_panel()
		if x := tab_by_id(a.n); x != nil do browser_new_tab({url = x.url, container = x.container, after = x, select = true})
	case .Close_Others:
		close_panel()
		keep_tab := tab_by_id(a.n)
		for i := 0; i < len(b.tabs); {
			if b.tabs[i] != keep_tab { browser_close(b.tabs[i]) } else { i += 1 }
		}
	case .Reload_Tab:
		close_panel()
		if x := tab_by_id(a.n); x != nil do tab_reload(x)
	case .New_Container: open_panel(.New_Container, ui.panel_anchor, true)
	case .Pick_Icon:
		names := CONTAINER_ICONS
		ui.new_icon = names[a.n]
	case .Add_Container:
		name := strings.trim_space(line_string(&ui.name))
		if len(name) == 0 do break
		k := container_add(name, ui.new_icon)
		close_panel()
		browser_new_tab({container = k.id, select = true})
	case .Remove_Container_Panel: open_panel(.Remove_Container, ui.panel_anchor, true)
	case .Remove_Container:
		close_panel()
		id := strings.clone(a.s, context.temp_allocator)
		for i := 0; i < len(b.tabs); {
			if b.tabs[i].container == id { browser_close(b.tabs[i]) } else { i += 1 }
		}
		container_remove(id)
	case .Ctx_Tab, .Ctx_In, .Ctx_Copy, .Ctx_Save, .Ctx_Edit, .Ctx_Back, .Ctx_Forward, .Ctx_Reload, .Ctx_Ask_AI:
		close_panel()
		context_action(a)
	case .Option:
		ui.panel = .None
		answer_option(a.n)
		chrome_set_focus(false)
	case .Find_Prev: find("prev")
	case .Find_Next: find("next")
	case .Find_Close: close_find()
	case .Toast_Action:
		for x in ui.toasts do if x == cast(^Toast)uintptr(a.n) {
			x.answered = true
			if x.perm != 0 {
				answer_permission(x.perm, true)
			} else if len(x.url) > 0 {
				browser_new_tab({url = x.url, select = true})
			}
			toast_gone(x)
		}
	case .Dialog_Ok: answer_dialog(true)
	case .Dialog_Cancel: answer_dialog(false)
	case .Minimize: plat.minimize(&b.win)
	case .Maximize: plat.toggle_maximized(&b.win)
	case .Close_Window: browser_quit()
	}
	chrome_push()
}

@(private="file") context_action :: proc(a: Action) {
	t := b.context_tab
	if t == nil || !browser_has_tab(t) do return
	#partial switch a.op {
	case .Ctx_Tab: browser_new_tab({url = a.s, container = t.container, after = t})
	case .Ctx_In: browser_new_tab({url = a.s, container = a.s2, after = t, select = true})
	case .Ctx_Copy: clipboard_offer(a.s)
	case .Ctx_Save:
		if t.sandboxed {
			browser_toast("Downloads are off for sites in the sandbox")
		} else {
			tab_download(t, a.s)
		}
	case .Ctx_Edit: tab_edit(t, a.s)
	case .Ctx_Back: tab_back(t)
	case .Ctx_Forward: tab_forward(t)
	case .Ctx_Reload: tab_reload(t)
	case .Ctx_Ask_AI:
		tab_run(t, "window.getSelection().toString()", proc(t: ^Tab, result: string) {
			q := strings.trim_space(result)
			if len(q) == 0 do return
			browser_new_tab({url = ai_url(q, context.temp_allocator), container = t.container, after = t, select = true})
		})
	}
}

// ---------------------------------------------------------------- the pointer

/// a pointer event for the chrome (the browser decided it is the chrome's)
chrome_pointer :: proc(e: plat.Pointer_Event) {
	p := [2]f32{f32(e.x), f32(e.y)}
	ui.pointer = p
	h, over := chrome_hit_at(p)
	switch e.kind {
	case .Enter, .Motion:
		ui.hot = over ? h.id : 0
		if ui.drag_id != 0 && ui.pressed != 0 {
			ui.drag_dx = p.x - ui.drag_x0
			if abs(ui.drag_dx) > 6 do ui.dragging = true
		}
		if ui.pressed != 0 && (wid_of(ui.pressed) == .Address || wid_of(ui.pressed) == .Find_Field || wid_of(ui.pressed) == .Prompt || wid_of(ui.pressed) == .Name) {
			// selecting by dragging in a field
			if l, r := field_of(wid_of(ui.pressed)); l != nil do l.cursor = line_index_at(l, r, p.x, field_size(wid_of(ui.pressed)))
		}
		chrome_push()
	case .Leave:
		ui.hot = 0
		chrome_push()
	case .Scroll, .Scroll_Stop:
		if ui.panel != .None && inside(ui.panel_rect, p) {
			ui.panel_scroll = max(0, ui.panel_scroll + f32(e.dy) * (e.precise ? 1 : 40))
			chrome_push()
		}
	case .Button:
		if e.pressed {
			press(e, p, h, over)
		} else {
			release(e, p, h, over)
		}
	}
}

@(private="file") press :: proc(e: plat.Pointer_Event, p: [2]f32, h: Hit, over: bool) {
	k := wid_of(h.id)
	// a press away from an open panel closes it (and does nothing else)
	if ui.panel != .None && !inside(ui.panel_rect, p) && k != .Shield && k != .Downloads && k != .Containers {
		close_panel()
		if !over || k == .Scrim do return
	}
	if ui.dialog_open && !(k == .Dialog || k == .Dialog_Ok || k == .Dialog_Cancel || k == .Prompt) do return
	if !over do return
	ui.pressed = h.id
	ui.pressed_act = h.act
	#partial switch k {
	case .Tab:
		if e.button == 2 {
			if x := tab_by_id(h.act.n); x != nil do browser_close(x)
			ui.pressed = 0
			return
		}
		if e.button == 3 {
			ui.panel_tab = h.act.n
			open_panel(.Tab_Menu, {p.x, p.y + 4, 0, 0}, false)
			ui.pressed = 0
			return
		}
		ui.drag_id = h.act.n
		ui.drag_x0 = p.x
		ui.drag_dx = 0
		ui.dragging = false
	case .Plus:
		if e.button == 3 {
			open_panel(.Containers, h.r, false)
			ui.panel_tab = -1
			ui.pressed = 0
		}
	case .Drag:
		ui.pressed = 0
		if e.clicks == 2 {
			plat.toggle_maximized(&b.win)
		} else if e.button == 1 {
			plat.begin_move(&b.win)
		}
	case .Address:
		if ui.focus != .Address {
			chrome_focus_address()
			ui.pressed = 0 // the first click selects all, as browsers do
			return
		}
		field_press(&ui.address, h.r, p, e.clicks, 14.5)
	case .Find_Field:
		focus_field(.Find)
		field_press(&ui.find, h.r, p, e.clicks, 14)
	case .Prompt:
		focus_field(.Prompt)
		field_press(&ui.prompt, h.r, p, e.clicks, 14)
	case .Name:
		focus_field(.Name)
		field_press(&ui.name, h.r, p, e.clicks, 14)
	case:
		if ui.focus == .Address && k != .Suggest do chrome_set_focus(false)
	}
	chrome_push()
}

@(private="file") release :: proc(e: plat.Pointer_Event, p: [2]f32, h: Hit, over: bool) {
	pressed := ui.pressed
	pa := ui.pressed_act
	ui.pressed = 0
	if ui.drag_id != 0 {
		id := ui.drag_id
		ui.drag_id = 0
		if ui.dragging {
			ui.dragging = false
			move_tab(id, p.x)
			chrome_push()
			return
		}
	}
	if pressed == 0 || !over || h.id != pressed do return
	if e.button != 1 do return
	act(pa)
}

/// a tab dropped at x: before the first tab whose middle is right of it
@(private="file") move_tab :: proc(id: int, x: f32) {
	t := tab_by_id(id)
	if t == nil do return
	to := 0
	for o in b.tabs {
		if o == t do continue
		if x > ui.tab_x[o.id] + ui.tab_w[o.id] / 2 do to += 1
	}
	for o, i in b.tabs do if o == t {
		ordered_remove(&b.tabs, i)
		break
	}
	inject_at(&b.tabs, clamp(to, 0, len(b.tabs)), t)
}

@(private="file") field_of :: proc(k: Wid) -> (^Line, [4]f32) {
	r := [4]f32{}
	for h in ui.hits do if wid_of(h.id) == k do r = h.r
	#partial switch k {
	case .Address: return &ui.address, r
	case .Find_Field: return &ui.find, r
	case .Prompt: return &ui.prompt, r
	case .Name: return &ui.name, r
	}
	return nil, r
}

@(private="file") field_size :: proc(k: Wid) -> f32 { return k == .Address ? 14.5 : 14 }

/// the byte in a field nearest x
@(private="file") line_index_at :: proc(l: ^Line, r: [4]f32, x: f32, size: f32) -> int {
	s := shape(line_string(l), size)
	px := x - r.x + l.scroll
	best := len(l.text)
	for g in s.glyphs {
		if px < g.x + g.adv / 2 {
			best = g.byte
			break
		}
	}
	return best
}

@(private="file") field_press :: proc(l: ^Line, r: [4]f32, p: [2]f32, clicks: int, size: f32) {
	i := line_index_at(l, r, p.x, size)
	switch clicks {
	case 2: line_select_word(l, i)
	case 3: line_select_all(l)
	case:
		l.cursor = i
		l.anchor = i
	}
}

// ---------------------------------------------------------------- keys

/// a key for the chrome; true when it used it
chrome_key :: proc(e: plat.Key_Event) -> bool {
	if !e.pressed do return true
	if ui.dialog_open {
		if e.sym == plat.KEY_Return || e.sym == plat.KEY_KP_Enter {
			answer_dialog(true)
		} else if e.sym == plat.KEY_Escape {
			answer_dialog(false)
		} else if ui.focus == .Prompt {
			line_key(&ui.prompt, e)
		}
		chrome_push()
		return true
	}
	// a menu: the arrows move, Enter chooses, Escape closes
	if ui.panel != .None && ui.focus != .Name {
		n := len(ui.rows)
		switch e.sym {
		case plat.KEY_Down: if n > 0 do ui.sel = (ui.sel + 1) % n
		case plat.KEY_Up: if n > 0 do ui.sel = (ui.sel - 1 + n) % n
		case plat.KEY_Return, plat.KEY_KP_Enter: if ui.sel >= 0 && ui.sel < n do act(ui.rows[ui.sel])
		case plat.KEY_Escape: close_panel()
		case: if ui.focus == .None do return true
		}
		chrome_push()
		if ui.focus == .None do return true
	}
	switch ui.focus {
	case .Address:
		n := len(ui.suggestions)
		switch e.sym {
		case plat.KEY_Down:
			if n > 0 do ui.suggest_sel = (ui.suggest_sel + 1) % n
			chrome_push()
			return true
		case plat.KEY_Up:
			if n > 0 do ui.suggest_sel = (ui.suggest_sel - 1 + n) % n
			chrome_push()
			return true
		}
		switch line_key(&ui.address, e) {
		case .Enter:
			text := line_string(&ui.address)
			if ui.suggest_sel >= 0 && ui.suggest_sel < n do text = ui.suggestions[ui.suggest_sel].url
			if len(strings.trim_space(text)) > 0 {
				u := strings.clone(text, context.temp_allocator)
				chrome_set_focus(false)
				browser_go(u)
			}
		case .Escape:
			if n > 0 { clear_suggestions() } else { chrome_set_focus(false) }
		case .Changed:
			ui.suggest_sel = -1
			suggest(line_string(&ui.address))
		case .Moved, .Ignored:
		}
	case .Find:
		switch line_key(&ui.find, e) {
		case .Enter: find(.Shift in e.mods ? "prev" : "next")
		case .Escape: close_find()
		case .Changed: find("")
		case .Moved, .Ignored:
		}
	case .Name:
		switch line_key(&ui.name, e) {
		case .Enter: act({op = .Add_Container})
		case .Escape: close_panel()
		case .Changed, .Moved, .Ignored:
		}
	case .Prompt, .None:
	}
	ui.address.blink = 0
	chrome_push()
	return true
}

// ---------------------------------------------------------------- drawing helpers

@(private="file") now_s :: proc() -> f64 { return f64(time.tick_now()._nsec) / 1e9 }

/// eases a value towards its target; true while it moves
@(private="file") ease :: proc(v: ^f32, target: f32, dt: f32, speed: f32 = 16) -> bool {
	d := target - v^
	if abs(d) < 0.002 {
		v^ = target
		return false
	}
	v^ += d * min(1, dt * speed)
	return true
}

@(private="file") hover_of :: proc(i: Id, dt: f32) -> f32 {
	h := ui.hover[i]
	if ease(&h, ui.hot == i ? 1 : 0, dt, 18) do ui.animating = true
	ui.hover[i] = h
	return h
}

/// glass, faded in by amount (a hovered button's glass comes and goes)
@(private="file") glass_amount :: proc(g: Glass, a: f32) -> Glass {
	x := g
	x.tint.a *= a
	x.rim_light *= a
	x.shadow *= a
	x.bend *= a
	return x
}

@(private="file") baseline :: proc(y, h, size: f32) -> f32 {
	asc, desc := text_metrics(size)
	return y + (h + asc - desc) / 2
}

@(private="file") fill :: proc(r: [4]f32, radius: f32, c: [4]f32) {
	draw_fill(r.x, r.y, r.z, r.w, radius, c)
}

/// a round button with an icon: its glass shows while hovered
@(private="file") button :: proc(k: Wid, r: [4]f32, ic: Icon, a: Action, dt: f32, enabled := true, color := INK, n := 0) {
	i := id(k, n)
	hv := enabled ? hover_of(i, dt) : 0
	if hv > 0.01 do draw_glass(r.x, r.y, r.z, r.w, glass_amount(glass_style({r = r.w / 2, kind = 3}), hv))
	c := color
	if !enabled do c.a *= 0.32
	s: f32 = 19
	draw_icon(ic, r.x + (r.z - s) / 2, r.y + (r.w - s) / 2, s, c)
	if enabled do hit(i, r, a)
}

// ---------------------------------------------------------------- the frame

/// draws the chrome over the scene (after the page; before nothing)
chrome_draw :: proc(W, H: f32) {
	for s in ui.frame_strings do delete(s)
	clear(&ui.frame_strings)
	clear(&ui.next_hits)
	now := time.tick_now()
	dt: f32 = 1.0 / 60
	if ui.last_frame._nsec != 0 do dt = clamp(f32(time.duration_seconds(time.tick_diff(ui.last_frame, now))), 0.001, 0.1)
	ui.last_frame = now
	if ui_test_dt > 0 do dt = ui_test_dt
	ui.animating = false

	if !(b.page_fullscreen || b.fullscreen) {
		draw_strip(W, dt)
		draw_bar(W, dt)
	}
	draw_find(dt)
	draw_status()
	draw_toasts(W, H, dt)
	if ui.focus == .Address && len(ui.suggestions) > 0 do draw_suggestions(dt)
	if ui.panel != .None do draw_panel(W, H, dt)
	if ui.dialog_open do draw_dialog(W, H, dt)

	ui.hits, ui.next_hits = ui.next_hits, ui.hits
	if ui.focus != .None do ui.animating = true // the cursor blinks
	if ui.animating do after(16, proc(_: rawptr) { plat.invalidate(&b.win) }, nil)
}

// ---------------------------------------------------------------- the tab strip

@(private="file") draw_strip :: proc(W: f32, dt: f32) {
	own := !b.win.server_frame
	right := W - 8 - (own ? 3 * 34 : 0)
	x0: f32 = 10
	avail := right - x0 - 40 - 60
	n := max(1, len(b.tabs))
	tw := clamp(avail / f32(n), 52, 220)
	x := x0
	for t in b.tabs {
		if t.id not_in ui.tab_x {
			ui.tab_x[t.id] = x
			ui.tab_w[t.id] = 0
		}
		tx, tww := ui.tab_x[t.id], ui.tab_w[t.id]
		if ease(&tx, x, dt, 14) do ui.animating = true
		if ease(&tww, tw, dt, 14) do ui.animating = true
		ui.tab_x[t.id], ui.tab_w[t.id] = tx, tww
		x += tw + 2
	}
	// what closed lets its place go
	for k in ui.tab_x {
		found := false
		for t in b.tabs do if t.id == k do found = true
		if !found {
			delete_key(&ui.tab_x, k)
			delete_key(&ui.tab_w, k)
		}
	}
	dragged: ^Tab
	for t in b.tabs {
		if ui.dragging && t.id == ui.drag_id {
			dragged = t
			continue
		}
		draw_tab(t, ui.tab_x[t.id], ui.tab_w[t.id], dt)
	}
	if dragged != nil do draw_tab(dragged, ui.tab_x[dragged.id] + ui.drag_dx, ui.tab_w[dragged.id], dt)
	// the new-tab button, then the empty strip that moves the window
	px := min(x, right - 40)
	button(.Plus, {px + 2, 9, 32, 32}, .Plus, {op = .New_Tab}, dt)
	hit(id(.Drag), {px + 38, 0, right - px - 38, 46})
	if own {
		ic := [3]Icon{.Min, b.win.maximized ? .Restore : .Max, .Close}
		ops := [3]Op{.Minimize, .Maximize, .Close_Window}
		ks := [3]Wid{.Frame_Min, .Frame_Max, .Frame_Close}
		for i in 0 ..< 3 do button(ks[i], {right + 4 + f32(i) * 34, 10, 30, 30}, ic[i], {op = ops[i]}, dt)
	}
}

@(private="file") draw_tab :: proc(t: ^Tab, x, w: f32, dt: f32) {
	if w < 8 do return
	r := [4]f32{x, 9, w, 32}
	i := id(.Tab, t.id)
	cur := t == b.current
	hv := hover_of(i, dt)
	if cur {
		draw_glass(r.x, r.y, r.z, r.w, glass_style({r = 16, kind = 2}))
	} else if hv > 0.01 {
		draw_glass(r.x, r.y, r.z, r.w, glass_amount(glass_style({r = 16, kind = 3}), hv))
	}
	if t.sandboxed do draw_fill(r.x + 10, r.y + r.w - 3, r.z - 20, 2, 1, WARN)
	k, has := container_get(t.container)
	if has do draw_fill(r.x + 6, r.y + 6, 6, 6, 3, parse_color(k.color))
	// the site's icon, or what stands for it
	ix := r.x + 11
	iy := r.y + 8
	switch {
	case t.loading: draw_spinner(ix + 8, iy + 8, 6)
	case t.sandboxed: draw_icon(.Warn, ix, iy, 16, WARN)
	case tab_is_private(t): draw_icon(.Mask, ix, iy, 16, INK)
	case is_ai_mode(t.url): draw_icon(.Sparkle, ix, iy, 16, ACCENT)
	case len(t.favicon_px) > 0:
		if t.favicon_dirty {
			texture_upload(&t.favicon_tex, raw_data(t.favicon_px), t.favicon_w, t.favicon_h, t.favicon_stride)
			t.favicon_dirty = false
		}
		draw_texture(t.favicon_tex, ix, iy, 16, 16, 3)
	case: draw_icon(.Globe, ix, iy, 16, DIM)
	}
	title := t.title
	if len(title) == 0 do title = is_ai_mode(t.url) ? "Google AI Mode" : display_url(t.url, context.temp_allocator)
	if len(title) == 0 do title = "New Tab"
	show_close := cur || hv > 0.3
	tmax := r.z - 8 - 27 - (show_close ? 24 : 8)
	if tmax > 8 do draw_text(title, r.x + 35, baseline(r.y, r.w, 13), 13, cur ? INK : DIM, .Semibold, tmax)
	hit(i, r, {op = .Select_Tab, n = t.id})
	if show_close && r.z > 80 {
		cr := [4]f32{r.x + r.z - 26, r.y + 6, 20, 20}
		ci := id(.Tab_Close, t.id)
		ch := hover_of(ci, dt)
		if ch > 0.01 do draw_fill(cr.x, cr.y, cr.z, cr.w, 10, {FAINT.r, FAINT.g, FAINT.b, FAINT.a * ch})
		draw_icon(.Close, cr.x + 3, cr.y + 3, 14, {INK.r, INK.g, INK.b, 0.7})
		hit(ci, cr, {op = .Close_Tab, n = t.id})
	}
}

@(private="file") draw_spinner :: proc(cx, cy, rad: f32) {
	// a ring with a bright arc turning
	a := f32(math.mod(now_s() * 5, 2 * math.PI))
	draw_fill(cx - rad, cy - rad, rad * 2, rad * 2, rad, FAINT)
	for k in 0 ..< 6 {
		ang := a + f32(k) * 0.22
		px := cx + math.cos(ang) * (rad - 1.2)
		py := cy + math.sin(ang) * (rad - 1.2)
		c := ACCENT
		c.a = 1 - f32(k) / 6
		draw_fill(px - 1.4, py - 1.4, 2.8, 2.8, 1.4, c)
	}
	ui.animating = true
}

@(private="file") parse_color :: proc(hex: string) -> [4]f32 {
	if len(hex) != 7 || hex[0] != '#' do return DIM
	v :: proc(c: u8) -> f32 {
		switch c {
		case '0' ..= '9': return f32(c - '0')
		case 'a' ..= 'f': return f32(c - 'a' + 10)
		case 'A' ..= 'F': return f32(c - 'A' + 10)
		}
		return 0
	}
	return {(v(hex[1]) * 16 + v(hex[2])) / 255, (v(hex[3]) * 16 + v(hex[4])) / 255, (v(hex[5]) * 16 + v(hex[6])) / 255, 1}
}

// ---------------------------------------------------------------- the bar

@(private="file") draw_bar :: proc(W: f32, dt: f32) {
	t := b.current
	y: f32 = 48
	h: f32 = 44
	// back, forward, reload
	nav := [4]f32{10, y, 116, h}
	draw_glass(nav.x, nav.y, nav.z, nav.w, glass_style({r = 22, kind = 0}))
	hit(id(.Panel, 100), nav)
	loading := t != nil && t.loading
	button(.Back, {15, y + 5, 34, 34}, .Back, {op = .Back}, dt, t != nil && t.can_back)
	button(.Forward, {51, y + 5, 34, 34}, .Forward, {op = .Forward}, dt, t != nil && t.can_forward)
	button(.Reload, {87, y + 5, 34, 34}, loading ? .Stop : .Reload, {op = loading ? .Stop : .Reload}, dt)
	// the actions, from the right
	d_shown := downloads_active() > 0 || b.unseen_downloads > 0 || ui.panel == .Downloads
	nb := d_shown ? 3 : 2
	aw := f32(10 + nb * 34 + (nb - 1) * 2)
	act_r := [4]f32{W - 10 - aw, y, aw, h}
	draw_glass(act_r.x, act_r.y, act_r.z, act_r.w, glass_style({r = 22, kind = 0}))
	hit(id(.Panel, 101), act_r)
	bx := act_r.x + 5
	s := settings()
	host := ""
	if t != nil do host, _ = host_of(t.url, context.temp_allocator)
	on_here := s.shields && shields_on_for(host)
	button(.Shield, {bx, y + 5, 34, 34}, !s.shields ? .Shield_Off : on_here ? .Shield_On : .Shield, {op = .Toggle_Panel, n = int(Panel.Shields)}, dt, color = on_here ? INK : DIM)
	bx += 36
	if d_shown {
		button(.Downloads, {bx, y + 5, 34, 34}, .Download, {op = .Toggle_Panel, n = int(Panel.Downloads)}, dt)
		if b.unseen_downloads > 0 && downloads_active() == 0 {
			label := fmt.tprint(b.unseen_downloads)
			bw := max(16, text_width(label, 10.5, .Heavy) + 8)
			draw_fill(bx + 34 - bw + 1, y + 6, bw, 16, 8, ACCENT)
			draw_text(label, bx + 34 - bw + 1 + (bw - text_width(label, 10.5, .Heavy)) / 2, y + 18, 10.5, WHITE, .Heavy)
		}
		bx += 36
	}
	button(.Containers, {bx, y + 5, 34, 34}, .Layers, {op = .Toggle_Panel, n = int(Panel.Containers)}, dt)
	// the address between them
	ar := [4]f32{136, y, act_r.x - 10 - 136, h}
	ui.address_rect = ar
	draw_glass(ar.x, ar.y, ar.z, ar.w, glass_style({r = 22, kind = 0}))
	draw_address(ar, dt)
	// the page loading: a line along the address's bottom
	if loading {
		pw := (ar.z - 36) * f32(max(0.08, t.progress))
		draw_fill(ar.x + 18, ar.y + ar.w - 5.5, pw, 2.5, 1.25, ACCENT)
		ui.animating = true
	}
}

@(private="file") draw_address :: proc(r: [4]f32, dt: f32) {
	t := b.current
	x := r.x + 14
	// the chip: the sandbox, a private tab, a container, or AI Mode
	if t != nil && ui.focus != .Address {
		k, has := container_get(t.container)
		switch {
		case t.sandboxed:
			draw_icon(.Warn, x, r.y + 14, 16, WARN)
			x += 20 + draw_text("Sandbox", x + 20, baseline(r.y, r.w, 12.5), 12.5, WARN, .Bold) + 10
		case tab_is_private(t):
			draw_icon(.Mask, x, r.y + 14, 16, INK)
			x += 20 + draw_text("Private", x + 20, baseline(r.y, r.w, 12.5), 12.5, DIM, .Bold) + 10
		case has:
			c := parse_color(k.color)
			draw_icon(container_icon(k.icon), x, r.y + 14, 16, c)
			x += 20 + draw_text(k.name, x + 20, baseline(r.y, r.w, 12.5), 12.5, c, .Bold, 120) + 10
		case is_ai_mode(t.url):
			draw_icon(.Sparkle, x, r.y + 14, 16, ACCENT)
			x += 26
		}
	}
	tr := [4]f32{x, r.y, r.x + r.z - 14 - x, r.w}
	if ui.focus == .Address {
		draw_field(&ui.address, tr, 14.5, "Ask Google AI Mode or type an address", dt)
	} else {
		text := ""
		if t != nil {
			q, ai := ai_query(t.url, context.temp_allocator)
			text = ai ? q : (is_ai_mode(t.url) ? "" : editable_url(t.url, context.temp_allocator))
		}
		if len(text) == 0 {
			draw_text("Ask Google AI Mode or type an address", tr.x, baseline(tr.y, tr.w, 14.5), 14.5, DIM, max_w = tr.z)
		} else {
			draw_text(text, tr.x, baseline(tr.y, tr.w, 14.5), 14.5, INK, max_w = tr.z)
		}
	}
	hit(id(.Address), {r.x, r.y, r.z, r.w}, {}, .Text)
}

/// an editable line: its text, selection and cursor, scrolled to keep the
/// cursor in view
@(private="file") draw_field :: proc(l: ^Line, r: [4]f32, size: f32, placeholder: string, dt: f32) {
	s := shape(line_string(l), size)
	pos :: proc(s: Shaped, i: int, text_len: int) -> f32 {
		if i >= text_len do return s.width
		for g in s.glyphs do if g.byte >= i do return g.x
		return s.width
	}
	cx := pos(s, l.cursor, len(l.text))
	// keep the cursor in view
	if cx - l.scroll > r.z - 4 do l.scroll = cx - r.z + 4
	if cx - l.scroll < 0 do l.scroll = cx
	if s.width < r.z do l.scroll = 0
	by := baseline(r.y, r.w, size)
	asc, desc := text_metrics(size)
	if line_has_selection(l) {
		lo, hi := line_selection(l)
		a := pos(s, lo, len(l.text)) - l.scroll
		z := pos(s, hi, len(l.text)) - l.scroll
		a, z = max(a, 0), min(z, r.z)
		if z > a do draw_fill(r.x + a, by - asc, z - a, asc + desc, 3, {ACCENT.r, ACCENT.g, ACCENT.b, 0.24})
	}
	if len(l.text) == 0 {
		draw_text(placeholder, r.x, by, size, DIM, max_w = r.z)
	} else {
		// the text, moved left by the scroll, clipped to the field
		clip_push(r)
		draw_shaped(s, r.x - l.scroll, by, INK)
		clip_pop()
	}
	// the cursor: steady while typing, then blinking
	if !line_has_selection(l) && math.mod(now_s(), 1.0) < 0.6 {
		draw_fill(r.x + cx - l.scroll - 0.75, by - asc + 1, 1.5, asc + desc - 2, 0.75, ACCENT)
	}
}

// ---------------------------------------------------------------- find

@(private="file") draw_find :: proc(dt: f32) {
	if !ui.find_open do return
	c := b.card
	w: f32 = 380
	r := [4]f32{c.x + c.z - w - 12, c.y + 12, w, 44}
	draw_glass(r.x, r.y, r.z, r.w, glass_style({r = 22, kind = 0}))
	hit(id(.Panel, 102), r)
	draw_icon(.Search, r.x + 14, r.y + 13, 18, DIM)
	count := ""
	switch {
	case ui.find_count == 0: count = "No matches"
	case ui.find_count == 1: count = "1 match"
	case ui.find_count > 1: count = fmt.tprintf("%d matches", ui.find_count)
	}
	cw := len(count) > 0 ? text_width(count, 12.5) : 0
	fr := [4]f32{r.x + 40, r.y, r.z - 40 - 3 * 34 - 14 - cw - 8, r.w}
	if ui.focus == .Find {
		draw_field(&ui.find, fr, 14, "Find in page", dt)
	} else {
		text := line_string(&ui.find)
		draw_text(len(text) > 0 ? text : "Find in page", fr.x, baseline(fr.y, fr.w, 14), 14, len(text) > 0 ? INK : DIM, max_w = fr.z)
	}
	hit(id(.Find_Field), fr, {}, .Text)
	if cw > 0 do draw_text(count, fr.x + fr.z + 4, baseline(r.y, r.w, 12.5), 12.5, DIM)
	bx := r.x + r.z - 5 - 3 * 34
	button(.Find_Prev, {bx, r.y + 5, 34, 34}, .Up, {op = .Find_Prev}, dt)
	button(.Find_Next, {bx + 34, r.y + 5, 34, 34}, .Down, {op = .Find_Next}, dt)
	button(.Find_Close, {bx + 68, r.y + 5, 34, 34}, .Close, {op = .Find_Close}, dt)
}

// ---------------------------------------------------------------- notes

@(private="file") draw_status :: proc() {
	if len(ui.status) == 0 do return
	c := b.card
	w := min(text_width(ui.status, 12.5) + 24, c.z * 0.5)
	r := [4]f32{c.x + 10, c.y + c.w - 10 - 28, w, 28}
	draw_glass(r.x, r.y, r.z, r.w, glass_style({r = 12, kind = 1}))
	draw_text(ui.status, r.x + 12, baseline(r.y, r.w, 12.5), 12.5, DIM, max_w = r.z - 24)
}

@(private="file") draw_toasts :: proc(W, H: f32, dt: f32) {
	c := b.card
	y := c.y + c.w - 22
	#reverse for t, i in ui.toasts {
		if ease(&t.show, t.gone ? 0 : 1, dt, 14) do ui.animating = true
		if t.show < 0.01 do continue
		tw := text_width(t.text, 14, .Semibold)
		aw: f32 = len(t.action) > 0 ? text_width(t.action, 13, .Bold) + 28 : 0
		w := min(tw + 36 + (aw > 0 ? aw + 14 : 0), W * 0.7)
		h: f32 = 44
		y -= h
		r := [4]f32{(W - w) / 2, y + (1 - t.show) * 8, w, h}
		g := glass_amount(glass_style({r = 20, kind = 1}), t.show)
		draw_glass(r.x, r.y, r.z, r.w, g)
		ink := INK
		ink.a = t.show
		draw_text(t.text, r.x + 18, baseline(r.y, r.w, 14), 14, ink, .Semibold, r.z - 36 - (aw > 0 ? aw + 14 : 0))
		hit(id(.Toast, i), r)
		if aw > 0 {
			ar := [4]f32{r.x + r.z - aw - 8, r.y + 8, aw, 28}
			fill(ar, 14, {ACCENT.r, ACCENT.g, ACCENT.b, t.show})
			draw_text(t.action, ar.x + 14, baseline(ar.y, ar.w, 13), 13, {1, 1, 1, t.show}, .Bold)
			hit(id(.Toast_Action, i), ar, {op = .Toast_Action, n = int(uintptr(t))})
		}
		y -= 8
	}
}

// ---------------------------------------------------------------- suggestions

@(private="file") draw_suggestions :: proc(dt: f32) {
	a := ui.address_rect
	w := max(a.z, 420)
	n := len(ui.suggestions)
	r := [4]f32{a.x, a.y + a.w + 8, w, f32(n) * 36 + 12}
	draw_glass(r.x, r.y, r.z, r.w, glass_style({r = 18, kind = 1}))
	hit(id(.Panel, 103), r)
	for s, i in ui.suggestions {
		rr := [4]f32{r.x + 6, r.y + 6 + f32(i) * 36, r.z - 12, 36}
		ri := id(.Suggest, i)
		hv := hover_of(ri, dt)
		if i == ui.suggest_sel || hv > 0.01 do fill(rr, 11, {ACCENT.r, ACCENT.g, ACCENT.b, 0.10 * max(hv, i == ui.suggest_sel ? 1 : 0)})
		draw_icon(s.icon, rr.x + 12, rr.y + 9, 18, s.icon == .Sparkle ? ACCENT : INK)
		sw := len(s.sub) > 0 ? min(text_width(s.sub, 12), rr.z * 0.4) : 0
		draw_text(s.title, rr.x + 42, baseline(rr.y, rr.w, 13.5), 13.5, INK, .Semibold, rr.z - 54 - sw - (sw > 0 ? 12 : 0))
		if sw > 0 do draw_text(s.sub, rr.x + rr.z - 12 - sw, baseline(rr.y, rr.w, 12), 12, DIM, max_w = sw)
		hit(ri, rr, {op = .Go, s = keep(s.url)})
	}
}

// ---------------------------------------------------------------- panels and menus

Item_Kind :: enum u8 { Row, Sep, Head, Note, Title, Field, Icons, Buttons, Download, Title_Buttons }

Item :: struct {
	kind:      Item_Kind,
	icon:      Maybe(Icon),
	icon_color: [4]f32,
	text, keys: string,
	act:       Action,
	on, disabled: bool,
	buttons:   [3]Pill,
	n_buttons: int,
	dl:        ^Download,
}

Pill :: struct {
	text:    string,
	act:     Action,
	primary: bool,
}

@(private="file") row :: proc(items: ^[dynamic]Item, icon: Maybe(Icon), text: string, a: Action, keys := "", on := false, disabled := false, color := INK) {
	append(items, Item{kind = .Row, icon = icon, icon_color = color, text = text, act = a, keys = keys, on = on, disabled = disabled})
}

@(private="file") panel_items :: proc() -> (items: [dynamic]Item, width: f32) {
	items = make([dynamic]Item, context.temp_allocator)
	t := b.current
	switch ui.panel {
	case .None:
	case .Shields:
		width = 320
		s := settings()
		append(&items, Item{kind = .Title, text = "Iris Shields"})
		append(&items, Item{kind = .Note, text = "Ads and trackers are stopped inside the engine, before a request leaves the computer. Cookies never go to other sites."})
		host := ""
		if t != nil do host, _ = host_of(t.url, context.temp_allocator)
		site := site_of(host)
		if len(site) > 0 && s.shields {
			on := shields_on_for(host)
			row(&items, on ? .Shield_On : .Shield_Off, fmt.tprintf("%s for %s", on ? "On" : "Off", site), {op = .Shield_Site}, on ? "Turn off" : "Turn on", on = on)
		}
		row(&items, s.shields ? .Shield_On : .Shield_Off, s.shields ? "On everywhere" : "Off everywhere", {op = .Shield_All}, s.shields ? "Turn off" : "Turn on", on = s.shields)
		if s.shields {
			append(&items, Item{kind = .Sep})
			for l in Level do row(&items, l == s.shieldLevel ? Icon.Check : nil, level_title(l), {op = .Level, n = int(l)}, on = l == s.shieldLevel)
			append(&items, Item{kind = .Note, text = level_hint(s.shieldLevel)})
			if !engine_shields_ready() do append(&items, Item{kind = .Note, text = "Getting the block list ready (the first start takes a moment)…"})
		}
	case .Downloads:
		width = 380
		it := Item{kind = .Title_Buttons, text = "Downloads"}
		it.buttons[0] = {text = "Folder", act = {op = .Dl_Folder}}
		it.n_buttons = 1
		for d in downloads do if d.done || d.failed {
			it.buttons[1] = {text = "Clear", act = {op = .Dl_Clear}}
			it.n_buttons = 2
			break
		}
		append(&items, it)
		if len(downloads) == 0 do append(&items, Item{kind = .Note, text = "Nothing downloaded yet"})
		n := 0
		#reverse for d in downloads {
			if n == 12 do break
			append(&items, Item{kind = .Download, dl = d})
			n += 1
		}
	case .Containers:
		width = 270
		append(&items, Item{kind = .Head, text = "New tab in"})
		row(&items, .Globe, "No Container", {op = .New_Tab})
		containers_ensure()
		for k in containers do row(&items, container_icon(k.icon), k.name, {op = .New_Tab_In, s = keep(k.id)}, color = parse_color(k.color))
		row(&items, .Mask, "Private", {op = .New_Tab_In, s = PRIVATE_ID}, color = {0.37, 0.36, 0.9, 1})
		if ui.panel_tab != -1 && t != nil && len(t.url) > 0 {
			append(&items, Item{kind = .Sep}, Item{kind = .Head, text = "Open this page in"})
			if len(t.container) > 0 do row(&items, .Globe, "No Container", {op = .Open_In, n = t.id, s = ""})
			for k in containers do if k.id != t.container do row(&items, container_icon(k.icon), k.name, {op = .Open_In, n = t.id, s = keep(k.id)}, color = parse_color(k.color))
		}
		append(&items, Item{kind = .Sep})
		row(&items, .Plus, "New Container…", {op = .New_Container})
		if len(containers) > 0 do row(&items, .Trash, "Remove a Container…", {op = .Remove_Container_Panel})
	case .New_Container:
		width = 290
		append(&items, Item{kind = .Title, text = "New Container"})
		append(&items, Item{kind = .Note, text = "A container keeps its own cookies, sign-ins and site data, apart from every other."})
		append(&items, Item{kind = .Field, text = "Name"})
		append(&items, Item{kind = .Icons})
		it := Item{kind = .Buttons}
		it.buttons[0] = {text = "Add", act = {op = .Add_Container}, primary = true}
		it.n_buttons = 1
		append(&items, it)
	case .Remove_Container:
		width = 290
		append(&items, Item{kind = .Title, text = "Remove a Container"})
		append(&items, Item{kind = .Note, text = "Its tabs close, and its cookies, sign-ins and site data are deleted."})
		for k in containers do row(&items, container_icon(k.icon), k.name, {op = .Remove_Container, s = keep(k.id)}, color = parse_color(k.color))
	case .Tab_Menu:
		width = 240
		id := ui.panel_tab
		x := tab_by_id(id)
		if x == nil do break
		row(&items, .Reload, "Reload", {op = .Reload_Tab, n = id})
		row(&items, .Copy, "Duplicate", {op = .Duplicate, n = id})
		first := true
		for k in containers do if k.id != x.container {
			if first do append(&items, Item{kind = .Sep})
			first = false
			row(&items, container_icon(k.icon), fmt.tprintf("Open in %s", k.name), {op = .Open_In, n = id, s = keep(k.id)}, color = parse_color(k.color))
		}
		append(&items, Item{kind = .Sep})
		row(&items, .Close, "Close Other Tabs", {op = .Close_Others, n = id})
		row(&items, .Close, "Close Tab", {op = .Close_Tab, n = id}, "Ctrl+W")
	case .Context:
		width = 250
		c := b.context_info
		ct := b.context_tab
		// the sandbox downloads nothing, from the menu either
		saves := ct == nil || !ct.sandboxed
		if len(c.link) > 0 {
			// a link to a file of yours (or another program) from a web
			// page can be copied, not opened or downloaded by Iris
			opens := page_may_open(c.link, ct != nil ? ct.url : "")
			if opens {
				row(&items, .Tab, "Open Link in New Tab", {op = .Ctx_Tab, s = keep(c.link)})
				for k in containers do if ct == nil || k.id != ct.container do row(&items, container_icon(k.icon), fmt.tprintf("Open Link in %s", k.name), {op = .Ctx_In, s = keep(c.link), s2 = keep(k.id)}, color = parse_color(k.color))
			}
			row(&items, .Link, "Copy Link", {op = .Ctx_Copy, s = keep(c.link)})
			if saves && opens do row(&items, .Download, "Download Link", {op = .Ctx_Save, s = keep(c.link)})
		}
		if len(c.image) > 0 {
			if len(items) > 0 do append(&items, Item{kind = .Sep})
			row(&items, .Image, "Open Image in New Tab", {op = .Ctx_Tab, s = keep(c.image)})
			row(&items, .Copy, "Copy Image Address", {op = .Ctx_Copy, s = keep(c.image)})
			if saves do row(&items, .Download, "Save Image", {op = .Ctx_Save, s = keep(c.image)})
		}
		if len(c.media) > 0 && len(c.image) == 0 {
			if len(items) > 0 do append(&items, Item{kind = .Sep})
			row(&items, .Copy, "Copy Video Address", {op = .Ctx_Copy, s = keep(c.media)})
			if saves do row(&items, .Download, "Save Video", {op = .Ctx_Save, s = keep(c.media)})
		}
		if c.editable {
			if len(items) > 0 do append(&items, Item{kind = .Sep})
			row(&items, .Cut, "Cut", {op = .Ctx_Edit, s = EDIT_CUT}, "Ctrl+X")
			row(&items, .Copy, "Copy", {op = .Ctx_Edit, s = EDIT_COPY}, "Ctrl+C")
			row(&items, .Paste, "Paste", {op = .Ctx_Edit, s = EDIT_PASTE}, "Ctrl+V")
			row(&items, .Select_All, "Select All", {op = .Ctx_Edit, s = EDIT_SELECT_ALL}, "Ctrl+A")
		} else if c.selection {
			if len(items) > 0 do append(&items, Item{kind = .Sep})
			row(&items, .Copy, "Copy", {op = .Ctx_Edit, s = EDIT_COPY}, "Ctrl+C")
			row(&items, .Sparkle, "Ask Google AI Mode", {op = .Ctx_Ask_AI}, color = ACCENT)
		}
		if len(items) == 0 {
			row(&items, .Back, "Back", {op = .Ctx_Back}, "Alt+←", disabled = ct == nil || !ct.can_back)
			row(&items, .Forward, "Forward", {op = .Ctx_Forward}, "Alt+→", disabled = ct == nil || !ct.can_forward)
			row(&items, .Reload, "Reload", {op = .Ctx_Reload}, "Ctrl+R")
			row(&items, .Select_All, "Select All", {op = .Ctx_Edit, s = EDIT_SELECT_ALL}, "Ctrl+A")
		}
	case .Option:
		width = max(ui.panel_anchor.z, 200)
		for o, i in ui.options {
			if o.group {
				append(&items, Item{kind = .Head, text = o.label})
				continue
			}
			row(&items, o.selected ? Icon.Check : nil, o.label, {op = .Option, n = i}, on = o.selected, disabled = !o.enabled)
		}
	}
	return
}

@(private="file") item_height :: proc(it: Item, w: f32) -> f32 {
	switch it.kind {
	case .Row: return 36
	case .Sep: return 11
	case .Head: return 28
	case .Note: return f32(len(wrap_text(it.text, 12.5, w - 24))) * 17 + 12
	case .Title: return 32
	case .Title_Buttons: return 40
	case .Field: return 46
	case .Icons: return 2 * 40 + 8
	case .Buttons: return 46
	case .Download: return 62
	}
	return 0
}

@(private="file") draw_panel :: proc(W, H: f32, dt: f32) {
	items, width := panel_items()
	if len(items) == 0 {
		close_panel()
		return
	}
	pad: f32 = 6
	content: f32 = pad * 2
	for it in items do content += item_height(it, width - 2 * pad)
	h := min(content, H - 120)
	a := ui.panel_anchor
	x, y: f32
	if a.w > 0 {
		// under the button it opened from
		x = ui.panel_right ? a.x + a.z - width : a.x
		y = a.y + a.w + 8
	} else {
		x, y = a.x, a.y
	}
	x = clamp(x, 8, W - width - 8)
	if y + h > H - 8 do y = max(8, a.w > 0 ? H - h - 8 : a.y - h)
	r := [4]f32{x, y, width, h}
	ui.panel_rect = r
	ui.panel_scroll = clamp(ui.panel_scroll, 0, max(0, content - h))
	if ease(&ui.panel_show, 1, dt, 18) do ui.animating = true
	sh := ui.panel_show
	draw_glass(r.x, r.y + (1 - sh) * -4, r.z, r.w, glass_amount(glass_style({r = 18, kind = 1}), sh))
	hit(id(.Panel), r)
	clip_push(r)
	defer clip_pop()
	cy := r.y + pad - ui.panel_scroll
	clear(&ui.rows)
	ri := 0
	for it in items {
		ih := item_height(it, width - 2 * pad)
		ir := [4]f32{r.x + pad, cy, r.z - 2 * pad, ih}
		defer cy += ih
		if cy + ih < r.y || cy > r.y + r.w do if it.kind == .Row {
			append(&ui.rows, it.act)
			ri += 1
			continue
		}
		switch it.kind {
		case .Row:
			i := id(.Row, ri)
			hv := it.disabled ? 0 : hover_of(i, dt)
			if (ri == ui.sel || hv > 0.01) && !it.disabled do fill(ir, 11, {ACCENT.r, ACCENT.g, ACCENT.b, 0.10 * max(hv, ri == ui.sel ? 1 : 0)})
			c := it.on ? ACCENT : INK
			if it.disabled do c.a = 0.4
			ic := it.icon_color
			if it.on do ic = ACCENT
			if it.disabled do ic.a = 0.4
			if icn, ok := it.icon.?; ok do draw_icon(icn, ir.x + 12, ir.y + 9.5, 17, ic)
			kw := len(it.keys) > 0 ? text_width(it.keys, 11.5, .Semibold) : 0
			draw_text(it.text, ir.x + 40, baseline(ir.y, ir.w, 13.5), 13.5, c, .Semibold, ir.z - 52 - (kw > 0 ? kw + 10 : 0))
			if kw > 0 do draw_text(it.keys, ir.x + ir.z - 12 - kw, baseline(ir.y, ir.w, 11.5), 11.5, DIM, .Semibold)
			if !it.disabled do hit(i, ir, it.act)
			append(&ui.rows, it.act)
			ri += 1
		case .Sep:
			draw_fill(ir.x + 10, ir.y + 5, ir.z - 20, 1, 0.5, FAINT)
		case .Head:
			draw_text(it.text, ir.x + 12, ir.y + 20, 11.5, DIM, .Heavy)
		case .Note:
			ly := ir.y + 16
			for l in wrap_text(it.text, 12.5, ir.z - 24) {
				draw_text(l, ir.x + 12, ly, 12.5, DIM)
				ly += 17
			}
		case .Title:
			draw_text(it.text, ir.x + 12, ir.y + 24, 15, INK, .Heavy)
		case .Title_Buttons:
			draw_text(it.text, ir.x + 12, baseline(ir.y, ir.w, 15), 15, INK, .Heavy)
			bx := ir.x + ir.z
			for k := it.n_buttons - 1; k >= 0; k -= 1 {
				p := it.buttons[k]
				pw := text_width(p.text, 13, .Bold) + 28
				bx -= pw + 6
				pill(p, {bx, ir.y + 6, pw, 28}, k, dt)
			}
		case .Field:
			fr := [4]f32{ir.x + 2, ir.y + 5, ir.z - 4, 36}
			fill(fr, 11, {1, 1, 1, 0.55})
			inner := [4]f32{fr.x + 12, fr.y, fr.z - 24, fr.w}
			if ui.focus == .Name {
				draw_field(&ui.name, inner, 14, it.text, dt)
			} else {
				text := line_string(&ui.name)
				draw_text(len(text) > 0 ? text : it.text, inner.x, baseline(inner.y, inner.w, 14), 14, len(text) > 0 ? INK : DIM, max_w = inner.z)
			}
			hit(id(.Name), inner, {}, .Text)
		case .Icons:
			names := CONTAINER_ICONS
			for name, k in names {
				cx := ir.x + 8 + f32(k % 6) * 40
				cyy := ir.y + 4 + f32(k / 6) * 40
				cr := [4]f32{cx, cyy, 36, 36}
				sel := name == ui.new_icon
				ci := id(.Icon_Choice, k)
				hv := hover_of(ci, dt)
				if sel {
					fill(cr, 10, {ACCENT.r, ACCENT.g, ACCENT.b, 0.16})
				} else if hv > 0.01 {
					fill(cr, 10, {FAINT.r, FAINT.g, FAINT.b, FAINT.a * hv})
				}
				draw_icon(container_icon(name), cx + 9, cyy + 9, 18, sel ? ACCENT : INK)
				hit(ci, cr, {op = .Pick_Icon, n = k})
			}
		case .Buttons:
			bx := ir.x + ir.z
			for k := it.n_buttons - 1; k >= 0; k -= 1 {
				p := it.buttons[k]
				pw := text_width(p.text, 13, .Bold) + 32
				bx -= pw + 6
				pill(p, {bx, ir.y + 9, pw, 30}, k, dt)
			}
		case .Download:
			draw_download(it.dl, ir, dt)
		}
	}
	if ui.sel >= len(ui.rows) do ui.sel = -1
}

@(private="file") pill :: proc(p: Pill, r: [4]f32, k: int, dt: f32) {
	i := id(.Pill, k)
	hv := hover_of(i, dt)
	if p.primary {
		fill(r, r.w / 2, ACCENT)
	} else {
		fill(r, r.w / 2, {INK.r, INK.g, INK.b, 0.07 + 0.05 * hv})
	}
	tw := text_width(p.text, 13, .Bold)
	draw_text(p.text, r.x + (r.z - tw) / 2, baseline(r.y, r.w, 13), 13, p.primary ? WHITE : INK, .Bold)
	hit(i, r, p.act)
}

@(private="file") draw_download :: proc(d: ^Download, r: [4]f32, dt: f32) {
	i := id(.Download_Row, d.id)
	hv := hover_of(i, dt)
	if hv > 0.01 && d.done do fill(r, 11, {ACCENT.r, ACCENT.g, ACCENT.b, 0.10 * hv})
	if d.done do hit(i, r, {op = .Dl_Open, n = d.id})
	draw_icon(d.failed ? .Warn : .Download, r.x + 12, r.y + 10, 17, d.failed ? WARN : INK)
	name := len(d.name) > 0 ? d.name : "Starting…"
	draw_text(name, r.x + 40, r.y + 24, 13.5, INK, .Semibold, r.z - 52 - 30)
	if !d.done && !d.failed {
		draw_fill(r.x + 40, r.y + 33, r.z - 52 - 30, 4, 2, FAINT)
		draw_fill(r.x + 40, r.y + 33, (r.z - 52 - 30) * f32(clamp(d.progress, 0, 1)), 4, 2, ACCENT)
	}
	draw_text(download_status(d), r.x + 40, r.y + 53, 12, DIM, max_w = r.z - 52)
	ar := [4]f32{r.x + r.z - 34, r.y + 6, 28, 28}
	if !d.done && !d.failed {
		button(.Download_Act, ar, .Stop, {op = .Dl_Cancel, n = d.id}, dt, n = d.id)
	} else if d.done {
		button(.Download_Act, ar, .Folder, {op = .Dl_Show, n = d.id}, dt, n = d.id)
	}
}

// ---------------------------------------------------------------- dialogs

@(private="file") draw_dialog :: proc(W, H: f32, dt: f32) {
	draw_fill(0, 0, W, H, 0, {0.14, 0.11, 0.25, 0.18})
	hit(id(.Scrim), {0, 0, W, H})
	w := min(440, W * 0.9)
	lines := wrap_text(ui.dialog_message, 13.5, w - 44)
	shown := min(len(lines), 14)
	prompt := ui.dialog_kind == WEBKIT_SCRIPT_DIALOG_PROMPT
	h := 52 + f32(shown) * 19 + (prompt ? 48 : 0) + 58
	r := [4]f32{(W - w) / 2, H * 0.34 - h / 2, w, h}
	draw_glass(r.x, r.y, r.z, r.w, glass_style({r = 20, kind = 1}))
	hit(id(.Dialog), r)
	draw_text(fmt.tprintf("%s says", ui.dialog_title), r.x + 22, r.y + 34, 15, INK, .Heavy, r.z - 44)
	ly := r.y + 62
	for l in lines[:shown] {
		draw_text(l, r.x + 22, ly, 13.5, INK)
		ly += 19
	}
	if prompt {
		fr := [4]f32{r.x + 18, ly - 6, r.z - 36, 36}
		fill(fr, 11, {1, 1, 1, 0.6})
		inner := [4]f32{fr.x + 12, fr.y, fr.z - 24, fr.w}
		draw_field(&ui.prompt, inner, 14, "", dt)
		hit(id(.Prompt), inner, {}, .Text)
		ly += 48
	}
	by := r.y + r.w - 48
	ok_text := ui.dialog_kind == WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM ? "Leave" : "OK"
	ow := text_width(ok_text, 13, .Bold) + 36
	bx := r.x + r.z - 18 - ow
	pill({text = ok_text, act = {op = .Dialog_Ok}, primary = true}, {bx, by, ow, 32}, 10, dt)
	if ui.dialog_kind != WEBKIT_SCRIPT_DIALOG_ALERT {
		c_text := ui.dialog_kind == WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM ? "Stay" : "Cancel"
		cw := text_width(c_text, 13, .Bold) + 36
		pill({text = c_text, act = {op = .Dialog_Cancel}}, {bx - cw - 8, by, cw, 32}, 11, dt)
	}
}


