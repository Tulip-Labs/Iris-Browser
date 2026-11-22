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
	for d, ic in ICON_PATHS {
		pp := path_parse(d, 1)
		testing.expectf(t, len(pp.polys) > 0, "icon %v has no outline", ic)
	}
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
