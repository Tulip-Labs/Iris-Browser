// Resizing: the alternate screen is cut or padded; the main screen and its
// history are rewrapped (a line that was wrapped joins again, and wraps at
// the new width), with the cursor kept on the same character.
package term

Logical :: struct {
	cells:  [dynamic]Cell,
	prompt: bool,
}

term_resize :: proc(t: ^Term, cols0, rows0: int) {
	cols, rows := clamp(cols0, 1, MAX_COLS), clamp(rows0, 1, MAX_ROWS)
	if cols == t.cols && rows == t.rows do return
	// the cursor of the main screen: the live one, or the one saved under the alternate screen
	mc := t.modes.alt_screen ? &t.saved.cursor : &t.cursor
	if !t.modes.alt_screen || t.saved.set {
		reflow_main(t, cols, rows, mc)
	} else {
		dummy := Cursor{}
		reflow_main(t, cols, rows, &dummy)
	}
	// the alternate screen: what fits stays where it is
	old := t.alt
	grid_make(&t.alt, cols, rows)
	for y in 0 ..< min(len(old.rows), rows) {
		copy(t.alt.rows[y].cells, old.rows[y].cells[:min(len(old.rows[y].cells), cols)])
		// a wide character cut by the new edge
		if cols < len(old.rows[y].cells) && has_attr(t.alt.rows[y].cells[cols - 1], .Wide) {
			t.alt.rows[y].cells[cols - 1] = Cell{ch = ' '}
		}
	}
	grid_free(&old)
	t.grid = t.modes.alt_screen ? &t.alt : &t.main
	t.cols, t.rows = cols, rows
	t.top, t.bottom = 0, rows - 1
	tabs_reset(t)
	if t.modes.alt_screen {
		t.cursor.x = clamp(t.cursor.x, 0, cols - 1)
		t.cursor.y = clamp(t.cursor.y, 0, rows - 1)
		t.cursor.pending = false
		t.saved_alt.cursor.x = clamp(t.saved_alt.cursor.x, 0, cols - 1)
		t.saved_alt.cursor.y = clamp(t.saved_alt.cursor.y, 0, rows - 1)
	} else {
		t.saved_alt.cursor.x = clamp(t.saved_alt.cursor.x, 0, cols - 1)
		t.saved_alt.cursor.y = clamp(t.saved_alt.cursor.y, 0, rows - 1)
		t.saved.cursor.x = clamp(t.saved.cursor.x, 0, cols - 1)
		t.saved.cursor.y = clamp(t.saved.cursor.y, 0, rows - 1)
	}
	t.view = 0
	t.gen += 1
}

@(private) main_line :: proc(t: ^Term, i: int) -> ^Row {
	if i < t.sb.count do return sb_row(t, i)
	return &t.main.rows[i - t.sb.count]
}

@(private) reflow_main :: proc(t: ^Term, cols, rows: int, mc: ^Cursor) {
	// the last screen row that holds anything (or the cursor)
	last := t.rows - 1
	for last > mc.y && row_used(t.main.rows[last]) == 0 && !t.main.rows[last].prompt do last -= 1

	// 1. logical lines
	lines := make([dynamic]Logical, context.temp_allocator)
	cur := Logical{cells = make([dynamic]Cell, context.temp_allocator)}
	cursor_line, cursor_off := -1, 0
	cursor_row_global := t.sb.count + mc.y
	for i in 0 ..< t.sb.count + last + 1 {
		row := main_line(t, i)
		n := row.wrapped ? len(row.cells) : row_used(row^)
		if i == cursor_row_global {
			cursor_line = len(lines)
			cursor_off = len(cur.cells) + mc.x + (mc.pending ? 1 : 0)
		}
		append(&cur.cells, ..row.cells[:n])
		cur.prompt ||= row.prompt
		if !row.wrapped {
			append(&lines, cur)
			cur = Logical{cells = make([dynamic]Cell, context.temp_allocator)}
		}
	}
	if len(cur.cells) > 0 || cur.prompt do append(&lines, cur)
	if cursor_line < 0 {
		cursor_line = len(lines)
		cursor_off = mc.x
		append(&lines, Logical{cells = make([dynamic]Cell, context.temp_allocator)})
	}

	// 2. rewrap
	out := make([dynamic]Row, context.temp_allocator)
	new_row :: proc(cols: int) -> Row { return Row{cells = blank_cells(cols)} }
	cur_row, cur_x := 0, 0
	for &ln, li in lines {
		first := len(out)
		if li == cursor_line {
			for len(ln.cells) <= cursor_off do append(&ln.cells, BLANK)
		}
		append(&out, new_row(cols))
		x := 0
		for c, idx in ln.cells {
			if has_attr(c, .Wide_Cont) do continue
			w := has_attr(c, .Wide) ? 2 : 1
			if w > cols do continue
			if x + w > cols {
				out[len(out) - 1].wrapped = true
				append(&out, new_row(cols))
				x = 0
			}
			if li == cursor_line && idx == cursor_off {
				cur_row, cur_x = len(out) - 1, x
			}
			r := &out[len(out) - 1]
			r.cells[x] = c
			if w == 2 {
				cont := c
				cont.ch = ' '
				cont.attr = c.attr & ~A_WIDE | A_WIDE_CONT
				r.cells[x + 1] = cont
			}
			x += w
		}
		out[first].prompt = ln.prompt
	}

	// 3. which rows are the screen
	n := len(out)
	start := max(0, n - rows)
	if cur_row < start do start = cur_row

	// 4. the new history and screen
	for i in 0 ..< t.sb.count do delete(sb_row(t, i).cells)
	for r in t.main.rows do delete(r.cells)
	clear(&t.sb.rows)
	t.dropped += u64(t.sb.count)
	t.sb.start, t.sb.count = 0, 0
	for i in 0 ..< start {
		sb_push(t, out[i])
		delete(out[i].cells)
	}
	delete(t.main.rows)
	t.main.rows = make([dynamic]Row, rows)
	for y in 0 ..< rows {
		if start + y < n {
			t.main.rows[y] = out[start + y]
		} else {
			t.main.rows[y] = new_row(cols)
		}
	}
	mc^ = {x = clamp(cur_x, 0, cols - 1), y = clamp(cur_row - start, 0, rows - 1)}
}
