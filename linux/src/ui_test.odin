package iris

import "core:testing"
import plat "../plat"

@(private="file") key :: proc(sym: u32, mods: plat.Mods = {}, text := "") -> plat.Key_Event {
	return {sym = sym, pressed = true, mods = mods, text = text}
}

@(test)
test_line_editing :: proc(t: ^testing.T) {
	l: Line
	defer line_free(&l)
	line_set(&l, "hello world")
	testing.expect_value(t, l.cursor, 11)
	line_key(&l, key(plat.KEY_Left, {.Ctrl}))
	testing.expect_value(t, l.cursor, 6)
	line_key(&l, key(plat.KEY_BackSpace, {.Ctrl}))
	testing.expect_value(t, line_string(&l), "world")
	line_key(&l, key('z', {.Ctrl}))
	testing.expect_value(t, line_string(&l), "hello world")
	line_select_all(&l)
	line_insert(&l, "ñandú\ncafé")
	testing.expect_value(t, line_string(&l), "ñandú café")
	line_key(&l, key(plat.KEY_Home))
	line_key(&l, key(plat.KEY_Right, {.Shift}))
	lo, hi := line_selection(&l)
	testing.expect_value(t, hi - lo, 2) // ñ is two bytes
	line_key(&l, key(plat.KEY_Delete))
	testing.expect_value(t, line_string(&l), "andú café")
	line_key(&l, key(plat.KEY_End))
	line_key(&l, key(0, text = "!"))
	testing.expect_value(t, line_string(&l), "andú café!")
	line_select_word(&l, 2)
	lo, hi = line_selection(&l)
	testing.expect_value(t, string(l.text[lo:hi]), "andú")
	testing.expect_value(t, line_key(&l, key(plat.KEY_Return)), Line_Result.Enter)
}

@(test)
test_path_parse :: proc(t: ^testing.T) {
	p := path_parse("M8 1l7.5 6.5H13V15h-3.5v-4.5h-3z")
	testing.expect_value(t, len(p.polys), 1)
	q := p.polys[0]
	testing.expect_value(t, q[0], [2]f32{8, 1})
	testing.expect_value(t, q[1], [2]f32{15.5, 7.5})
	testing.expect_value(t, q[2], [2]f32{13, 7.5})
	testing.expect_value(t, q[3], [2]f32{13, 15})
	testing.expect_value(t, q[len(q) - 1], [2]f32{8, 1}) // closed
	// a relative move after a close starts a new polygon from the start
	p2 := path_parse("M2 2h4v4zm1 1h1v1z")
	testing.expect_value(t, len(p2.polys), 2)
	testing.expect_value(t, p2.polys[1][0], [2]f32{3, 3})
	// every icon parses into something
	for src, ic in ICON_SVG {
		sv := svg_parse(src)
		testing.expectf(t, sv.view == {0, 0, 24, 24}, "icon %v: viewBox %v", ic, sv.view)
		testing.expectf(t, len(sv.shapes) > 0, "icon %v has no shapes", ic)
		for sh in sv.shapes {
			pp := path_parse(sh.d, 1)
			testing.expectf(t, len(pp.polys) > 0, "icon %v has a shape with no outline", ic)
			testing.expectf(t, sh.fill || sh.stroke, "icon %v has a shape that paints nothing", ic)
		}
		// rasterised at 18 px it covers something, and stays inside its box
		n := 20
		r := raster_make(n, n)
		k := f32(18) / 24
		for sh in sv.shapes {
			pp := path_parse(sh.d, k)
			if sh.fill do raster_fill(&r, pp, k, {1, 1})
			if sh.stroke do raster_stroke(&r, pp, k, {1, 1}, max(sh.width * k, 1.1))
		}
		cov := make([]u8, n * n, context.temp_allocator)
		raster_coverage(&r, cov)
		sum := 0
		for c in cov do sum += int(c)
		testing.expectf(t, sum > 255 * 4, "icon %v draws (almost) nothing", ic)
	}
	// the SVG reader: shapes, paint inherited from <svg>, and rounded rects
	sv := svg_parse(`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="3" width="10" height="8" rx="2"/><circle cx="5" cy="5" r="2" fill="currentColor" stroke="none"/><path id="x" d="M1 1L5 5"/></svg>`)
	testing.expect_value(t, len(sv.shapes), 3)
	testing.expect(t, sv.shapes[0].stroke && !sv.shapes[0].fill)
	testing.expect_value(t, sv.shapes[0].width, 2)
	testing.expect(t, sv.shapes[1].fill && !sv.shapes[1].stroke)
	testing.expect_value(t, sv.shapes[2].d, "M1 1L5 5")
}

@(test)
test_raster_coverage :: proc(t: ^testing.T) {
	// a 4 × 4 square in an 8 × 8 raster covers exactly 16 pixels
	r := raster_make(8, 8)
	p := path_parse("M2 2h4v4h-4z")
	raster_fill(&r, p, 1, {})
	cov := make([]u8, 64, context.temp_allocator)
	raster_coverage(&r, cov)
	sum := 0
	for c in cov do sum += int(c)
	testing.expect_value(t, sum, 16 * 255)
	testing.expect_value(t, cov[3 * 8 + 3], 255)
	testing.expect_value(t, cov[0], 0)
	// half a pixel on each side: a half-covered rim
	r2 := raster_make(8, 8)
	raster_fill(&r2, path_parse("M2.5 2.5h3v3h-3z"), 1, {})
	cov2 := make([]u8, 64, context.temp_allocator)
	raster_coverage(&r2, cov2)
	testing.expect(t, cov2[2 * 8 + 3] > 120 && cov2[2 * 8 + 3] < 135, "an edge half across a pixel covers half of it")
}

@(test)
test_versions :: proc(t: ^testing.T) {
	testing.expect(t, version_newer("2.10", "2.9.9"))
	testing.expect(t, version_newer("2.2.1", "2.2.0"))
	testing.expect(t, !version_newer("2.2.0", "2.2"))
}

// WebKit names its sandboxed web processes after the program name only when
// it is a valid application ID; otherwise the Flatpak portal refuses to start
// them and Iris closes (2.2.0 on Fedora).
@(test)
test_app_id :: proc(t: ^testing.T) {
	testing.expect(t, g_application_id_is_valid(APP_ID) != 0, "APP_ID is not a valid application ID")
	testing.expect(t, g_application_id_is_valid("iris") == 0, "g_application_id_is_valid changed its rules")
}

@(test)
test_url_parts :: proc(t: ^testing.T) {
	s, h, r := url_parts("https://www.example.com:8080/a/b?c=d#e")
	testing.expect_value(t, s, "https://")
	testing.expect_value(t, h, "www.example.com:8080")
	testing.expect_value(t, r, "/a/b?c=d#e")
	s, h, r = url_parts("about:blank")
	testing.expect_value(t, s, "")
	testing.expect_value(t, h, "")
	testing.expect_value(t, r, "about:blank")
	s, h, r = url_parts("https://example.com")
	testing.expect_value(t, h, "example.com")
	testing.expect_value(t, r, "")
}

@(test)
test_elide_middle :: proc(t: ^testing.T) {
	// 40 glyphs of 10 px, one byte each: 400 px into 200
	xs: [40]f32
	bs: [40]int
	for i in 0 ..< 40 do xs[i], bs[i] = f32(i) * 10, i
	h, tl := elide_middle(xs[:], bs[:], 400, 200, 10, 8, 40)
	testing.expect(t, h <= tl, "the head runs into the tail")
	head_w := f32(h) * 10
	tail_w := f32(40 - tl) * 10
	testing.expect(t, head_w + 10 + tail_w <= 200, "the cut address is wider than its place")
	testing.expect(t, h >= 8, "the host was cut")
	testing.expect(t, tl < 40, "nothing of the end is shown")
	// what fits is not cut
	h, tl = elide_middle(xs[:], bs[:], 400, 500, 10, 8, 40)
	testing.expect_value(t, h, 40)
	testing.expect_value(t, tl, 40)
}

@(test)
test_fade :: proc(t: ^testing.T) {
	k, moving := fade(10, 10.06)
	testing.expect(t, moving && k > 0.4 && k < 0.6, "halfway through a fade")
	k, moving = fade(10, 10.2)
	testing.expect(t, !moving && k == 1, "a fade ends (and stops asking for frames)")
	theme.reduce_motion = true
	k, moving = fade(10, 10.0)
	testing.expect(t, !moving && k == 1, "reduced motion: no fade at all")
	theme.reduce_motion = false
}

@(test)
test_new_window_choice :: proc(t: ^testing.T) {
	page := "https://news.example.com/a"
	// a link you click: a tab Iris loads itself (never a blank window)
	testing.expect_value(t, new_window_choice("https://other.org/x", page, true, true, false, true), Window_Choice.Own_Tab)
	testing.expect_value(t, new_window_choice("https://other.org/x", page, true, false, false, false), Window_Choice.Own_Tab)
	// a script's window for the same site, a sign-in or a blank one to fill: WebKit's view
	testing.expect_value(t, new_window_choice("https://www.example.com/pay", page, false, true, false, true), Window_Choice.Related)
	testing.expect_value(t, new_window_choice("https://accounts.google.com/o", page, false, true, false, true), Window_Choice.Related)
	testing.expect_value(t, new_window_choice("", page, false, true, false, true), Window_Choice.Related)
	testing.expect_value(t, new_window_choice("about:blank", page, false, true, false, true), Window_Choice.Related)
	// without your click, or to another site with Shields on: nothing
	testing.expect_value(t, new_window_choice("https://ads.example.net/", page, false, false, false, true), Window_Choice.Block)
	testing.expect_value(t, new_window_choice("https://other.org/", page, false, true, false, true), Window_Choice.Block)
	// Shields off: another site's window is a tab of its own
	testing.expect_value(t, new_window_choice("https://other.org/", page, false, true, false, false), Window_Choice.Own_Tab)
	// never a file of yours
	testing.expect_value(t, new_window_choice("file:///etc/passwd", page, true, true, false, false), Window_Choice.Block)
	// middle click and Ctrl+click (WPE: CEF tells these apart itself, as
	// OnOpenURLFromTab's disposition)
	when !ENGINE_CEF {
		testing.expect(t, link_wants_new_tab(2, 0))
		testing.expect(t, link_wants_new_tab(1, u32(WPE_MODIFIER_KEYBOARD_CONTROL)))
		testing.expect(t, !link_wants_new_tab(1, 0))
	}
}

@(test)
test_page_first_keys :: proc(t: ^testing.T) {
	// a web app's own shortcuts: the page first
	testing.expect(t, page_first_key(key('k', {.Ctrl})))
	testing.expect(t, page_first_key(key('m', {.Ctrl})))
	testing.expect(t, page_first_key(key('f', {.Ctrl})))
	testing.expect(t, page_first_key(key('c', {.Ctrl, .Shift})))
	testing.expect(t, page_first_key(key('s', {.Ctrl, .Shift})))
	// always Iris's
	for sym in ([?]u32{'l', 't', 'w', 'n', 'q'}) do testing.expect(t, !page_first_key(key(sym, {.Ctrl})))
	testing.expect(t, !page_first_key(key('t', {.Ctrl, .Shift})))
	testing.expect(t, !page_first_key(key(plat.KEY_Tab, {.Ctrl})))
	testing.expect(t, !page_first_key(key('k', {.Ctrl, .Shift})))
	testing.expect(t, !page_first_key(key('c', {.Ctrl})))
	testing.expect(t, !page_first_key(key('k', {.Ctrl, .Alt})))
	testing.expect(t, !page_first_key(key('k')))
	// the page's answer, for this ask only
	testing.expect_value(t, key_answer("7:page", 7), Key_Answer.Page)
	testing.expect_value(t, key_answer("7:free", 7), Key_Answer.Free)
	testing.expect_value(t, key_answer("7:", 7), Key_Answer.Free)
	testing.expect_value(t, key_answer("7:pending", 7), Key_Answer.Pending)
	testing.expect_value(t, key_answer("6:page", 7), Key_Answer.Other)
	testing.expect_value(t, key_answer("", 7), Key_Answer.Other)
}
