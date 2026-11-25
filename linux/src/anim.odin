// Iris's motion: one easing curve, one spring, and the clock they run on.
// The chrome draws again only while something moves (ui.animating); when
// nothing does, Iris draws nothing at all.
package iris

import "core:math"

/// fast at first, settling softly
ease_out_cubic :: proc(x: f32) -> f32 {
	t := clamp(x, 0, 1)
	u := 1 - t
	return 1 - u * u * u
}

/// how far (0..1, eased) a motion of ms milliseconds that began at t0 (on
/// the chrome's clock, seconds) has come after a delay; and whether it goes
/// on. With reduced motion every motion is a short plain fade.
motion :: proc(t0, now: f64, ms: f32, delay_ms: f32 = 0) -> (k: f32, moving: bool) {
	d := theme.reduce_motion ? REDUCED_MS : ms
	wait := theme.reduce_motion ? 0 : delay_ms
	x := (f32(now - t0) * 1000 - wait) / d
	if x >= 1 do return 1, false
	return ease_out_cubic(x), true
}

REDUCED_MS :: f32(120)

/// a scale or offset that only moves when motion is welcome (with reduced
/// motion things just appear, at their place)
motion_from :: proc(from, to, k: f32) -> f32 {
	if theme.reduce_motion do return to
	return from + (to - from) * k
}

Spring :: struct {
	x, v: f32,
}

/// one step of a critically damped spring towards target (~180 ms to
/// settle); true while it moves
spring_step :: proc(s: ^Spring, target, dt: f32, stiffness: f32 = 900) -> bool {
	if theme.reduce_motion || dt <= 0 {
		s.x, s.v = target, 0
		return false
	}
	damping := 2 * math.sqrt(stiffness)
	// small steps, so a slow frame does not shoot past
	steps := int(math.ceil(dt / (1.0 / 240)))
	h := dt / f32(steps)
	for _ in 0 ..< steps {
		a := stiffness * (target - s.x) - damping * s.v
		s.v += a * h
		s.x += s.v * h
	}
	if abs(target - s.x) < 0.004 && abs(s.v) < 0.05 {
		s.x, s.v = target, 0
		return false
	}
	return true
}
