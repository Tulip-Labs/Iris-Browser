// What one output draws: a halo behind each window it shows, and the one
// animation (about 300 ms) that eases from one scene to the next.
package logic

import "core:math"

MAX_HALOS :: 16
ANIM_MS :: 300

Halo :: struct {
	id:    u64,
	rect:  Rect, // logical pixels, on the output
	tint:  Rgb,
	power: f32, // 0 .. 1: how much it shows
}

Frame :: struct {
	halos: [MAX_HALOS]Halo,
	n:     int,
	dark:  f32, // 0 light, 1 dark
}

/// the halos of the windows on the output's active workspace, the ones
/// that are on the output at all (a tiled window with a known place)
scene_for_output :: proc(m: ^Model, output: string, w, h: f32, dark: bool) -> (f: Frame) {
	f.dark = dark ? 1 : 0
	if m.overview do return
	ws := active_workspace(m, output)
	if ws == 0 && len(m.workspaces) > 0 do return
	for win in m.windows {
		if f.n >= MAX_HALOS do break
		if win.floating || !win.has_rect do continue
		if ws != 0 && win.ws_id != ws do continue
		r := win.rect
		if r.x >= w || r.y >= h || r.x + r.w <= 0 || r.y + r.h <= 0 do continue
		tint := win.has_sampled ? win.sampled : tint_for(win.app_id, win.title)
		f.halos[f.n] = Halo{win.id, r, tint, win.focused ? 1.0 : 0.7}
		f.n += 1
	}
	return
}

@(private) near :: proc(a, b: f32) -> bool { return math.abs(a - b) < 0.01 }

frame_equal :: proc(a, b: ^Frame) -> bool {
	if a.n != b.n || !near(a.dark, b.dark) do return false
	for i in 0 ..< a.n {
		x, y := a.halos[i], b.halos[i]
		if x.id != y.id || !near(x.power, y.power) do return false
		if !near(x.rect.x, y.rect.x) || !near(x.rect.y, y.rect.y) || !near(x.rect.w, y.rect.w) || !near(x.rect.h, y.rect.h) do return false
		for k in 0 ..< 3 do if math.abs(x.tint[k] - y.tint[k]) > 0.004 do return false
	}
	return true
}

Anim :: struct {
	from, to: Frame,
	t0:       i64, // ms
	dur:      i64,
	running:  bool,
}

ease_out_cubic :: proc(t: f32) -> f32 {
	u := 1 - clamp(t, 0, 1)
	return 1 - u * u * u
}

@(private) lerp :: proc(a, b, t: f32) -> f32 { return a + (b - a) * t }

/// the picture at `now`; done when it is the target itself
anim_value :: proc(a: ^Anim, now: i64) -> (f: Frame, done: bool) {
	if !a.running || a.dur <= 0 || now >= a.t0 + a.dur do return a.to, true
	t := ease_out_cubic(f32(now - a.t0) / f32(a.dur))
	f.dark = lerp(a.from.dark, a.to.dark, t)
	// windows in the target: from where they were (or from nothing)
	for i in 0 ..< a.to.n {
		to := a.to.halos[i]
		h := to
		found := false
		for j in 0 ..< a.from.n {
			fr := a.from.halos[j]
			if fr.id != to.id do continue
			found = true
			h.rect = {lerp(fr.rect.x, to.rect.x, t), lerp(fr.rect.y, to.rect.y, t), lerp(fr.rect.w, to.rect.w, t), lerp(fr.rect.h, to.rect.h, t)}
			for k in 0 ..< 3 do h.tint[k] = lerp(fr.tint[k], to.tint[k], t)
			h.power = lerp(fr.power, to.power, t)
			break
		}
		if !found do h.power = to.power * t
		f.halos[f.n] = h
		f.n += 1
	}
	// windows that went: they fade out where they were
	for j in 0 ..< a.from.n {
		fr := a.from.halos[j]
		gone := true
		for i in 0 ..< a.to.n do if a.to.halos[i].id == fr.id do gone = false
		if gone && f.n < MAX_HALOS {
			h := fr
			h.power = fr.power * (1 - t)
			f.halos[f.n] = h
			f.n += 1
		}
	}
	return f, false
}

/// ease from what is shown now to `target`; with dur 0 it is there at once.
/// It reports whether there is anything to animate.
anim_to :: proc(a: ^Anim, now: i64, target: Frame, dur: i64 = ANIM_MS) -> bool {
	t := target
	if frame_equal(&t, &a.to) do return false
	cur, _ := anim_value(a, now)
	a.from = cur
	a.to = target
	a.t0 = now
	a.dur = dur
	a.running = dur > 0
	return true
}

/// show `target` at once (the first picture of an output: no fade from nothing)
anim_jump :: proc(a: ^Anim, target: Frame) {
	a.from, a.to = target, target
	a.running = false
}
