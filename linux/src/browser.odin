// The browser: one window, its tabs, and the chrome around them.
//
// The chrome (tabs, address bar, menus, dialogs) is drawn by Iris itself
// (chrome.odin), with its glass over the live page; each pointer event and
// key goes to the chrome or to the page (the engine's: engine_api.odin).
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
	closed:        [dynamic]Closed_Tab,
	/// split view: the left and right tabs (layout.odin)
	split_a, split_b: ^Tab,
	split_ratio:   f32,
	/// a link open in a floating card over the page (peek.odin)
	peek:          ^Tab,
	/// the workspace shown, and the tab last on screen in each (spaces.odin)
	space:         string,
	space_last:    map[string]int,
	/// the page under the pointer, and the one a press went to
	hover_tab, grab_tab: ^Tab,
	fullscreen:    bool,
	page_fullscreen: bool,
	// the keyboard goes to the chrome (a field, a menu) rather than the page
	chrome_focus:  bool,
	/// where the page is (logical pixels)
	card:          [4]f32,
	// input
	hover:         Target,
	grab:          Target,
	// what pages asked for, until answered (the engine's handles)
	using pending: Browser_Asks,
	context_tab:   ^Tab,
	context_info:  Context_Info,
	asks:          int,
	/// the tab whose dialog is showing
	dialog_tab:    ^Tab,
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
	theme_init()
	renderer_init(w.egl_display)
	text_init()
	clipboard_init(w)
	w.keymap = proc(w: ^plat.Window, format: u32, fd: i32, size: u32) { set_keymap(format, fd, size) }
	w.pointer = proc(w: ^plat.Window, e: plat.Pointer_Event) { browser_pointer(e) }
	w.key = proc(w: ^plat.Window, e: plat.Key_Event) { browser_key(e) }
	w.focus = proc(w: ^plat.Window, on: bool) {
		for t in screen_tabs() do if t.page != nil do page_set_active(t.page, on)
	}
	w.resized = proc(w: ^plat.Window) { browser_layout() }
	w.close = proc(w: ^plat.Window) { browser_quit() }
	w.presented = proc(w: ^plat.Window) {
		for t in screen_tabs() do if t.page != nil do flush_rendered(t.page)
	}
	w.draw = browser_draw
	chrome_start()
	browser_layout()
	return true
}

browser_quit :: proc() {
	browser_save_session()
	history_flush()
	privacy_flush()
	clear_on_exit()
	b.win.closed = true
	g_main_loop_quit(main_loop)
}

// ---------------------------------------------------------------- drawing

browser_draw :: proc(w: ^plat.Window) {
	frame_begin(w.pixel_w, w.pixel_h, w.scale)
	draw_dawn()
	// the pages in the scene, so the glass bends them: the tab on screen, or
	// both halves of a split (a peek is drawn over its glass, in the chrome)
	for t in screen_tabs() {
		if t.page == nil do continue
		p := t.page
		page_latch(p)
		if t == b.peek do continue
		c := browser_tab_rect(t)
		// a failing certificate: nothing of the site shows (interstitial.odin)
		if t.cert_error != nil do continue
		r: f32 = b.page_fullscreen ? 0 : 14
		draw_fill(c.x, c.y + 6, c.z, c.w, r, {0, 0, 0, 0.12}, soft = 16)
		draw_fill(c.x, c.y, c.z, c.w, r, {1, 1, 1, 1})
		draw_texture(p.tex, c.x, c.y, c.z, c.w, r)
	}
	// the chrome unchanged and over nothing that moved: its layer, copied
	// (no blur, no glass, no text this frame)
	again := ui.dirty || !ui.cacheable
	frame_scene_done(blur = again)
	if !again && layer_copy() do return
	layer_begin()
	chrome_draw(f32(w.width), f32(w.height))
	layer_end()
}

/// a page's certificate page on screen (Iris draws it in the chrome)
cert_on_screen :: proc() -> bool {
	for t in screen_tabs() do if t.cert_error != nil do return true
	return false
}

/// Iris's glass for each kind the chrome asks for: clear and colourless,
/// light or dark
glass_style :: proc(g: Glass_Rect) -> Glass {
	dk := theme.dark
	switch g.kind {
	case 1: // panels, menus, notes: frosted, for reading
		return {radius = g.r, tint = dk ? {0.11, 0.12, 0.14, 0.78} : {0.99, 0.99, 1, 0.8}, bend = 3.5, rim = 10, lens = 0.01, frost = 1, shadow = 1.2, rim_light = dk ? 0.5 : 1, dispersion = true}
	case 2: // the selected tab's pill
		return {radius = g.r, tint = dk ? {1, 1, 1, 0.12} : {1, 1, 1, 0.42}, bend = 6, rim = 12, lens = 0.02, shadow = 0.5, rim_light = dk ? 0.5 : 1}
	case 3: // a hovered button
		return {radius = g.r, tint = dk ? {1, 1, 1, 0.10} : {1, 1, 1, 0.3}, bend = 4, rim = 9, lens = 0.02, rim_light = dk ? 0.4 : 0.8}
	}
	// bars: clear glass that bends the page
	return {radius = g.r, tint = dk ? {0.08, 0.09, 0.10, 0.30} : {1, 1, 1, 0.22}, bend = 8, rim = 16, lens = 0.03, shadow = 0.8, rim_light = dk ? 0.5 : 1, dispersion = true}
}

browser_layout :: proc() {
	w := &b.win
	b.card = chrome_card(f32(w.width), f32(w.height))
	for t in screen_tabs() {
		if t.page == nil do continue
		c := browser_tab_rect(t)
		if c.z > 0 && c.w > 0 do page_place(t.page, f64(c.x), f64(c.y), f64(c.z), f64(c.w), w.scale)
	}
	chrome_push() // the chrome, laid out again
}

/// the tabs whose pages are on screen: the current one, its split partner,
/// the peek (temporary)
screen_tabs :: proc() -> []^Tab {
	out := make([dynamic]^Tab, 0, 3, context.temp_allocator)
	if b.current != nil do append(&out, b.current)
	if o := split_other(b.current); o != nil do append(&out, o)
	if b.peek != nil do append(&out, b.peek)
	return out[:]
}

browser_page_frame :: proc(t: ^Tab) {
	if tab_on_screen(t) {
		plat.invalidate(&b.win)
		return
	}
	// a page out of sight: its frame is taken and given back at once
	page_latch(t.page)
	flush_rendered(t.page)
}

browser_page_cursor :: proc(t: ^Tab) {
	if t == b.hover_tab && b.hover == .Page do plat.set_cursor(&b.win, t.page.cursor)
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
	/// the engine's opener view, for a pop-up that must share its process
	/// and talk to its opener (both engines make such related pop-ups)
	related:   rawptr,
	lazy:      bool,
	pinned:    bool,
}

/// a new tab; a plain one is Iris's start page, drawn by Iris (no web
/// view at all until you go somewhere: it opens at once and costs nothing)
browser_new_tab :: proc(o: New_Tab) -> ^Tab {
	plain := len(o.url) == 0 && o.related == nil
	container := o.container
	t := tab_new(container)
	t.space = strings.clone(b.space)
	t.pinned = o.pinned
	at := len(b.tabs)
	if o.after != nil {
		for x, i in b.tabs do if x == o.after do at = i + 1
	}
	inject_at(&b.tabs, clamp_insert(at, t.pinned, pinned_count(), len(b.tabs)), t)
	if o.related != nil {
		tab_ensure_web(t, o.related)
		t.held = true
	} else if plain {
		// the start page: nothing to load
	} else if o.lazy {
		set_str(&t.url, o.url)
	} else {
		tab_load(t, o.url)
	}
	if o.select do browser_select(t)
	browser_session_changed()
	chrome_push()
	return t
}

/// a tab showing Iris's start page (no page in it)
tab_is_start :: proc(t: ^Tab) -> bool {
	return t != nil && !tab_has_view(t) && len(t.url) == 0
}

/// the tab back to the start page (Alt+Home)
browser_go_start :: proc(t: ^Tab) {
	if t == nil do return
	if split_has(t) do split_end()
	cert_clear(t)
	tab_release_web(t)
	set_str(&t.url, "")
	set_str(&t.title, "")
	delete(t.favicon_px)
	t.favicon_px = nil
	t.loading, t.can_back, t.can_forward, t.progress = false, false, false, 0
	browser_session_changed()
	if t == b.current do chrome_start_shown()
	browser_layout()
	chrome_push()
}

browser_attach :: proc(t: ^Tab) {
	if t.page == nil do return
	page_set_visible(t.page, tab_on_screen(t))
	if tab_on_screen(t) do browser_layout()
}

browser_detach :: proc(t: ^Tab) {
	if t.page != nil do page_set_visible(t.page, false)
}

browser_has_tab :: proc(t: ^Tab) -> bool {
	for x in b.tabs do if x == t do return true
	return false
}

browser_select :: proc(t: ^Tab) {
	if !browser_has_tab(t) do return
	old := b.current
	if old == t do return
	// the other half of a split: it takes the keys, both stay
	if split_has(t) && split_has(old) {
		split_focus(t)
		return
	}
	// a tab of another workspace: to it
	if t.space != b.space {
		if old != nil do b.space_last[b.space] = old.id
		set_str(&b.space, t.space)
		set_str(&settings().space, t.space)
	}
	if split_on() && !split_has(t) do split_end()
	// (CEF engine agent) the new tab is current before the old one is
	// hidden: the engine may freeze or put to sleep the tab you left, and
	// must not take it for the current one
	b.current = t
	if old != nil && old.page != nil {
		page_set_visible(old.page, false)
		page_focus(old.page, false)
	}
	if !tab_is_start(t) do chrome_leave_start()
	if !tab_has_view(t) && len(t.url) > 0 {
		u := strings.clone(t.url, context.temp_allocator)
		tab_load(t, u)
	}
	if t.page != nil {
		page_set_visible(t.page, true)
		if !b.chrome_focus do page_focus(t.page, true)
	}
	b.hover = .None
	if tab_is_start(t) do chrome_start_shown()
	browser_layout()
	chrome_push()
}

browser_close :: proc(t: ^Tab) {
	idx := -1
	for x, i in b.tabs do if x == t do idx = i
	if idx < 0 do return
	// the tab beside it in its workspace takes its place
	near := -1
	vis := visible_tabs()
	for x, i in vis do if x == t do near = i
	// the last CLOSED_MAX are kept for Ctrl+Shift+T
	closed_push(t, idx)
	partner := split_other(t)
	if split_has(t) do split_end()
	chrome_tab_closed(t)
	ordered_remove(&b.tabs, idx)
	if b.hover_tab == t do b.hover_tab = nil
	if b.grab_tab == t do b.grab_tab = nil
	if b.current == t {
		b.current = nil
		rest := visible_tabs()
		if partner != nil && browser_has_tab(partner) {
			browser_select(partner)
		} else if len(rest) > 0 {
			browser_select(rest[clamp(near, 0, len(rest) - 1)])
		}
	}
	private_left := false
	for x in b.tabs do if tab_is_private(x) do private_left = true
	tab_free(t)
	browser_session_changed()
	if !private_left do end_private()
	if b.current == nil || len(visible_tabs()) == 0 {
		browser_new_tab({select = true})
		return
	}
	chrome_push()
}

browser_close_later :: proc(t: ^Tab) {
	idle(proc(d: rawptr) {
		t := cast(^Tab)d
		if t == b.peek {
			peek_close()
		} else if browser_has_tab(t) {
			browser_close(t)
		}
	}, t)
}

/// the last closed tab again, where it was (its workspace, pinned or not)
browser_reopen :: proc() {
	if len(b.closed) == 0 do return
	c := pop(&b.closed)
	defer closed_free(c)
	s := c.tab
	// a container removed since then: the tab opens without one
	k := s.container
	if k != "" {
		if _, ok := container_get(k); !ok do k = ""
	}
	if space := space_for_saved(s.space); space != b.space do space_switch(space)
	before: ^Tab
	if c.index > 0 && c.index - 1 < len(b.tabs) do before = b.tabs[c.index - 1]
	browser_new_tab({url = s.url, container = k, select = true, after = before, pinned = s.pinned})
}

CLOSED_MAX :: 25

browser_cycle :: proc(d: int) {
	tabs := visible_tabs()
	if len(tabs) < 2 || b.current == nil do return
	for x, i in tabs do if x == b.current {
		browser_select(tabs[(i + d + len(tabs)) % len(tabs)])
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
	cert_clear(b.current)
	tab_load(b.current, u)
	chrome_set_focus(false)
}

browser_tab_changed :: proc(t: ^Tab) {
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

Window_Choice :: enum u8 { Block, Own_Tab, Related }

/// what a page asking for a new window gets: nothing (an ad, a file, a
/// script's pop-up without your click), a tab of Iris's own that loads the
/// address itself, or (a pop-up of the same site or a sign-in page, which
/// talks to its opener) a view WebKit fills
new_window_choice :: proc(u, page_url: string, link, gesture, sandboxed, shield: bool) -> Window_Choice {
	host, _ := host_of(u, context.temp_allocator)
	page_host, _ := host_of(page_url, context.temp_allocator)
	// a page opens web addresses in new tabs, never your files or other
	// programs (WebKit would refuse them in the page itself)
	if len(u) > 0 && !page_may_open(u, page_url) do return .Block
	// a link you click is a plain new tab, loaded by Iris (its address is
	// known, and nothing then depends on WebKit filling a window later),
	// even through a host Iris's list blocks: a webmail's links go through
	// email click-trackers, and a password reset must open
	if link && len(u) > 0 && u != "about:blank" do return .Own_Tab
	// a pop-up a script opens to an ad or tracker host goes nowhere
	if shield && host_blocked(host) do return .Block
	if sandboxed do return .Block
	if gesture && (site_of(host) == site_of(page_host) || is_sign_in(host) || len(u) == 0 || u == "about:blank") do return .Related
	if shield do return .Block
	return len(u) > 0 && u != "about:blank" ? .Own_Tab : .Block
}

/// a link from t's page in a tab of its own, next to t
browser_open_link :: proc(t: ^Tab, u: string, background: bool) {
	// (a peek is in no strip: its links go next to the tab under it)
	browser_new_tab({url = strings.clone(u, context.temp_allocator), container = t.container, after = t == b.peek ? b.current : t, select = !background})
}

// ---------------------------------------------------------------- input

@(private="file") inside :: proc(r: [4]f32, x, y: f64) -> bool {
	return f32(x) >= r.x && f32(x) < r.x + r.z && f32(y) >= r.y && f32(y) < r.y + r.w
}

@(private="file") target_at :: proc(x, y: f64) -> Target {
	if chrome_modal() do return .Chrome
	if interstitial_at(x, y) do return .Chrome
	if _, ok := chrome_hit_at({f32(x), f32(y)}); ok && !over_peek_page(x, y) do return .Chrome
	if page_tab_at(x, y) != nil do return .Page
	return .Chrome
}

@(private="file") over_peek_page :: proc(x, y: f64) -> bool {
	return b.peek != nil && b.peek.page != nil && inside(peek_page_rect(), x, y)
}

/// the tab whose page is at a point: the peek's while one is open (the page
/// under it waits), else either half of a split, else the current one
@(private="file") page_tab_at :: proc(x, y: f64) -> ^Tab {
	if b.peek != nil do return over_peek_page(x, y) ? b.peek : nil
	for t in screen_tabs() do if t.page != nil && inside(browser_tab_rect(t), x, y) do return t
	return nil
}

@(private="file") send_to :: proc(t: Target, e: plat.Pointer_Event, page: ^Tab = nil) {
	switch t {
	case .Chrome: chrome_pointer(e)
	case .Page: if page != nil && page.page != nil && browser_tab_alive(page) do page_pointer(page.page, e)
	case .None:
	}
}

browser_pointer :: proc(e: plat.Pointer_Event) {
	rnd.pointer = e.kind == .Leave ? {-1, -1} : {f32(e.x), f32(e.y)}
	compact_pointer(e.y, e.kind == .Leave)
	t := b.grab != .None ? b.grab : target_at(e.x, e.y)
	pt: ^Tab
	if t == .Page do pt = b.grab != .None ? b.grab_tab : page_tab_at(e.x, e.y)
	if e.kind == .Leave {
		send_to(b.hover, e, b.hover_tab)
		b.hover = .None
		b.hover_tab = nil
		return
	}
	if t != b.hover || pt != b.hover_tab {
		if b.hover != .None do send_to(b.hover, {kind = .Leave, x = e.x, y = e.y, time = e.time, mods = e.mods}, b.hover_tab)
		b.hover = t
		b.hover_tab = pt
		send_to(t, {kind = .Enter, x = e.x, y = e.y, time = e.time, mods = e.mods}, pt)
		cursor := plat.Cursor_Shape.Default
		if t == .Page && pt != nil && pt.page != nil do cursor = pt.page.cursor
		plat.set_cursor(&b.win, cursor)
	}
	if t == .Chrome {
		h, _ := chrome_hit_at({f32(e.x), f32(e.y)})
		plat.set_cursor(&b.win, h.cursor)
	}
	if e.kind == .Enter do return
	// Alt+click on a link: the link in a peek (the page never sees the click)
	@(static) swallow: bool
	if e.kind == .Button && t == .Page {
		if e.pressed && pt != b.peek && len(ui.status) > 0 && link_wants_peek(e.button, e.mods) && page_may_open(ui.status, pt != nil ? pt.url : "") {
			swallow = true
			peek_open(pt, ui.status)
			return
		}
		if !e.pressed && swallow {
			swallow = false
			return
		}
	}
	if e.kind == .Button {
		if e.pressed {
			b.grab = t
			b.grab_tab = pt
			// a press in the page gives it the keyboard; in the chrome, the chrome decides
			if t == .Page {
				chrome_set_focus(false)
				if pt == b.peek {
					peek_engage()
				} else if pt != nil && pt != b.current {
					split_focus(pt)
				}
			}
		} else {
			b.grab = .None
			b.grab_tab = nil
		}
	}
	send_to(t, e, pt)
	// the pointer's light on the glass: only near the bars (over the page
	// the page answers for itself)
	if e.kind == .Motion && (t == .Chrome || f32(e.y) < b.card.y + 60) do chrome_push()
}

/// Iris's own keys first (but those a web app may want, which its page has
/// first: page_first_key); the rest go to the chrome or the page
browser_key :: proc(e: plat.Key_Event) {
	if e.pressed && page_first_key(e) {
		if t := key_page(); t != nil {
			page_key(t.page, e)
			page_first_ask(t, e)
			return
		}
	}
	if e.pressed && browser_shortcut(e) do return
	if chrome_wants_keys() {
		chrome_key(e)
	} else if t := b.peek != nil ? b.peek : b.current; t != nil && t.cert_error != nil {
		// Iris's page for a failing certificate has the keys, not the site
		interstitial_key(t, e)
	} else if b.peek != nil {
		if e.pressed && peek_key(e) do return
		if b.peek.page != nil do page_key(b.peek.page, e)
	} else if tab_is_start(b.current) {
		// typing on the start page goes into its search
		if e.pressed && len(e.text) > 0 do chrome_focus_start()
		if chrome_wants_keys() do chrome_key(e)
	} else if b.current != nil && b.current.page != nil {
		page_key(b.current.page, e)
	}
}

// ---------------------------------------------------------------- keys a page has first

/// Iris's shortcuts that web apps use too (Ctrl+K a search or a link,
/// Ctrl+M, Ctrl+F their own find, Ctrl+Shift+C, Ctrl+Shift+S): the page
/// has them first, and Iris acts only if the page did not take the key
/// (preventDefault). Ctrl+L, Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+Shift+T and the
/// rest are always Iris's.
page_first_key :: proc(e: plat.Key_Event) -> bool {
	if !(.Ctrl in e.mods) || .Alt in e.mods do return false
	shift := .Shift in e.mods
	switch e.sym {
	case 'k', 'm', 'f': return !shift
	case 'c', 's': return shift
	}
	return false
}

/// the tab whose page has the keyboard (none: the chrome, the start page,
/// Iris's page for a failing certificate)
@(private="file") key_page :: proc() -> ^Tab {
	if chrome_wants_keys() || b.chrome_focus do return nil
	t := b.peek != nil ? b.peek : b.current
	if t == nil || t.page == nil || t.cert_error != nil || tab_is_start(t) do return nil
	return t
}

/// what the page did with a key, seen by Iris's own listener (installed
/// with page_keys_watch, in Iris's world where the engine has one): it
/// reads the event's defaultPrevented once every listener has run
PAGE_KEYS_JS :: `(() => {
  if (window.__irisKeys) return 1;
  const s = window.__irisKeys = { r: '' };
  addEventListener('keydown', e => {
    if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
    const k = (e.key || '').toLowerCase();
    if (!(['k', 'm', 'f'].includes(k) && !e.shiftKey) && !(['c', 's'].includes(k) && e.shiftKey)) return;
    // seen, its answer still to come (the page's own listeners run first,
    // then this timeout, however long the page keeps its thread)
    s.r = 'pending';
    setTimeout(() => { s.r = e.defaultPrevented ? 'page' : 'free'; }, 0);
  }, true);
  return 1;
})()`

/// a page that loaded gets the listener (cheap: one listener, no polling)
page_keys_watch :: proc(t: ^Tab) {
	if !strings.has_prefix(t.url, "http") && !strings.has_prefix(t.url, "file:") do return
	tab_run_isolated(t, PAGE_KEYS_JS, proc(t: ^Tab, result: string) {})
}

@(private="file") Key_Ask :: struct {
	seq, tab: int,
	e:        plat.Key_Event,
	done:     bool,
	/// the page saw the key and was still busy with it when last asked
	pending:  bool,
	started:  f64,
}
@(private="file") key_ask: Key_Ask

/// how long the page has before Iris asks what it did (and between asks
/// while it is busy), and when Iris stops asking
KEY_ASK_MS :: 60
KEY_GIVE_UP_MS :: 350

Key_Answer :: enum u8 {
	/// another ask's answer (or none)
	Other,
	/// the page took the key (preventDefault): Iris does nothing
	Page,
	/// the page let it be, or has no listener: Iris acts
	Free,
	/// the page saw the key and has not finished with it: ask again
	Pending,
}

/// the answer to ask seq: "<seq>:page", "<seq>:free", "<seq>:pending" or
/// "<seq>:" (no word: no listener)
key_answer :: proc(result: string, seq: int) -> Key_Answer {
	c := strings.index_byte(result, ':')
	if c < 0 || result[:c] != fmt.tprint(seq) do return .Other
	switch result[c + 1:] {
	case "page": return .Page
	case "pending": return .Pending
	}
	return .Free
}

@(private="file") page_first_ask :: proc(t: ^Tab, e: plat.Key_Event) {
	key_ask.seq += 1
	ev := e
	ev.text = "" // (the event's own text does not outlive it)
	key_ask = {seq = key_ask.seq, tab = t.id, e = ev, started = now_s()}
	seq := rawptr(uintptr(key_ask.seq))
	after(KEY_ASK_MS, key_ask_page, seq)
	after(KEY_GIVE_UP_MS, proc(d: rawptr) {
		seq := int(uintptr(d))
		if key_ask.seq != seq || key_ask.done do return
		key_ask.done = true
		// a page still busy with the key may yet act on it: Iris does not
		// act too (one find bar, not two); one that never answered is let be
		if key_ask.pending do return
		if t := key_page(); t != nil && t.id == key_ask.tab do browser_shortcut(key_ask.e)
	}, seq)
}

@(private="file") key_ask_page :: proc(d: rawptr) {
	seq := int(uintptr(d))
	if key_ask.seq != seq || key_ask.done do return
	t := key_page()
	if t == nil || t.id != key_ask.tab {
		key_ask.done = true // the keys went elsewhere meanwhile
		return
	}
	// (a pending answer stays for the next ask; a final one is taken)
	js := fmt.tprintf("(() => { const s = window.__irisKeys; const r = s ? s.r : ''; if (s && r !== 'pending') s.r = ''; return '%d:' + r; })()", seq)
	tab_run_isolated(t, js, proc(t: ^Tab, result: string) {
		if key_ask.done do return
		switch key_answer(result, key_ask.seq) {
		case .Other:
		case .Pending:
			key_ask.pending = true
			if (now_s() - key_ask.started) * 1000 + KEY_ASK_MS < KEY_GIVE_UP_MS do after(KEY_ASK_MS, key_ask_page, rawptr(uintptr(key_ask.seq)))
		case .Page:
			key_ask.done = true
		case .Free:
			key_ask.done = true
			if key_page() == t do browser_shortcut(key_ask.e)
		}
	})
}

@(private="file") browser_shortcut :: proc(e: plat.Key_Event) -> bool {
	ctrl := .Ctrl in e.mods
	shift := .Shift in e.mods
	alt := .Alt in e.mods
	if ctrl && alt {
		switch e.sym {
		case 'r': reader_toggle(b.current)
		case: return false
		}
		return true
	}
	if ctrl && !alt {
		switch e.sym {
		case 't': if shift { browser_reopen() } else { browser_new_tab({select = true}) }
		case 'n': browser_new_tab({container = shift ? PRIVATE_ID : "", select = true})
		case 'w': if b.current != nil do browser_close(b.current)
		case 'q': browser_quit()
		case 'l': chrome_focus_address()
		case 'k':
			if shift {
				if t := b.current; t != nil && !tab_is_start(t) do browser_new_tab({url = t.url, container = t.container, after = t, select = true})
			} else {
				palette_open()
			}
		case 's': if !shift do return false; split_toggle()
		case 'c': if !shift do return false; compact_toggle()
		case 'm': tab_toggle_mute(b.current)
		case 'r':
			if b.current != nil {
				if shift { tab_reload_bypass(b.current) } else { tab_reload(b.current) }
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
			// Ctrl+9 is the last tab, as in every browser
			tabs := visible_tabs()
			i := int(e.sym - plat.KEY_1)
			if e.sym == plat.KEY_9 do i = len(tabs) - 1
			if i >= 0 && i < len(tabs) do browser_select(tabs[i])
		case: return false
		}
		return true
	}
	if alt && !ctrl {
		switch e.sym {
		case plat.KEY_Left: if b.current != nil do tab_back(b.current)
		case plat.KEY_Right: if b.current != nil do tab_forward(b.current)
		case plat.KEY_Home: browser_go_start(b.current)
		case plat.KEY_1 ..= plat.KEY_9:
			l := space_list()
			i := int(e.sym - plat.KEY_1)
			if i < len(l) do space_switch(l[i].id)
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
		if b.peek != nil && !chrome_wants_keys() {
			peek_close()
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
		if h, ok := host_of(link, context.temp_allocator); ok do tab_warm_dns(t, h)
	}
	chrome_status(link)
}

/// what was under the pointer when a page's context menu was asked for
/// (strings are copied); the chrome shows its menu at x, y in the page
browser_context_menu_at :: proc(t: ^Tab, x, y: f32, info: Context_Info) {
	ci := &b.context_info
	delete(ci.link)
	delete(ci.image)
	delete(ci.media)
	ci^ = {editable = info.editable, selection = info.selection}
	if !strings.has_prefix(info.link, "javascript:") do ci.link = strings.clone(info.link)
	ci.image = strings.clone(info.image)
	ci.media = strings.clone(info.media)
	b.context_tab = t
	r := browser_tab_rect(t)
	chrome_context_menu(r.x + x, r.y + y)
}

/// a tab going away answers the dialog its page left open
browser_forget_dialog :: proc(t: ^Tab) {
	if b.dialog_tab == t do chrome_dismiss_dialog()
}

// ---------------------------------------------------------------- the session

SESSION_SAVE_MS :: 1500

@(private="file") session_pending: bool

/// the tabs changed (opened, closed, gone somewhere, pinned, moved, to
/// another workspace): the session is saved a moment later, once for all
/// the changes of that moment (a crash then loses little); nothing waits
/// while nothing changes
browser_session_changed :: proc() {
	if session_pending || b.win.closed do return
	session_pending = true
	after(SESSION_SAVE_MS, proc(_: rawptr) {
		session_pending = false
		if !b.win.closed do browser_save_session()
	}, nil)
}

browser_save_session :: proc() {
	s := settings()
	session_clear(&s.session)
	// with "forget everything when Iris closes", no session is kept
	if !s.clearOnExit do for t in b.tabs {
		if tab_is_private(t) || t.sandboxed || len(t.url) == 0 || is_ai_mode(t.url) do continue
		append(&s.session, Saved_Tab{url = strings.clone(t.url), title = strings.clone(t.title), container = strings.clone(t.container), pinned = t.pinned, space = strings.clone(t.space)})
	}
	set_str(&s.space, b.space)
	settings_save()
}

/// the tabs open last time come back, in their workspaces, pinned ones
/// pinned (only the one on screen loads; the others wait until you go to
/// them)
browser_restore :: proc() {
	st := settings()
	set_str(&b.space, space_for_saved(st.space))
	for s in st.session {
		k := s.container
		if _, ok := container_get(k); !ok do k = ""
		t := browser_new_tab({url = s.url, container = k, lazy = true, pinned = s.pinned})
		set_str(&t.space, space_for_saved(s.space))
		set_str(&t.title, s.title)
	}
	if tabs := visible_tabs(); len(tabs) > 0 {
		browser_select(tabs[0])
	} else if len(b.tabs) > 0 {
		browser_new_tab({select = true})
	}
}

