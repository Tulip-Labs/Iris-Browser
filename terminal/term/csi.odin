// What the control sequences do: CSI (cursor, erase, scroll, modes, SGR,
// reports) and the plain ESC ones.
package term

import "core:fmt"
import "core:strings"

/// parameter i, or `def` when it was not given
@(private) pv :: #force_inline proc(p: ^Parser, i: int, def: int) -> int {
	if !p.has_params || i > p.np || p.params[i] < 0 do return def
	return int(p.params[i])
}

/// a count: 0 and missing both mean 1
@(private) pn :: #force_inline proc(p: ^Parser, i: int) -> int {
	v := pv(p, i, 1)
	return v == 0 ? 1 : v
}

@(private) esc_dispatch :: proc(t: ^Term, inter: u8, final: u8, inter2: u8 = 0) {
	t.gen += 1
	switch inter {
	case 0:
		switch final {
		case '7': save_cursor(t)
		case '8': restore_cursor(t)
		case 'D': index(t)
		case 'E':
			index(t)
			t.cursor.x = 0
			t.cursor.pending = false
		case 'H':
			if t.cursor.x < len(t.tabs) do t.tabs[t.cursor.x] = true
		case 'M': reverse_index(t)
		case 'Z': reply(t, "\x1b[?62;22c")
		case 'c': term_reset(t)
		case '=': t.modes.app_keypad = true
		case '>': t.modes.app_keypad = false
		case 'n': t.gl = 2
		case 'o': t.gl = 3
		}
	case '(', ')', '*', '+':
		idx := inter == '(' ? 0 : inter == ')' ? 1 : inter == '*' ? 2 : 3
		t.charset[idx] = final == '0' ? '0' : 'B'
	case '#':
		if final == '8' {
			for y in 0 ..< t.rows do for x in 0 ..< t.cols do t.grid.rows[y].cells[x] = Cell{ch = 'E'}
		}
	}
}

@(private) csi_dispatch :: proc(t: ^Term, p: ^Parser, final: u8) {
	t.gen += 1
	inter := p.ni > 0 ? p.inter[0] : u8(0)
	switch p.marker {
	case 0:
	case '?':
		switch final {
		case 'h': set_modes(t, p, true, true)
		case 'l': set_modes(t, p, false, true)
		case 'n': dsr_private(t, p)
		case 'p':
			if inter == '$' do report_mode(t, pv(p, 0, 0), true)
		}
		return
	case '>':
		switch final {
		case 'c': reply(t, "\x1b[>0;115;0c")
		case 'q': reply(t, fmt.tprintf("\x1bP>|iris-terminal %s\x1b\\", t.version))
		}
		return
	case:
		return
	}
	switch inter {
	case 0:
	case ' ':
		if final == 'q' {
			v := pv(p, 0, 0)
			switch v {
			case 0:
				t.cursor_style, t.cursor_style_set = .Block, false
			case 1, 2:
				t.cursor_style, t.cursor_style_set = .Block, true
			case 3, 4:
				t.cursor_style, t.cursor_style_set = .Underline, true
			case 5, 6:
				t.cursor_style, t.cursor_style_set = .Bar, true
			}
			t.modes.cursor_blink = v == 0 || v % 2 == 1
		}
		return
	case '!':
		if final == 'p' do term_soft_reset(t)
		return
	case '$':
		if final == 'p' do report_mode(t, pv(p, 0, 0), false)
		return
	case:
		return
	}

	c := &t.cursor
	switch final {
	case '@': insert_chars(t, pn(p, 0))
	case 'A':
		top := c.y >= t.top ? t.top : 0
		c.y = max(c.y - pn(p, 0), top)
		c.pending = false
	case 'B', 'e':
		bot := c.y <= t.bottom ? t.bottom : t.rows - 1
		c.y = min(c.y + pn(p, 0), bot)
		c.pending = false
	case 'C', 'a':
		c.x = min(c.x + pn(p, 0), t.cols - 1)
		c.pending = false
	case 'D':
		c.x = max(c.x - pn(p, 0), 0)
		c.pending = false
	case 'E':
		c.y = min(c.y + pn(p, 0), c.y <= t.bottom ? t.bottom : t.rows - 1)
		c.x, c.pending = 0, false
	case 'F':
		c.y = max(c.y - pn(p, 0), c.y >= t.top ? t.top : 0)
		c.x, c.pending = 0, false
	case 'G', '`':
		c.x = clamp(pn(p, 0) - 1, 0, t.cols - 1)
		c.pending = false
	case 'H', 'f': cursor_to(t, pn(p, 1) - 1, pn(p, 0) - 1)
	case 'I': tab_forward(t, pn(p, 0))
	case 'J': erase_in_display(t, pv(p, 0, 0))
	case 'K': erase_in_line(t, pv(p, 0, 0))
	case 'L': insert_lines(t, pn(p, 0))
	case 'M': delete_lines(t, pn(p, 0))
	case 'P': delete_chars(t, pn(p, 0))
	case 'S': scroll_up(t, pn(p, 0), t.top, t.bottom)
	case 'T':
		if p.np == 0 do scroll_down(t, pn(p, 0), t.top, t.bottom)
	case 'X': erase_chars(t, pn(p, 0))
	case 'Z': tab_back(t, pn(p, 0))
	case 'b':
		if t.last_char != 0 {
			n := min(pn(p, 0), 65535)
			for _ in 0 ..< n do print_rune(t, t.last_char)
		}
	case 'c':
		if pv(p, 0, 0) == 0 do reply(t, "\x1b[?62;22c")
	case 'd':
		y := clamp(pn(p, 0) - 1, 0, t.rows - 1)
		if t.modes.origin { c.y = clamp(y + t.top, t.top, t.bottom) } else { c.y = y }
		c.pending = false
	case 'g':
		switch pv(p, 0, 0) {
		case 0: if c.x < len(t.tabs) do t.tabs[c.x] = false
		case 3: for i in 0 ..< len(t.tabs) do t.tabs[i] = false
		}
	case 'h': set_modes(t, p, true, false)
	case 'l': set_modes(t, p, false, false)
	case 'm': sgr(t, p)
	case 'n':
		switch pv(p, 0, 0) {
		case 5: reply(t, "\x1b[0n")
		case 6:
			y := t.modes.origin ? c.y - t.top : c.y
			reply(t, fmt.tprintf("\x1b[%d;%dR", y + 1, c.x + 1))
		}
	case 'r':
		top, bot := pn(p, 0) - 1, pv(p, 1, 0)
		if bot == 0 do bot = t.rows
		bot -= 1
		if top < bot && bot < t.rows {
			t.top, t.bottom = top, bot
			cursor_to(t, 0, 0)
		}
	case 's':
		if !p.has_params do save_cursor(t)
	case 'u':
		if !p.has_params do restore_cursor(t)
	case 't': window_ops(t, p)
	}
}

@(private) window_ops :: proc(t: ^Term, p: ^Parser) {
	switch pv(p, 0, 0) {
	case 14: reply(t, fmt.tprintf("\x1b[4;%d;%dt", t.rows * t.cell_px.y, t.cols * t.cell_px.x))
	case 16: reply(t, fmt.tprintf("\x1b[6;%d;%dt", t.cell_px.y, t.cell_px.x))
	case 18, 19: reply(t, fmt.tprintf("\x1b[8;%d;%dt", t.rows, t.cols))
	case 22:
		if len(t.title_stack) < 16 do append(&t.title_stack, strings.clone(t.title))
	case 23:
		if n := len(t.title_stack); n > 0 {
			delete(t.title)
			t.title = pop(&t.title_stack)
			t.events += {.Title}
		}
	}
}

@(private) dsr_private :: proc(t: ^Term, p: ^Parser) {
	switch pv(p, 0, 0) {
	case 6:
		y := t.modes.origin ? t.cursor.y - t.top : t.cursor.y
		reply(t, fmt.tprintf("\x1b[?%d;%dR", y + 1, t.cursor.x + 1))
	case 15: reply(t, "\x1b[?13n")
	case 25: reply(t, "\x1b[?20n")
	case 26: reply(t, "\x1b[?27;1;0;0n")
	}
}

/// the state of a mode for DECRQM: 0 not known, 1 set, 2 reset
@(private) mode_state :: proc(t: ^Term, ps: int, private: bool) -> int {
	b :: proc(v: bool) -> int { return v ? 1 : 2 }
	m := &t.modes
	if !private {
		switch ps {
		case 4: return b(m.insert)
		case 12: return 1
		case 20: return b(m.newline)
		}
		return 0
	}
	switch ps {
	case 1: return b(m.app_cursor)
	case 3: return 4
	case 5: return b(m.reverse)
	case 6: return b(m.origin)
	case 7: return b(m.autowrap)
	case 8: return 1
	case 9: return b(m.mouse == .X10)
	case 12: return b(m.cursor_blink)
	case 25: return b(m.cursor_visible)
	case 47, 1047, 1049: return b(m.alt_screen)
	case 66: return b(m.app_keypad)
	case 1000: return b(m.mouse == .Press_Release)
	case 1002: return b(m.mouse == .Drag)
	case 1003: return b(m.mouse == .Any)
	case 1004: return b(m.focus_events)
	case 1005: return b(m.mouse_enc == .Utf8)
	case 1006: return b(m.mouse_enc == .Sgr)
	case 1007: return b(m.alt_scroll)
	case 1015: return b(m.mouse_enc == .Urxvt)
	case 2004: return b(m.bracketed)
	case 2026: return b(m.sync)
	}
	return 0
}

@(private) report_mode :: proc(t: ^Term, ps: int, private: bool) {
	reply(t, fmt.tprintf("\x1b[%s%d;%d$y", private ? "?" : "", ps, mode_state(t, ps, private)))
}

@(private) set_modes :: proc(t: ^Term, p: ^Parser, on: bool, private: bool) {
	for i in 0 ..= p.np {
		ps := pv(p, i, 0)
		if !p.has_params do break
		if private { set_private_mode(t, ps, on) } else { set_ansi_mode(t, ps, on) }
	}
}

@(private) set_ansi_mode :: proc(t: ^Term, ps: int, on: bool) {
	switch ps {
	case 4: t.modes.insert = on
	case 20: t.modes.newline = on
	}
}

@(private) set_private_mode :: proc(t: ^Term, ps: int, on: bool) {
	m := &t.modes
	switch ps {
	case 1: m.app_cursor = on
	case 5: m.reverse = on
	case 6:
		m.origin = on
		cursor_to(t, 0, 0)
	case 7: m.autowrap = on
	case 9: m.mouse = on ? .X10 : (m.mouse == .X10 ? .None : m.mouse)
	case 12: m.cursor_blink = on
	case 25: m.cursor_visible = on
	case 47, 1047: term_alt_screen(t, on, false, on)
	case 1048:
		if on { save_cursor(t) } else { restore_cursor(t) }
	case 1049: term_alt_screen(t, on, true, on)
	case 66: m.app_keypad = on
	case 1000: m.mouse = on ? .Press_Release : (m.mouse == .Press_Release ? .None : m.mouse)
	case 1002: m.mouse = on ? .Drag : (m.mouse == .Drag ? .None : m.mouse)
	case 1003: m.mouse = on ? .Any : (m.mouse == .Any ? .None : m.mouse)
	case 1004: m.focus_events = on
	case 1005: m.mouse_enc = on ? .Utf8 : (m.mouse_enc == .Utf8 ? .Default : m.mouse_enc)
	case 1006: m.mouse_enc = on ? .Sgr : (m.mouse_enc == .Sgr ? .Default : m.mouse_enc)
	case 1007: m.alt_scroll = on
	case 1015: m.mouse_enc = on ? .Urxvt : (m.mouse_enc == .Urxvt ? .Default : m.mouse_enc)
	case 2004: m.bracketed = on
	case 2026: m.sync = on
	}
}

// ---------------------------------------------------------------- SGR

@(private) set_attr :: #force_inline proc(pen: ^Pen, a: Attr, on: bool) {
	if on { pen.attr |= 1 << u16(a) } else { pen.attr &= ~(1 << u16(a)) }
}

@(private) set_underline :: #force_inline proc(pen: ^Pen, u: Underline) {
	pen.attr = pen.attr & ~UL_MASK | u16(u) << UL_SHIFT
}

/// the colour after 38 / 48 / 58 at parameter i: both `;5;n` and `:5:n`
/// forms, and true colour `;2;r;g;b` / `:2::r:g:b`. Returns where to go on.
@(private) extended_color :: proc(p: ^Parser, i: int) -> (c: Color, next: int, ok: bool) {
	next = i + 1
	if next > p.np do return
	colon := p.sub[next]
	// the sub-parameters of a colon form
	end := next
	if colon do for end + 1 <= p.np && p.sub[end + 1] do end += 1
	mode := pv(p, next, -1)
	switch mode {
	case 5:
		if next + 1 > p.np do return {}, p.np + 1, false
		idx := pv(p, next + 1, 0)
		return color_idx(u8(clamp(idx, 0, 255))), colon ? end + 1 : next + 2, true
	case 2:
		first := next + 1
		// ":2::r:g:b" carries a colour-space id first
		if colon && end - next >= 4 do first += 1
		if first + 2 > p.np do return {}, p.np + 1, false
		r, g, b := pv(p, first, 0), pv(p, first + 1, 0), pv(p, first + 2, 0)
		return color_rgb(u8(clamp(r, 0, 255)), u8(clamp(g, 0, 255)), u8(clamp(b, 0, 255))), colon ? end + 1 : first + 3, true
	}
	return {}, next + 1, false
}

@(private) sgr :: proc(t: ^Term, p: ^Parser) {
	pen := &t.pen
	if !p.has_params {
		pen^ = {link = pen.link}
		return
	}
	i := 0
	for i <= p.np {
		v := pv(p, i, 0)
		i += 1
		switch v {
		case 0:
			link := pen.link
			pen^ = {link = link}
		case 1: set_attr(pen, .Bold, true)
		case 2: set_attr(pen, .Dim, true)
		case 3: set_attr(pen, .Italic, true)
		case 4:
			u := Underline.Single
			if i <= p.np && p.sub[i] {
				switch pv(p, i, 1) {
				case 0: u = .None
				case 2: u = .Double
				case 3: u = .Curly
				case 4: u = .Dotted
				case 5: u = .Dashed
				}
				i += 1
			}
			set_underline(pen, u)
		case 5, 6: set_attr(pen, .Blink, true)
		case 7: set_attr(pen, .Reverse, true)
		case 8: set_attr(pen, .Hidden, true)
		case 9: set_attr(pen, .Strike, true)
		case 21: set_underline(pen, .Double)
		case 22:
			set_attr(pen, .Bold, false)
			set_attr(pen, .Dim, false)
		case 23: set_attr(pen, .Italic, false)
		case 24: set_underline(pen, .None)
		case 25: set_attr(pen, .Blink, false)
		case 27: set_attr(pen, .Reverse, false)
		case 28: set_attr(pen, .Hidden, false)
		case 29: set_attr(pen, .Strike, false)
		case 30 ..= 37: pen.fg = color_idx(u8(v - 30))
		case 38:
			if c, nx, ok := extended_color(p, i - 1); ok { pen.fg = c; i = nx } else { i = nx }
		case 39: pen.fg = COLOR_DEFAULT
		case 40 ..= 47: pen.bg = color_idx(u8(v - 40))
		case 48:
			if c, nx, ok := extended_color(p, i - 1); ok { pen.bg = c; i = nx } else { i = nx }
		case 49: pen.bg = COLOR_DEFAULT
		case 53: set_attr(pen, .Overline, true)
		case 55: set_attr(pen, .Overline, false)
		case 58:
			_, nx, _ := extended_color(p, i - 1) // the underline colour is not drawn
			i = nx
		case 59:
		case 90 ..= 97: pen.fg = color_idx(u8(v - 90 + 8))
		case 100 ..= 107: pen.bg = color_idx(u8(v - 100 + 8))
		}
	}
}
