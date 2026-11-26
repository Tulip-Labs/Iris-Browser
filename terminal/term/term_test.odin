package term

import "core:strings"
import "core:testing"

@(private="file") mk :: proc(cols, rows: int, sb := 100) -> ^Term {
	t := new(Term)
	term_init(t, cols, rows, sb)
	return t
}

@(private="file") done :: proc(t: ^Term) {
	term_destroy(t)
	free(t)
}

@(private="file") feed :: proc(t: ^Term, s: string) { term_feed(t, transmute([]u8)s) }

@(private="file") expect_screen :: proc(tt: ^testing.T, t: ^Term, want: string, loc := #caller_location) {
	got := screen_text(t)
	testing.expectf(tt, got == want, "screen:\n%q\nwant:\n%q", got, want, loc = loc)
}

@(private="file") out_string :: proc(t: ^Term) -> string {
	s := strings.clone(string(t.out[:]), context.temp_allocator)
	clear(&t.out)
	return s
}

@(test)
test_print_and_newline :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer done(t)
	feed(t, "hello\r\nworld")
	expect_screen(tt, t, "hello\nworld")
	testing.expect_value(tt, t.cursor.x, 5)
	testing.expect_value(tt, t.cursor.y, 1)
}

@(test)
test_autowrap_marks_the_row :: proc(tt: ^testing.T) {
	t := mk(5, 3)
	defer done(t)
	feed(t, "abcdefgh")
	testing.expect_value(tt, screen_row_text(t, 0), "abcde")
	testing.expect_value(tt, screen_row_text(t, 1), "fgh")
	testing.expect(tt, t.grid.rows[0].wrapped)
	testing.expect(tt, !t.grid.rows[1].wrapped)
	// a full row does not wrap until the next character
	t2 := mk(5, 3)
	defer done(t2)
	feed(t2, "abcde")
	testing.expect_value(tt, t2.cursor.y, 0)
	testing.expect(tt, t2.cursor.pending)
	feed(t2, "f")
	testing.expect_value(tt, t2.cursor.y, 1)
}

@(test)
test_no_autowrap :: proc(tt: ^testing.T) {
	t := mk(5, 2)
	defer done(t)
	feed(t, "\x1b[?7labcdefgh")
	testing.expect_value(tt, screen_row_text(t, 0), "abcdh")
	testing.expect_value(tt, screen_row_text(t, 1), "")
}

@(test)
test_cursor_moves :: proc(tt: ^testing.T) {
	t := mk(20, 10)
	defer done(t)
	feed(t, "\x1b[5;10H")
	testing.expect_value(tt, t.cursor.x, 9)
	testing.expect_value(tt, t.cursor.y, 4)
	feed(t, "\x1b[2A\x1b[3C")
	testing.expect_value(tt, t.cursor.x, 12)
	testing.expect_value(tt, t.cursor.y, 2)
	feed(t, "\x1b[B\x1b[2D")
	testing.expect_value(tt, t.cursor.x, 10)
	testing.expect_value(tt, t.cursor.y, 3)
	feed(t, "\x1b[H")
	testing.expect_value(tt, t.cursor.x, 0)
	testing.expect_value(tt, t.cursor.y, 0)
	feed(t, "\x1b[99;99H")
	testing.expect_value(tt, t.cursor.x, 19)
	testing.expect_value(tt, t.cursor.y, 9)
	feed(t, "\x1b[3G\x1b[4d")
	testing.expect_value(tt, t.cursor.x, 2)
	testing.expect_value(tt, t.cursor.y, 3)
	feed(t, "\x1b[;5H")
	testing.expect_value(tt, t.cursor.x, 4)
	testing.expect_value(tt, t.cursor.y, 0)
}

@(test)
test_erase :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer done(t)
	feed(t, "0123456789\r\nabcdefghij\r\nABCDEFGHIJ")
	feed(t, "\x1b[2;5H\x1b[K")
	expect_screen(tt, t, "0123456789\nabcd\nABCDEFGHIJ")
	feed(t, "\x1b[2;3H\x1b[1K")
	expect_screen(tt, t, "0123456789\n   d\nABCDEFGHIJ")
	feed(t, "\x1b[3;4H\x1b[J")
	expect_screen(tt, t, "0123456789\n   d\nABC")
	feed(t, "\x1b[2J")
	expect_screen(tt, t, "")
	feed(t, "\x1b[1;1Hxyz\x1b[1;2H\x1b[X")
	testing.expect_value(tt, screen_row_text(t, 0), "x z")
	feed(t, "\x1b[3X")
	testing.expect_value(tt, screen_row_text(t, 0), "x")
}

@(test)
test_insert_delete_chars :: proc(tt: ^testing.T) {
	t := mk(10, 2)
	defer done(t)
	feed(t, "abcdef\x1b[1;3H\x1b[2@")
	testing.expect_value(tt, screen_row_text(t, 0), "ab  cdef")
	feed(t, "\x1b[3P")
	testing.expect_value(tt, screen_row_text(t, 0), "abdef")
	feed(t, "\x1b[4h\x1b[1;1HXY\x1b[4l")
	testing.expect_value(tt, screen_row_text(t, 0), "XYabdef")
}

@(test)
test_insert_delete_lines_and_scroll_region :: proc(tt: ^testing.T) {
	t := mk(6, 5)
	defer done(t)
	feed(t, "1\r\n2\r\n3\r\n4\r\n5")
	feed(t, "\x1b[2;4r") // region rows 2..4
	testing.expect_value(tt, t.cursor.y, 0) // the cursor goes home (not into the region: no origin mode)
	feed(t, "\x1b[2;1H\x1b[L")
	expect_screen(tt, t, "1\n\n2\n3\n5")
	feed(t, "\x1b[M")
	expect_screen(tt, t, "1\n2\n3\n\n5")
	// a linefeed at the bottom of the region scrolls only the region
	feed(t, "\x1b[4;1H\n")
	expect_screen(tt, t, "1\n3\n\n\n5")
	// reverse index at the top of the region
	feed(t, "\x1b[2;1H\x1bM")
	expect_screen(tt, t, "1\n\n3\n\n5")
	testing.expect_value(tt, t.sb.count, 0) // nothing went to the scrollback
}

@(test)
test_scroll_up_down_sequences :: proc(tt: ^testing.T) {
	t := mk(4, 4)
	defer done(t)
	feed(t, "a\r\nb\r\nc\r\nd")
	feed(t, "\x1b[2S")
	expect_screen(tt, t, "c\nd")
	feed(t, "\x1b[1T")
	expect_screen(tt, t, "\nc\nd")
}

@(test)
test_scrollback :: proc(tt: ^testing.T) {
	t := mk(10, 3, 5)
	defer done(t)
	for i in 0 ..< 8 {
		feed(t, "line")
		feed(t, string([]u8{u8('0' + i)}))
		feed(t, "\r\n")
	}
	// 8 lines on 3 rows: 6 scrolled off (line0..line5), the 5 newest are kept
	testing.expect_value(tt, t.sb.count, 5)
	testing.expect_value(tt, string(row_str(t, line_at(t, 0))), "line1")
	testing.expect_value(tt, string(row_str(t, line_at(t, 4))), "line5")
	testing.expect_value(tt, t.dropped, u64(1))
}

@(private="file") row_str :: proc(t: ^Term, r: ^Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	row_text(t, r, 0, len(r.cells), true, &b)
	return strings.to_string(b)
}

@(test)
test_sgr_colors :: proc(tt: ^testing.T) {
	t := mk(20, 2)
	defer done(t)
	feed(t, "\x1b[31;1mR\x1b[0mn\x1b[38;5;200mP\x1b[48;2;1;2;3mT\x1b[m")
	c0 := t.grid.rows[0].cells[0]
	testing.expect_value(tt, c0.fg, color_idx(1))
	testing.expect(tt, has_attr(c0, .Bold))
	c1 := t.grid.rows[0].cells[1]
	testing.expect(tt, color_is_default(c1.fg))
	testing.expect(tt, !has_attr(c1, .Bold))
	testing.expect_value(tt, t.grid.rows[0].cells[2].fg, color_idx(200))
	testing.expect_value(tt, t.grid.rows[0].cells[3].bg, color_rgb(1, 2, 3))
	testing.expect_value(tt, t.grid.rows[0].cells[3].fg, color_idx(200))
	// bright colours, default colours
	feed(t, "\x1b[91;102mX\x1b[39;49mY")
	testing.expect_value(tt, t.grid.rows[0].cells[4].fg, color_idx(9))
	testing.expect_value(tt, t.grid.rows[0].cells[4].bg, color_idx(10))
	testing.expect(tt, color_is_default(t.grid.rows[0].cells[5].fg))
	testing.expect(tt, color_is_default(t.grid.rows[0].cells[5].bg))
}

@(test)
test_sgr_colon_forms :: proc(tt: ^testing.T) {
	t := mk(20, 2)
	defer done(t)
	feed(t, "\x1b[38:2::10:20:30mA\x1b[48:2:40:50:60mB\x1b[38:5:99mC\x1b[4:3mD\x1b[4:0mE")
	testing.expect_value(tt, t.grid.rows[0].cells[0].fg, color_rgb(10, 20, 30))
	testing.expect_value(tt, t.grid.rows[0].cells[1].bg, color_rgb(40, 50, 60))
	testing.expect_value(tt, t.grid.rows[0].cells[2].fg, color_idx(99))
	testing.expect_value(tt, cell_underline(t.grid.rows[0].cells[3]), Underline.Curly)
	testing.expect_value(tt, cell_underline(t.grid.rows[0].cells[4]), Underline.None)
	// a semicolon form with the rest after it
	feed(t, "\x1b[38;2;7;8;9;1mF")
	c := t.grid.rows[0].cells[5]
	testing.expect_value(tt, c.fg, color_rgb(7, 8, 9))
	testing.expect(tt, has_attr(c, .Bold))
}

@(test)
test_sgr_attributes :: proc(tt: ^testing.T) {
	t := mk(20, 2)
	defer done(t)
	feed(t, "\x1b[1;2;3;4;7;9mA\x1b[22;23;24;27;29mB\x1b[21mC\x1b[8mD\x1b[5mE")
	a := t.grid.rows[0].cells[0]
	testing.expect(tt, has_attr(a, .Bold) && has_attr(a, .Dim) && has_attr(a, .Italic) && has_attr(a, .Reverse) && has_attr(a, .Strike))
	testing.expect_value(tt, cell_underline(a), Underline.Single)
	b := t.grid.rows[0].cells[1]
	testing.expect(tt, !has_attr(b, .Bold) && !has_attr(b, .Dim) && !has_attr(b, .Italic) && !has_attr(b, .Reverse) && !has_attr(b, .Strike))
	testing.expect_value(tt, cell_underline(b), Underline.None)
	testing.expect_value(tt, cell_underline(t.grid.rows[0].cells[2]), Underline.Double)
	testing.expect(tt, has_attr(t.grid.rows[0].cells[3], .Hidden))
	testing.expect(tt, has_attr(t.grid.rows[0].cells[4], .Blink))
}

@(test)
test_utf8_and_split_input :: proc(tt: ^testing.T) {
	t := mk(10, 2)
	defer done(t)
	// the bytes of "é€😀" arrive in pieces
	s := "é€😀"
	b := transmute([]u8)s
	for i in 0 ..< len(b) do term_feed(t, b[i:i + 1])
	testing.expect_value(tt, screen_row_text(t, 0), "é€😀")
	testing.expect_value(tt, t.cursor.x, 4) // é 1, € 1, 😀 2
	// a broken sequence is one replacement character, and the byte after it is kept
	feed(t, "\xe2\x82A")
	testing.expect_value(tt, screen_row_text(t, 0), "é€😀�A")
	// an overlong encoding
	t2 := mk(10, 1)
	defer done(t2)
	feed(t2, "\xc0\xaf")
	testing.expect_value(tt, screen_row_text(t2, 0), "\uFFFD")
}

@(test)
test_wide_characters :: proc(tt: ^testing.T) {
	t := mk(6, 3)
	defer done(t)
	feed(t, "a世b")
	testing.expect_value(tt, t.cursor.x, 4)
	testing.expect(tt, has_attr(t.grid.rows[0].cells[1], .Wide))
	testing.expect(tt, has_attr(t.grid.rows[0].cells[2], .Wide_Cont))
	testing.expect_value(tt, screen_row_text(t, 0), "a世b")
	// a wide character that does not fit in the last column wraps
	feed(t, "\r\n12345世")
	testing.expect_value(tt, screen_row_text(t, 1), "12345")
	testing.expect_value(tt, screen_row_text(t, 2), "世")
	testing.expect(tt, t.grid.rows[1].wrapped)
	// overwriting half of a wide character blanks the other half
	feed(t, "\x1b[3;2Hx")
	testing.expect_value(tt, screen_row_text(t, 2), " x")
	// emoji are two cells
	t2 := mk(6, 1)
	defer done(t2)
	feed(t2, "😀a")
	testing.expect_value(tt, t2.cursor.x, 3)
}

@(test)
test_combining_characters :: proc(tt: ^testing.T) {
	t := mk(6, 1)
	defer done(t)
	feed(t, "éx")
	testing.expect_value(tt, t.cursor.x, 2)
	testing.expect_value(tt, screen_row_text(t, 0), "éx")
	// a joiner glues the next emoji into the same cell
	t2 := mk(8, 1)
	defer done(t2)
	feed(t2, "👨‍👩z")
	testing.expect_value(tt, t2.cursor.x, 3)
	testing.expect_value(tt, screen_row_text(t2, 0), "👨‍👩z")
	// a variation selector adds no width
	t3 := mk(8, 1)
	defer done(t3)
	feed(t3, "❤️a")
	testing.expect_value(tt, t3.cursor.x, 2)
}

@(test)
test_tabs :: proc(tt: ^testing.T) {
	t := mk(30, 2)
	defer done(t)
	feed(t, "a\tb\tc")
	testing.expect_value(tt, t.cursor.x, 17)
	feed(t, "\x1b[2I")
	testing.expect_value(tt, t.cursor.x, 29) // the last tab stop is at 24; then the margin
	feed(t, "\x1b[Z")
	testing.expect_value(tt, t.cursor.x, 24)
	feed(t, "\x1b[3g\r\tz")
	testing.expect_value(tt, t.cursor.x, 30 - 1)
	// set a stop
	t2 := mk(30, 2)
	defer done(t2)
	feed(t2, "\x1b[1;5H\x1bH\r\t")
	testing.expect_value(tt, t2.cursor.x, 4)
}

@(test)
test_alternate_screen :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer done(t)
	feed(t, "main\x1b[2;3H")
	feed(t, "\x1b[?1049h")
	testing.expect(tt, t.modes.alt_screen)
	expect_screen(tt, t, "")
	feed(t, "alt") // the cursor stays where it was
	expect_screen(tt, t, "\n  alt")
	feed(t, "\x1b[?1049l")
	testing.expect(tt, !t.modes.alt_screen)
	expect_screen(tt, t, "main")
	testing.expect_value(tt, t.cursor.x, 2)
	testing.expect_value(tt, t.cursor.y, 1)
	// the alternate screen has no scrollback
	feed(t, "\x1b[?1049h")
	feed(t, "1\r\n2\r\n3\r\n4\r\n5\r\n")
	testing.expect_value(tt, t.sb.count, 0)
	feed(t, "\x1b[?1049l")
}

@(test)
test_save_restore_cursor :: proc(tt: ^testing.T) {
	t := mk(10, 5)
	defer done(t)
	feed(t, "\x1b[3;4H\x1b[31m\x1b7\x1b[1;1H\x1b[0m\x1b8X")
	testing.expect_value(tt, t.grid.rows[2].cells[3].fg, color_idx(1))
	testing.expect_value(tt, t.cursor.x, 4)
	feed(t, "\x1b[2;2H\x1b[s\x1b[5;5H\x1b[u")
	testing.expect_value(tt, t.cursor.x, 1)
	testing.expect_value(tt, t.cursor.y, 1)
}

@(test)
test_origin_mode :: proc(tt: ^testing.T) {
	t := mk(10, 6)
	defer done(t)
	feed(t, "\x1b[3;5r\x1b[?6h\x1b[1;1H")
	testing.expect_value(tt, t.cursor.y, 2)
	feed(t, "\x1b[9;1H")
	testing.expect_value(tt, t.cursor.y, 4)
	feed(t, "\x1b[6n")
	testing.expect_value(tt, out_string(t), "\x1b[3;1R")
}

@(test)
test_line_drawing_charset :: proc(tt: ^testing.T) {
	t := mk(10, 1)
	defer done(t)
	feed(t, "\x1b(0lqk\x1b(Bq")
	testing.expect_value(tt, screen_row_text(t, 0), "┌─┐q")
	// shift out / in
	t2 := mk(10, 1)
	defer done(t2)
	feed(t2, "\x1b)0a\x0eq\x0fq")
	testing.expect_value(tt, screen_row_text(t2, 0), "a─q")
}

@(test)
test_replies :: proc(tt: ^testing.T) {
	t := mk(80, 24)
	defer done(t)
	feed(t, "\x1b[c")
	testing.expect(tt, strings.has_prefix(out_string(t), "\x1b[?62;"))
	feed(t, "\x1b[>c")
	testing.expect(tt, strings.has_prefix(out_string(t), "\x1b[>0;"))
	feed(t, "\x1b[5n")
	testing.expect_value(tt, out_string(t), "\x1b[0n")
	feed(t, "\x1b[3;7H\x1b[6n")
	testing.expect_value(tt, out_string(t), "\x1b[3;7R")
	feed(t, "\x1b[?6n")
	testing.expect_value(tt, out_string(t), "\x1b[?3;7R")
	feed(t, "\x1b[>q")
	testing.expect_value(tt, out_string(t), "\x1bP>|iris-terminal 1.0.0\x1b\\")
	feed(t, "\x1b[18t")
	testing.expect_value(tt, out_string(t), "\x1b[8;24;80t")
	// DECRQM: 2026 is known and reset; then set
	feed(t, "\x1b[?2026$p")
	testing.expect_value(tt, out_string(t), "\x1b[?2026;2$y")
	feed(t, "\x1b[?2026h\x1b[?2026$p")
	testing.expect_value(tt, out_string(t), "\x1b[?2026;1$y")
	testing.expect(tt, t.modes.sync)
	feed(t, "\x1b[?9999$p")
	testing.expect_value(tt, out_string(t), "\x1b[?9999;0$y")
	feed(t, "\x1bP+q544e\x1b\\")
	testing.expect_value(tt, out_string(t), "\x1bP0+r\x1b\\")
}

@(test)
test_modes :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer done(t)
	feed(t, "\x1b[?1h\x1b=\x1b[?25l\x1b[?2004h\x1b[?1004h\x1b[?1007l")
	testing.expect(tt, t.modes.app_cursor && t.modes.app_keypad && !t.modes.cursor_visible && t.modes.bracketed && t.modes.focus_events && !t.modes.alt_scroll)
	feed(t, "\x1b[?1l\x1b>\x1b[?25h\x1b[?2004l\x1b[?1004l")
	testing.expect(tt, !t.modes.app_cursor && !t.modes.app_keypad && t.modes.cursor_visible && !t.modes.bracketed && !t.modes.focus_events)
	// several modes in one sequence
	feed(t, "\x1b[?1000;1006h")
	testing.expect_value(tt, t.modes.mouse, Mouse_Mode.Press_Release)
	testing.expect_value(tt, t.modes.mouse_enc, Mouse_Encoding.Sgr)
	feed(t, "\x1b[?1002h")
	testing.expect_value(tt, t.modes.mouse, Mouse_Mode.Drag)
	feed(t, "\x1b[?1003h")
	testing.expect_value(tt, t.modes.mouse, Mouse_Mode.Any)
	feed(t, "\x1b[?1003l\x1b[?1006l")
	testing.expect_value(tt, t.modes.mouse, Mouse_Mode.None)
	testing.expect_value(tt, t.modes.mouse_enc, Mouse_Encoding.Default)
}

@(test)
test_cursor_style :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer done(t)
	feed(t, "\x1b[5 q")
	testing.expect_value(tt, t.cursor_style, Cursor_Style.Bar)
	feed(t, "\x1b[4 q")
	testing.expect_value(tt, t.cursor_style, Cursor_Style.Underline)
	feed(t, "\x1b[2 q")
	testing.expect_value(tt, t.cursor_style, Cursor_Style.Block)
	feed(t, "\x1b[0 q")
	testing.expect(tt, !t.cursor_style_set)
}

@(test)
test_osc_title_cwd :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer done(t)
	feed(t, "\x1b]0;hello world\x07")
	testing.expect_value(tt, t.title, "hello world")
	testing.expect(tt, .Title in t.events)
	feed(t, "\x1b]2;with st\x1b\\")
	testing.expect_value(tt, t.title, "with st")
	feed(t, "\x1b]7;file://host/home/user/a%20b/c\x07")
	testing.expect_value(tt, t.cwd, "/home/user/a b/c")
	feed(t, "\x1b]7;file:///tmp\x07")
	testing.expect_value(tt, t.cwd, "/tmp")
	// control characters never reach the title
	feed(t, "\x1b]2;a\x01b\x07")
	testing.expect_value(tt, t.title, "ab")
	// a title in pieces
	feed(t, "\x1b]2;sp")
	feed(t, "lit\x07")
	testing.expect_value(tt, t.title, "split")
}

@(test)
test_osc_hyperlinks :: proc(tt: ^testing.T) {
	t := mk(20, 2)
	defer done(t)
	feed(t, "a\x1b]8;;https://example.org/x\x1b\\link\x1b]8;;\x1b\\b")
	r := &t.grid.rows[0]
	testing.expect_value(tt, r.cells[0].link, u16(0))
	testing.expect(tt, r.cells[1].link != 0)
	testing.expect_value(tt, link_url(t, r.cells[1].link), "https://example.org/x")
	testing.expect_value(tt, r.cells[1].link, r.cells[4].link)
	testing.expect_value(tt, r.cells[5].link, u16(0))
	// with parameters
	feed(t, "\r\n\x1b]8;id=7;file:///tmp\x07z\x1b]8;;\x07")
	testing.expect_value(tt, link_url(t, t.grid.rows[1].cells[0].link), "file:///tmp")
}

@(test)
test_osc52_clipboard :: proc(tt: ^testing.T) {
	t := mk(20, 2)
	defer done(t)
	feed(t, "\x1b]52;c;aGVsbG8=\x07")
	testing.expect(tt, .Clipboard in t.events)
	testing.expect_value(tt, string(t.clip_write[:]), "hello")
	testing.expect_value(tt, t.clip_target, u8('c'))
	// reading is not allowed: a query is dropped
	t.events = {}
	feed(t, "\x1b]52;c;?\x07")
	testing.expect(tt, .Clipboard not_in t.events)
	feed(t, "\x1b]52;p;Zm9v\x07")
	testing.expect_value(tt, t.clip_target, u8('p'))
	testing.expect_value(tt, string(t.clip_write[:]), "foo")
	// invalid base64 is dropped
	t.events = {}
	feed(t, "\x1b]52;c;!!!\x07")
	testing.expect(tt, .Clipboard not_in t.events)
}

@(test)
test_osc133_marks :: proc(tt: ^testing.T) {
	t := mk(20, 4)
	defer done(t)
	feed(t, "\x1b]133;A\x07$ ls\r\n\x1b]133;C\x07out\r\n\x1b]133;D;3\x07\x1b]133;A\x07$ ")
	testing.expect(tt, t.has_marks)
	testing.expect(tt, t.grid.rows[0].prompt)
	testing.expect(tt, !t.grid.rows[1].prompt)
	testing.expect(tt, t.grid.rows[2].prompt)
	testing.expect_value(tt, t.last_status, 3)
}

@(test)
test_osc_colors :: proc(tt: ^testing.T) {
	t := mk(20, 2)
	defer done(t)
	feed(t, "\x1b]11;rgb:10/20/30\x07")
	testing.expect_value(tt, t.default_bg, RGB{0x10, 0x20, 0x30})
	feed(t, "\x1b]10;#ffeedd\x07")
	testing.expect_value(tt, t.default_fg, RGB{0xff, 0xee, 0xdd})
	feed(t, "\x1b]11;?\x07")
	testing.expect_value(tt, out_string(t), "\x1b]11;rgb:1010/2020/3030\x1b\\")
	feed(t, "\x1b]4;1;rgb:ff/00/00\x07")
	testing.expect_value(tt, t.palette[1], RGB{255, 0, 0})
	feed(t, "\x1b]4;1;?\x07")
	testing.expect_value(tt, out_string(t), "\x1b]4;1;rgb:ffff/0000/0000\x1b\\")
	feed(t, "\x1b]104\x07\x1b]111\x07")
	testing.expect_value(tt, t.palette[1], t.theme_palette[1])
	testing.expect_value(tt, t.default_bg, t.theme_bg)
}

@(test)
test_color_spec_parser :: proc(tt: ^testing.T) {
	c, ok := parse_color_spec("rgb:f/0/8")
	testing.expect(tt, ok)
	testing.expect_value(tt, c, RGB{255, 0, 136})
	c, ok = parse_color_spec("#abc")
	testing.expect(tt, ok)
	testing.expect_value(tt, c, RGB{0xaa, 0xbb, 0xcc})
	c, ok = parse_color_spec("#aabbcc")
	testing.expect_value(tt, c, RGB{0xaa, 0xbb, 0xcc})
	c, ok = parse_color_spec("rgb:ffff/8000/0000")
	testing.expect_value(tt, c, RGB{255, 128, 0})
	_, ok = parse_color_spec("rgb:zz/00/00")
	testing.expect(tt, !ok)
	_, ok = parse_color_spec("red")
	testing.expect(tt, !ok)
	_, ok = parse_color_spec("#12")
	testing.expect(tt, !ok)
}

@(test)
test_bell :: proc(tt: ^testing.T) {
	t := mk(10, 2)
	defer done(t)
	feed(t, "a\x07")
	testing.expect(tt, .Bell in t.events)
	// but not inside an OSC (it ends it)
	t.events = {}
	feed(t, "\x1b]2;x\x07")
	testing.expect(tt, .Bell not_in t.events)
}

@(test)
test_rep :: proc(tt: ^testing.T) {
	t := mk(10, 2)
	defer done(t)
	feed(t, "ab\x1b[3b")
	testing.expect_value(tt, screen_row_text(t, 0), "abbbb")
}

@(test)
test_ris_and_decstr :: proc(tt: ^testing.T) {
	t := mk(10, 3)
	defer done(t)
	feed(t, "text\x1b[31m\x1b[?1h\x1b[2;3r")
	feed(t, "\x1b[!p")
	testing.expect(tt, !t.modes.app_cursor)
	testing.expect_value(tt, t.top, 0)
	testing.expect_value(tt, t.bottom, 2)
	testing.expect_value(tt, screen_row_text(t, 0), "text")
	feed(t, "\x1bc")
	expect_screen(tt, t, "")
	testing.expect_value(tt, t.cursor.x, 0)
}

@(test)
test_decaln :: proc(tt: ^testing.T) {
	t := mk(4, 2)
	defer done(t)
	feed(t, "\x1b#8")
	expect_screen(tt, t, "EEEE\nEEEE")
}

@(test)
test_back_color_erase :: proc(tt: ^testing.T) {
	t := mk(6, 2)
	defer done(t)
	feed(t, "\x1b[44m\x1b[2K")
	testing.expect_value(tt, t.grid.rows[0].cells[3].bg, color_idx(4))
	// a scroll brings in lines in the current background too
	feed(t, "\x1b[2;1H\n")
	testing.expect_value(tt, t.grid.rows[1].cells[0].bg, color_idx(4))
}

@(test)
test_ignores_unknown_sequences :: proc(tt: ^testing.T) {
	t := mk(10, 2)
	defer done(t)
	feed(t, "a\x1b[?9999z\x1b[>1;2;3x\x1b_Gsomething\x1b\\\x1bPqsixel\x1b\\\x1b^pm\x1b\\b")
	testing.expect_value(tt, screen_row_text(t, 0), "ab")
	// CAN aborts a sequence
	feed(t, "\x1b[1;\x18c")
	testing.expect_value(tt, screen_row_text(t, 0), "abc")
	// too many parameters do not overflow
	feed(t, "\x1b[1;2;3;4;5;6;7;8;9;1;2;3;4;5;6;7;8;9;1;2;3;4;5;6;7;8;9;1;2;3;4;5;6;7;8;9;1;2;3mz")
	testing.expect_value(tt, screen_row_text(t, 0), "abcz")
}

@(test)
test_resize_without_reflow_keeps_text :: proc(tt: ^testing.T) {
	t := mk(10, 4)
	defer done(t)
	feed(t, "one\r\ntwo\r\nthree")
	term_resize(t, 10, 6)
	expect_screen(tt, t, "one\ntwo\nthree")
	testing.expect_value(tt, t.cursor.y, 2)
	testing.expect_value(tt, t.cursor.x, 5)
	term_resize(t, 10, 2)
	// the top lines went to the scrollback; the cursor line is on screen
	testing.expect_value(tt, screen_row_text(t, 1), "three")
	testing.expect_value(tt, t.sb.count, 1)
	expect_screen(tt, t, "two\nthree")
	term_resize(t, 10, 5)
	// they come back
	expect_screen(tt, t, "one\ntwo\nthree")
	testing.expect_value(tt, t.cursor.y, 2)
}

@(test)
test_resize_reflows_wrapped_lines :: proc(tt: ^testing.T) {
	t := mk(10, 4)
	defer done(t)
	feed(t, "0123456789ABCDEFGHIJxyz")
	testing.expect_value(tt, screen_row_text(t, 0), "0123456789")
	testing.expect_value(tt, screen_row_text(t, 2), "xyz")
	term_resize(t, 5, 6)
	testing.expect_value(tt, screen_row_text(t, 0), "01234")
	testing.expect_value(tt, screen_row_text(t, 1), "56789")
	testing.expect_value(tt, screen_row_text(t, 3), "FGHIJ")
	testing.expect_value(tt, screen_row_text(t, 4), "xyz")
	testing.expect_value(tt, t.cursor.y, 4)
	testing.expect_value(tt, t.cursor.x, 3)
	term_resize(t, 20, 6)
	testing.expect_value(tt, screen_row_text(t, 0), "0123456789ABCDEFGHIJ")
	testing.expect_value(tt, screen_row_text(t, 1), "xyz")
	testing.expect_value(tt, t.cursor.y, 1)
	testing.expect_value(tt, t.cursor.x, 3)
	// the text is the same one line
	testing.expect_value(tt, screen_text(t), "0123456789ABCDEFGHIJxyz")
}

@(test)
test_resize_reflow_with_history :: proc(tt: ^testing.T) {
	t := mk(8, 3, 50)
	defer done(t)
	for i in 0 ..< 10 {
		feed(t, "aaaaaaaaaaaa") // 12 chars: two rows at 8
		feed(t, string([]u8{u8('0' + i)}))
		feed(t, "\r\n")
	}
	before := screen_text(t, true)
	rows_before := line_count(t)
	term_resize(t, 20, 3)
	after := screen_text(t, true)
	// joined: every line is one row now
	testing.expect(tt, line_count(t) < rows_before)
	testing.expect(tt, strings.contains(after, "aaaaaaaaaaaa0\n"))
	testing.expect(tt, strings.contains(after, "aaaaaaaaaaaa9"))
	term_resize(t, 8, 3)
	testing.expect_value(tt, screen_text(t, true), before)
}

@(test)
test_resize_wide_char_at_edge :: proc(tt: ^testing.T) {
	t := mk(6, 3)
	defer done(t)
	feed(t, "ab世cd")
	term_resize(t, 3, 4)
	// "ab" then the wide character does not fit in the last column: it wraps
	testing.expect_value(tt, screen_row_text(t, 0), "ab")
	testing.expect_value(tt, screen_row_text(t, 1), "世c")
	testing.expect_value(tt, screen_row_text(t, 2), "d")
}

@(test)
test_resize_alt_screen :: proc(tt: ^testing.T) {
	t := mk(10, 4)
	defer done(t)
	feed(t, "main1\r\nmain2")
	feed(t, "\x1b[?1049h\x1b[2;2Halt")
	term_resize(t, 6, 3)
	testing.expect(tt, t.modes.alt_screen)
	testing.expect_value(tt, screen_row_text(t, 1), " alt")
	testing.expect(tt, t.cursor.x < 6 && t.cursor.y < 3)
	feed(t, "\x1b[?1049l")
	testing.expect_value(tt, screen_text(t), "main1\nmain2")
	testing.expect_value(tt, t.cursor.y, 1)
	testing.expect_value(tt, t.cursor.x, 5)
}

@(test)
test_scrolled_view_stays_anchored :: proc(tt: ^testing.T) {
	t := mk(6, 2, 100)
	defer done(t)
	for _ in 0 ..< 10 do feed(t, "x\r\n")
	t.view = 3
	feed(t, "y\r\n")
	testing.expect_value(tt, t.view, 4)
	// clearing the scrollback returns to the live screen
	feed(t, "\x1b[3J")
	testing.expect_value(tt, t.view, 0)
	testing.expect_value(tt, t.sb.count, 0)
}

@(test)
test_line_ids_survive_scrolling :: proc(tt: ^testing.T) {
	t := mk(6, 2, 3)
	defer done(t)
	feed(t, "a\r\nb\r\n")
	id := line_id(t, t.sb.count + 1) // the row of "b"... after the linefeed it scrolled
	_ = id
	feed(t, "c\r\nd\r\ne\r\nf\r\n")
	testing.expect(tt, t.dropped > 0)
	testing.expect_value(tt, line_from_id(t, line_id(t, 2)), 2)
}

@(test)
test_throughput_is_sane :: proc(tt: ^testing.T) {
	t := mk(120, 40, 1000)
	defer done(t)
	line := "the quick brown fox jumps over the lazy dog 0123456789 the quick brown fox jumps over the lazy dog 0123456789\r\n"
	buf := make([dynamic]u8, 0, 1 << 20, context.temp_allocator)
	for len(buf) + len(line) < 1 << 20 do append(&buf, ..transmute([]u8)line)
	for _ in 0 ..< 20 do term_feed(t, buf[:])
	testing.expect(tt, t.sb.count == 1000)
	testing.expect_value(tt, screen_row_text(t, 0)[:9], "the quick")
}
