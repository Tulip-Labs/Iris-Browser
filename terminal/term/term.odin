// The terminal emulator's state and the operations on it: the screen and
// its scrollback, the cursor, the modes. The parser (parser.odin) and the
// sequences (csi.odin, osc.odin) call these. Nothing here touches the
// system: it is all testable with `odin test`.
package term

import "core:strings"

RGB :: [3]u8

SCROLLBACK_DEFAULT :: 10000
MAX_COLS :: 1000
MAX_ROWS :: 500

Cursor_Style :: enum u8 { Block, Bar, Underline }

Cursor :: struct {
	x, y:    int,
	/// the last column was written: the next character wraps first
	pending: bool,
}

/// DECSC saves these
Saved_Cursor :: struct {
	cursor:  Cursor,
	pen:     Pen,
	origin:  bool,
	charset: [4]u8,
	gl:      u8,
	set:     bool,
}

Mouse_Mode :: enum u8 { None, X10, Press_Release, Drag, Any }
Mouse_Encoding :: enum u8 { Default, Utf8, Sgr, Urxvt }

Modes :: struct {
	app_cursor:    bool, // DECCKM
	app_keypad:    bool, // DECKPAM
	autowrap:      bool, // DECAWM
	origin:        bool, // DECOM
	insert:        bool, // IRM
	newline:       bool, // LNM: LF also returns the carriage
	reverse:       bool, // DECSCNM
	cursor_visible: bool,
	cursor_blink:  bool,
	bracketed:     bool, // 2004
	focus_events:  bool, // 1004
	sync:          bool, // 2026
	alt_scroll:    bool, // 1007
	mouse:         Mouse_Mode,
	mouse_enc:     Mouse_Encoding,
	alt_screen:    bool,
}

Grid :: struct {
	rows: [dynamic]Row,
}

/// the lines that scrolled off the top, oldest first (a ring)
Scrollback :: struct {
	rows:  [dynamic]Row,
	start: int,
	count: int,
	max:   int,
}

Cluster :: struct {
	r: [6]rune,
	n: u8,
}

/// what the app has to do after feeding the terminal
Event :: enum u8 { Bell, Title, Cwd, Clipboard, Prompt, Reset }
Events :: bit_set[Event; u8]

Term :: struct {
	cols, rows:  int,
	main, alt:   Grid,
	grid:        ^Grid, // the one shown: main or alt
	sb:          Scrollback,
	/// lines that fell off the far end of the scrollback (keeps selection ids stable)
	dropped:     u64,
	cursor:      Cursor,
	saved:       Saved_Cursor, // for the main screen
	saved_alt:   Saved_Cursor,
	pen:         Pen,
	top, bottom: int, // scroll region, rows
	tabs:        [dynamic]bool,
	modes:       Modes,
	cursor_style: Cursor_Style,
	/// DECSCUSR was never sent: the app's setting rules
	cursor_style_set: bool,
	charset:     [4]u8, // 'B' ASCII, '0' DEC graphics
	gl:          u8,
	last_char:   rune, // for REP
	parser:      Parser,

	clusters:    [dynamic]Cluster,
	links:       [dynamic]string, // id - 1
	link_ids:    map[string]u16,
	cur_link:    u16,

	title:       string,
	cwd:         string,
	icon_title:  string,
	title_stack: [dynamic]string,
	/// the text of the last OSC 52 write, until the app takes it
	clip_write:  [dynamic]u8,
	clip_target: u8, // 'c' or 'p'
	events:      Events,
	/// bumped by every change of what is on screen
	gen:         u64,
	/// what the shell said about prompts (OSC 133): the exit status of the last command
	last_status: int,
	cmd_running: bool,

	/// answers for the program (DA, DSR, ...), until the app writes them to the pty
	out:         [dynamic]u8,

	palette:     [256]RGB,
	default_fg, default_bg, cursor_color: RGB,
	theme_palette: [256]RGB,
	theme_fg, theme_bg, theme_cursor: RGB,

	/// the part of the history that is shown: 0 is the live screen
	view:        int,
	cell_px:     [2]int, // for the size reports (CSI t)
	/// OSC 133 is in use (a shell says where its prompts are)
	has_marks:   bool,
	version:     string,
}

// ---------------------------------------------------------------- creation

term_init :: proc(t: ^Term, cols, rows: int, scrollback := SCROLLBACK_DEFAULT) {
	t.cols, t.rows = clamp(cols, 1, MAX_COLS), clamp(rows, 1, MAX_ROWS)
	t.sb.max = max(scrollback, 0)
	grid_make(&t.main, t.cols, t.rows)
	grid_make(&t.alt, t.cols, t.rows)
	t.grid = &t.main
	t.version = "1.0.0"
	palette_default(&t.theme_palette)
	t.theme_fg, t.theme_bg, t.theme_cursor = {0xe6, 0xe8, 0xeb}, {0x0b, 0x0c, 0x0e}, {0xf2, 0xf4, 0xf7}
	t.palette = t.theme_palette
	t.default_fg, t.default_bg, t.cursor_color = t.theme_fg, t.theme_bg, t.theme_cursor
	t.link_ids = make(map[string]u16)
	term_reset(t)
}

term_destroy :: proc(t: ^Term) {
	grid_free(&t.main)
	grid_free(&t.alt)
	for i in 0 ..< t.sb.count do delete(sb_row(t, i).cells)
	delete(t.sb.rows)
	delete(t.tabs)
	delete(t.clusters)
	for l in t.links do delete(l)
	delete(t.links)
	delete(t.link_ids)
	delete(t.title)
	delete(t.cwd)
	delete(t.icon_title)
	for s in t.title_stack do delete(s)
	delete(t.title_stack)
	delete(t.clip_write)
	delete(t.out)
	delete(t.parser.osc)
	delete(t.parser.dcs)
}

@(private) grid_make :: proc(g: ^Grid, cols, rows: int) {
	g.rows = make([dynamic]Row, rows)
	for &r in g.rows do r.cells = blank_cells(cols)
}

@(private) grid_free :: proc(g: ^Grid) {
	for r in g.rows do delete(r.cells)
	delete(g.rows)
}

@(private) blank_cells :: proc(n: int, bg := COLOR_DEFAULT) -> []Cell {
	c := make([]Cell, n)
	for &x in c do x = Cell{ch = ' ', bg = bg}
	return c
}

/// RIS: the terminal as when it was new (the screen is cleared, the
/// scrollback is kept)
term_reset :: proc(t: ^Term) {
	t.modes = {autowrap = true, cursor_visible = true, alt_scroll = true}
	t.cursor = {}
	t.saved, t.saved_alt = {}, {}
	t.pen = {}
	t.top, t.bottom = 0, t.rows - 1
	t.charset = {'B', 'B', 'B', 'B'}
	t.gl = 0
	t.cursor_style = .Block
	t.cursor_style_set = false
	t.cur_link = 0
	t.last_char = 0
	t.palette = t.theme_palette
	t.default_fg, t.default_bg, t.cursor_color = t.theme_fg, t.theme_bg, t.theme_cursor
	if t.grid != &t.main do t.grid = &t.main
	for y in 0 ..< t.rows do row_clear(t, &t.main.rows[y], 0, t.cols, COLOR_DEFAULT)
	for y in 0 ..< t.rows do row_clear(t, &t.alt.rows[y], 0, t.cols, COLOR_DEFAULT)
	tabs_reset(t)
	t.view = 0
	t.events += {.Reset}
	t.gen += 1
}

/// DECSTR: the soft reset (modes, margins, pen; the screen stays)
term_soft_reset :: proc(t: ^Term) {
	m := t.modes
	t.modes = {autowrap = true, cursor_visible = true, alt_scroll = true, alt_screen = m.alt_screen}
	t.pen = {}
	t.top, t.bottom = 0, t.rows - 1
	t.charset = {'B', 'B', 'B', 'B'}
	t.gl = 0
	t.saved = {}
	t.cursor_style = .Block
	t.cursor_style_set = false
	t.cur_link = 0
}

@(private) tabs_reset :: proc(t: ^Term) {
	resize(&t.tabs, t.cols)
	for i in 0 ..< t.cols do t.tabs[i] = i % 8 == 0 && i > 0
}

/// the colours of a theme: the palette (16 colours), and the default ink,
/// ground and cursor. A palette the program changed (OSC 4) is kept.
term_set_theme :: proc(t: ^Term, ansi: [16]RGB, fg, bg, cursor: RGB) {
	old := t.theme_palette
	palette_default(&t.theme_palette)
	for i in 0 ..< 16 do t.theme_palette[i] = ansi[i]
	for i in 0 ..< 256 do if t.palette[i] == old[i] do t.palette[i] = t.theme_palette[i]
	if t.default_fg == t.theme_fg do t.default_fg = fg
	if t.default_bg == t.theme_bg do t.default_bg = bg
	if t.cursor_color == t.theme_cursor do t.cursor_color = cursor
	t.theme_fg, t.theme_bg, t.theme_cursor = fg, bg, cursor
	t.gen += 1
}

/// the xterm palette: 16 base colours, a 6x6x6 cube, 24 greys
palette_default :: proc(p: ^[256]RGB) {
	base := [16]RGB{
		{0, 0, 0}, {205, 49, 49}, {13, 188, 121}, {229, 229, 16}, {36, 114, 200}, {188, 63, 188}, {17, 168, 205}, {229, 229, 229},
		{102, 102, 102}, {241, 76, 76}, {35, 209, 139}, {245, 245, 67}, {59, 142, 234}, {214, 112, 214}, {41, 184, 219}, {255, 255, 255},
	}
	for i in 0 ..< 16 do p[i] = base[i]
	for i in 16 ..< 232 {
		n := i - 16
		lv :: proc(v: int) -> u8 { return v == 0 ? 0 : u8(55 + v * 40) }
		p[i] = {lv(n / 36), lv((n / 6) % 6), lv(n % 6)}
	}
	for i in 232 ..< 256 {
		v := u8(8 + (i - 232) * 10)
		p[i] = {v, v, v}
	}
}

// ---------------------------------------------------------------- colours

/// the colour of a cell's ink or ground (the default ones are the
/// terminal's own), with Reverse and Dim already applied by the caller
resolve :: proc(t: ^Term, c: Color, is_fg: bool) -> RGB {
	switch color_kind(c) {
	case 1: return t.palette[u8(u32(c) & 0xff)]
	case 2: return {u8(u32(c) >> 16), u8(u32(c) >> 8), u8(u32(c))}
	}
	return is_fg ? t.default_fg : t.default_bg
}

// ---------------------------------------------------------------- rows and the history

@(private) sb_index :: #force_inline proc(t: ^Term, i: int) -> int { return (t.sb.start + i) % len(t.sb.rows) }
sb_row :: proc(t: ^Term, i: int) -> ^Row { return &t.sb.rows[sb_index(t, i)] }

/// the number of lines before the live screen
history_len :: proc(t: ^Term) -> int { return t.sb.count }

/// line `i` of the whole text: 0 is the oldest scrollback line, then the screen
line_at :: proc(t: ^Term, i: int) -> ^Row {
	if i < t.sb.count do return sb_row(t, i)
	return &t.grid.rows[i - t.sb.count]
}

line_count :: proc(t: ^Term) -> int { return t.sb.count + t.rows }

/// the row shown at screen row y (the view may be scrolled back)
view_row :: proc(t: ^Term, y: int) -> ^Row {
	return line_at(t, t.sb.count - t.view + y)
}

/// a stable number for a line: it keeps meaning the same text while lines scroll
line_id :: proc(t: ^Term, i: int) -> i64 { return i64(t.dropped) + i64(i) }
line_from_id :: proc(t: ^Term, id: i64) -> int { return int(id - i64(t.dropped)) }

cell_at :: #force_inline proc(r: ^Row, x: int) -> Cell {
	if x < len(r.cells) do return r.cells[x]
	return BLANK
}

@(private) sb_push :: proc(t: ^Term, r: Row) {
	if t.sb.max == 0 {
		return
	}
	// a wrapped row keeps its length (the next row continues it); others lose their blank end
	n := r.wrapped ? len(r.cells) : row_used(r)
	cells := make([]Cell, n)
	copy(cells, r.cells[:n])
	nr := Row{cells = cells, wrapped = r.wrapped, prompt = r.prompt}
	if t.sb.count < t.sb.max {
		if len(t.sb.rows) < t.sb.max && t.sb.count == len(t.sb.rows) {
			append(&t.sb.rows, nr)
		} else {
			t.sb.rows[sb_index(t, t.sb.count)] = nr
		}
		t.sb.count += 1
	} else {
		i := t.sb.start
		delete(t.sb.rows[i].cells)
		t.sb.rows[i] = nr
		t.sb.start = (t.sb.start + 1) % len(t.sb.rows)
		t.dropped += 1
	}
	if t.view > 0 do t.view = min(t.view + 1, t.sb.count)
}

term_clear_history :: proc(t: ^Term) {
	for i in 0 ..< t.sb.count do delete(sb_row(t, i).cells)
	clear(&t.sb.rows)
	t.dropped += u64(t.sb.count)
	t.sb.start, t.sb.count = 0, 0
	t.view = 0
	t.gen += 1
}

/// fills cells x0..x1 (exclusive) of a row with blanks that carry the
/// background `bg` (back-colour erase), keeping wide characters whole
@(private) row_clear :: proc(t: ^Term, r: ^Row, x0, x1: int, bg: Color) {
	a, b := clamp(x0, 0, len(r.cells)), clamp(x1, 0, len(r.cells))
	if a >= b do return
	if a > 0 && has_attr(r.cells[a], .Wide_Cont) do r.cells[a - 1] = Cell{ch = ' ', bg = bg}
	if b < len(r.cells) && has_attr(r.cells[b], .Wide_Cont) do r.cells[b] = Cell{ch = ' ', bg = bg}
	for i in a ..< b do r.cells[i] = Cell{ch = ' ', bg = bg}
	if b == len(r.cells) {
		r.wrapped = false
	}
}

@(private) row_reset :: proc(t: ^Term, r: ^Row, bg: Color) {
	for i in 0 ..< len(r.cells) do r.cells[i] = Cell{ch = ' ', bg = bg}
	r.wrapped = false
	r.prompt = false
}

// ---------------------------------------------------------------- scrolling

/// scrolls the region up by n lines (what a linefeed at the bottom does)
scroll_up :: proc(t: ^Term, n0: int, top, bottom: int) {
	n := clamp(n0, 0, bottom - top + 1)
	if n == 0 do return
	g := t.grid
	full := top == 0 && bottom == t.rows - 1 && t.grid == &t.main
	for _ in 0 ..< n {
		first := g.rows[top]
		if full do sb_push(t, first)
		for y in top ..< bottom do g.rows[y] = g.rows[y + 1]
		g.rows[bottom] = first
		row_reset(t, &g.rows[bottom], t.pen.bg)
	}
	t.gen += 1
}

scroll_down :: proc(t: ^Term, n0: int, top, bottom: int) {
	n := clamp(n0, 0, bottom - top + 1)
	if n == 0 do return
	g := t.grid
	for _ in 0 ..< n {
		last := g.rows[bottom]
		for y := bottom; y > top; y -= 1 do g.rows[y] = g.rows[y - 1]
		g.rows[top] = last
		row_reset(t, &g.rows[top], t.pen.bg)
	}
	t.gen += 1
}

/// IND / LF: down one line, scrolling at the bottom of the region
index :: proc(t: ^Term) {
	if t.cursor.y == t.bottom {
		scroll_up(t, 1, t.top, t.bottom)
	} else if t.cursor.y < t.rows - 1 {
		t.cursor.y += 1
	}
}

reverse_index :: proc(t: ^Term) {
	if t.cursor.y == t.top {
		scroll_down(t, 1, t.top, t.bottom)
	} else if t.cursor.y > 0 {
		t.cursor.y -= 1
	}
}

// ---------------------------------------------------------------- cursor

cursor_to :: proc(t: ^Term, x, y: int) {
	t.cursor.x = clamp(x, 0, t.cols - 1)
	if t.modes.origin {
		t.cursor.y = clamp(y + t.top, t.top, t.bottom)
	} else {
		t.cursor.y = clamp(y, 0, t.rows - 1)
	}
	t.cursor.pending = false
}

// ---------------------------------------------------------------- writing

@(private) cluster_new :: proc(t: ^Term, base: rune) -> u32 {
	if len(t.clusters) >= 65536 do return u32(base)
	c := Cluster{n = 1}
	c.r[0] = base
	append(&t.clusters, c)
	return CLUSTER_BIT | u32(len(t.clusters) - 1)
}

/// the characters of a cell: its base, and the combining marks after it
cell_runes :: proc(t: ^Term, c: Cell, buf: ^[7]rune) -> []rune {
	if c.ch & CLUSTER_BIT == 0 {
		buf[0] = rune(c.ch)
		return buf[:1]
	}
	cl := t.clusters[c.ch & ~CLUSTER_BIT]
	for i in 0 ..< int(cl.n) do buf[i] = cl.r[i]
	return buf[:cl.n]
}

/// a combining mark (or a joined character) goes into the previous cell
@(private) attach :: proc(t: ^Term, r: rune) {
	x := t.cursor.pending ? t.cursor.x : t.cursor.x - 1
	if x < 0 do return
	row := &t.grid.rows[t.cursor.y]
	if x > 0 && has_attr(row.cells[x], .Wide_Cont) do x -= 1
	c := &row.cells[x]
	if c.ch & CLUSTER_BIT == 0 {
		c.ch = cluster_new(t, rune(c.ch))
		if c.ch & CLUSTER_BIT == 0 do return
	}
	cl := &t.clusters[c.ch & ~CLUSTER_BIT]
	if int(cl.n) >= len(cl.r) do return
	// a cluster is shared by nothing (each cell has its own entry), so it can grow
	cl.r[cl.n] = r
	cl.n += 1
}

/// is the character before the cursor a joiner (the next one joins it)
@(private) after_joiner :: proc(t: ^Term) -> bool {
	x := t.cursor.pending ? t.cursor.x : t.cursor.x - 1
	if x < 0 do return false
	if x > 0 && has_attr(t.grid.rows[t.cursor.y].cells[x], .Wide_Cont) do x -= 1
	c := t.grid.rows[t.cursor.y].cells[x]
	if c.ch & CLUSTER_BIT == 0 do return false
	cl := t.clusters[c.ch & ~CLUSTER_BIT]
	return cl.r[cl.n - 1] == 0x200d
}

@(private) wrap_line :: proc(t: ^Term) {
	t.grid.rows[t.cursor.y].wrapped = true
	t.cursor.x = 0
	t.cursor.pending = false
	index(t)
}

/// the character set: DEC special graphics turns 0x5f..0x7e into line drawing
@(private) DEC_GRAPHICS := [32]rune{
	0x00a0, '◆', '▒', '␉', '␌', '␍', '␊', '°', '±', '␤', '␋', '┘', '┐', '┌', '└', '┼',
	'⎺', '⎻', '─', '⎼', '⎽', '├', '┤', '┴', '┬', '│', '≤', '≥', 'π', '≠', '£', '·',
}

/// writes one character at the cursor
print_rune :: proc(t: ^Term, r0: rune) {
	r := r0
	if t.charset[t.gl] == '0' && r >= 0x5f && r <= 0x7e do r = DEC_GRAPHICS[r - 0x5f]
	w := char_width(r)
	if w == 0 {
		attach(t, r)
		t.gen += 1
		return
	}
	if after_joiner(t) {
		attach(t, r)
		t.gen += 1
		return
	}
	t.last_char = r
	if t.cursor.pending {
		if t.modes.autowrap { wrap_line(t) } else { t.cursor.pending = false }
	}
	if w == 2 && t.cursor.x == t.cols - 1 {
		if t.cols < 2 do return
		if t.modes.autowrap {
			row := &t.grid.rows[t.cursor.y]
			row.cells[t.cursor.x] = Cell{ch = ' ', bg = t.pen.bg}
			wrap_line(t)
		} else {
			t.cursor.x -= 1
		}
	}
	row := &t.grid.rows[t.cursor.y]
	x := t.cursor.x
	if t.modes.insert {
		for i := t.cols - 1; i >= x + w; i -= 1 do row.cells[i] = row.cells[i - w]
		fix_wide_end(row)
	}
	// overwriting half of a wide character blanks the other half
	if has_attr(row.cells[x], .Wide_Cont) && x > 0 do row.cells[x - 1] = Cell{ch = ' ', bg = row.cells[x - 1].bg}
	if has_attr(row.cells[x], .Wide) && x + 1 < t.cols do row.cells[x + 1] = Cell{ch = ' ', bg = row.cells[x + 1].bg}
	attr := t.pen.attr
	row.cells[x] = Cell{ch = u32(r), fg = t.pen.fg, bg = t.pen.bg, attr = attr | (w == 2 ? 1 << u16(Attr.Wide) : 0), link = t.cur_link}
	if w == 2 {
		if has_attr(row.cells[x + 1], .Wide) && x + 2 < t.cols do row.cells[x + 2] = Cell{ch = ' ', bg = row.cells[x + 2].bg}
		row.cells[x + 1] = Cell{ch = ' ', fg = t.pen.fg, bg = t.pen.bg, attr = attr | 1 << u16(Attr.Wide_Cont), link = t.cur_link}
	}
	if x + w >= t.cols {
		t.cursor.x = t.cols - 1
		t.cursor.pending = true
	} else {
		t.cursor.x = x + w
	}
	t.gen += 1
}

/// a wide character cut off by the end of the row becomes a blank
@(private) fix_wide_end :: proc(row: ^Row) {
	n := len(row.cells)
	if n > 0 && has_attr(row.cells[n - 1], .Wide) do row.cells[n - 1] = Cell{ch = ' ', bg = row.cells[n - 1].bg}
}

/// a run of printable ASCII (the common case), written without the checks
/// a general character needs
print_ascii :: proc(t: ^Term, s: []u8) {
	if t.charset[t.gl] != '0' && !t.modes.insert {
		i := 0
		for i < len(s) {
			if t.cursor.pending {
				if t.modes.autowrap { wrap_line(t) } else { t.cursor.pending = false }
			}
			row := &t.grid.rows[t.cursor.y]
			x := t.cursor.x
			room := t.cols - x
			n := min(room, len(s) - i)
			// the cells overwritten may be halves of wide characters
			if has_attr(row.cells[x], .Wide_Cont) && x > 0 do row.cells[x - 1] = Cell{ch = ' ', bg = row.cells[x - 1].bg}
			if x + n < t.cols && has_attr(row.cells[x + n], .Wide_Cont) do row.cells[x + n] = Cell{ch = ' ', bg = row.cells[x + n].bg}
			c := Cell{fg = t.pen.fg, bg = t.pen.bg, attr = t.pen.attr, link = t.cur_link}
			for k in 0 ..< n {
				c.ch = u32(s[i + k])
				row.cells[x + k] = c
			}
			t.last_char = rune(s[i + n - 1])
			i += n
			if x + n >= t.cols {
				t.cursor.x = t.cols - 1
				t.cursor.pending = true
			} else {
				t.cursor.x = x + n
			}
		}
		t.gen += 1
		return
	}
	for b in s do print_rune(t, rune(b))
}

// ---------------------------------------------------------------- erasing and editing

erase_in_line :: proc(t: ^Term, mode: int) {
	row := &t.grid.rows[t.cursor.y]
	switch mode {
	case 0: row_clear(t, row, t.cursor.x, t.cols, t.pen.bg)
	case 1: row_clear(t, row, 0, t.cursor.x + 1, t.pen.bg)
	case 2: row_clear(t, row, 0, t.cols, t.pen.bg)
	}
	t.cursor.pending = false
	t.gen += 1
}

erase_in_display :: proc(t: ^Term, mode: int) {
	switch mode {
	case 0:
		row_clear(t, &t.grid.rows[t.cursor.y], t.cursor.x, t.cols, t.pen.bg)
		for y in t.cursor.y + 1 ..< t.rows do row_reset(t, &t.grid.rows[y], t.pen.bg)
	case 1:
		for y in 0 ..< t.cursor.y do row_reset(t, &t.grid.rows[y], t.pen.bg)
		row_clear(t, &t.grid.rows[t.cursor.y], 0, t.cursor.x + 1, t.pen.bg)
	case 2:
		for y in 0 ..< t.rows do row_reset(t, &t.grid.rows[y], t.pen.bg)
	case 3:
		term_clear_history(t)
	}
	t.gen += 1
}

insert_chars :: proc(t: ^Term, n0: int) {
	row := &t.grid.rows[t.cursor.y]
	x := t.cursor.x
	n := clamp(n0, 1, t.cols - x)
	if has_attr(row.cells[x], .Wide_Cont) && x > 0 do row.cells[x - 1] = Cell{ch = ' ', bg = t.pen.bg}
	for i := t.cols - 1; i >= x + n; i -= 1 do row.cells[i] = row.cells[i - n]
	for i in x ..< x + n do row.cells[i] = Cell{ch = ' ', bg = t.pen.bg}
	fix_wide_end(row)
	t.cursor.pending = false
	t.gen += 1
}

delete_chars :: proc(t: ^Term, n0: int) {
	row := &t.grid.rows[t.cursor.y]
	x := t.cursor.x
	n := clamp(n0, 1, t.cols - x)
	if has_attr(row.cells[x], .Wide_Cont) && x > 0 do row.cells[x - 1] = Cell{ch = ' ', bg = t.pen.bg}
	for i in x ..< t.cols - n do row.cells[i] = row.cells[i + n]
	for i in t.cols - n ..< t.cols do row.cells[i] = Cell{ch = ' ', bg = t.pen.bg}
	if x < t.cols && has_attr(row.cells[x], .Wide_Cont) do row.cells[x] = Cell{ch = ' ', bg = t.pen.bg}
	t.cursor.pending = false
	t.gen += 1
}

erase_chars :: proc(t: ^Term, n0: int) {
	row := &t.grid.rows[t.cursor.y]
	n := clamp(n0, 1, t.cols - t.cursor.x)
	row_clear(t, row, t.cursor.x, t.cursor.x + n, t.pen.bg)
	t.cursor.pending = false
	t.gen += 1
}

insert_lines :: proc(t: ^Term, n: int) {
	if t.cursor.y < t.top || t.cursor.y > t.bottom do return
	scroll_down(t, n, t.cursor.y, t.bottom)
	t.cursor.x = 0
	t.cursor.pending = false
}

delete_lines :: proc(t: ^Term, n: int) {
	if t.cursor.y < t.top || t.cursor.y > t.bottom do return
	// lines deleted inside the region do not go to the scrollback
	g := t.grid
	m := clamp(n, 1, t.bottom - t.cursor.y + 1)
	for _ in 0 ..< m {
		first := g.rows[t.cursor.y]
		for y in t.cursor.y ..< t.bottom do g.rows[y] = g.rows[y + 1]
		g.rows[t.bottom] = first
		row_reset(t, &g.rows[t.bottom], t.pen.bg)
	}
	t.cursor.x = 0
	t.cursor.pending = false
	t.gen += 1
}

// ---------------------------------------------------------------- tabs

tab_forward :: proc(t: ^Term, n: int) {
	x := t.cursor.x
	for _ in 0 ..< n {
		x += 1
		for x < t.cols - 1 && !t.tabs[x] do x += 1
		if x >= t.cols - 1 {
			x = t.cols - 1
			break
		}
	}
	t.cursor.x = x
	t.cursor.pending = false
}

tab_back :: proc(t: ^Term, n: int) {
	x := t.cursor.x
	for _ in 0 ..< n {
		x -= 1
		for x > 0 && !t.tabs[x] do x -= 1
		if x <= 0 {
			x = 0
			break
		}
	}
	t.cursor.x = max(x, 0)
	t.cursor.pending = false
}

// ---------------------------------------------------------------- the alternate screen

term_alt_screen :: proc(t: ^Term, on: bool, save_cursor: bool, clear: bool) {
	if on == t.modes.alt_screen do return
	if on {
		if save_cursor do t.saved = save(t)
		t.grid = &t.alt
		t.modes.alt_screen = true
		if clear do for y in 0 ..< t.rows do row_reset(t, &t.alt.rows[y], COLOR_DEFAULT)
		t.view = 0
	} else {
		t.grid = &t.main
		t.modes.alt_screen = false
		if save_cursor do restore(t, t.saved)
	}
	t.gen += 1
}

@(private) save :: proc(t: ^Term) -> Saved_Cursor {
	return {cursor = t.cursor, pen = t.pen, origin = t.modes.origin, charset = t.charset, gl = t.gl, set = true}
}

@(private) restore :: proc(t: ^Term, s: Saved_Cursor) {
	if !s.set {
		t.cursor = {}
		t.pen = {}
		t.modes.origin = false
		return
	}
	t.cursor = s.cursor
	t.cursor.x = clamp(t.cursor.x, 0, t.cols - 1)
	t.cursor.y = clamp(t.cursor.y, 0, t.rows - 1)
	t.pen = s.pen
	t.modes.origin = s.origin
	t.charset = s.charset
	t.gl = s.gl
}

save_cursor :: proc(t: ^Term) {
	if t.modes.alt_screen { t.saved_alt = save(t) } else { t.saved = save(t) }
}

restore_cursor :: proc(t: ^Term) {
	restore(t, t.modes.alt_screen ? t.saved_alt : t.saved)
}

// ---------------------------------------------------------------- the pen

link_id :: proc(t: ^Term, url: string) -> u16 {
	if len(url) == 0 do return 0
	if id, ok := t.link_ids[url]; ok do return id
	if len(t.links) >= 60000 do return 0
	u := strings.clone(url)
	append(&t.links, u)
	id := u16(len(t.links))
	t.link_ids[u] = id
	return id
}

link_url :: proc(t: ^Term, id: u16) -> string {
	if id == 0 || int(id) > len(t.links) do return ""
	return t.links[id - 1]
}

/// answers for the program: queued, the app writes them to the pty
reply :: proc(t: ^Term, s: string) {
	append(&t.out, ..transmute([]u8)s)
}
