// The rasteriser (from the browser's linux/src/raster.odin, without the
// icon paths): outlines (a font's glyphs, the line icons) become
// coverage bitmaps, antialiased by the exact area each edge covers in
// each pixel (signed-area accumulation, as font-rs does). Curves are
// flattened into short lines; strokes become filled shapes first.
package main

import "core:math"

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

