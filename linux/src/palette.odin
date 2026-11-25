// The command palette (Ctrl+K), as in Arc and Helium: one field, and as you
// type, your open tabs (in every workspace), Iris's commands and pages from
// your history, by a fuzzy match. Enter does the first; the arrows move.
// With nothing typed it lists your tabs and the commands, never your most
// visited sites. Iris's commands (Command) are also what the menus, the tab
// strip and the reader's button send.
package iris

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import plat "../plat"

Command :: enum u8 {
	None, New_Tab, New_Private, Reopen, Close_Tab, Duplicate, Pin, Mute, Reader, Split, Split_With,
	Compact, Peek_Link, Peek_Promote, Peek_Close, Report, Copy_Link, Find, Downloads, Address,
	Spaces, Space, Space_New, Space_Add, Space_Remove, Space_Move, Https, Clear_Exit, Shields_Site,
	Zoom_In, Zoom_Out, Zoom_Reset, Full_Screen, Next_Space, Prev_Space,
}

Palette_Item :: struct {
	icon:  Icon,
	title: string,
	sub:   string,
	keys:  string,
	act:   Action,
	score: int,
}

/// how well a query matches text, letter by letter in order (0: not at
/// all): the start of the text and of its words, and letters together,
/// count most
fuzzy_score :: proc(query, text: string) -> int {
	if len(query) == 0 do return 1
	q := strings.to_lower(query, context.temp_allocator)
	s := strings.to_lower(text, context.temp_allocator)
	if strings.has_prefix(s, q) do return 1000 - min(len(s), 500)
	if i := strings.index(s, q); i >= 0 {
		word := i == 0 || s[i - 1] == ' ' || s[i - 1] == '.' || s[i - 1] == '/' || s[i - 1] == '-'
		return (word ? 700 : 500) - min(i, 200)
	}
	score, at, run := 0, 0, 0
	for c in transmute([]u8)q {
		if c == ' ' do continue
		found := false
		for at < len(s) {
			x := s[at]
			at += 1
			if x == c {
				start := at == 1 || s[at - 2] == ' ' || s[at - 2] == '.' || s[at - 2] == '/'
				run += 1
				score += 10 + run * 5 + (start ? 15 : 0)
				found = true
				break
			}
			run = 0
		}
		if !found do return 0
	}
	return score
}

palette_open :: proc() {
	close_panel()
	clear_suggestions()
	ui.palette_open = true
	ui.palette_t0 = ui.clock
	line_set(&ui.palette, "")
	focus_field(.Palette)
	palette_refresh()
}

palette_close :: proc() {
	if !ui.palette_open do return
	ui.palette_open = false
	palette_free_items()
	if ui.focus == .Palette do chrome_set_focus(false)
	chrome_push()
}

@(private="file") palette_free_items :: proc() {
	for it in ui.palette_items {
		delete(it.title)
		delete(it.sub)
		delete(it.act.s)
	}
	clear(&ui.palette_items)
}

@(private="file") cmd :: proc(c: Command, n2 := 0, s := "") -> Action { return {op = .Command, n = int(c), n2 = n2, s = s} }

/// what the palette lists for what was typed, best first
palette_refresh :: proc() {
	palette_free_items()
	q := strings.trim_space(line_string(&ui.palette))
	items := make([dynamic]Palette_Item, context.temp_allocator)
	add :: proc(items: ^[dynamic]Palette_Item, q: string, icon: Icon, title, sub, keys: string, a: Action, bonus := 0) {
		sc := fuzzy_score(q, title)
		if sc == 0 && len(sub) > 0 do sc = fuzzy_score(q, sub) / 2
		if sc == 0 do return
		append(items, Palette_Item{icon, title, sub, keys, a, sc + bonus})
	}
	// what was typed, opened or asked
	if len(q) > 0 {
		u := resolve(q, context.temp_allocator)
		if is_url_like(q) {
			append(&items, Palette_Item{.Open, display_url(u, context.temp_allocator), "Open", "Enter", {op = .Go, s = u}, 5000})
		} else {
			append(&items, Palette_Item{.Search, q, "Search Google", "", {op = .Go, s = search_url(q, context.temp_allocator)}, 1})
		}
	}
	// the tabs, in every workspace
	for t in b.tabs {
		title := len(t.title) > 0 ? t.title : (tab_is_start(t) ? "New Tab" : display_url(t.url, context.temp_allocator))
		sub := display_url(t.url, context.temp_allocator)
		if t.space != b.space do sub = fmt.tprintf("%s · %s", space_name(t.space), sub)
		add(&items, q, t.pinned ? .Pin : .Tab, title, sub, t == b.current ? "This tab" : "", {op = .Select_Tab, n = t.id}, len(q) == 0 ? 100 : 60)
	}
	// the commands
	t := b.current
	page := t != nil && !tab_is_start(t)
	s := settings()
	add(&items, q, .Plus, "New Tab", "", "Ctrl+T", cmd(.New_Tab))
	add(&items, q, .Mask, "New Private Tab", "", "Ctrl+Shift+N", cmd(.New_Private))
	if len(b.closed) > 0 do add(&items, q, .History, "Reopen Closed Tab", b.closed[len(b.closed) - 1].tab.title, "Ctrl+Shift+T", cmd(.Reopen))
	if t != nil {
		add(&items, q, .Close, "Close Tab", "", "Ctrl+W", cmd(.Close_Tab))
		add(&items, q, .Pin, t.pinned ? "Unpin Tab" : "Pin Tab", "", "", cmd(.Pin))
		add(&items, q, t.muted ? .Speaker : .Speaker_Off, t.muted ? "Unmute Tab" : "Mute Tab", "", "Ctrl+M", cmd(.Mute))
	}
	if page {
		add(&items, q, .Copy, "Duplicate Tab", "", "Ctrl+Shift+K", cmd(.Duplicate))
		if t.article || t.reader do add(&items, q, .Reader, t.reader ? "Leave Reader" : "Reader", "", "Ctrl+Alt+R", cmd(.Reader))
		add(&items, q, .Split, split_on() ? "End Split View" : "Split View", "", "Ctrl+Shift+S", cmd(.Split))
		add(&items, q, .Link, "Copy Clean Link", "the address without its tracking", "", cmd(.Copy_Link))
		add(&items, q, .Search, "Find in Page", "", "Ctrl+F", cmd(.Find))
		add(&items, q, .Plus, "Zoom In", "", "Ctrl+Plus", cmd(.Zoom_In))
		add(&items, q, .Min, "Zoom Out", "", "Ctrl+Minus", cmd(.Zoom_Out))
		add(&items, q, .Search, "Actual Size", "zoom", "Ctrl+0", cmd(.Zoom_Reset))
		if s.shields do add(&items, q, .Shield_Off, "Shields for This Site", "turn on or off", "", cmd(.Shields_Site))
	}
	add(&items, q, .Compact, s.compact ? "Leave Compact Mode" : "Compact Mode", "hide the tabs and bar", "Ctrl+Shift+C", cmd(.Compact))
	add(&items, q, .Eye, "Privacy Report", "trackers stopped", "", cmd(.Report))
	add(&items, q, .Download, "Downloads", "", "Ctrl+J", cmd(.Downloads))
	add(&items, q, .Max, "Full Screen", "", "F11", cmd(.Full_Screen))
	add(&items, q, .Lock, s.httpsOnly ? "Turn HTTPS First Off" : "Turn HTTPS First On", "", "", cmd(.Https))
	add(&items, q, .Trash, s.clearOnExit ? "Keep History and Sign-ins on Close" : "Forget Everything on Close", "history, cookies, site data, tabs", "", cmd(.Clear_Exit))
	add(&items, q, .Grid, "New Workspace", "", "", cmd(.Space_New))
	for sp, k in space_list() {
		if sp.id == b.space do continue
		add(&items, q, .Grid, fmt.tprintf("Workspace: %s", sp.name), "switch", k < 9 ? fmt.tprintf("Alt+%d", k + 1) : "", cmd(.Space, s = sp.id))
		if t != nil do add(&items, q, .Grid, fmt.tprintf("Move Tab to %s", sp.name), "workspace", "", cmd(.Space_Move, s = sp.id))
	}
	// pages from your history, only once something is typed
	if len(q) > 0 do for v in history_suggest(q, 5) {
		title := len(v.title) > 0 ? v.title : display_url(v.url, context.temp_allocator)
		append(&items, Palette_Item{.History, title, display_url(v.url, context.temp_allocator), "", {op = .Go, s = v.url}, max(fuzzy_score(q, title), fuzzy_score(q, v.url) / 2, 2)})
	}
	slice.stable_sort_by(items[:], proc(a, z: Palette_Item) -> bool { return a.score > z.score })
	for it in items[:min(len(items), PALETTE_ROWS)] {
		x := it
		x.title = strings.clone(it.title)
		x.sub = strings.clone(it.sub)
		x.act.s = strings.clone(it.act.s)
		append(&ui.palette_items, x)
	}
	ui.palette_sel = 0
}

PALETTE_ROWS :: 9

palette_key :: proc(e: plat.Key_Event) {
	n := len(ui.palette_items)
	switch e.sym {
	case plat.KEY_Down: if n > 0 do ui.palette_sel = (ui.palette_sel + 1) % n
	case plat.KEY_Up: if n > 0 do ui.palette_sel = (ui.palette_sel - 1 + n) % n
	case:
		switch line_key(&ui.palette, e) {
		case .Enter: if ui.palette_sel >= 0 && ui.palette_sel < n do palette_pick(ui.palette_sel)
		case .Escape: palette_close()
		case .Changed: palette_refresh()
		case .Moved, .Ignored:
		}
	}
}

@(private="file") palette_pick :: proc(i: int) {
	a := ui.palette_items[i].act
	// the strings go with the items: a copy for the action
	a.s = strings.clone(a.s, context.temp_allocator)
	palette_close()
	act(a)
}

/// the palette: a card of glass at the top of the page, its field and rows
draw_palette :: proc(W, H: f32, dt: f32) {
	k, moving := motion(ui.palette_t0, ui.clock, 160)
	if moving do ui.animating = true
	w := min(640, W - 40)
	n := len(ui.palette_items)
	h := 60 + f32(n) * 40 + (n > 0 ? 8 : 0)
	r := [4]f32{(W - w) / 2, max(60, H * 0.14) + motion_from(-8, 0, k), w, h}
	ui.palette_rect = r
	draw_glass(r.x, r.y, r.z, r.w, glass_amount(glass_style({r = 22, kind = 1}), k))
	hit(id(.Palette_Card), r)
	draw_icon(.Command, r.x + 20, r.y + 20, 18, DIM)
	fr := [4]f32{r.x + 52, r.y + 4, r.z - 72, 52}
	draw_field(&ui.palette, fr, 16, "Search tabs, commands and history", dt)
	hit(id(.Palette_Field), fr, {}, .Text)
	if n > 0 do draw_fill(r.x + 14, r.y + 58, r.z - 28, 1, 0.5, FAINT)
	for it, i in ui.palette_items {
		rr := [4]f32{r.x + 6, r.y + 62 + f32(i) * 40, r.z - 12, 40}
		ri := id(.Palette_Row, i)
		hv := hover_of(ri, dt)
		if i == ui.palette_sel || hv > 0.01 do fill(rr, 12, {ACCENT.r, ACCENT.g, ACCENT.b, 0.10 * max(hv, i == ui.palette_sel ? 1 : 0)})
		draw_icon(it.icon, rr.x + 12, rr.y + 11, 18, it.icon == .Sparkle ? ACCENT : INK)
		kw := len(it.keys) > 0 ? text_width(it.keys, 11.5, .Semibold) : 0
		sw := len(it.sub) > 0 ? min(text_width(it.sub, 12), rr.z * 0.35) : 0
		tw := rr.z - 54 - (kw > 0 ? kw + 14 : 0) - (sw > 0 ? sw + 12 : 0)
		used := draw_text(it.title, rr.x + 42, baseline(rr.y, rr.w, 14), 14, INK, .Semibold, tw)
		if sw > 0 do draw_text(it.sub, rr.x + 42 + used + 12, baseline(rr.y, rr.w, 12), 12, DIM, max_w = sw)
		if kw > 0 do draw_text(it.keys, rr.x + rr.z - 12 - kw, baseline(rr.y, rr.w, 11.5), 11.5, DIM, .Semibold)
		hit(ri, rr, it.act)
	}
}

// ---------------------------------------------------------------- the commands

/// one of Iris's commands; a.n2 names a tab (else the current one), a.s
/// an address or a workspace
run_command :: proc(c: Command, a: Action) {
	t := b.current
	if a.n2 != 0 {
		t = tab_by_id(a.n2)
		if t == nil do return
	}
	switch c {
	case .None:
	case .New_Tab: browser_new_tab({select = true})
	case .New_Private: browser_new_tab({container = PRIVATE_ID, select = true})
	case .Reopen: browser_reopen()
	case .Close_Tab: if t != nil do browser_close(t)
	case .Duplicate: if t != nil && !tab_is_start(t) do browser_new_tab({url = t.url, container = t.container, after = t, select = true})
	case .Pin: if t != nil do tab_set_pinned(t, !t.pinned)
	case .Mute: tab_toggle_mute(t)
	case .Reader: reader_toggle(t)
	case .Split: split_toggle()
	case .Split_With: if t != nil && b.current != nil do split_start(b.current, t)
	case .Compact: compact_toggle()
	case .Peek_Link: if b.context_tab != nil && len(a.s) > 0 do peek_open(b.context_tab, a.s)
	case .Peek_Promote: peek_promote()
	case .Peek_Close: peek_close()
	case .Report: privacy_open(button_rect(.Shield))
	case .Copy_Link:
		if len(a.s) > 0 {
			copy_clean_link(a.s)
		} else if t != nil && !tab_is_start(t) {
			copy_clean_link(t.url)
		}
	case .Find: chrome_open_find()
	case .Downloads: chrome_open_downloads()
	case .Address: chrome_focus_address()
	case .Spaces: toggle_panel(.Containers, button_rect(.Space_Chip), false)
	case .Space: space_switch(a.s)
	case .Space_New: open_panel(.New_Space, button_rect(.Containers), true)
	case .Space_Add:
		name := strings.trim_space(line_string(&ui.name))
		if len(name) == 0 do break
		close_panel()
		id := space_add(name)
		space_switch(id)
	case .Space_Remove:
		close_panel()
		space_remove(a.s)
	case .Space_Move: tab_move_to_space(t, a.s)
	case .Https:
		s := settings()
		s.httpsOnly = !s.httpsOnly
		settings_save()
		browser_toast(s.httpsOnly ? "HTTPS first: http addresses are tried over https first" : "HTTPS first is off")
	case .Clear_Exit:
		s := settings()
		s.clearOnExit = !s.clearOnExit
		settings_save()
		browser_toast(s.clearOnExit ? "When Iris closes, your history, cookies, site data and tabs go" : "Iris keeps your history, sign-ins and tabs again")
	case .Shields_Site: act({op = .Shield_Site})
	case .Zoom_In: browser_zoom(1)
	case .Zoom_Out: browser_zoom(-1)
	case .Zoom_Reset: browser_zoom(0)
	case .Full_Screen:
		b.fullscreen = !b.fullscreen
		plat.set_fullscreen(&b.win, b.fullscreen)
		browser_layout()
	case .Next_Space: space_cycle(1)
	case .Prev_Space: space_cycle(-1)
	}
	chrome_push()
}

@(test) test_fuzzy :: proc(t: ^testing.T) {
	testing.expect(t, fuzzy_score("split", "Split View") > fuzzy_score("split", "Leave Split"))
	testing.expect(t, fuzzy_score("spv", "Split View") > 0, "letters in order match")
	testing.expect_value(t, fuzzy_score("xyz", "Split View"), 0)
	testing.expect(t, fuzzy_score("view", "Split View") > fuzzy_score("iew", "Split View"), "the start of a word counts more")
	testing.expect(t, fuzzy_score("rdr", "Reader") > 0)
	testing.expect_value(t, fuzzy_score("", "anything"), 1)
}
