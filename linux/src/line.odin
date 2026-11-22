// One line of editable text (the address, find, a prompt, a name): the
// cursor and selection by characters and words, the clipboard, undo.
package iris

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import plat "../plat"

Line :: struct {
	text:   [dynamic]u8,
	cursor: int, // bytes
	anchor: int, // the other end of the selection (== cursor: none)
	scroll: f32, // how far the text is moved left to keep the cursor in view
	undo:   [dynamic]Line_Undo,
	blink:  f64, // when the cursor last moved (it shows steadily for a while)
}

Line_Undo :: struct {
	text:   string,
	cursor: int,
}

line_string :: proc(l: ^Line) -> string { return string(l.text[:]) }

line_set :: proc(l: ^Line, s: string) {
	clear(&l.text)
	append(&l.text, s)
	l.cursor = len(l.text)
	l.anchor = l.cursor
	l.scroll = 0
	for u in l.undo do delete(u.text)
	clear(&l.undo)
}

line_free :: proc(l: ^Line) {
	delete(l.text)
	for u in l.undo do delete(u.text)
	delete(l.undo)
}

line_selection :: proc(l: ^Line) -> (lo, hi: int) {
	return min(l.cursor, l.anchor), max(l.cursor, l.anchor)
}

line_has_selection :: proc(l: ^Line) -> bool { return l.cursor != l.anchor }

line_select_all :: proc(l: ^Line) {
	l.anchor = 0
	l.cursor = len(l.text)
}

@(private="file") remember :: proc(l: ^Line) {
	if len(l.undo) >= 100 {
		delete(l.undo[0].text)
		ordered_remove(&l.undo, 0)
	}
	append(&l.undo, Line_Undo{strings.clone(line_string(l)), l.cursor})
}

line_undo :: proc(l: ^Line) -> bool {
	if len(l.undo) == 0 do return false
	u := pop(&l.undo)
	clear(&l.text)
	append(&l.text, u.text)
	l.cursor = min(u.cursor, len(l.text))
	l.anchor = l.cursor
	delete(u.text)
	return true
}

/// text typed or pasted, over the selection (line breaks become spaces)
line_insert :: proc(l: ^Line, s0: string) {
	s, _ := strings.replace_all(s0, "\n", " ", context.temp_allocator)
	s, _ = strings.replace_all(s, "\r", "", context.temp_allocator)
	s, _ = strings.replace_all(s, "\t", " ", context.temp_allocator)
	remember(l)
	lo, hi := line_selection(l)
	remove_range(&l.text, lo, hi)
	inject_at(&l.text, lo, ..transmute([]u8)s)
	l.cursor = lo + len(s)
	l.anchor = l.cursor
}

line_delete_selection :: proc(l: ^Line) {
	if !line_has_selection(l) do return
	remember(l)
	lo, hi := line_selection(l)
	remove_range(&l.text, lo, hi)
	l.cursor, l.anchor = lo, lo
}

@(private="file") prev_rune :: proc(s: string, i: int) -> int {
	if i <= 0 do return 0
	_, n := utf8.decode_last_rune_in_string(s[:i])
	return i - max(n, 1)
}

@(private="file") next_rune :: proc(s: string, i: int) -> int {
	if i >= len(s) do return len(s)
	_, n := utf8.decode_rune_in_string(s[i:])
	return i + max(n, 1)
}

@(private="file") is_word :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'
}

/// the start of the word before i (Ctrl+Left, Ctrl+Backspace)
word_left :: proc(s: string, i0: int) -> int {
	i := i0
	for i > 0 {
		r, _ := utf8.decode_last_rune_in_string(s[:i])
		if is_word(r) do break
		i = prev_rune(s, i)
	}
	for i > 0 {
		r, _ := utf8.decode_last_rune_in_string(s[:i])
		if !is_word(r) do break
		i = prev_rune(s, i)
	}
	return i
}

/// the end of the word after i (Ctrl+Right, Ctrl+Delete)
word_right :: proc(s: string, i0: int) -> int {
	i := i0
	for i < len(s) {
		r, _ := utf8.decode_rune_in_string(s[i:])
		if is_word(r) do break
		i = next_rune(s, i)
	}
	for i < len(s) {
		r, _ := utf8.decode_rune_in_string(s[i:])
		if !is_word(r) do break
		i = next_rune(s, i)
	}
	return i
}

/// the word around i (a double click)
line_select_word :: proc(l: ^Line, i: int) {
	s := line_string(l)
	a, b := i, i
	for a > 0 {
		r, _ := utf8.decode_last_rune_in_string(s[:a])
		if !is_word(r) do break
		a = prev_rune(s, a)
	}
	for b < len(s) {
		r, _ := utf8.decode_rune_in_string(s[b:])
		if !is_word(r) do break
		b = next_rune(s, b)
	}
	if a == b do b = next_rune(s, b)
	l.anchor, l.cursor = a, b
}

/// a key for the line; what it did
Line_Result :: enum { Ignored, Changed, Moved, Enter, Escape }

line_key :: proc(l: ^Line, e: plat.Key_Event) -> Line_Result {
	if !e.pressed do return .Ignored
	s := line_string(l)
	ctrl := .Ctrl in e.mods
	shift := .Shift in e.mods
	move :: proc(l: ^Line, to: int, shift: bool) -> Line_Result {
		if !shift && line_has_selection(l) {
			l.anchor = l.cursor
		}
		l.cursor = to
		if !shift do l.anchor = to
		return .Moved
	}
	switch e.sym {
	case plat.KEY_Return, plat.KEY_KP_Enter: return .Enter
	case plat.KEY_Escape: return .Escape
	case plat.KEY_Left:
		if !shift && line_has_selection(l) {
			lo, _ := line_selection(l)
			return move(l, lo, false)
		}
		return move(l, ctrl ? word_left(s, l.cursor) : prev_rune(s, l.cursor), shift)
	case plat.KEY_Right:
		if !shift && line_has_selection(l) {
			_, hi := line_selection(l)
			return move(l, hi, false)
		}
		return move(l, ctrl ? word_right(s, l.cursor) : next_rune(s, l.cursor), shift)
	case plat.KEY_Home: return move(l, 0, shift)
	case plat.KEY_End: return move(l, len(s), shift)
	case plat.KEY_BackSpace:
		if line_has_selection(l) {
			line_delete_selection(l)
		} else if l.cursor > 0 {
			l.anchor = ctrl ? word_left(s, l.cursor) : prev_rune(s, l.cursor)
			line_delete_selection(l)
		}
		return .Changed
	case plat.KEY_Delete:
		if line_has_selection(l) {
			line_delete_selection(l)
		} else if l.cursor < len(s) {
			l.anchor = ctrl ? word_right(s, l.cursor) : next_rune(s, l.cursor)
			line_delete_selection(l)
		}
		return .Changed
	}
	if ctrl {
		switch e.sym {
		case 'a':
			line_select_all(l)
			return .Moved
		case 'c', 'x':
			if line_has_selection(l) {
				lo, hi := line_selection(l)
				clipboard_offer(s[lo:hi])
				if e.sym == 'x' {
					line_delete_selection(l)
					return .Changed
				}
			}
			return .Moved
		case 'v':
			if len(clipboard_text) > 0 do line_insert(l, clipboard_text)
			return .Changed
		case 'z':
			return line_undo(l) ? .Changed : .Moved
		}
		return .Ignored
	}
	if len(e.text) > 0 && e.text[0] >= 0x20 && e.text[0] != 0x7f {
		line_insert(l, e.text)
		return .Changed
	}
	return .Ignored
}
