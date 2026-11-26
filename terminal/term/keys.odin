// Keys and mouse buttons as the program wants them: xterm's encodings
// (cursor keys, keypad, modifiers, function keys; X10, normal, button, any
// and SGR mouse reporting).
package term

import "core:fmt"
import "core:unicode/utf8"

Mod :: enum u8 { Shift, Alt, Ctrl, Logo }
Mods :: bit_set[Mod; u8]

// keysyms (X11), the ones the terminal treats specially
KS_BackSpace :: 0xff08
KS_Tab :: 0xff09
KS_ISO_Left_Tab :: 0xfe20
KS_Return :: 0xff0d
KS_Escape :: 0xff1b
KS_Home :: 0xff50
KS_Left :: 0xff51
KS_Up :: 0xff52
KS_Right :: 0xff53
KS_Down :: 0xff54
KS_Page_Up :: 0xff55
KS_Page_Down :: 0xff56
KS_End :: 0xff57
KS_Begin :: 0xff58
KS_Insert :: 0xff63
KS_Delete :: 0xffff
KS_KP_Enter :: 0xff8d
KS_KP_Home :: 0xff95
KS_KP_Left :: 0xff96
KS_KP_Up :: 0xff97
KS_KP_Right :: 0xff98
KS_KP_Down :: 0xff99
KS_KP_Page_Up :: 0xff9a
KS_KP_Page_Down :: 0xff9b
KS_KP_End :: 0xff9c
KS_KP_Begin :: 0xff9d
KS_KP_Insert :: 0xff9e
KS_KP_Delete :: 0xff9f
KS_KP_Multiply :: 0xffaa
KS_KP_Add :: 0xffab
KS_KP_Separator :: 0xffac
KS_KP_Subtract :: 0xffad
KS_KP_Decimal :: 0xffae
KS_KP_Divide :: 0xffaf
KS_KP_0 :: 0xffb0
KS_KP_9 :: 0xffb9
KS_F1 :: 0xffbe
KS_F24 :: 0xffd5
KS_space :: 0x20

/// the Unicode character of a keysym (0 when it is not one)
keysym_rune :: proc "contextless" (sym: u32) -> rune {
	switch {
	case sym >= 0x20 && sym <= 0x7e: return rune(sym)
	case sym >= 0xa0 && sym <= 0xff: return rune(sym)
	case sym >= 0x01000100 && sym <= 0x0110ffff: return rune(sym - 0x01000000)
	}
	return 0
}

@(private) mod_param :: proc(m: Mods) -> int {
	v := 1
	if .Shift in m do v += 1
	if .Alt in m do v += 2
	if .Ctrl in m do v += 4
	return v
}

@(private) csi_final :: proc(out: ^[dynamic]u8, t: ^Term, letter: u8, m: Mods) {
	if p := mod_param(m); p > 1 {
		append(out, ..transmute([]u8)fmt.tprintf("\x1b[1;%d%c", p, letter))
	} else if t.modes.app_cursor {
		append(out, 0x1b, 'O', letter)
	} else {
		append(out, 0x1b, '[', letter)
	}
}

@(private) tilde :: proc(out: ^[dynamic]u8, n: int, m: Mods) {
	if p := mod_param(m); p > 1 {
		append(out, ..transmute([]u8)fmt.tprintf("\x1b[%d;%d~", n, p))
	} else {
		append(out, ..transmute([]u8)fmt.tprintf("\x1b[%d~", n))
	}
}

@(private) ss3 :: proc(out: ^[dynamic]u8, letter: u8, m: Mods) {
	if p := mod_param(m); p > 1 {
		append(out, ..transmute([]u8)fmt.tprintf("\x1b[1;%d%c", p, letter))
	} else {
		append(out, 0x1b, 'O', letter)
	}
}

/// the control character a Ctrl chord types (0..31 and 127), when it has one
ctrl_char :: proc "contextless" (r: rune) -> (c: u8, ok: bool) {
	switch {
	case r >= 'a' && r <= 'z': return u8(r - 'a' + 1), true
	case r >= 'A' && r <= 'Z': return u8(r - 'A' + 1), true
	}
	switch r {
	case ' ', '@', '2': return 0, true
	case '[', '3': return 0x1b, true
	case '\\', '4': return 0x1c, true
	case ']', '5': return 0x1d, true
	case '^', '6': return 0x1e, true
	case '_', '/', '7', '-': return 0x1f, true
	case '?', '8': return 0x7f, true
	}
	return 0, false
}

/// the bytes a key press sends. `text` is what the keyboard layout types
/// for it (empty for control keys, and with Ctrl or Alt held).
encode_key :: proc(t: ^Term, out: ^[dynamic]u8, sym: u32, mods: Mods, text: string) {
	m := mods - {.Logo}
	letter :: proc(out: ^[dynamic]u8, t: ^Term, l: u8, m: Mods) { csi_final(out, t, l, m) }
	switch sym {
	case KS_Up, KS_KP_Up: letter(out, t, 'A', m); return
	case KS_Down, KS_KP_Down: letter(out, t, 'B', m); return
	case KS_Right, KS_KP_Right: letter(out, t, 'C', m); return
	case KS_Left, KS_KP_Left: letter(out, t, 'D', m); return
	case KS_Home, KS_KP_Home: letter(out, t, 'H', m); return
	case KS_End, KS_KP_End: letter(out, t, 'F', m); return
	case KS_Begin, KS_KP_Begin: letter(out, t, 'E', m); return
	case KS_Insert, KS_KP_Insert: tilde(out, 2, m); return
	case KS_Delete, KS_KP_Delete: tilde(out, 3, m); return
	case KS_Page_Up, KS_KP_Page_Up: tilde(out, 5, m); return
	case KS_Page_Down, KS_KP_Page_Down: tilde(out, 6, m); return
	case KS_BackSpace:
		if .Alt in m do append(out, 0x1b)
		append(out, .Ctrl in m ? 0x08 : 0x7f)
		return
	case KS_Tab, KS_ISO_Left_Tab:
		if sym == KS_ISO_Left_Tab || .Shift in m {
			append(out, 0x1b, '[', 'Z')
		} else {
			if .Alt in m do append(out, 0x1b)
			append(out, '\t')
		}
		return
	case KS_Return:
		if .Alt in m do append(out, 0x1b)
		append(out, '\r')
		return
	case KS_KP_Enter:
		if t.modes.app_keypad && m == {} {
			append(out, 0x1b, 'O', 'M')
		} else {
			if .Alt in m do append(out, 0x1b)
			append(out, '\r')
		}
		return
	case KS_Escape:
		if .Alt in m do append(out, 0x1b)
		append(out, 0x1b)
		return
	}
	if sym >= KS_F1 && sym <= KS_F24 {
		n := int(sym - KS_F1) + 1
		switch {
		case n <= 4: ss3(out, u8('P' + n - 1), m)
		case:
			codes := [?]int{15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34, 35, 36, 37, 38}
			if n - 5 < len(codes) do tilde(out, codes[n - 5], m)
		}
		return
	}
	// the keypad in application mode
	if t.modes.app_keypad && m == {} {
		app: u8 = 0
		switch {
		case sym >= KS_KP_0 && sym <= KS_KP_9: app = u8('p' + (sym - KS_KP_0))
		case sym == KS_KP_Multiply: app = 'j'
		case sym == KS_KP_Add: app = 'k'
		case sym == KS_KP_Separator: app = 'l'
		case sym == KS_KP_Subtract: app = 'm'
		case sym == KS_KP_Decimal: app = 'n'
		case sym == KS_KP_Divide: app = 'o'
		}
		if app != 0 {
			append(out, 0x1b, 'O', app)
			return
		}
	}
	// characters
	r := keysym_rune(sym)
	if sym >= KS_KP_Multiply && sym <= KS_KP_9 && r == 0 {
		// the keypad types its own character when it is not in application mode
		switch {
		case sym >= KS_KP_0: r = rune('0' + (sym - KS_KP_0))
		case sym == KS_KP_Multiply: r = '*'
		case sym == KS_KP_Add: r = '+'
		case sym == KS_KP_Separator: r = ','
		case sym == KS_KP_Subtract: r = '-'
		case sym == KS_KP_Decimal: r = '.'
		case sym == KS_KP_Divide: r = '/'
		}
	}
	if .Ctrl in m && r != 0 {
		if c, ok := ctrl_char(r); ok {
			if .Alt in m do append(out, 0x1b)
			append(out, c)
			return
		}
	}
	if len(text) > 0 {
		if .Alt in m do append(out, 0x1b)
		append(out, ..transmute([]u8)text)
	} else if r != 0 && (.Alt in m || .Ctrl in m) {
		if .Alt in m do append(out, 0x1b)
		buf, n := utf8.encode_rune(r)
		append(out, ..buf[:n])
	}
}

// ---------------------------------------------------------------- the mouse

Mouse_Kind :: enum u8 { Press, Release, Motion, Wheel_Up, Wheel_Down, Wheel_Left, Wheel_Right }

Mouse_Event :: struct {
	kind:   Mouse_Kind,
	button: u8, // 0 left, 1 middle, 2 right (for press, release, and motion with a button down)
	held:   bool, // a button is down (for motion)
	x, y:   int, // cell, from 0
	mods:   Mods,
}

/// does the program want this event?
mouse_wants :: proc(t: ^Term, e: Mouse_Event) -> bool {
	switch t.modes.mouse {
	case .None: return false
	case .X10: return e.kind == .Press
	case .Press_Release: return e.kind != .Motion
	case .Drag: return e.kind != .Motion || e.held
	case .Any: return true
	}
	return false
}

/// the report for a mouse event (nothing when the program does not want it)
encode_mouse :: proc(t: ^Term, out: ^[dynamic]u8, e: Mouse_Event) -> bool {
	if !mouse_wants(t, e) do return false
	cb: int
	switch e.kind {
	case .Press, .Release, .Motion: cb = int(e.button)
	case .Wheel_Up: cb = 64
	case .Wheel_Down: cb = 65
	case .Wheel_Left: cb = 66
	case .Wheel_Right: cb = 67
	}
	sgr := t.modes.mouse_enc == .Sgr
	if e.kind == .Release && !sgr do cb = 3
	if t.modes.mouse != .X10 {
		if .Shift in e.mods do cb += 4
		if .Alt in e.mods do cb += 8
		if .Ctrl in e.mods do cb += 16
	}
	if e.kind == .Motion do cb += 32
	x, y := e.x + 1, e.y + 1
	switch t.modes.mouse_enc {
	case .Sgr:
		append(out, ..transmute([]u8)fmt.tprintf("\x1b[<%d;%d;%d%c", cb, x, y, e.kind == .Release ? 'm' : 'M'))
	case .Urxvt:
		append(out, ..transmute([]u8)fmt.tprintf("\x1b[%d;%d;%dM", cb + 32, x, y))
	case .Utf8:
		append(out, 0x1b, '[', 'M')
		for v in ([3]int{cb + 32, x + 32, y + 32}) {
			buf, n := utf8.encode_rune(rune(min(v, 2047)))
			append(out, ..buf[:n])
		}
	case .Default:
		if x > 223 || y > 223 do return false
		append(out, 0x1b, '[', 'M', u8(cb + 32), u8(x + 32), u8(y + 32))
	}
	return true
}

/// text for a paste: bracketed when the program asked, with the escape
/// characters taken out (a paste must not be able to end the bracket) and
/// newlines as the Return key sends them
paste_bytes :: proc(t: ^Term, out: ^[dynamic]u8, s: string) {
	if t.modes.bracketed do append(out, ..transmute([]u8)string("\x1b[200~"))
	prev: u8
	for c in transmute([]u8)s {
		switch {
		case c == 0x1b: // dropped
		case c == '\n':
			if prev != '\r' do append(out, '\r')
		case c == '\r': append(out, '\r')
		case c < 0x20 && c != '\t': // other controls are dropped
		case c == 0x7f:
		case: append(out, c)
		}
		prev = c
	}
	if t.modes.bracketed do append(out, ..transmute([]u8)string("\x1b[201~"))
}
