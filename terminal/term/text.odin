// The text of rows and of the whole screen: what a copy takes, what the
// test mode writes, what a search reads.
package term

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

/// the characters of cells x0..x1 of a row as text; with `map_cols`, the
/// cell each byte of the text came from
row_text :: proc(t: ^Term, r: ^Row, x0, x1: int, trim_end: bool, b: ^strings.Builder, map_cols: ^[dynamic]int = nil) {
	end := min(x1, len(r.cells))
	if trim_end {
		for end > x0 && r.cells[end - 1].ch == ' ' && !has_attr(r.cells[end - 1], .Wide_Cont) do end -= 1
		// (a blank with a link or a colour is still a blank in the text)
	}
	for x in max(x0, 0) ..< end {
		c := r.cells[x]
		if has_attr(c, .Wide_Cont) do continue
		buf: [7]rune
		for ru in cell_runes(t, c, &buf) {
			before := strings.builder_len(b^)
			strings.write_rune(b, ru == 0 ? ' ' : ru)
			if map_cols != nil do for _ in before ..< strings.builder_len(b^) do append(map_cols, x)
		}
	}
	// a selection to the margin: blanks past the end of a short row
	if !trim_end {
		for _ in max(end, 0) ..< x1 do strings.write_byte(b, ' ')
	}
}

/// the text of one screen row, without the blanks at its end
screen_row_text :: proc(t: ^Term, y: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	row_text(t, &t.grid.rows[y], 0, t.cols, true, &b)
	return strings.to_string(b)
}

/// the screen as lines (blanks at the ends trimmed; no empty lines at the end)
screen_text :: proc(t: ^Term, with_history := false, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	from := with_history ? 0 : t.sb.count
	last := line_count(t) - 1
	for last > from && row_used(line_at(t, last)^) == 0 do last -= 1
	for i in from ..= last {
		row := line_at(t, i)
		line := strings.builder_make(context.temp_allocator)
		row_text(t, row, 0, len(row.cells), true, &line)
		strings.write_string(&b, strings.to_string(line))
		// a soft-wrapped line continues without a break
		if !row.wrapped && i < last do strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private) color_text :: proc(c: Color) -> string {
	switch color_kind(c) {
	case 1: return fmt.tprintf("p%d", u32(c) & 0xff)
	case 2: return fmt.tprintf("#%06x", u32(c) & 0xffffff)
	}
	return "-"
}

/// the cell's style as a short word: fg/bg/attributes ("-" for the default)
cell_style_text :: proc(c: Cell) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s/%s/", color_text(c.fg), color_text(c.bg))
	a := cell_attrs(c)
	n := 0
	names := [?]struct{ a: Attr, s: string }{{.Bold, "b"}, {.Dim, "d"}, {.Italic, "i"}, {.Blink, "k"}, {.Reverse, "r"}, {.Hidden, "h"}, {.Strike, "s"}, {.Overline, "o"}}
	for nm in names do if nm.a in a {
		strings.write_string(&b, nm.s)
		n += 1
	}
	if u := cell_underline(c); u != .None {
		fmt.sbprintf(&b, "u%d", int(u))
		n += 1
	}
	if n == 0 do strings.write_byte(&b, '-')
	return strings.to_string(b)
}

/// everything the test mode writes besides the text: the cursor, the
/// modes, the title, the directory, the links, the styled cells
state_text :: proc(t: ^Term) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "size: %dx%d\n", t.cols, t.rows)
	fmt.sbprintf(&b, "cursor: %d,%d\n", t.cursor.x, t.cursor.y)
	fmt.sbprintf(&b, "alt: %v\n", t.modes.alt_screen)
	fmt.sbprintf(&b, "history: %d\n", t.sb.count)
	fmt.sbprintf(&b, "title: %s\n", t.title)
	fmt.sbprintf(&b, "cwd: %s\n", t.cwd)
	fmt.sbprintf(&b, "marks: %v\n", t.has_marks)
	fmt.sbprintf(&b, "status: %d\n", t.last_status)
	if len(t.clip_write) > 0 do fmt.sbprintf(&b, "clipboard(%c): %s\n", t.clip_target, string(t.clip_write[:]))
	for y in 0 ..< t.rows {
		row := &t.grid.rows[y]
		for x in 0 ..< len(row.cells) {
			c := row.cells[x]
			if has_attr(c, .Wide_Cont) do continue
			if c.link != 0 do fmt.sbprintf(&b, "link %d,%d %s\n", x, y, link_url(t, c.link))
			style := cell_style_text(c)
			if style != "-/-/-" && !(c.ch == ' ' && color_is_default(c.bg) && cell_underline(c) == .None && !has_attr(c, .Reverse)) {
				buf: [7]rune
				rs := cell_runes(t, c, &buf)
				fmt.sbprintf(&b, "cell %d,%d %s %s\n", x, y, style, utf8.runes_to_string(rs, context.temp_allocator))
			}
		}
	}
	return strings.to_string(b)
}
