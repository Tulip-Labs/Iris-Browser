// Iris's rasteriser: outlines (a font's glyphs, the line icons) become
// coverage bitmaps, antialiased by the exact area each edge covers in
// each pixel (signed-area accumulation, as font-rs does). Curves are
// flattened into short lines; strokes become filled shapes first.
package iris

import "core:math"
import "core:math/linalg"
import "core:strconv"

Raster :: struct {
	w, h: int,
	acc:  []f32, // w * h + 2 (an edge may write one past its last pixel)
}

raster_make :: proc(w, h: int, allocator := context.temp_allocator) -> Raster {
	return {w = w, h = h, acc = make([]f32, w * h + 2, allocator)}
}

/// one edge of a closed outline (pixels; y down)
raster_line :: proc(r: ^Raster, p0, p1: [2]f32) {
	if abs(p0.y - p1.y) <= 1e-6 do return
	a, b := p0, p1
	dir: f32 = 1
	if a.y > b.y {
		a, b = b, a
		dir = -1
	}
	// keep x inside the bitmap (what lies outside is clipped to its edge)
	a.x = clamp(a.x, 0, f32(r.w) - 1.001)
	b.x = clamp(b.x, 0, f32(r.w) - 1.001)
	dxdy := (b.x - a.x) / (b.y - a.y)
	x := a.x
	if a.y < 0 do x -= a.y * dxdy
	y0 := max(0, int(a.y))
	y1 := min(r.h, int(math.ceil(b.y)))
	for y in y0 ..< y1 {
		ls := y * r.w
		dy := min(f32(y + 1), b.y) - max(f32(y), a.y)
		xnext := x + dxdy * dy
		d := dy * dir
		x0, x1 := x, xnext
		if x0 > x1 do x0, x1 = x1, x0
		x0f := math.floor(x0)
		x0i := int(x0f)
		x1c := math.ceil(x1)
		x1i := int(x1c)
		if x1i <= x0i + 1 {
			xm := 0.5 * (x + xnext) - x0f
			r.acc[ls + x0i] += d - d * xm
			r.acc[ls + x0i + 1] += d * xm
		} else {
			s := 1 / (x1 - x0)
			xf := x0 - x0f
			a0 := 0.5 * s * (1 - xf) * (1 - xf)
			x1f := x1 - x1c + 1
			am := 0.5 * s * x1f * x1f
			r.acc[ls + x0i] += d * a0
			if x1i == x0i + 2 {
				r.acc[ls + x0i + 1] += d * (1 - a0 - am)
			} else {
				a1 := s * (1.5 - xf)
				r.acc[ls + x0i + 1] += d * (a1 - a0)
				for xi in x0i + 2 ..< x1i - 1 do r.acc[ls + xi] += d * s
				a2 := a1 + f32(x1i - x0i - 3) * s
				r.acc[ls + x1i - 1] += d * (1 - a2 - am)
			}
			r.acc[ls + x1i] += d * am
		}
		x = xnext
	}
}

/// the coverage of every pixel, 0..255 (overlapping shapes add up and
/// are clipped at full, so a stroke's pieces join without seams)
raster_coverage :: proc(r: ^Raster, out: []u8) {
	acc: f32
	for i in 0 ..< r.w * r.h {
		acc += r.acc[i]
		out[i] = u8(min(abs(acc), 1) * 255 + 0.5)
	}
}

// ---------------------------------------------------------------- paths

/// a path as closed polygons, in its own units
Path :: struct {
	polys: [dynamic][dynamic][2]f32,
}

path_free :: proc(p: ^Path) {
	for q in p.polys do delete(q)
	delete(p.polys)
}

@(private="file") path_move :: proc(p: ^Path, pt: [2]f32) {
	append(&p.polys, make([dynamic][2]f32, p.polys.allocator))
	append(&p.polys[len(p.polys) - 1], pt)
}

@(private="file") path_to :: proc(p: ^Path, pt: [2]f32) {
	if len(p.polys) == 0 do path_move(p, pt)
	append(&p.polys[len(p.polys) - 1], pt)
}

@(private="file") last :: proc(p: ^Path) -> [2]f32 {
	if len(p.polys) == 0 do return {}
	q := p.polys[len(p.polys) - 1]
	return len(q) > 0 ? q[len(q) - 1] : {}
}

/// how many lines a curve becomes: about one per half unit of its length,
/// in pixels of the size it is drawn at
@(private="file") steps_for :: proc(unit: f32, pts: ..[2]f32) -> int {
	l: f32
	for i in 1 ..< len(pts) do l += linalg.length(pts[i] - pts[i - 1])
	return clamp(int(l * unit / 2), 2, 40)
}

path_quad :: proc(p: ^Path, c, to: [2]f32, unit: f32 = 1) {
	a := last(p)
	n := steps_for(unit, a, c, to)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		path_to(p, u * u * a + 2 * u * t * c + t * t * to)
	}
}

path_cubic :: proc(p: ^Path, c1, c2, to: [2]f32, unit: f32 = 1) {
	a := last(p)
	n := steps_for(unit, a, c1, c2, to)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		path_to(p, u * u * u * a + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * to)
	}
}

/// an SVG elliptical arc (endpoint form) as lines
@(private="file") path_arc :: proc(p: ^Path, rx0, ry0, rot: f32, large, sweep: bool, to: [2]f32, unit: f32) {
	a := last(p)
	rx, ry := abs(rx0), abs(ry0)
	if rx < 1e-6 || ry < 1e-6 {
		path_to(p, to)
		return
	}
	phi := rot * math.PI / 180
	cp, sp := math.cos(phi), math.sin(phi)
	dx, dy := (a.x - to.x) / 2, (a.y - to.y) / 2
	x1 := cp * dx + sp * dy
	y1 := -sp * dx + cp * dy
	l := x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
	if l > 1 {
		rx *= math.sqrt(l)
		ry *= math.sqrt(l)
	}
	num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	k := math.sqrt(max(0, num / den))
	if large == sweep do k = -k
	cx1 := k * rx * y1 / ry
	cy1 := -k * ry * x1 / rx
	cx := cp * cx1 - sp * cy1 + (a.x + to.x) / 2
	cy := sp * cx1 + cp * cy1 + (a.y + to.y) / 2
	ang :: proc(ux, uy, vx, vy: f32) -> f32 {
		v := math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
		return v
	}
	t1 := ang(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
	dt := ang((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
	if !sweep && dt > 0 do dt -= 2 * math.PI
	if sweep && dt < 0 do dt += 2 * math.PI
	n := clamp(int(abs(dt) * max(rx, ry) * unit / 2), 4, 64)
	for i in 1 ..= n {
		t := t1 + dt * f32(i) / f32(n)
		x := rx * math.cos(t)
		y := ry * math.sin(t)
		path_to(p, {cp * x - sp * y + cx, sp * x + cp * y + cy})
	}
}

/// SVG path data ("M8 1l7.5 6.5H13V15z", with C, S, Q, T, A and relative
/// forms); unit is how many pixels one path unit becomes (for curve detail)
path_parse :: proc(d: string, unit: f32 = 1, allocator := context.temp_allocator) -> (p: Path) {
	p.polys = make([dynamic][dynamic][2]f32, allocator)
	context.allocator = allocator
	i := 0
	cmd: u8 = 'M'
	cur, start, prev_c: [2]f32
	prev_cmd: u8
	is_num_start :: proc(c: u8) -> bool { return (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' }
	skip :: proc(d: string, i: ^int) {
		for i^ < len(d) && (d[i^] == ' ' || d[i^] == ',' || d[i^] == '\n' || d[i^] == '\t' || d[i^] == '\r') do i^ += 1
	}
	num :: proc(d: string, i: ^int) -> f32 {
		skip(d, i)
		s := i^
		if i^ < len(d) && (d[i^] == '-' || d[i^] == '+') do i^ += 1
		dot := false
		for i^ < len(d) {
			c := d[i^]
			if c >= '0' && c <= '9' {
				i^ += 1
			} else if c == '.' && !dot {
				dot = true
				i^ += 1
			} else if (c == 'e' || c == 'E') && i^ + 1 < len(d) {
				i^ += 1
				if d[i^] == '-' || d[i^] == '+' do i^ += 1
			} else {
				break
			}
		}
		v, _ := strconv.parse_f32(d[s:i^])
		return v
	}
	flag :: proc(d: string, i: ^int) -> bool {
		skip(d, i)
		if i^ < len(d) && (d[i^] == '0' || d[i^] == '1') {
			v := d[i^] == '1'
			i^ += 1
			return v
		}
		return num(d, i) != 0
	}
	for {
		skip(d, &i)
		if i >= len(d) do break
		c := d[i]
		if !is_num_start(c) {
			cmd = c
			i += 1
			if cmd == 'Z' || cmd == 'z' {
				path_to(&p, start)
				cur = start
				prev_cmd = cmd
				continue
			}
		}
		rel := cmd >= 'a' && cmd <= 'z'
		o := rel ? cur : [2]f32{}
		switch cmd {
		case 'M', 'm':
			cur = o + {num(d, &i), num(d, &i)}
			path_move(&p, cur)
			start = cur
			cmd = rel ? 'l' : 'L' // further pairs are lines
		case 'L', 'l':
			cur = o + {num(d, &i), num(d, &i)}
			path_to(&p, cur)
		case 'H', 'h':
			cur.x = (rel ? cur.x : 0) + num(d, &i)
			path_to(&p, cur)
		case 'V', 'v':
			cur.y = (rel ? cur.y : 0) + num(d, &i)
			path_to(&p, cur)
		case 'C', 'c':
			c1 := o + {num(d, &i), num(d, &i)}
			c2 := o + {num(d, &i), num(d, &i)}
			to := o + {num(d, &i), num(d, &i)}
			path_cubic(&p, c1, c2, to, unit)
			prev_c, cur = c2, to
		case 'S', 's':
			c1 := (prev_cmd == 'C' || prev_cmd == 'c' || prev_cmd == 'S' || prev_cmd == 's') ? 2 * cur - prev_c : cur
			c2 := o + {num(d, &i), num(d, &i)}
			to := o + {num(d, &i), num(d, &i)}
			path_cubic(&p, c1, c2, to, unit)
			prev_c, cur = c2, to
		case 'Q', 'q':
			c1 := o + {num(d, &i), num(d, &i)}
			to := o + {num(d, &i), num(d, &i)}
			path_quad(&p, c1, to, unit)
			prev_c, cur = c1, to
		case 'T', 't':
			c1 := (prev_cmd == 'Q' || prev_cmd == 'q' || prev_cmd == 'T' || prev_cmd == 't') ? 2 * cur - prev_c : cur
			to := o + {num(d, &i), num(d, &i)}
			path_quad(&p, c1, to, unit)
			prev_c, cur = c1, to
		case 'A', 'a':
			rx, ry, rot := num(d, &i), num(d, &i), num(d, &i)
			large, sweep := flag(d, &i), flag(d, &i)
			to := o + {num(d, &i), num(d, &i)}
			path_arc(&p, rx, ry, rot, large, sweep, to, unit)
			cur = to
		case:
			return // not path data
		}
		prev_cmd = cmd
	}
	return
}

/// fills a path, scaled by k and moved by off, into the raster
raster_fill :: proc(r: ^Raster, p: Path, k: f32, off: [2]f32) {
	for poly in p.polys {
		if len(poly) < 2 do continue
		for j in 0 ..< len(poly) {
			a := poly[j] * k + off
			b := poly[(j + 1) % len(poly)] * k + off
			raster_line(r, a, b)
		}
	}
}

/// strokes a path with round caps and joins: each segment a rectangle and
/// each point a disc, all wound the same way so they join without seams
raster_stroke :: proc(r: ^Raster, p: Path, k: f32, off: [2]f32, width: f32) {
	hw := width / 2
	disc :: proc(r: ^Raster, c: [2]f32, rad: f32) {
		n := clamp(int(rad * 2.5), 8, 32)
		prev := c + {rad, 0}
		for i in 1 ..= n {
			t := f32(i) / f32(n) * 2 * math.PI
			q := c + {rad * math.cos(t), rad * math.sin(t)}
			raster_line(r, prev, q)
			prev = q
		}
	}
	for poly in p.polys {
		for j in 0 ..< len(poly) {
			a := poly[j] * k + off
			disc(r, a, hw)
			if j + 1 >= len(poly) do continue
			b := poly[j + 1] * k + off
			d := b - a
			l := linalg.length(d)
			if l < 1e-4 do continue
			nrm := [2]f32{-d.y, d.x} / l * hw
			// counter-clockwise, as the discs
			q := [4][2]f32{a - nrm, b - nrm, b + nrm, a + nrm}
			for m in 0 ..< 4 do raster_line(r, q[m], q[(m + 1) % 4])
		}
	}
}
