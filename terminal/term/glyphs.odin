// Characters the terminal draws itself, to the pixel: box drawing, block
// elements, braille and the powerline shapes. They are bitmaps of exactly
// one cell, so lines join across cells with no gap or overlap at any font
// size or scale.
package term

import "core:math"

/// does the terminal draw this character itself?
is_special_glyph :: proc "contextless" (r: rune) -> bool {
	switch {
	case r >= 0x2500 && r <= 0x259f: return true
	case r >= 0x2800 && r <= 0x28ff: return true
	case r >= 0xe0b0 && r <= 0xe0b7: return true
	}
	return false
}

// the arms of U+2500..U+257F as [left, right, up, down]: 0 none, 1 light,
// 2 heavy, 3 double; as one string of four digits per character
@(private) BOX_ARMS := [128]string{
	"1100", "2200", "0011", "0022", "", "", "", "", "", "", "", "", // 2500..250B (dashes below)
	"0101", "0201", "0102", "0202", // 250C..250F
	"1001", "2001", "1002", "2002", // 2510..2513
	"0110", "0210", "0120", "0220", // 2514..2517
	"1010", "2010", "1020", "2020", // 2518..251B (corner ┘ ┙ ┚ ┛: left+up)
	"0111", "0211", "0121", "0112", "0122", "0221", "0212", "0222", // 251C..2523
	"1011", "2011", "1021", "1012", "1022", "2021", "2012", "2022", // 2524..252B
	"1101", "2101", "1201", "2201", "1102", "2102", "1202", "2202", // 252C..2533
	"1110", "2110", "1210", "2210", "1120", "2120", "1220", "2220", // 2534..253B
	"1111", "2111", "1211", "2211", "1121", "1112", "1122", "2121", // 253C..2543
	"1221", "2112", "1212", "2221", "2212", "2122", "1222", "2222", // 2544..254B
	"", "", "", "", // 254C..254F (dashes)
	"3300", "0033", "0301", "0103", "0303", "3001", "1003", "3003", // 2550..2557
	"0310", "0130", "0330", "3010", "1030", "3030", "0311", "0133", // 2558..255F
	"0333", "3011", "1033", "3033", "3301", "1103", "3303", "3310", // 2560..2567
	"1130", "3330", "3311", "1133", "3333", // 2568..256C
	"", "", "", "", // 256D..2570 arcs
	"", "", "", // 2571..2573 diagonals
	"1000", "0010", "0100", "0001", "2000", "0020", "0200", "0002", // 2574..257B
	"1200", "0012", "2100", "0021", // 257C..257F
}

Bitmap :: struct {
	w, h: int,
	px:   []u8,
}

@(private) fill_rect :: proc(b: Bitmap, x0, y0, x1, y1: int, v: u8 = 255) {
	for y in max(y0, 0) ..< min(y1, b.h) {
		for x in max(x0, 0) ..< min(x1, b.w) do b.px[y * b.w + x] = max(b.px[y * b.w + x], v)
	}
}

/// the stroke thickness of light lines at a cell size
light_thickness :: proc(w, h: int) -> int {
	return max(1, int(math.round(f32(min(w, h * 2 / 3)) / 8)))
}

/// draws the special character into a w × h coverage bitmap (cleared by
/// the caller); false when it is not one
draw_special :: proc(r: rune, b: Bitmap) -> bool {
	switch {
	case r >= 0x2500 && r <= 0x257f: return draw_box(r, b)
	case r >= 0x2580 && r <= 0x259f: return draw_block(r, b)
	case r >= 0x2800 && r <= 0x28ff: return draw_braille(r, b)
	case r >= 0xe0b0 && r <= 0xe0b7: return draw_powerline(r, b)
	}
	return false
}

@(private) draw_block :: proc(r: rune, b: Bitmap) -> bool {
	w, h := b.w, b.h
	eighth :: proc(n, k: int) -> int { return int(math.round(f32(n) * f32(k) / 8)) }
	switch r {
	case 0x2580: fill_rect(b, 0, 0, w, eighth(h, 4))
	case 0x2581 ..= 0x2587: fill_rect(b, 0, h - eighth(h, int(r - 0x2580)), w, h)
	case 0x2588: fill_rect(b, 0, 0, w, h)
	case 0x2589 ..= 0x258f: fill_rect(b, 0, 0, eighth(w, 8 - int(r - 0x2588)), h)
	case 0x2590: fill_rect(b, w - eighth(w, 4), 0, w, h)
	case 0x2591: fill_rect(b, 0, 0, w, h, 64)
	case 0x2592: fill_rect(b, 0, 0, w, h, 128)
	case 0x2593: fill_rect(b, 0, 0, w, h, 192)
	case 0x2594: fill_rect(b, 0, 0, w, eighth(h, 1))
	case 0x2595: fill_rect(b, w - eighth(w, 1), 0, w, h)
	case 0x2596 ..= 0x259f:
		// quadrants: bit 0 upper left, 1 upper right, 2 lower left, 3 lower right
		q := [10]u8{0b0100, 0b1000, 0b0001, 0b0111, 0b1001, 0b1011, 0b1101, 0b0010, 0b0110, 0b1110}
		m := q[r - 0x2596]
		hw, hh := eighth(w, 4), eighth(h, 4)
		if m & 1 != 0 do fill_rect(b, 0, 0, hw, hh)
		if m & 2 != 0 do fill_rect(b, hw, 0, w, hh)
		if m & 4 != 0 do fill_rect(b, 0, hh, hw, h)
		if m & 8 != 0 do fill_rect(b, hw, hh, w, h)
	}
	return true
}

@(private) draw_dashes :: proc(r: rune, b: Bitmap) -> bool {
	t := light_thickness(b.w, b.h)
	heavy := false
	n := 0
	vertical := false
	switch r {
	case 0x2504, 0x2505: n, vertical, heavy = 3, false, r == 0x2505
	case 0x2506, 0x2507: n, vertical, heavy = 3, true, r == 0x2507
	case 0x2508, 0x2509: n, vertical, heavy = 4, false, r == 0x2509
	case 0x250a, 0x250b: n, vertical, heavy = 4, true, r == 0x250b
	case 0x254c, 0x254d: n, vertical, heavy = 2, false, r == 0x254d
	case 0x254e, 0x254f: n, vertical, heavy = 2, true, r == 0x254f
	case: return false
	}
	th := heavy ? t * 2 : t
	length := vertical ? b.h : b.w
	// n dashes, each followed by a gap of the same size, the line centred
	seg := max(1, length / (n * 2))
	start := (length - seg * (2 * n - 1)) / 2
	for i in 0 ..< n {
		a := start + i * seg * 2
		if vertical {
			x0 := (b.w - th) / 2
			fill_rect(b, x0, a, x0 + th, a + seg)
		} else {
			y0 := (b.h - th) / 2
			fill_rect(b, a, y0, a + seg, y0 + th)
		}
	}
	return true
}

@(private) arm_thick :: proc(wt: u8, t, th: int) -> int {
	switch wt {
	case '1', '3': return t // (a double line is two strokes of this thickness)
	case '2': return th
	}
	return 0
}

/// one arm of a box character, from the centre to the edge of the cell:
/// `horizontal` or vertical, towards the high end (right, down) or the low
/// end; `wt` its weight; `lo` and `hi` the weights of the arms across it
/// (up and down for a horizontal arm; left and right for a vertical one)
@(private) draw_arm :: proc(b: Bitmap, horizontal: bool, high: bool, wt, lo, hi: u8, t, th: int) {
	along, across := horizontal ? b.w : b.h, horizontal ? b.h : b.w
	put :: proc(b: Bitmap, horizontal: bool, a0, a1, c0, c1: int) {
		if horizontal { fill_rect(b, a0, c0, a1, c1) } else { fill_rect(b, c0, a0, c1, a1) }
	}
	perp_present := lo != '0' || hi != '0'
	perp_double := lo == '3' || hi == '3'
	perp_t := 0
	if perp_double {
		perp_t = t * 3
	} else {
		perp_t = max(arm_thick(lo, t, th), arm_thick(hi, t, th))
	}
	// the block where the arms across it cross this one
	cb0 := perp_present ? (along - perp_t) / 2 : along / 2
	cb1 := perp_present ? cb0 + perp_t : along / 2
	if wt == '3' {
		for s in 0 ..< 2 {
			this := s == 0 ? lo : hi
			c0 := (across - t * 3) / 2 + s * 2 * t
			a0, a1: int
			if high {
				a0, a1 = along / 2, along
				if perp_double {
					a0 = this != '0' ? cb1 - t : cb0
				} else if perp_present {
					a0 = cb0
				}
			} else {
				a0, a1 = 0, along / 2
				if perp_double {
					a1 = this != '0' ? cb0 + t : cb1
				} else if perp_present {
					a1 = cb1
				}
			}
			put(b, horizontal, a0, a1, c0, c0 + t)
		}
		return
	}
	tk := arm_thick(wt, t, th)
	c0 := (across - tk) / 2
	if high { put(b, horizontal, cb0, along, c0, c0 + tk) } else { put(b, horizontal, 0, cb1, c0, c0 + tk) }
}

@(private) draw_box :: proc(r: rune, b: Bitmap) -> bool {
	switch r {
	case 0x2504 ..= 0x250b, 0x254c ..= 0x254f: return draw_dashes(r, b)
	case 0x256d ..= 0x2570: return draw_arc(r, b)
	case 0x2571 ..= 0x2573: return draw_diagonal(r, b)
	}
	arms := BOX_ARMS[int(r - 0x2500)]
	if len(arms) != 4 do return false
	t := light_thickness(b.w, b.h)
	th := t * 2
	L, R, U, D := arms[0], arms[1], arms[2], arms[3]
	if R != '0' do draw_arm(b, true, true, R, U, D, t, th)
	if L != '0' do draw_arm(b, true, false, L, U, D, t, th)
	if D != '0' do draw_arm(b, false, true, D, L, R, t, th)
	if U != '0' do draw_arm(b, false, false, U, L, R, t, th)
	return true
}

/// coverage of a pixel by a shape given as an inside test, 4 × 4 samples
@(private) coverage :: proc(x, y: int, inside: proc(fx, fy: f32, data: rawptr) -> bool, data: rawptr) -> u8 {
	n := 0
	for sy in 0 ..< 4 {
		for sx in 0 ..< 4 {
			if inside(f32(x) + (f32(sx) + 0.5) / 4, f32(y) + (f32(sy) + 0.5) / 4, data) do n += 1
		}
	}
	return u8(n * 255 / 16)
}

@(private) Arc_Data :: struct {
	cx, cy, rx, ry, t: f32,
	// the quarter kept: which side of the centre
	sx, sy: f32,
}

@(private) draw_arc :: proc(r: rune, b: Bitmap) -> bool {
	w, h := f32(b.w), f32(b.h)
	t := f32(light_thickness(b.w, b.h))
	d := Arc_Data{rx = w / 2, ry = h / 2, t = t}
	// ╭ right+down: the centre of the arc is the cell's lower right corner
	switch r {
	case 0x256d: d.cx, d.cy, d.sx, d.sy = w, h, -1, -1
	case 0x256e: d.cx, d.cy, d.sx, d.sy = 0, h, 1, -1
	case 0x256f: d.cx, d.cy, d.sx, d.sy = 0, 0, 1, 1
	case 0x2570: d.cx, d.cy, d.sx, d.sy = w, 0, -1, 1
	}
	inside :: proc(fx, fy: f32, data: rawptr) -> bool {
		a := cast(^Arc_Data)data
		u, v := (fx - a.cx) / a.rx, (fy - a.cy) / a.ry
		if u * a.sx < 0 || v * a.sy < 0 do return false
		dist := (math.sqrt(u * u + v * v) - 1) * (a.rx + a.ry) / 2
		return abs(dist) <= a.t / 2
	}
	for y in 0 ..< b.h do for x in 0 ..< b.w do b.px[y * b.w + x] = coverage(x, y, inside, &d)
	// the straight stubs that reach the cell's edges where the arc ends
	return true
}

@(private) Line_Data :: struct {
	a, b: [2]f32,
	t:    f32,
	both: bool,
	c, d: [2]f32,
}

@(private) seg_dist :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	l2 := ab.x * ab.x + ab.y * ab.y
	k := l2 == 0 ? f32(0) : clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2, 0, 1)
	q := a + ab * k
	return math.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y))
}

@(private) draw_diagonal :: proc(r: rune, b: Bitmap) -> bool {
	w, h := f32(b.w), f32(b.h)
	d := Line_Data{t = f32(light_thickness(b.w, b.h)), a = {0, h}, b = {w, 0}, c = {0, 0}, d = {w, h}}
	switch r {
	case 0x2571: d.both = false // ╱
	case 0x2572: d.a, d.b = {0, 0}, {w, h}
	case 0x2573: d.both = true
	}
	inside :: proc(fx, fy: f32, data: rawptr) -> bool {
		l := cast(^Line_Data)data
		p := [2]f32{fx, fy}
		if seg_dist(p, l.a, l.b) <= l.t / 2 do return true
		return l.both && seg_dist(p, l.c, l.d) <= l.t / 2
	}
	if r == 0x2573 do d.a, d.b = {0, h}, {w, 0}
	for y in 0 ..< b.h do for x in 0 ..< b.w do b.px[y * b.w + x] = coverage(x, y, inside, &d)
	return true
}

@(private) Dot_Data :: struct {
	cx, cy, r: f32,
}

@(private) draw_braille :: proc(r: rune, b: Bitmap) -> bool {
	bits := u32(r - 0x2800)
	w, h := f32(b.w), f32(b.h)
	// dots 1..8 at (column, row)
	pos := [8][2]int{{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}, {0, 3}, {1, 3}}
	rad := max(f32(0.9), min(w / 5.5, h / 10))
	for i in 0 ..< 8 {
		if bits & (1 << u32(i)) == 0 do continue
		d := Dot_Data{cx = w * (0.28 + 0.44 * f32(pos[i].x)), cy = h * (0.125 + 0.25 * f32(pos[i].y)), r = rad}
		inside :: proc(fx, fy: f32, data: rawptr) -> bool {
			c := cast(^Dot_Data)data
			dx, dy := fx - c.cx, fy - c.cy
			return dx * dx + dy * dy <= c.r * c.r
		}
		x0, x1 := max(int(d.cx - rad) - 1, 0), min(int(d.cx + rad) + 2, b.w)
		y0, y1 := max(int(d.cy - rad) - 1, 0), min(int(d.cy + rad) + 2, b.h)
		for y in y0 ..< y1 {
			for x in x0 ..< x1 do b.px[y * b.w + x] = max(b.px[y * b.w + x], coverage(x, y, inside, &d))
		}
	}
	return true
}

@(private) Shape_Data :: struct {
	w, h, t: f32,
	kind:    rune,
}

@(private) draw_powerline :: proc(r: rune, b: Bitmap) -> bool {
	d := Shape_Data{w = f32(b.w), h = f32(b.h), t = f32(light_thickness(b.w, b.h)), kind = r}
	inside :: proc(fx, fy: f32, data: rawptr) -> bool {
		s := cast(^Shape_Data)data
		w, h := s.w, s.h
		switch s.kind {
		case 0xe0b0, 0xe0b2:
			x := s.kind == 0xe0b0 ? fx : w - fx
			// the triangle (0,0) (w,h/2) (0,h)
			return x <= w * (1 - abs(fy - h / 2) / (h / 2))
		case 0xe0b1, 0xe0b3:
			p := [2]f32{s.kind == 0xe0b1 ? fx : w - fx, fy}
			return seg_dist(p, {0, 0}, {w, h / 2}) <= s.t / 2 || seg_dist(p, {w, h / 2}, {0, h}) <= s.t / 2
		case 0xe0b4, 0xe0b6, 0xe0b5, 0xe0b7:
			x := (s.kind == 0xe0b4 || s.kind == 0xe0b5) ? fx : w - fx
			u, v := x / w, (fy - h / 2) / (h / 2)
			dd := math.sqrt(u * u + v * v)
			if s.kind == 0xe0b4 || s.kind == 0xe0b6 do return dd <= 1
			return abs(dd - 1) * (w + h / 2) / 2 <= s.t / 2 && u >= 0
		}
		return false
	}
	for y in 0 ..< b.h do for x in 0 ..< b.w do b.px[y * b.w + x] = coverage(x, y, inside, &d)
	return true
}
