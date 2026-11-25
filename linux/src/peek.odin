// The peek, as Zen's glance and Safari's link preview: Alt+click a link (or
// "Peek Link" in its menu) and it opens in a floating card of glass over
// the page. Esc, or a click beside it, closes it, and its view goes whole:
// a web process of its own (tab_isolate), ended with it. Enter (before you
// click into it), Ctrl+Enter or the expand button make it a tab, as it is.
package iris

import "core:strings"
import plat "../plat"

/// the peek's state beyond its tab: you clicked into it (Enter is the page's)
@(private="file") engaged: bool

/// Alt+click on a link
link_wants_peek :: proc(button: u32, mods: plat.Mods) -> bool {
	return button == 1 && .Alt in mods && !(.Ctrl in mods) && !(.Shift in mods)
}

peek_open :: proc(opener: ^Tab, u: string) {
	if len(u) == 0 do return
	url := strings.clone(u, context.temp_allocator)
	peek_close()
	t := tab_new(opener != nil ? opener.container : "")
	t.space = strings.clone(b.space)
	tab_isolate(t)
	b.peek = t
	engaged = false
	ui.peek_t0 = ui.clock
	chrome_set_focus(false)
	if c := b.current; c != nil && c.page != nil do page_focus(c.page, false)
	tab_load(t, url)
	if t.page != nil do page_focus(t.page, true)
	browser_layout()
	chrome_push()
}

/// the peek goes, and everything of it (its view, its process)
peek_close :: proc() {
	t := b.peek
	if t == nil do return
	b.peek = nil
	if b.hover_tab == t do b.hover_tab = nil
	if b.grab_tab == t do b.grab_tab = nil
	tab_free(t)
	if c := b.current; c != nil && c.page != nil && !b.chrome_focus do page_focus(c.page, true)
	browser_layout()
	chrome_push()
}

/// the peek becomes a tab next to yours, its page as it is
peek_promote :: proc() {
	t := b.peek
	if t == nil do return
	b.peek = nil
	at := len(b.tabs)
	for x, i in b.tabs do if x == b.current do at = i + 1
	inject_at(&b.tabs, clamp_insert(at, false, pinned_count(), len(b.tabs)), t)
	set_str(&t.space, b.space)
	browser_select(t)
	chrome_push()
}

/// a click went into the peek's page: Enter is the page's from now on
peek_engage :: proc() { engaged = true }

/// the peek's keys: Ctrl+Enter (or Enter before a click into it) makes it a tab
peek_key :: proc(e: plat.Key_Event) -> bool {
	enter := e.sym == plat.KEY_Return || e.sym == plat.KEY_KP_Enter
	if enter && (.Ctrl in e.mods || !engaged) {
		peek_promote()
		return true
	}
	return false
}

/// the card, in the middle of the page's place
peek_card_rect :: proc() -> [4]f32 {
	c := b.card
	w := min(c.z * 0.84, 1120)
	h := c.w * 0.88
	return {c.x + (c.z - w) / 2, c.y + (c.w - h) / 2, w, h}
}

/// the peek's page inside its card, under the card's header
peek_page_rect :: proc() -> [4]f32 {
	r := peek_card_rect()
	return {r.x + 8, r.y + 46, r.z - 16, r.w - 54}
}

/// the peek: the page behind dims, a card of glass rises, the page in it
draw_peek :: proc(W, H: f32, dt: f32) {
	t := b.peek
	k, moving := motion(ui.peek_t0, ui.clock, 200)
	if moving do ui.animating = true
	draw_fill(0, 0, W, H, 0, {0, 0, 0, 0.22 * k})
	hit(id(.Peek_Scrim), {0, 0, W, H}, {op = .Command, n = int(Command.Peek_Close)})
	r := peek_card_rect()
	sc := motion_from(0.96, 1, k)
	rr := [4]f32{r.x + r.z * (1 - sc) / 2, r.y + r.w * (1 - sc) / 2 + motion_from(10, 0, k), r.z * sc, r.w * sc}
	draw_glass(rr.x, rr.y, rr.z, rr.w, glass_amount(glass_style({r = 22, kind = 1}), k))
	hit(id(.Peek_Card), rr)
	// the header: where it goes, and its two buttons
	ink := INK
	ink.a *= k
	title := len(t.title) > 0 ? t.title : display_url(t.url, context.temp_allocator)
	if t.loading {
		draw_spinner(rr.x + 22, rr.y + 23, 6)
	} else {
		draw_icon(t.sandboxed ? .Warn : .Eye, rr.x + 14, rr.y + 14, 17, t.sandboxed ? WARN : DIM)
	}
	draw_text(title, rr.x + 40, baseline(rr.y + 4, 38, 13.5), 13.5, ink, .Semibold, rr.z - 40 - 92)
	button(.Peek_Open, {rr.x + rr.z - 82, rr.y + 6, 34, 34}, .Expand, {op = .Command, n = int(Command.Peek_Promote)}, dt)
	button(.Peek_Close, {rr.x + rr.z - 44, rr.y + 6, 34, 34}, .Close, {op = .Command, n = int(Command.Peek_Close)}, dt)
	if t.loading {
		pw := (rr.z - 36) * f32(max(0.08, t.progress))
		draw_fill(rr.x + 18, rr.y + 42, pw, 2, 1, ACCENT)
		ui.animating = true
	}
	// the page itself, drawn over its glass (it is not behind it)
	if t.page != nil && k > 0.02 {
		p := peek_page_rect()
		draw_texture(t.page.tex, p.x, p.y + motion_from(10, 0, k), p.z, p.w, 14, k)
	}
}
