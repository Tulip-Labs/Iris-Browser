// Iris's start page, drawn by Iris: no web page behind it (a new tab opens
// at once and costs no web process until you go somewhere). The backdrop,
// the Iris ring (clear glass with light through it, red to blue and never
// purple; drawn once into a texture) and one search, in the middle.
// Nothing on it moves.
package iris

import "core:strings"
import plat "../plat"

START_PLACEHOLDER :: "Search or enter address"

/// the start page came into view: its search takes the keys
chrome_start_shown :: proc() {
	line_set(&ui.start, "")
	focus_field(.Start)
	chrome_push()
}

/// the keyboard to the start page's search
chrome_focus_start :: proc() {
	if !tab_is_start(b.current) do return
	if ui.focus == .Start do return
	close_panel()
	focus_field(.Start)
	warm_for_search()
}

/// a tab that is no start page took the window: its search lets the keys go
chrome_leave_start :: proc() {
	if ui.focus != .Start do return
	ui.focus = .None
	b.chrome_focus = false
	line_set(&ui.start, "")
}

/// where the start page puts its ring and search, in the page's place
start_layout :: proc(card: [4]f32) -> (ring: [4]f32, search: [4]f32) {
	sw := min(640, card.z * 0.6)
	sh: f32 = 52
	cx := card.x + card.z / 2
	sy := card.y + card.w * 0.55 - sh / 2
	search = {cx - sw / 2, sy, sw, sh}
	d := max(72, min(card.z, card.w) * 0.22)
	// the ring above the search, never above the page's top
	gap: f32 = 40
	d = min(d, sy - gap - (card.y + 16))
	d = max(d, 0)
	ring = {cx - d / 2, sy - gap - d, d, d}
	return
}

/// the start page, still: the ring (copied from its texture) and the
/// search, its rim a little brighter while it has the keys
draw_start :: proc(W, H: f32, dt: f32) {
	card := chrome_card(W, H)
	ring, r := start_layout(card)
	if ring.z >= 24 do draw_ring(ring.x + ring.z / 2, ring.y + ring.w / 2, ring.z)
	focused := ui.focus == .Start
	g := glass_style({r = r.w / 2, kind = 0})
	if focused do g.rim_light *= 1.6
	g.shadow = 1
	draw_glass(r.x, r.y, r.z, r.w, g)
	draw_icon(.Search, r.x + 20, r.y + (r.w - 18) / 2, 18, DIM)
	fr := start_field_rect(r)
	if focused {
		draw_field(&ui.start, fr, 16, START_PLACEHOLDER, dt)
	} else {
		text := line_string(&ui.start)
		draw_text(len(text) > 0 ? text : START_PLACEHOLDER, fr.x, baseline(fr.y, fr.w, 16), 16, len(text) > 0 ? INK : DIM, max_w = fr.z)
	}
	hit(id(.Start_Field), r, {}, .Text)
}

/// a key for the start page's search
start_key :: proc(e: plat.Key_Event) {
	switch line_key(&ui.start, e) {
	case .Enter:
		text := strings.trim_space(line_string(&ui.start))
		if len(text) == 0 do return
		// words are a Google search; an address opens
		u := is_url_like(text) ? resolve(text, context.temp_allocator) : search_url(text, context.temp_allocator)
		chrome_set_focus(false)
		browser_go(u)
	case .Escape:
		line_set(&ui.start, "")
	case .Changed:
		warm_for_search()
	case .Moved, .Ignored:
	}
}
