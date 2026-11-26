// The colours: the Iris glass themes (colourless clear glass, dark or
// light) and their ANSI palettes. Magenta is a rose, never a violet.
package term

Theme :: struct {
	name:     string,
	dark:     bool,
	ansi:     [16]RGB,
	fg, bg:   RGB, // the ink, and the tint of the glass
	cursor:   RGB,
	selection: [4]f32, // rgba
	/// how much of the glass shows what is behind (alpha of the fill), with a blur and without
	alpha_blur, alpha_plain: f32,
	/// the light along the rim
	rim: f32,
}

@(private) DARK_ANSI := [16]RGB{
	{0x3b, 0x3f, 0x46}, {0xf2, 0x70, 0x6f}, {0x7f, 0xd4, 0x8a}, {0xe8, 0xc8, 0x74}, {0x6e, 0xa8, 0xfe}, {0xe5, 0x8f, 0xb8}, {0x5f, 0xd0, 0xd6}, {0xd4, 0xd7, 0xdd},
	{0x6e, 0x74, 0x7f}, {0xff, 0x8a, 0x85}, {0x9b, 0xe8, 0xa5}, {0xf5, 0xdc, 0x92}, {0x8f, 0xc0, 0xff}, {0xf2, 0xaa, 0xca}, {0x86, 0xe4, 0xe8}, {0xff, 0xff, 0xff},
}

@(private) LIGHT_ANSI := [16]RGB{
	{0x2b, 0x2f, 0x36}, {0xc2, 0x38, 0x33}, {0x24, 0x84, 0x44}, {0x95, 0x6c, 0x00}, {0x25, 0x5f, 0xd0}, {0xb0, 0x36, 0x70}, {0x16, 0x82, 0x90}, {0x7b, 0x81, 0x8b},
	{0x5c, 0x63, 0x6e}, {0xd8, 0x4a, 0x44}, {0x2f, 0x9b, 0x55}, {0xa9, 0x7e, 0x0a}, {0x3a, 0x74, 0xe6}, {0xc8, 0x4a, 0x85}, {0x20, 0x9a, 0xa8}, {0x3a, 0x3f, 0x47},
}

THEME_NAMES :: [?]string{"glass", "glass-dark", "glass-light", "graphite", "paper"}

/// a theme by name; "glass" (and anything unknown) follows `dark`
theme_by_name :: proc(name: string, dark: bool) -> Theme {
	switch name {
	case "glass-dark", "dark": return theme_glass(true)
	case "glass-light", "light": return theme_glass(false)
	case "graphite":
		t := theme_glass(true)
		t.name = "graphite"
		t.bg = {0x14, 0x15, 0x17}
		t.alpha_blur, t.alpha_plain = 0.84, 0.95
		return t
	case "paper":
		t := theme_glass(false)
		t.name = "paper"
		t.bg = {0xfa, 0xfa, 0xf8}
		t.alpha_blur, t.alpha_plain = 0.88, 0.97
		return t
	}
	return theme_glass(dark)
}

theme_glass :: proc(dark: bool) -> Theme {
	if dark {
		return {
			name = "glass-dark", dark = true, ansi = DARK_ANSI, fg = {0xe8, 0xea, 0xed}, bg = {0x0a, 0x0c, 0x0f}, cursor = {0xf5, 0xf7, 0xfa},
			selection = {1, 1, 1, 0.24}, alpha_blur = 0.55, alpha_plain = 0.88, rim = 0.20,
		}
	}
	return {
		name = "glass-light", dark = false, ansi = LIGHT_ANSI, fg = {0x1c, 0x1e, 0x22}, bg = {0xf6, 0xf7, 0xf9}, cursor = {0x1c, 0x1e, 0x22},
		selection = {0.0, 0.0, 0.0, 0.16}, alpha_blur = 0.62, alpha_plain = 0.90, rim = 0.55,
	}
}

term_apply_theme :: proc(t: ^Term, th: Theme) {
	term_set_theme(t, th.ansi, th.fg, th.bg, th.cursor)
}

/// IRIS_THEME / gsettings text: `'prefer-dark'` is dark; anything else follows `default_dark`
parse_scheme :: proc(s: string, default_dark := true) -> bool {
	if contains_text(s, "prefer-dark") do return true
	if contains_text(s, "prefer-light") do return false
	if s == "dark" do return true
	if s == "light" do return false
	return default_dark
}

@(private) contains_text :: proc(s, sub: string) -> bool {
	if len(sub) > len(s) do return false
	for i in 0 ..= len(s) - len(sub) do if s[i:i + len(sub)] == sub do return true
	return false
}
