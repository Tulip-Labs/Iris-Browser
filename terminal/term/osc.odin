// Operating system commands (OSC): titles, the working directory, links,
// the clipboard, colours, prompt marks; and the device control strings
// the terminal answers (XTGETTCAP, DECRQSS: "not supported").
package term

import "core:encoding/base64"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

@(private) TITLE_MAX :: 1024

@(private) osc_dispatch :: proc(t: ^Term, s: string) {
	t.gen += 1
	semi := strings.index_byte(s, ';')
	code_s := semi < 0 ? s : s[:semi]
	data := semi < 0 ? "" : s[semi + 1:]
	code, ok := strconv.parse_int(code_s, 10)
	if !ok do return
	switch code {
	case 0, 2:
		set_title(t, data)
	case 1:
		delete(t.icon_title)
		t.icon_title = strings.clone(data)
	case 4: osc_palette(t, data)
	case 104: osc_palette_reset(t, data)
	case 7: osc_cwd(t, data)
	case 8: osc_link(t, data)
	case 10, 11, 12: osc_dynamic(t, code, data)
	case 110: t.default_fg = t.theme_fg
	case 111: t.default_bg = t.theme_bg
	case 112: t.cursor_color = t.theme_cursor
	case 52: osc_clipboard(t, data)
	case 133: osc_prompt(t, data)
	}
}

@(private) set_title :: proc(t: ^Term, s: string) {
	if !utf8.valid_string(s) do return
	end := min(len(s), TITLE_MAX)
	// not in the middle of a character
	for end > 0 && end < len(s) && s[end] & 0xc0 == 0x80 do end -= 1
	title := strings.clone(s[:end])
	// control characters never reach the window title
	b := transmute([]u8)title
	for &c in b do if c < 0x20 || c == 0x7f do c = ' '
	delete(t.title)
	t.title = title
	t.events += {.Title}
}

/// %XX in a path
percent_decode :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_byte(s, '%') < 0 do return strings.clone(s, allocator)
	b := make([dynamic]u8, 0, len(s), allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			hi, ok1 := hex_val(s[i + 1])
			lo, ok2 := hex_val(s[i + 2])
			if ok1 && ok2 {
				append(&b, u8(hi << 4 | lo))
				i += 3
				continue
			}
		}
		append(&b, s[i])
		i += 1
	}
	return string(b[:])
}

@(private) hex_val :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9': return int(c - '0'), true
	case 'a' ..= 'f': return int(c - 'a' + 10), true
	case 'A' ..= 'F': return int(c - 'A' + 10), true
	}
	return 0, false
}

/// OSC 7: file://host/path
@(private) osc_cwd :: proc(t: ^Term, s: string) {
	rest := s
	if strings.has_prefix(rest, "file://") {
		rest = rest[7:]
		slash := strings.index_byte(rest, '/')
		if slash < 0 do return
		rest = rest[slash:]
	} else if !strings.has_prefix(rest, "/") {
		return
	}
	path := percent_decode(rest)
	delete(t.cwd)
	t.cwd = path
	t.events += {.Cwd}
}

/// OSC 8 ; params ; uri
@(private) osc_link :: proc(t: ^Term, s: string) {
	semi := strings.index_byte(s, ';')
	if semi < 0 {
		t.cur_link = 0
		return
	}
	uri := s[semi + 1:]
	t.cur_link = link_id(t, uri)
}

@(private) osc_prompt :: proc(t: ^Term, s: string) {
	if len(s) == 0 do return
	switch s[0] {
	case 'A':
		t.has_marks = true
		t.grid.rows[t.cursor.y].prompt = true
		t.cmd_running = false
		t.events += {.Prompt}
	case 'C': t.cmd_running = true
	case 'D':
		t.cmd_running = false
		if len(s) > 2 && s[1] == ';' {
			if v, ok := strconv.parse_int(s[2:], 10); ok do t.last_status = v
		}
	}
}

// ---------------------------------------------------------------- colours

/// "rgb:rr/gg/bb" (1 to 4 hex digits each) or "#rgb", "#rrggbb", "#rrrgggbbb", "#rrrrggggbbbb"
parse_color_spec :: proc(s: string) -> (c: RGB, ok: bool) {
	scale :: proc(v: string) -> (u8, bool) {
		if len(v) == 0 || len(v) > 4 do return 0, false
		n := 0
		for ch in transmute([]u8)v {
			h, ok := hex_val(ch)
			if !ok do return 0, false
			n = n << 4 | h
		}
		max_v := (1 << uint(4 * len(v))) - 1
		return u8((n * 255 + max_v / 2) / max_v), true
	}
	if strings.has_prefix(s, "rgb:") {
		parts := strings.split(s[4:], "/", context.temp_allocator)
		if len(parts) != 3 do return
		r, ok1 := scale(parts[0])
		g, ok2 := scale(parts[1])
		b, ok3 := scale(parts[2])
		if !(ok1 && ok2 && ok3) do return
		return {r, g, b}, true
	}
	if strings.has_prefix(s, "#") {
		h := s[1:]
		if len(h) == 0 || len(h) % 3 != 0 || len(h) > 12 do return
		k := len(h) / 3
		r, ok1 := scale(h[:k])
		g, ok2 := scale(h[k:2 * k])
		b, ok3 := scale(h[2 * k:])
		if !(ok1 && ok2 && ok3) do return
		return {r, g, b}, true
	}
	return
}

@(private) color_reply :: proc(c: RGB) -> string {
	return fmt.tprintf("rgb:%02x%02x/%02x%02x/%02x%02x", c.r, c.r, c.g, c.g, c.b, c.b)
}

@(private) osc_palette :: proc(t: ^Term, s: string) {
	parts := strings.split(s, ";", context.temp_allocator)
	for i := 0; i + 1 < len(parts); i += 2 {
		idx, ok := strconv.parse_int(parts[i], 10)
		if !ok || idx < 0 || idx > 255 do continue
		if parts[i + 1] == "?" {
			reply(t, fmt.tprintf("\x1b]4;%d;%s\x1b\\", idx, color_reply(t.palette[idx])))
		} else if c, ok2 := parse_color_spec(parts[i + 1]); ok2 {
			t.palette[idx] = c
		}
	}
}

@(private) osc_palette_reset :: proc(t: ^Term, s: string) {
	if len(s) == 0 {
		t.palette = t.theme_palette
		return
	}
	for part in strings.split(s, ";", context.temp_allocator) {
		if idx, ok := strconv.parse_int(part, 10); ok && idx >= 0 && idx < 256 do t.palette[idx] = t.theme_palette[idx]
	}
}

@(private) osc_dynamic :: proc(t: ^Term, code: int, s: string) {
	// "10;spec" (and "10;spec;spec" sets the next ones too: only the first is read)
	spec := s
	if semi := strings.index_byte(s, ';'); semi >= 0 do spec = s[:semi]
	target: ^RGB
	switch code {
	case 10: target = &t.default_fg
	case 11: target = &t.default_bg
	case 12: target = &t.cursor_color
	}
	if spec == "?" {
		reply(t, fmt.tprintf("\x1b]%d;%s\x1b\\", code, color_reply(target^)))
	} else if c, ok := parse_color_spec(spec); ok {
		target^ = c
	}
}

// ---------------------------------------------------------------- the clipboard

/// OSC 52 ; targets ; base64 (writing only: a program cannot read what you copied)
@(private) osc_clipboard :: proc(t: ^Term, s: string) {
	semi := strings.index_byte(s, ';')
	if semi < 0 do return
	targets, data := s[:semi], s[semi + 1:]
	if data == "?" || len(data) == 0 do return
	dec, err := base64.decode(data, allocator = context.temp_allocator)
	if err != nil || len(dec) == 0 do return
	t.clip_target = 'c'
	if len(targets) > 0 && (strings.contains_rune(targets, 'p') || strings.contains_rune(targets, 's')) && !strings.contains_rune(targets, 'c') {
		t.clip_target = 'p'
	}
	clear(&t.clip_write)
	append(&t.clip_write, ..dec)
	t.events += {.Clipboard}
}

// ---------------------------------------------------------------- DCS

@(private) dcs_dispatch :: proc(t: ^Term, s: string) {
	// XTGETTCAP (+q) and DECRQSS ($q): answered "invalid", so a program that asks does not wait
	if strings.has_prefix(s, "+q") {
		reply(t, "\x1bP0+r\x1b\\")
	} else if strings.has_prefix(s, "$q") {
		reply(t, "\x1bP0$r\x1b\\")
	}
}
