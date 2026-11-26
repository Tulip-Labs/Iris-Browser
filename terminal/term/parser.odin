// The VT500-class parser (Paul Williams' state machine, with UTF-8 in the
// ground state): bytes in, calls into the terminal out.
package term

import "core:unicode/utf8"

MAX_PARAMS :: 32
OSC_LIMIT :: 1 << 20
DCS_LIMIT :: 1 << 12

Parser_State :: enum u8 {
	Ground,
	Escape,
	Escape_Inter,
	Csi_Entry,
	Csi_Param,
	Csi_Inter,
	Csi_Ignore,
	Osc,
	Dcs,
	Sos_Pm_Apc, // strings that are read and dropped
}

Parser :: struct {
	state:      Parser_State,
	params:     [MAX_PARAMS]i32, // -1: not given
	sub:        [MAX_PARAMS]bool, // separated from the one before by ':'
	np:         int, // index of the parameter being read
	has_params: bool,
	inter:      [2]u8,
	ni:         int,
	marker:     u8, // < = > ? at the start of a CSI
	osc:        [dynamic]u8,
	dcs:        [dynamic]u8,
	utf_cp:     u32,
	utf_need:   int,
	utf_min:    u32,
}

@(private) csi_clear :: proc(p: ^Parser) {
	p.np = 0
	p.params[0] = -1
	for i in 0 ..< MAX_PARAMS do p.sub[i] = false
	p.has_params = false
	p.ni = 0
	p.marker = 0
}

/// the bytes the program wrote
term_feed :: proc(t: ^Term, data: []u8) {
	p := &t.parser
	i := 0
	n := len(data)
	for i < n {
		if p.state == .Ground && p.utf_need == 0 {
			j := i
			for j < n && data[j] >= 0x20 && data[j] < 0x7f do j += 1
			if j > i {
				print_ascii(t, data[i:j])
				i = j
				continue
			}
		}
		b := data[i]
		i += 1
		step(t, p, b)
	}
}

@(private) step :: proc(t: ^Term, p: ^Parser, b: u8) {
	// bytes that act in every state
	switch p.state {
	case .Ground:
		ground(t, p, b)
		return
	case .Osc, .Dcs, .Sos_Pm_Apc:
		string_byte(t, p, b)
		return
	case .Escape, .Escape_Inter, .Csi_Entry, .Csi_Param, .Csi_Inter, .Csi_Ignore:
	}
	switch b {
	case 0x18, 0x1a: // CAN, SUB: cancel
		p.state = .Ground
		return
	case 0x1b:
		p.state = .Escape
		p.ni = 0
		return
	case 0x00 ..= 0x17, 0x19, 0x1c ..= 0x1f:
		execute(t, b)
		return
	case 0x7f:
		return
	}
	switch p.state {
	case .Escape:
		switch b {
		case 0x20 ..= 0x2f:
			p.inter[0] = b
			p.ni = 1
			p.state = .Escape_Inter
		case '[':
			csi_clear(p)
			p.state = .Csi_Entry
		case ']':
			clear(&p.osc)
			p.state = .Osc
		case 'P':
			clear(&p.dcs)
			p.state = .Dcs
		case 'X', '^', '_':
			p.state = .Sos_Pm_Apc
		case 0x30 ..= 0x7e:
			esc_dispatch(t, 0, b)
			p.state = .Ground
		case:
			p.state = .Ground
		}
	case .Escape_Inter:
		switch b {
		case 0x20 ..= 0x2f:
			if p.ni < 2 do p.inter[p.ni] = b
			p.ni += 1
		case 0x30 ..= 0x7e:
			esc_dispatch(t, p.inter[0], b, p.ni > 1 ? p.inter[1] : 0)
			p.state = .Ground
		case:
			p.state = .Ground
		}
	case .Csi_Entry, .Csi_Param:
		switch b {
		case '0' ..= '9':
			if p.state == .Csi_Entry do p.state = .Csi_Param
			p.has_params = true
			cur := &p.params[p.np]
			if cur^ < 0 do cur^ = 0
			if cur^ < 1 << 24 do cur^ = cur^ * 10 + i32(b - '0')
		case ';', ':':
			if p.state == .Csi_Entry do p.state = .Csi_Param
			p.has_params = true
			if p.np + 1 < MAX_PARAMS {
				p.np += 1
				p.params[p.np] = -1
				p.sub[p.np] = b == ':'
			}
		case '<', '=', '>', '?':
			if p.state == .Csi_Entry {
				p.marker = b
				p.state = .Csi_Param
			} else {
				p.state = .Csi_Ignore
			}
		case 0x20 ..= 0x2f:
			p.inter[0] = b
			p.ni = 1
			p.state = .Csi_Inter
		case 0x40 ..= 0x7e:
			csi_dispatch(t, p, b)
			p.state = .Ground
		case:
			p.state = .Csi_Ignore
		}
	case .Csi_Inter:
		switch b {
		case 0x20 ..= 0x2f:
			if p.ni < 2 do p.inter[p.ni] = b
			p.ni += 1
		case 0x40 ..= 0x7e:
			csi_dispatch(t, p, b)
			p.state = .Ground
		case:
			p.state = .Csi_Ignore
		}
	case .Csi_Ignore:
		if b >= 0x40 && b <= 0x7e do p.state = .Ground
	case .Ground, .Osc, .Dcs, .Sos_Pm_Apc:
	}
}

@(private) ground :: proc(t: ^Term, p: ^Parser, b: u8) {
	if p.utf_need > 0 {
		if b & 0xc0 == 0x80 {
			p.utf_cp = p.utf_cp << 6 | u32(b & 0x3f)
			p.utf_need -= 1
			if p.utf_need == 0 {
				cp := p.utf_cp
				if cp < p.utf_min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) do cp = 0xfffd
				print_rune(t, rune(cp))
			}
			return
		}
		// a sequence cut short: a replacement character, and this byte starts afresh
		p.utf_need = 0
		print_rune(t, 0xfffd)
	}
	switch {
	case b < 0x20:
		if b == 0x1b {
			p.state = .Escape
			p.ni = 0
		} else if b != 0x18 && b != 0x1a {
			execute(t, b)
		}
	case b < 0x7f:
		print_ascii(t, {b})
	case b == 0x7f:
	case b & 0xe0 == 0xc0:
		p.utf_cp, p.utf_need, p.utf_min = u32(b & 0x1f), 1, 0x80
	case b & 0xf0 == 0xe0:
		p.utf_cp, p.utf_need, p.utf_min = u32(b & 0x0f), 2, 0x800
	case b & 0xf8 == 0xf0:
		p.utf_cp, p.utf_need, p.utf_min = u32(b & 0x07), 3, 0x10000
	case:
		print_rune(t, 0xfffd)
	}
}

@(private) string_byte :: proc(t: ^Term, p: ^Parser, b: u8) {
	switch b {
	case 0x1b:
		// ESC ends the string (ESC \ is its terminator; anything else starts a sequence)
		finish_string(t, p)
		p.state = .Escape
		p.ni = 0
		return
	case 0x07:
		if p.state == .Osc {
			finish_string(t, p)
			p.state = .Ground
			return
		}
	case 0x18, 0x1a:
		p.state = .Ground
		return
	}
	switch p.state {
	case .Osc:
		if b >= 0x20 && len(p.osc) < OSC_LIMIT do append(&p.osc, b)
	case .Dcs:
		if len(p.dcs) < DCS_LIMIT do append(&p.dcs, b)
	case .Ground, .Escape, .Escape_Inter, .Csi_Entry, .Csi_Param, .Csi_Inter, .Csi_Ignore, .Sos_Pm_Apc:
	}
}

@(private) finish_string :: proc(t: ^Term, p: ^Parser) {
	#partial switch p.state {
	case .Osc: osc_dispatch(t, string(p.osc[:]))
	case .Dcs: dcs_dispatch(t, string(p.dcs[:]))
	}
	if cap(p.osc) > 1 << 16 do shrink(&p.osc)
}

@(private) execute :: proc(t: ^Term, b: u8) {
	switch b {
	case 0x07: t.events += {.Bell}
	case 0x08:
		if t.cursor.x > 0 do t.cursor.x -= 1
		t.cursor.pending = false
	case 0x09: tab_forward(t, 1)
	case 0x0a, 0x0b, 0x0c:
		index(t)
		if t.modes.newline do t.cursor.x = 0
		t.cursor.pending = false
	case 0x0d:
		t.cursor.x = 0
		t.cursor.pending = false
	case 0x0e: t.gl = 1
	case 0x0f: t.gl = 0
	}
	t.gen += 1
}

@(private) shrink :: proc(d: ^[dynamic]u8) {
	delete(d^)
	d^ = nil
}

@(private) _unused_utf8 :: utf8.RUNE_ERROR
