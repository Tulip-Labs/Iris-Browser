// The terminal's data: a cell, its colour and attributes.
package term

/// A colour is one u32: the top byte says what the rest means.
///   0           the default foreground or background
///   1           a palette entry (low byte: 0..255)
///   2           true colour (low 24 bits: r, g, b)
Color :: distinct u32

COLOR_DEFAULT :: Color(0)

color_idx :: #force_inline proc "contextless" (i: u8) -> Color { return Color(1 << 24 | u32(i)) }
color_rgb :: #force_inline proc "contextless" (r, g, b: u8) -> Color { return Color(2 << 24 | u32(r) << 16 | u32(g) << 8 | u32(b)) }
color_kind :: #force_inline proc "contextless" (c: Color) -> u8 { return u8(u32(c) >> 24) }
color_is_default :: #force_inline proc "contextless" (c: Color) -> bool { return u32(c) == 0 }

Attr :: enum u16 {
	Bold,
	Dim,
	Italic,
	Blink,
	Reverse,
	Hidden,
	Strike,
	Overline,
	Wide, // the first half of a wide character
	Wide_Cont, // its second half (draws nothing)
	// the underline style takes the next three bits (Underline_Style)
}
Attrs :: bit_set[Attr; u16]

A_WIDE :: u16(1) << u16(Attr.Wide)
A_WIDE_CONT :: u16(1) << u16(Attr.Wide_Cont)
A_REVERSE :: u16(1) << u16(Attr.Reverse)

UL_SHIFT :: 10
UL_MASK :: u16(7) << UL_SHIFT

Underline :: enum u8 { None, Single, Double, Curly, Dotted, Dashed }

Cell :: struct {
	ch:   u32, // the character; CLUSTER_BIT | n: a base with combining marks (clusters[n])
	fg:   Color,
	bg:   Color,
	attr: u16, // Attrs, and the underline style from bit 10
	link: u16, // the hyperlink (OSC 8) it belongs to: 0 none
}

CLUSTER_BIT :: u32(1) << 31

cell_attrs :: #force_inline proc "contextless" (c: Cell) -> Attrs { return transmute(Attrs)(c.attr & ~UL_MASK) }
cell_underline :: #force_inline proc "contextless" (c: Cell) -> Underline { return Underline((c.attr & UL_MASK) >> UL_SHIFT) }
has_attr :: #force_inline proc "contextless" (c: Cell, a: Attr) -> bool { return c.attr & (1 << u16(a)) != 0 }

/// the pen: what new characters are written with
Pen :: struct {
	fg, bg: Color,
	attr:   u16,
	link:   u16,
}

BLANK :: Cell{ch = ' '}

Row :: struct {
	cells:   []Cell,
	/// this row continues on the next one (a soft wrap, not a newline)
	wrapped: bool,
	/// a shell prompt starts on this row (OSC 133 ; A)
	prompt:  bool,
}

/// the cells up to the last one that shows something
row_used :: proc(r: Row) -> int {
	n := len(r.cells)
	for n > 0 {
		c := r.cells[n - 1]
		if c.ch != ' ' || !color_is_default(c.bg) || c.attr & u16(1 << u16(Attr.Reverse) | UL_MASK) != 0 || c.link != 0 do break
		n -= 1
	}
	return n
}
