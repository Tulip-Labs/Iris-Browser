// The colour a window reflects when nothing can be read from its pixels: a
// small table of what people have open (a site's title, an app's id), and
// otherwise a stable colour made from the app id (and a little from the
// title, so it follows what is open in it). The hue stays between red and
// blue (0 to 220 degrees): never purple.
package logic

import "core:math"

Tint_Rule :: struct {
	key:   string,
	title: bool, // in the title (a site), or in the app id
	color: Rgb,
}

// lower case keys; the first rule that matches wins, titles before apps
TINT_RULES := [?]Tint_Rule{
	{"youtube", true, {1.00, 0.18, 0.16}},
	{"netflix", true, {0.93, 0.13, 0.18}},
	{"twitch", true, {0.30, 0.62, 1.00}},
	{"github", true, {0.60, 0.63, 0.68}},
	{"gitlab", true, {0.99, 0.45, 0.16}},
	{"stack overflow", true, {0.96, 0.52, 0.12}},
	{"reddit", true, {1.00, 0.36, 0.12}},
	{"spotify", true, {0.12, 0.84, 0.38}},
	{"wikipedia", true, {0.74, 0.75, 0.78}},
	{"google docs", true, {0.26, 0.52, 0.96}},
	{"google sheets", true, {0.13, 0.66, 0.36}},
	{"gmail", true, {0.92, 0.27, 0.22}},
	{"discord", true, {0.32, 0.56, 1.00}},
	{"foot", false, {0.52, 0.78, 0.66}},
	{"alacritty", false, {0.52, 0.78, 0.66}},
	{"kitty", false, {0.52, 0.78, 0.66}},
	{"wezterm", false, {0.52, 0.78, 0.66}},
	{"ghostty", false, {0.52, 0.78, 0.66}},
	{"konsole", false, {0.52, 0.78, 0.66}},
	{"terminal", false, {0.52, 0.78, 0.66}},
	{"code", false, {0.20, 0.56, 0.96}},
	{"zed", false, {0.20, 0.56, 0.96}},
	{"spotify", false, {0.12, 0.84, 0.38}},
	{"steam", false, {0.34, 0.58, 0.80}},
	{"nautilus", false, {0.45, 0.70, 0.95}},
}

@(private) lower_into :: proc(buf: []u8, s: string) -> string {
	n := min(len(buf), len(s))
	for i in 0 ..< n {
		c := s[i]
		buf[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	return string(buf[:n])
}

@(private) contains :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 || len(needle) > len(hay) do return false
	for i in 0 ..= len(hay) - len(needle) {
		if hay[i:i + len(needle)] == needle do return true
	}
	return false
}

fnv1a :: proc(s: string) -> u32 {
	h: u32 = 2166136261
	for i in 0 ..< len(s) {
		h = (h ~ u32(s[i])) * 16777619
	}
	return h
}

hsv :: proc(h, s, v: f32) -> Rgb {
	hh := h - math.floor(h)
	k := [3]f32{0, 4, 2}
	out: Rgb
	for i in 0 ..< 3 {
		x := math.abs(math.mod(hh * 6 + k[i], 6) - 3) - 1
		x = clamp(x, 0, 1)
		out[i] = v * (1 + (x - 1) * s)
	}
	return out
}

/// the colour for a window, from its app id and title
tint_for :: proc(app_id, title: string) -> Rgb {
	ab, tb: [128]u8
	app := lower_into(ab[:], app_id)
	ttl := lower_into(tb[:], title)
	for r in TINT_RULES {
		if r.title && contains(ttl, r.key) do return r.color
	}
	for r in TINT_RULES {
		if !r.title && contains(app, r.key) do return r.color
	}
	// a stable hue per app (red .. blue), nudged a little by the title
	span :: f32(220.0 / 360.0)
	base := f32(fnv1a(app_id) % 1000) / 1000
	nudge := (f32(fnv1a(title) % 1000) / 1000 - 0.5) * 0.08
	h := clamp(base * span + nudge, 0, span)
	if len(app_id) == 0 && len(title) == 0 do return {0.7, 0.72, 0.76}
	return hsv(h, 0.55, 1.0)
}

/// what a window's pixels say: the mean colour of a few samples, made a
/// little more vivid so it reads as a tint (a grey page stays grey)
tint_from_mean :: proc(mean: Rgb) -> Rgb {
	mx := max(mean.r, mean.g, mean.b)
	mn := min(mean.r, mean.g, mean.b)
	if mx <= 0.0001 do return {0.6, 0.6, 0.62}
	sat := (mx - mn) / mx
	boost := clamp(sat * 1.5, 0, 0.9)
	v := clamp(mx * 1.15 + 0.15, 0.55, 1.0)
	// keep the hue, set the saturation and brightness
	if mx - mn < 0.0001 do return {v, v, v}
	d := mx - mn
	h: f32
	switch {
	case mx == mean.r: h = math.mod((mean.g - mean.b) / d, 6)
	case mx == mean.g: h = (mean.b - mean.r) / d + 2
	case: h = (mean.r - mean.g) / d + 4
	}
	if h < 0 do h += 6
	return hsv(h / 6, boost, v)
}
