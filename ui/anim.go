package ui

import "math"

// Motion: values that glide to where the interface wants them instead of
// jumping, so a hover, a press, a focus or a choice is felt as well as seen.
// Everything is short (about a sixth of a second) and eases out, and nothing
// moves when the reader asked for less motion (Ui.NoMotion).

type animVal struct {
	v    float32
	seen float64
}

// Motion rates: how quickly a value closes on its target (per second).
const (
	RateFast  = 22 // presses
	RateQuick = 14 // hovers, focus, toggles
	RateCalm  = 9  // panels, larger moves
)

// frameDt is the time since the last frame, worked out once per frame.
func (u *Ui) frameDt() float32 {
	st := u.St
	if st.animNow != u.In.Now {
		dt := u.In.Now - st.animNow
		if st.animNow == 0 || dt < 0 || dt > 0.1 {
			dt = 1.0 / 60
		}
		st.animDt = float32(dt)
		st.animNow = u.In.Now
		// let go of values not drawn for a while
		if len(st.anims) > 256 {
			for k, a := range st.anims {
				if u.In.Now-a.seen > 5 {
					delete(st.anims, k)
				}
			}
		}
	}
	return st.animDt
}

// Ease is a value of id that glides towards target; the first time it is
// asked for, it starts there.
func (u *Ui) Ease(id ID, target, rate float32) float32 {
	return u.ease(id, target, rate, target)
}

// EaseFrom is Ease starting at from the first time (an entrance).
func (u *Ui) EaseFrom(id ID, target, rate, from float32) float32 {
	return u.ease(id, target, rate, from)
}

func (u *Ui) ease(id ID, target, rate, start float32) float32 {
	st := u.St
	if st.anims == nil {
		st.anims = map[ID]*animVal{}
	}
	dt := u.frameDt()
	a := st.anims[id]
	if a == nil {
		a = &animVal{v: start}
		st.anims[id] = a
	}
	a.seen = u.In.Now
	if u.NoMotion {
		a.v = target
		return target
	}
	d := target - a.v
	if d > -0.002 && d < 0.002 {
		a.v = target
		return target
	}
	a.v += d * float32(1-math.Exp(float64(-rate*dt)))
	u.Redraw = true
	return a.v
}

// Hot is how much the pointer is over r (0 to 1, gliding), for hover effects.
func (u *Ui) Hot(id ID, r Rect, enabled bool) float32 {
	t := float32(0)
	if enabled && u.Hover(r) {
		t = 1
	}
	return u.Ease(id.Sub("hot"), t, RateQuick)
}

// Press is how pressed id is (0 to 1, quick), for the small squeeze a
// pressed control gives.
func (u *Ui) Press(id ID, enabled bool) float32 {
	t := float32(0)
	if enabled && u.IsActive(id) {
		t = 1
	}
	return u.Ease(id.Sub("press"), t, RateFast)
}

// Squeeze shrinks r about its center by up to 4% as p goes to 1.
func Squeeze(r Rect, p float32) Rect {
	if p <= 0 {
		return r
	}
	k := 1 - 0.04*p
	return RectAround(r.CX(), r.CY(), r.W*k, r.H*k)
}

// Smooth is the smoothstep of t in 0..1 (an easing for entrances).
func Smooth(t float32) float32 {
	t = clampf(t, 0, 1)
	return t * t * (3 - 2*t)
}

// On is 1 for true and 0 for false: a target for Ease.
func On(b bool) float32 { return b2f(b) }

// Forget drops id's motion, so its next EaseFrom starts again (an entrance
// that should play each time something appears).
func (u *Ui) Forget(id ID) {
	if u.St.anims != nil {
		delete(u.St.anims, id)
	}
}
