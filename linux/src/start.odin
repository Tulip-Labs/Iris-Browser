// Iris's start page, drawn by Iris: no web page behind it (a new tab opens
// at once and costs no web process until you go somewhere). The backdrop,
// the Iris ring (clear glass with light through it, red to blue and never
// purple) and one search, in the middle.
package iris

import "core:strings"
import plat "../plat"

START_PLACEHOLDER :: "Search or enter address"

/// the start page came into view: it appears again (ring, then search)
chrome_start_shown :: proc() {
	ui.start_t0 = ui.clock
	ui.start_fresh = true
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

draw_start :: proc(W, H: f32, dt: f32) {
	if ui.start_fresh {
		// the clock of the frame it first shows in
		ui.start_t0 = ui.clock
		ui.start_fresh = false
	}
	card := chrome_card(W, H)
	ring, sr := start_layout(card)
	kr, m1 := motion(ui.start_t0, ui.clock, 220)
	ks, m2 := motion(ui.start_t0, ui.clock, 220, 40)
	if m1 || m2 do ui.animating = true

	// the ring: clear glass, scaled in a little, its colours turning a few
	// degrees as it appears and with the pointer (never on their own)
	if ring.z >= 24 {
		sc := motion_from(0.96, 1, kr)
		d := ring.z * sc
		cx, cy := ring.x + ring.z / 2, ring.y + ring.w / 2
		px := ui.pointer.x > 0 ? (ui.pointer.x - cx) / max(W, 1) : 0
		g := Glass{
			radius = d / 2, tint = theme.dark ? {1, 1, 1, 0.05} : {1, 1, 1, 0.12},
			bend = d * 0.07, rim = d * 0.07, lens = 0, frost = 0.15, shadow = 1,
			rim_light = 1, dispersion = true,
			ring = d * 0.14, spectrum = theme.dark ? 0.75 : 0.6, spin = 0.04 * px + motion_from(-0.03, 0, kr),
		}
		g = glass_amount(g, kr)
		g.spectrum *= kr
		draw_glass(cx - d / 2, cy - d / 2, d, d, g)
	}

	// the search: a glass capsule that grows a touch when it has the keys
	focused := ui.focus == .Start
	if spring_step(&ui.start_focus, focused ? 1 : 0, dt) do ui.animating = true
	f := ui.start_focus.x
	grow := 1 + 0.02 * f
	r := [4]f32{sr.x - sr.z * (grow - 1) / 2, sr.y - sr.w * (grow - 1) / 2 + motion_from(6, 0, ks), sr.z * grow, sr.w * grow}
	g := glass_style({r = r.w / 2, kind = 0})
	g.rim_light *= 1 + 0.6 * f
	g.shadow = 1
	draw_glass(r.x, r.y, r.z, r.w, glass_amount(g, ks))
	ic := DIM
	ic.a *= ks
	draw_icon(.Search, r.x + 20, r.y + (r.w - 18) / 2, 18, ic)
	fr := start_field_rect(r)
	if focused {
		draw_field(&ui.start, fr, 16, START_PLACEHOLDER, dt)
	} else {
		text := line_string(&ui.start)
		c := len(text) > 0 ? INK : DIM
		c.a *= ks
		draw_text(len(text) > 0 ? text : START_PLACEHOLDER, fr.x, baseline(fr.y, fr.w, 16), 16, c, max_w = fr.z)
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
