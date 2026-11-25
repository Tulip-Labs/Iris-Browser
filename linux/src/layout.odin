// Where pages go on screen: split view (two tabs side by side, as in Zen,
// with a divider you drag) and compact mode (the tab strip and bar hidden
// until the pointer reaches the top edge). Both are Iris's own compositing:
// each page is a texture of its own, so two pages, or a peek over a page,
// are just more rectangles in the same frame.
package iris

import "core:testing"

SPLIT_GAP :: f32(10)
SPLIT_MIN :: f32(0.2)

/// the two halves of the page's place, divided at ratio with a gap between
split_rects :: proc(card: [4]f32, ratio, gap: f32) -> (a, z: [4]f32) {
	r := clamp(ratio, SPLIT_MIN, 1 - SPLIT_MIN)
	w := max(card.z - gap, 0)
	lw := w * r
	a = {card.x, card.y, lw, card.w}
	z = {card.x + lw + gap, card.y, w - lw, card.w}
	return
}

split_on :: proc() -> bool { return b.split_a != nil && b.split_b != nil && !b.page_fullscreen }

split_has :: proc(t: ^Tab) -> bool { return t != nil && split_on() && (t == b.split_a || t == b.split_b) }

split_other :: proc(t: ^Tab) -> ^Tab {
	if !split_on() do return nil
	if t == b.split_a do return b.split_b
	if t == b.split_b do return b.split_a
	return nil
}

/// the current tab beside another (the next one in the strip, else the one
/// before it); a start page has no page to show beside
split_toggle :: proc() {
	if split_on() {
		split_end()
		return
	}
	t := b.current
	if t == nil || tab_is_start(t) {
		browser_toast("Split View needs a page in this tab")
		return
	}
	tabs := visible_tabs()
	at := -1
	for x, i in tabs do if x == t do at = i
	other: ^Tab
	for i in at + 1 ..< len(tabs) do if !tab_is_start(tabs[i]) {
		other = tabs[i]
		break
	}
	if other == nil do for i := at - 1; i >= 0; i -= 1 do if !tab_is_start(tabs[i]) {
		other = tabs[i]
		break
	}
	if other == nil {
		browser_toast("Split View needs a second tab with a page")
		return
	}
	split_start(t, other)
}

/// t on the left, other on the right; t keeps the keys
split_start :: proc(t, other: ^Tab) {
	if t == nil || other == nil || t == other || tab_is_start(t) || tab_is_start(other) do return
	peek_close()
	if other.space != t.space do set_str(&other.space, t.space)
	b.split_a, b.split_b = t, other
	if b.split_ratio <= 0 do b.split_ratio = 0.5
	if b.current != t do browser_select(t)
	if !tab_has_view(other) && len(other.url) > 0 {
		tab_load(other, other.url)
	}
	if other.page != nil do page_set_visible(other.page, true)
	browser_layout()
	chrome_push()
}

/// back to one page: the one with the keys stays
split_end :: proc() {
	if b.split_a == nil && b.split_b == nil do return
	for x in ([2]^Tab{b.split_a, b.split_b}) {
		if x != nil && x != b.current && x.page != nil do page_set_visible(x.page, false)
	}
	b.split_a, b.split_b = nil, nil
	browser_layout()
	chrome_push()
}

/// the other half takes the keys (a click in it); both stay on screen
split_focus :: proc(t: ^Tab) {
	if !split_has(t) || t == b.current do return
	old := b.current
	if old != nil && old.page != nil do page_focus(old.page, false)
	b.current = t
	if t.page != nil && !b.chrome_focus do page_focus(t.page, true)
	chrome_push()
}

/// a tab is drawn this frame: the one on screen, its split partner, the peek
tab_on_screen :: proc(t: ^Tab) -> bool {
	if t == nil do return false
	return t == b.current || t == b.peek || split_has(t)
}

/// where a tab's page is in the window (logical pixels)
browser_tab_rect :: proc(t: ^Tab) -> [4]f32 {
	if t != nil && t == b.peek do return peek_page_rect()
	if split_has(t) {
		a, z := split_rects(b.card, b.split_ratio, SPLIT_GAP)
		return t == b.split_a ? a : z
	}
	return b.card
}

// ---------------------------------------------------------------- compact mode

compact_on :: proc() -> bool { return settings().compact && !(b.fullscreen || b.page_fullscreen) }

compact_toggle :: proc() {
	s := settings()
	s.compact = !s.compact
	settings_save()
	ui.compact_hold = false
	browser_layout()
	if s.compact do browser_toast("Compact: move the pointer to the top to show the tabs")
	chrome_push()
}

/// the pointer moved: in compact mode the bars show while it is at the
/// top edge, and stay while it is over them
compact_pointer :: proc(y: f64, leave: bool) {
	if !compact_on() do return
	hold := !leave && (y <= 6 || (ui.compact_show.x > 0.3 && y < 100))
	if hold != ui.compact_hold {
		ui.compact_hold = hold
		chrome_push()
	}
}

@(test) test_split_rects :: proc(t: ^testing.T) {
	a, z := split_rects({8, 100, 1010, 600}, 0.5, 10)
	testing.expect_value(t, a, [4]f32{8, 100, 500, 600})
	testing.expect_value(t, z, [4]f32{518, 100, 500, 600})
	// never thinner than a fifth
	a, z = split_rects({0, 0, 1000, 500}, 0.01, 0)
	testing.expect_value(t, a.z, 200)
	testing.expect_value(t, z.x, 200)
	testing.expect_value(t, z.z, 800)
}
