// Iris's motion, kept to almost nothing: a menu, a note or a card fades in
// over FADE_MS, and that is all. Nothing moves on its own, nothing runs
// per frame on the tabs or the start page, and while nothing fades Iris
// draws no frames at all (ui.animating). With reduced motion even the
// fade goes.
package iris

FADE_MS :: f32(120)

/// how far (0..1) a fade that began at t0 (the chrome's clock, seconds) has
/// come, and whether it goes on
fade :: proc(t0, now: f64) -> (k: f32, moving: bool) {
	if theme.reduce_motion do return 1, false
	x := f32(now - t0) * 1000 / FADE_MS
	if x >= 1 || x < 0 do return 1, false
	return x, true
}
