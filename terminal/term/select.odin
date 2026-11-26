// Selection (by character, word, line, block), search in the scrollback,
// links under the pointer (OSC 8 and plain URLs), and the jumps between
// shell prompts.
package term

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Sel_Kind :: enum u8 { None, Chars, Word, Line, Block }

/// a place in the text: a line (by its stable id) and a cell
Point :: struct {
	line: i64,
	col:  int,
}

Selection :: struct {
	kind:         Sel_Kind,
	anchor, head: Point,
}

sel_active :: proc(s: Selection) -> bool { return s.kind != .None }

@(private) point_less :: proc(a, b: Point) -> bool {
	return a.line < b.line || (a.line == b.line && a.col < b.col)
}

/// the cell where a wide character starts
@(private) wide_start :: proc(t: ^Term, line: int, col: int) -> int {
	r := line_at(t, line)
	if col > 0 && col < len(r.cells) && has_attr(r.cells[col], .Wide_Cont) do return col - 1
	return col
}

DEFAULT_WORD_SEPARATORS :: " \t,│`|:\"'()[]{}<>"

/// the cells of the word around col in a line: [lo, hi]
word_bounds :: proc(t: ^Term, line: int, col: int, seps := DEFAULT_WORD_SEPARATORS) -> (lo, hi: int) {
	r := line_at(t, line)
	n := len(r.cells)
	if n == 0 do return col, col
	c := clamp(wide_start(t, line, col), 0, max(n, t.cols) - 1)
	if c >= n do return c, c
	is_sep :: proc(t: ^Term, cell: Cell, seps: string) -> bool {
		if has_attr(cell, .Wide_Cont) do return false
		if cell.ch & CLUSTER_BIT != 0 do return false
		return cell.ch == ' ' || cell.ch == 0 || strings.contains_rune(seps, rune(cell.ch))
	}
	kind := is_sep(t, r.cells[c], seps)
	lo, hi = c, c
	for lo > 0 && is_sep(t, r.cells[lo - 1], seps) == kind do lo -= 1
	for hi + 1 < n && is_sep(t, r.cells[hi + 1], seps) == kind do hi += 1
	if has_attr(r.cells[hi], .Wide) && hi + 1 < n do hi += 1
	return lo, hi
}

/// the first and last line of the logical line (the wrapped rows) that holds `line`
logical_bounds :: proc(t: ^Term, line: int) -> (first, last: int) {
	first, last = line, line
	for first > 0 && line_at(t, first - 1).wrapped do first -= 1
	for last + 1 < line_count(t) && line_at(t, last).wrapped do last += 1
	return
}

/// the selected range, in order, with words and lines widened
sel_range :: proc(t: ^Term, s: Selection, seps := DEFAULT_WORD_SEPARATORS) -> (a, b: Point, ok: bool) {
	if s.kind == .None do return
	a, b = s.anchor, s.head
	if point_less(b, a) do a, b = b, a
	la, lb := line_from_id(t, a.line), line_from_id(t, b.line)
	if lb < 0 || la >= line_count(t) do return
	la, lb = max(la, 0), min(lb, line_count(t) - 1)
	switch s.kind {
	case .None, .Block:
	case .Chars:
		a.col = wide_start(t, la, a.col)
		if lb < line_count(t) {
			r := line_at(t, lb)
			if b.col < len(r.cells) && has_attr(r.cells[b.col], .Wide) do b.col += 1
		}
	case .Word:
		lo, _ := word_bounds(t, la, a.col, seps)
		_, hi := word_bounds(t, lb, b.col, seps)
		a.col, b.col = lo, hi
	case .Line:
		fa, _ := logical_bounds(t, la)
		_, lz := logical_bounds(t, lb)
		a = {line_id(t, fa), 0}
		b = {line_id(t, lz), t.cols - 1}
		la, lb = fa, lz
	}
	return a, b, true
}

/// is the cell in the selection (for drawing it)
sel_contains :: proc(t: ^Term, s: Selection, a, b: Point, line: int, col: int) -> bool {
	id := line_id(t, line)
	if id < a.line || id > b.line do return false
	if s.kind == .Block {
		c0, c1 := min(s.anchor.col, s.head.col), max(s.anchor.col, s.head.col)
		return col >= c0 && col <= c1
	}
	if id == a.line && col < a.col do return false
	if id == b.line && col > b.col do return false
	return true
}

/// the selected text
sel_text :: proc(t: ^Term, s: Selection, seps := DEFAULT_WORD_SEPARATORS, allocator := context.temp_allocator) -> string {
	a, b, ok := sel_range(t, s, seps)
	if !ok do return ""
	la, lb := max(line_from_id(t, a.line), 0), min(line_from_id(t, b.line), line_count(t) - 1)
	sb := strings.builder_make(allocator)
	for l in la ..= lb {
		r := line_at(t, l)
		x0, x1 := 0, t.cols
		if s.kind == .Block {
			x0, x1 = min(s.anchor.col, s.head.col), max(s.anchor.col, s.head.col) + 1
		} else {
			if l == la do x0 = a.col
			if l == lb do x1 = b.col + 1
		}
		row_text(t, r, x0, x1, true, &sb)
		if l < lb && (!r.wrapped || s.kind == .Block) do strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// ---------------------------------------------------------------- search

Match :: struct {
	line:     i64,
	col0, col1: int, // cells, inclusive
}

@(private) fold :: proc(r: rune, ci: bool) -> rune { return ci ? unicode.to_lower(r) : r }

/// all matches of `query` in the history and the screen, oldest first. A
/// query with no capital letter ignores case (smart case).
search :: proc(t: ^Term, query: string, allocator := context.allocator) -> []Match {
	res := make([dynamic]Match, allocator)
	if len(query) == 0 do return res[:]
	q := utf8.string_to_runes(query, context.temp_allocator)
	ci := true
	for r in q do if unicode.is_upper(r) do ci = false
	for &r in q do r = fold(r, ci)
	for l in 0 ..< line_count(t) {
		row := line_at(t, l)
		n := row_used(row^)
		if n < len(q) do continue
		// the cell of each character of the row
		hay := make([dynamic]rune, 0, n, context.temp_allocator)
		cols := make([dynamic]int, 0, n, context.temp_allocator)
		for x in 0 ..< n {
			c := row.cells[x]
			if has_attr(c, .Wide_Cont) do continue
			buf: [7]rune
			rs := cell_runes(t, c, &buf)
			append(&hay, fold(rs[0], ci))
			append(&cols, x)
		}
		i := 0
		for i + len(q) <= len(hay) {
			hit := true
			for k in 0 ..< len(q) do if hay[i + k] != q[k] {
				hit = false
				break
			}
			if hit {
				last := cols[i + len(q) - 1]
				if last < len(row.cells) && has_attr(row.cells[last], .Wide) do last += 1
				append(&res, Match{line = line_id(t, l), col0 = cols[i], col1 = last})
				i += len(q)
			} else {
				i += 1
			}
		}
	}
	return res[:]
}

// ---------------------------------------------------------------- links

Link_Hit :: struct {
	url:        string, // temp allocated
	line0, col0: int,
	line1, col1: int, // inclusive
}

URL_SCHEMES := [?]string{"https://", "http://", "ftp://", "file://", "mailto:"}

@(private) url_char :: proc(r: rune) -> bool {
	if r <= 0x20 || r == 0x7f do return false
	switch r {
	case '<', '>', '"', '`', '{', '}', '|', '\\', '^': return false
	}
	return true
}

/// the link under a cell: an OSC 8 link, or a URL in the text
link_at :: proc(t: ^Term, line: int, col: int) -> (hit: Link_Hit, ok: bool) {
	if line < 0 || line >= line_count(t) do return
	r := line_at(t, line)
	if col < 0 || col >= len(r.cells) do return
	c0 := wide_start(t, line, col)
	cell := r.cells[c0]
	if cell.link != 0 {
		hit.url = link_url(t, cell.link)
		hit.line0, hit.col0, hit.line1, hit.col1 = line, c0, line, c0
		for hit.col0 > 0 && r.cells[hit.col0 - 1].link == cell.link do hit.col0 -= 1
		for hit.col1 + 1 < len(r.cells) && r.cells[hit.col1 + 1].link == cell.link do hit.col1 += 1
		return hit, true
	}
	// a URL in the text: the wrapped rows of the line are one string
	first, last := logical_bounds(t, line)
	b := strings.builder_make(context.temp_allocator)
	Pos :: struct { line, col: int }
	pos := make([dynamic]Pos, context.temp_allocator)
	for l in first ..= last {
		row := line_at(t, l)
		for x in 0 ..< len(row.cells) {
			c := row.cells[x]
			if has_attr(c, .Wide_Cont) do continue
			buf: [7]rune
			for ru in cell_runes(t, c, &buf) {
				before := strings.builder_len(b)
				strings.write_rune(&b, ru)
				for _ in before ..< strings.builder_len(b) do append(&pos, Pos{l, x})
			}
		}
	}
	text := strings.to_string(b)
	// which byte is the pointer on
	at := -1
	for p, i in pos do if p.line == line && p.col == c0 {
		at = i
		break
	}
	if at < 0 do return
	for scheme in URL_SCHEMES {
		from := 0
		for {
			k := strings.index(text[from:], scheme)
			if k < 0 do break
			start := from + k
			end := start
			for end < len(text) {
				r, n := utf8.decode_rune_in_string(text[end:])
				if !url_char(r) do break
				end += n
			}
			// trailing punctuation is not part of it; a closing bracket only when it was opened inside
			for end > start + len(scheme) {
				ch := text[end - 1]
				if ch == '.' || ch == ',' || ch == ';' || ch == ':' || ch == '!' || ch == '?' || ch == '\'' || ch == '*' {
					end -= 1
				} else if ch == ')' && strings.count(text[start:end], "(") < strings.count(text[start:end], ")") {
					end -= 1
				} else if ch == ']' && strings.count(text[start:end], "[") < strings.count(text[start:end], "]") {
					end -= 1
				} else {
					break
				}
			}
			if at >= start && at < end && end > start + len(scheme) {
				hit.url = text[start:end]
				hit.line0, hit.col0 = pos[start].line, pos[start].col
				hit.line1, hit.col1 = pos[end - 1].line, pos[end - 1].col
				if hit.line1 < line_count(t) {
					er := line_at(t, hit.line1)
					if hit.col1 < len(er.cells) && has_attr(er.cells[hit.col1], .Wide) do hit.col1 += 1
				}
				return hit, true
			}
			from = start + len(scheme)
			if from >= len(text) do break
		}
	}
	return
}

/// may Iris Terminal hand this link to the desktop? (only the usual kinds: a
/// program can put any text in a link)
url_allowed :: proc(url: string) -> bool {
	if len(url) == 0 || len(url) > 4096 do return false
	for c in transmute([]u8)url do if c < 0x20 || c == 0x7f do return false
	for s in URL_SCHEMES do if strings.has_prefix(url, s) do return true
	return strings.has_prefix(url, "sftp://") || strings.has_prefix(url, "ssh://")
}

// ---------------------------------------------------------------- prompts

/// the line of the previous shell prompt above `line` (OSC 133 ; A), or -1
prev_prompt :: proc(t: ^Term, line: int) -> int {
	for l := min(line, line_count(t)) - 1; l >= 0; l -= 1 do if line_at(t, l).prompt do return l
	return -1
}

next_prompt :: proc(t: ^Term, line: int) -> int {
	for l in max(line, -1) + 1 ..< line_count(t) do if line_at(t, l).prompt do return l
	return -1
}

/// the view so that `line` is its top row
view_line_at_top :: proc(t: ^Term, line: int) {
	t.view = clamp(t.sb.count - line, 0, t.sb.count)
	t.gen += 1
}

/// the line shown at the top of the screen
view_top_line :: proc(t: ^Term) -> int { return t.sb.count - t.view }
