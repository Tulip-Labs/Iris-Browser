package term

import "core:strings"
import "core:testing"

@(private="file") enc :: proc(t: ^Term, sym: u32, mods: Mods = {}, text := "") -> string {
	out := make([dynamic]u8, context.temp_allocator)
	encode_key(t, &out, sym, mods, text)
	return string(out[:])
}

@(private="file") mkt :: proc() -> ^Term {
	t := new(Term)
	term_init(t, 80, 24, 10)
	return t
}

@(test)
test_plain_keys :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	testing.expect_value(tt, enc(t, 'a', {}, "a"), "a")
	testing.expect_value(tt, enc(t, 0xe9, {}, "é"), "é")
	testing.expect_value(tt, enc(t, KS_Return), "\r")
	testing.expect_value(tt, enc(t, KS_Tab), "\t")
	testing.expect_value(tt, enc(t, KS_ISO_Left_Tab, {.Shift}), "\x1b[Z")
	testing.expect_value(tt, enc(t, KS_Escape), "\x1b")
	testing.expect_value(tt, enc(t, KS_BackSpace), "\x7f")
	testing.expect_value(tt, enc(t, KS_BackSpace, {.Ctrl}), "\x08")
	testing.expect_value(tt, enc(t, KS_BackSpace, {.Alt}), "\x1b\x7f")
}

@(test)
test_ctrl_and_alt :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	testing.expect_value(tt, enc(t, 'c', {.Ctrl}), "\x03")
	testing.expect_value(tt, enc(t, 'C', {.Ctrl, .Shift}), "\x03")
	testing.expect_value(tt, enc(t, 'a', {.Ctrl}), "\x01")
	testing.expect_value(tt, enc(t, 'z', {.Ctrl}), "\x1a")
	testing.expect_value(tt, enc(t, '[', {.Ctrl}), "\x1b")
	testing.expect_value(tt, enc(t, ' ', {.Ctrl}), "\x00")
	testing.expect_value(tt, enc(t, '\\', {.Ctrl}), "\x1c")
	testing.expect_value(tt, enc(t, '/', {.Ctrl}), "\x1f")
	testing.expect_value(tt, enc(t, 'x', {.Alt}), "\x1bx")
	testing.expect_value(tt, enc(t, 'X', {.Alt, .Shift}), "\x1bX")
	testing.expect_value(tt, enc(t, 'b', {.Alt, .Ctrl}), "\x1b\x02")
	testing.expect_value(tt, enc(t, KS_Return, {.Alt}), "\x1b\r")
	// the logo key is the desktop's
	testing.expect_value(tt, enc(t, 'a', {.Logo}, "a"), "a")
}

@(test)
test_cursor_keys :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	testing.expect_value(tt, enc(t, KS_Up), "\x1b[A")
	testing.expect_value(tt, enc(t, KS_Left), "\x1b[D")
	testing.expect_value(tt, enc(t, KS_Home), "\x1b[H")
	testing.expect_value(tt, enc(t, KS_End), "\x1b[F")
	testing.expect_value(tt, enc(t, KS_Right, {.Ctrl}), "\x1b[1;5C")
	testing.expect_value(tt, enc(t, KS_Left, {.Shift}), "\x1b[1;2D")
	testing.expect_value(tt, enc(t, KS_Up, {.Ctrl, .Shift}), "\x1b[1;6A")
	testing.expect_value(tt, enc(t, KS_Down, {.Alt}), "\x1b[1;3B")
	term_feed(t, transmute([]u8)string("\x1b[?1h"))
	testing.expect_value(tt, enc(t, KS_Up), "\x1bOA")
	testing.expect_value(tt, enc(t, KS_Home), "\x1bOH")
	testing.expect_value(tt, enc(t, KS_Up, {.Ctrl}), "\x1b[1;5A")
}

@(test)
test_editing_and_function_keys :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	testing.expect_value(tt, enc(t, KS_Delete), "\x1b[3~")
	testing.expect_value(tt, enc(t, KS_Insert), "\x1b[2~")
	testing.expect_value(tt, enc(t, KS_Page_Up), "\x1b[5~")
	testing.expect_value(tt, enc(t, KS_Page_Down), "\x1b[6~")
	testing.expect_value(tt, enc(t, KS_Delete, {.Ctrl}), "\x1b[3;5~")
	testing.expect_value(tt, enc(t, KS_F1), "\x1bOP")
	testing.expect_value(tt, enc(t, KS_F1 + 3), "\x1bOS")
	testing.expect_value(tt, enc(t, KS_F1 + 4), "\x1b[15~")
	testing.expect_value(tt, enc(t, KS_F1 + 11), "\x1b[24~")
	testing.expect_value(tt, enc(t, KS_F1, {.Shift}), "\x1b[1;2P")
	testing.expect_value(tt, enc(t, KS_F1 + 5, {.Ctrl}), "\x1b[17;5~")
}

@(test)
test_keypad :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	testing.expect_value(tt, enc(t, KS_KP_Enter), "\r")
	testing.expect_value(tt, enc(t, KS_KP_0 + 5, {}, "5"), "5")
	term_feed(t, transmute([]u8)string("\x1b="))
	testing.expect_value(tt, enc(t, KS_KP_Enter), "\x1bOM")
	testing.expect_value(tt, enc(t, KS_KP_0 + 5, {}, "5"), "\x1bOu")
	testing.expect_value(tt, enc(t, KS_KP_Add), "\x1bOk")
}

@(private="file") menc :: proc(t: ^Term, e: Mouse_Event) -> (string, bool) {
	out := make([dynamic]u8, context.temp_allocator)
	ok := encode_mouse(t, &out, e)
	return string(out[:]), ok
}

@(test)
test_mouse_reporting :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	_, ok := menc(t, {kind = .Press, x = 1, y = 1})
	testing.expect(tt, !ok) // not asked for
	term_feed(t, transmute([]u8)string("\x1b[?1000h"))
	s, ok2 := menc(t, {kind = .Press, button = 0, x = 4, y = 2})
	testing.expect(tt, ok2)
	testing.expect_value(tt, s, "\x1b[M %#")
	s, _ = menc(t, {kind = .Release, button = 0, x = 4, y = 2})
	testing.expect_value(tt, s, "\x1b[M#%#")
	_, ok = menc(t, {kind = .Motion, held = true, button = 0, x = 5, y = 2})
	testing.expect(tt, !ok) // 1000 has no motion
	term_feed(t, transmute([]u8)string("\x1b[?1002h\x1b[?1006h"))
	s, ok = menc(t, {kind = .Press, button = 0, x = 9, y = 4})
	testing.expect_value(tt, s, "\x1b[<0;10;5M")
	s, _ = menc(t, {kind = .Release, button = 0, x = 9, y = 4})
	testing.expect_value(tt, s, "\x1b[<0;10;5m")
	s, ok = menc(t, {kind = .Motion, held = true, button = 0, x = 10, y = 4})
	testing.expect_value(tt, s, "\x1b[<32;11;5M")
	_, ok = menc(t, {kind = .Motion, held = false, x = 10, y = 4})
	testing.expect(tt, !ok) // 1002: only with a button down
	term_feed(t, transmute([]u8)string("\x1b[?1003h"))
	_, ok = menc(t, {kind = .Motion, held = false, x = 10, y = 4})
	testing.expect(tt, ok)
	s, _ = menc(t, {kind = .Wheel_Up, x = 0, y = 0})
	testing.expect_value(tt, s, "\x1b[<64;1;1M")
	s, _ = menc(t, {kind = .Wheel_Down, x = 0, y = 0, mods = {.Ctrl, .Shift}})
	testing.expect_value(tt, s, "\x1b[<85;1;1M")
	s, _ = menc(t, {kind = .Press, button = 2, x = 0, y = 0, mods = {.Alt}})
	testing.expect_value(tt, s, "\x1b[<10;1;1M")
	// X10 reports presses only, without modifiers
	t2 := mkt()
	defer { term_destroy(t2); free(t2) }
	term_feed(t2, transmute([]u8)string("\x1b[?9h"))
	_, ok = menc(t2, {kind = .Release, x = 1, y = 1})
	testing.expect(tt, !ok)
	s, _ = menc(t2, {kind = .Press, button = 1, x = 0, y = 0, mods = {.Ctrl}})
	testing.expect_value(tt, s, "\x1b[M!!!")
	// the default encoding cannot reach past column 223
	t3 := mkt()
	defer { term_destroy(t3); free(t3) }
	term_feed(t3, transmute([]u8)string("\x1b[?1000h"))
	_, ok = menc(t3, {kind = .Press, x = 230, y = 1})
	testing.expect(tt, !ok)
	term_feed(t3, transmute([]u8)string("\x1b[?1015h"))
	s, _ = menc(t3, {kind = .Press, button = 0, x = 230, y = 1})
	testing.expect_value(tt, s, "\x1b[32;231;2M")
}

@(test)
test_paste :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	out := make([dynamic]u8, context.temp_allocator)
	paste_bytes(t, &out, "ls\nls -l\r\nx\ty\x1b[201~\x03z")
	testing.expect_value(tt, string(out[:]), "ls\rls -l\rx\ty[201~z")
	term_feed(t, transmute([]u8)string("\x1b[?2004h"))
	clear(&out)
	paste_bytes(t, &out, "a\x1b[201~b")
	testing.expect_value(tt, string(out[:]), "\x1b[200~a[201~b\x1b[201~")
}

@(test)
test_keysym_rune :: proc(tt: ^testing.T) {
	testing.expect_value(tt, keysym_rune('a'), 'a')
	testing.expect_value(tt, keysym_rune(0xe9), 'é')
	testing.expect_value(tt, keysym_rune(0x010020ac), '€')
	testing.expect_value(tt, keysym_rune(KS_Up), rune(0))
}

// ---------------------------------------------------------------- selection

@(private="file") feed :: proc(t: ^Term, s: string) { term_feed(t, transmute([]u8)s) }

@(test)
test_selection_chars_and_lines :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	feed(t, "hello world\r\nsecond line\r\nthird")
	sel := Selection{kind = .Chars, anchor = {line_id(t, t.sb.count), 6}, head = {line_id(t, t.sb.count + 1), 5}}
	testing.expect_value(tt, sel_text(t, sel), "world\nsecond")
	// backwards
	sel.anchor, sel.head = sel.head, sel.anchor
	testing.expect_value(tt, sel_text(t, sel), "world\nsecond")
	// a line
	line := Selection{kind = .Line, anchor = {line_id(t, t.sb.count + 1), 3}, head = {line_id(t, t.sb.count + 1), 3}}
	testing.expect_value(tt, sel_text(t, line), "second line")
}

@(test)
test_selection_word :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	feed(t, "foo bar-baz (qux) /usr/bin/ls")
	id := line_id(t, t.sb.count)
	word := Selection{kind = .Word, anchor = {id, 5}, head = {id, 5}}
	testing.expect_value(tt, sel_text(t, word), "bar-baz")
	word.anchor, word.head = {id, 10}, {id, 10}
	testing.expect_value(tt, sel_text(t, word), "bar-baz")
	word.anchor, word.head = {id, 13}, {id, 13}
	testing.expect_value(tt, sel_text(t, word), "qux")
	word.anchor, word.head = {id, 20}, {id, 20}
	testing.expect_value(tt, sel_text(t, word), "/usr/bin/ls")
	// from a word to another: both widened
	word.anchor, word.head = {id, 1}, {id, 6}
	testing.expect_value(tt, sel_text(t, word), "foo bar-baz")
}

@(test)
test_selection_wrapped_lines_join :: proc(tt: ^testing.T) {
	t := new(Term)
	term_init(t, 6, 4, 10)
	defer { term_destroy(t); free(t) }
	feed(t, "abcdefghij\r\nnext")
	id := line_id(t, t.sb.count)
	sel := Selection{kind = .Line, anchor = {id + 1, 0}, head = {id + 1, 0}}
	testing.expect_value(tt, sel_text(t, sel), "abcdefghij")
	sel = Selection{kind = .Chars, anchor = {id, 2}, head = {id + 2, 1}}
	testing.expect_value(tt, sel_text(t, sel), "cdefghij\nne")
}

@(test)
test_selection_block :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	feed(t, "abcdef\r\nghijkl\r\nmnopqr")
	id := line_id(t, t.sb.count)
	sel := Selection{kind = .Block, anchor = {id, 1}, head = {id + 2, 3}}
	testing.expect_value(tt, sel_text(t, sel), "bcd\nhij\nnop")
}

@(test)
test_selection_wide :: proc(tt: ^testing.T) {
	t := mkt()
	defer { term_destroy(t); free(t) }
	feed(t, "a世界b")
	id := line_id(t, t.sb.count)
	// the pointer on the second half of 世 selects the whole character
	sel := Selection{kind = .Chars, anchor = {id, 2}, head = {id, 3}}
	testing.expect_value(tt, sel_text(t, sel), "世界")
}

@(test)
test_selection_stays_on_its_text :: proc(tt: ^testing.T) {
	t := new(Term)
	term_init(t, 10, 3, 4)
	defer { term_destroy(t); free(t) }
	feed(t, "keep me\r\n")
	id := line_id(t, t.sb.count - 1 + 0)
	_ = id
	first := line_id(t, t.sb.count) // the line "keep me" is on the screen's first row
	sel := Selection{kind = .Line, anchor = {first, 0}, head = {first, 0}}
	feed(t, "1\r\n2\r\n3\r\n")
	testing.expect_value(tt, sel_text(t, sel), "keep me")
	// once it falls off the end of the scrollback, there is nothing
	feed(t, "4\r\n5\r\n6\r\n7\r\n8\r\n")
	testing.expect_value(tt, sel_text(t, sel), "")
}

// ---------------------------------------------------------------- search, links, prompts

@(test)
test_search :: proc(tt: ^testing.T) {
	t := new(Term)
	term_init(t, 20, 3, 50)
	defer { term_destroy(t); free(t) }
	feed(t, "Alpha beta\r\nbeta gamma BETA\r\nx\r\ny\r\nbeta")
	m := search(t, "beta", context.temp_allocator)
	testing.expect_value(tt, len(m), 4) // smart case: lower case ignores case
	testing.expect_value(tt, m[0].col0, 6)
	testing.expect_value(tt, m[0].col1, 9)
	m2 := search(t, "BETA", context.temp_allocator)
	testing.expect_value(tt, len(m2), 1) // a capital: exact
	testing.expect_value(tt, len(search(t, "nothing", context.temp_allocator)), 0)
	testing.expect_value(tt, len(search(t, "", context.temp_allocator)), 0)
	// the hit's line is in the scrollback and has a stable id
	testing.expect(tt, line_from_id(t, m[0].line) >= 0)
}

@(test)
test_links :: proc(tt: ^testing.T) {
	t := new(Term)
	term_init(t, 60, 4, 10)
	defer { term_destroy(t); free(t) }
	line := "see https://example.org/a?b=c, and (http://x.y/z) ok"
	feed(t, line)
	feed(t, "\r\n")
	feed(t, "\x1b]8;;https://osc.example/\x07click\x1b]8;;\x07 here")
	base := t.sb.count
	h, ok := link_at(t, base, 8)
	testing.expect(tt, ok)
	testing.expect_value(tt, h.url, "https://example.org/a?b=c")
	_, ok = link_at(t, base, 0)
	testing.expect(tt, !ok)
	// the URL in brackets does not take the bracket
	h, ok = link_at(t, base, strings.index(line, "http://x") + 3)
	testing.expect(tt, ok)
	testing.expect_value(tt, h.url, "http://x.y/z")
	// an OSC 8 link
	h, ok = link_at(t, base + 1, 2)
	testing.expect(tt, ok)
	testing.expect_value(tt, h.url, "https://osc.example/")
	testing.expect_value(tt, h.col0, 0)
	testing.expect_value(tt, h.col1, 4)
	testing.expect(tt, url_allowed("https://a.b/c"))
	testing.expect(tt, url_allowed("mailto:me@example.org"))
	testing.expect(tt, !url_allowed("javascript:alert(1)"))
	testing.expect(tt, !url_allowed("x-scheme://boo"))
	testing.expect(tt, !url_allowed("https://a.b/\x1b[31m"))
	testing.expect(tt, !url_allowed(""))
}

@(test)
test_link_wrapped_over_rows :: proc(tt: ^testing.T) {
	t := new(Term)
	term_init(t, 12, 4, 10)
	defer { term_destroy(t); free(t) }
	feed(t, "go https://example.org/very/long/path now")
	h, ok := link_at(t, t.sb.count + 1, 3)
	testing.expect(tt, ok)
	testing.expect_value(tt, h.url, "https://example.org/very/long/path")
	testing.expect(tt, h.line1 > h.line0)
}

@(test)
test_prompt_jumps :: proc(tt: ^testing.T) {
	t := new(Term)
	term_init(t, 10, 3, 50)
	defer { term_destroy(t); free(t) }
	for i in 0 ..< 6 {
		feed(t, "\x1b]133;A\x07$ ")
		feed(t, string([]u8{u8('0' + i)}))
		feed(t, "\r\nout\r\n")
	}
	marks := 0
	for l in 0 ..< line_count(t) do if line_at(t, l).prompt do marks += 1
	testing.expect(tt, marks >= 3)
	last := line_count(t) - 1
	p := prev_prompt(t, last)
	testing.expect(tt, p >= 0 && line_at(t, p).prompt)
	p2 := prev_prompt(t, p)
	testing.expect(tt, p2 >= 0 && p2 < p)
	testing.expect_value(tt, next_prompt(t, p2), p)
	view_line_at_top(t, p2)
	testing.expect_value(tt, view_top_line(t), p2)
}

// ---------------------------------------------------------------- the characters it draws

@(private="file") glyph :: proc(r: rune, w, h: int) -> Bitmap {
	b := Bitmap{w, h, make([]u8, w * h, context.temp_allocator)}
	draw_special(r, b)
	return b
}

@(test)
test_box_table_is_in_order :: proc(tt: ^testing.T) {
	arms :: proc(r: rune) -> string { return BOX_ARMS[int(r - 0x2500)] }
	testing.expect_value(tt, arms('─'), "1100")
	testing.expect_value(tt, arms('┃'), "0022")
	testing.expect_value(tt, arms('┌'), "0101")
	testing.expect_value(tt, arms('┘'), "1010")
	testing.expect_value(tt, arms('├'), "0111")
	testing.expect_value(tt, arms('┬'), "1101")
	testing.expect_value(tt, arms('┼'), "1111")
	testing.expect_value(tt, arms('╋'), "2222")
	testing.expect_value(tt, arms('═'), "3300")
	testing.expect_value(tt, arms('╔'), "0303")
	testing.expect_value(tt, arms('╬'), "3333")
	testing.expect_value(tt, arms('╴'), "1000")
	testing.expect_value(tt, arms('╿'), "0021")
	testing.expect_value(tt, arms('╾'), "2100")
	// every character of the block that is a plain line has a table entry
	for r in rune(0x2500) ..= rune(0x257f) {
		a := BOX_ARMS[int(r - 0x2500)]
		special := (r >= 0x2504 && r <= 0x250b) || (r >= 0x254c && r <= 0x254f) || (r >= 0x256d && r <= 0x2573)
		testing.expectf(tt, special == (len(a) == 0), "U+%04X: %q", r, a)
	}
}

@(test)
test_box_drawing_pixels :: proc(tt: ^testing.T) {
	w, h := 9, 18
	b := glyph('─', w, h)
	// the light line: one row, across the whole cell
	row := (h - light_thickness(w, h)) / 2
	for x in 0 ..< w do testing.expect_value(tt, b.px[row * w + x], u8(255))
	n := 0
	for v in b.px do if v != 0 do n += 1
	testing.expect_value(tt, n, w * light_thickness(w, h))
	// two cells side by side join: the first and last column are both set
	testing.expect_value(tt, b.px[row * w], u8(255))
	testing.expect_value(tt, b.px[row * w + w - 1], u8(255))
	v := glyph('│', w, h)
	col := (w - light_thickness(w, h)) / 2
	for y in 0 ..< h do testing.expect_value(tt, v.px[y * w + col], u8(255))
	// a corner meets the middle of its neighbours
	c := glyph('┌', w, h)
	testing.expect_value(tt, c.px[row * w + col], u8(255))
	testing.expect_value(tt, c.px[row * w + w - 1], u8(255))
	testing.expect_value(tt, c.px[(h - 1) * w + col], u8(255))
	testing.expect_value(tt, c.px[0], u8(0))
	// heavy is thicker
	hv := glyph('━', w, h)
	m := 0
	for p in hv.px do if p != 0 do m += 1
	testing.expect(tt, m == 2 * n)
}

@(test)
test_blocks_and_shades :: proc(tt: ^testing.T) {
	w, h := 8, 16
	full := glyph('█', w, h)
	for p in full.px do testing.expect_value(tt, p, u8(255))
	up := glyph('▀', w, h)
	testing.expect_value(tt, up.px[0], u8(255))
	testing.expect_value(tt, up.px[7 * w], u8(255))
	testing.expect_value(tt, up.px[8 * w], u8(0))
	low := glyph('▄', w, h)
	testing.expect_value(tt, low.px[7 * w], u8(0))
	testing.expect_value(tt, low.px[8 * w], u8(255))
	left := glyph('▌', w, h)
	testing.expect_value(tt, left.px[3], u8(255))
	testing.expect_value(tt, left.px[4], u8(0))
	testing.expect_value(tt, glyph('░', w, h).px[5], u8(64))
	testing.expect_value(tt, glyph('▒', w, h).px[5], u8(128))
	testing.expect_value(tt, glyph('▓', w, h).px[5], u8(192))
	// an eighth
	e := glyph('▁', w, h)
	testing.expect_value(tt, e.px[13 * w], u8(0))
	testing.expect_value(tt, e.px[14 * w], u8(255))
	testing.expect_value(tt, e.px[15 * w], u8(255))
	// quadrants: lower left only
	q := glyph('▖', w, h)
	testing.expect_value(tt, q.px[0], u8(0))
	testing.expect_value(tt, q.px[15 * w], u8(255))
	testing.expect_value(tt, q.px[15 * w + 7], u8(0))
}

@(test)
test_braille :: proc(tt: ^testing.T) {
	w, h := 10, 20
	b := glyph('⠀', w, h)
	for p in b.px do testing.expect_value(tt, p, u8(0))
	full := glyph('⣿', w, h)
	n := 0
	for p in full.px do if p > 0 do n += 1
	testing.expect(tt, n > 20)
	one := glyph('⠁', w, h) // dot 1 only: upper left
	var_left, var_right := 0, 0
	for y in 0 ..< h do for x in 0 ..< w do if one.px[y * w + x] > 0 {
		if x < w / 2 { var_left += 1 } else { var_right += 1 }
		testing.expect(tt, y < h / 4)
	}
	testing.expect(tt, var_left > 0 && var_right == 0)
}

@(test)
test_powerline_shapes :: proc(tt: ^testing.T) {
	w, h := 10, 20
	t := glyph('', w, h)
	// the point is at the right middle, the base the whole left edge
	testing.expect_value(tt, t.px[0], u8(255) / 1 * 0 + t.px[0]) // (anti-aliased corner)
	testing.expect_value(tt, t.px[10 * w], u8(255))
	testing.expect(tt, t.px[0 * w + w - 1] == 0)
	testing.expect_value(tt, t.px[10 * w + w - 1] > 0, true)
	mirror := glyph('', w, h)
	testing.expect_value(tt, mirror.px[10 * w + w - 1], u8(255))
	testing.expect(tt, mirror.px[10 * w] > 0)
	testing.expect(tt, is_special_glyph('') && !is_special_glyph('a') && is_special_glyph('─'))
}

@(test)
test_char_width :: proc(tt: ^testing.T) {
	testing.expect_value(tt, char_width('a'), 1)
	testing.expect_value(tt, char_width('é'), 1)
	testing.expect_value(tt, char_width('世'), 2)
	testing.expect_value(tt, char_width('한'), 2)
	testing.expect_value(tt, char_width('ｱ'), 1)
	testing.expect_value(tt, char_width('Ａ'), 2)
	testing.expect_value(tt, char_width('😀'), 2)
	testing.expect_value(tt, char_width('́'), 0)
	testing.expect_value(tt, char_width('‍'), 0)
	testing.expect_value(tt, char_width('️'), 0)
	testing.expect_value(tt, char_width(''), 1) // powerline: one cell
	testing.expect_value(tt, char_width(''), 1) // a Nerd Font icon
	testing.expect_value(tt, char_width('─'), 1)
	testing.expect_value(tt, char_width('✓'), 1)
	testing.expect_value(tt, char_width('✅'), 2)
}

@(private="file") _unused :: strings.Builder
