// The two little icons of the chrome (a hexagon for a container, a
// magnifier for the search), drawn from distance fields at the exact pixel
// size so they are sharp at every scale.
package main

import "core:math"

Icon :: enum u8 { Container, Search }

@(private="file") sd_segment :: proc(p, a, b: [2]f32) -> f32 {
	pa, ba := p - a, b - a
	h := clamp((pa.x * ba.x + pa.y * ba.y) / (ba.x * ba.x + ba.y * ba.y), 0, 1)
	d := pa - ba * h
	return math.sqrt(d.x * d.x + d.y * d.y)
}

/// the signed distance to a regular hexagon (flat top) of the radius r
@(private="file") sd_hexagon :: proc(p: [2]f32, r: f32) -> f32 {
	k := [3]f32{-0.866025404, 0.5, 0.577350269}
	q := [2]f32{abs(p.x), abs(p.y)}
	dot := k.x * q.x + k.y * q.y
	m := min(dot, 0)
	q.x -= 2 * m * k.x
	q.y -= 2 * m * k.y
	q.x -= clamp(q.x, -k.z * r, k.z * r)
	q.y -= r
	l := math.sqrt(q.x * q.x + q.y * q.y)
	return q.y < 0 ? -l : l
}

/// an icon `size` pixels square, as an atlas slot of coverage
atlas_icon :: proc(icon: Icon, size: int) -> (Atlas_Slot, bool) {
	key := Special_Key{rune(icon), i32(size), i32(size), 2}
	if s, found := atlas.specials[key]; found do return s, true
	n := size
	px := make([]u8, n * n, context.temp_allocator)
	fs := f32(n)
	th := max(1.3, fs / 11)
	for y in 0 ..< n {
		for x in 0 ..< n {
			p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			d: f32
			switch icon {
			case .Container:
				// a hexagon outline with a small hexagon inside
				q := p - fs * 0.5
				d1 := abs(sd_hexagon({q.y, q.x}, fs * 0.46)) - th * 0.5
				d2 := sd_hexagon({q.y, q.x}, fs * 0.16) - 0
				d = min(d1, d2)
			case .Search:
				c := [2]f32{fs * 0.42, fs * 0.42}
				q := p - c
				ring := abs(math.sqrt(q.x * q.x + q.y * q.y) - fs * 0.28) - th * 0.5
				handle := sd_segment(p, {fs * 0.63, fs * 0.63}, {fs * 0.88, fs * 0.88}) - th * 0.55
				d = min(ring, handle)
			}
			px[y * n + x] = u8(clamp(0.5 - d, 0, 1) * 255)
		}
	}
	x, y, ok := atlas_place(i32(n), i32(n))
	if !ok do return {}, false
	atlas_upload(x, y, i32(n), i32(n), px)
	s := Atlas_Slot{x = x, y = y, w = i32(n), h = i32(n)}
	atlas.specials[key] = s
	return s, true
}
