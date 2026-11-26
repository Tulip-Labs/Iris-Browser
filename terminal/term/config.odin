// The settings file: ~/.config/iris-terminal/config, plain `key = value`
// lines (a line that starts with # is a comment). No settings window.
package term

import "core:strconv"
import "core:strings"

DEFAULT_FONTS :: "MesloLGS NF, JetBrainsMono Nerd Font, FiraCode Nerd Font, Symbols Nerd Font Mono, DejaVu Sans Mono"

Config :: struct {
	/// font families, in order of preference (the first that is installed is
	/// the main one; the others fill in what it lacks)
	font:           string,
	/// in points (96 dpi: 12 is 16 pixels)
	font_size:      f32,
	/// glass, glass-dark, glass-light, graphite, paper
	theme:          string,
	/// how much the glass shows what is behind it (0 clear .. 1 solid); -1: by
	/// whether the compositor blurs
	opacity:        f32,
	blur:           bool,
	padding:        int,
	radius:         int,
	cursor:         Cursor_Style,
	cursor_glow:    bool,
	scrollback:     int,
	columns, rows:  int,
	shell:          string,
	container:      string,
	ligatures:      bool,
	bold_is_bright: bool,
	bell:           bool,
	osc52:          bool,
	copy_on_select: bool,
	word_chars:     string,
	animations:     bool,
	scroll_lines:   int,
	unknown:        [dynamic]string, // lines it did not understand
}

config_default :: proc() -> Config {
	return Config{
		font = strings.clone(DEFAULT_FONTS), font_size = 12, theme = strings.clone("glass"), opacity = -1, blur = true,
		padding = 14, radius = 14, cursor = .Block, cursor_glow = true, scrollback = SCROLLBACK_DEFAULT,
		columns = 100, rows = 30, shell = strings.clone(""), container = strings.clone(""), ligatures = true,
		bell = true, osc52 = true, copy_on_select = true, word_chars = strings.clone(DEFAULT_WORD_SEPARATORS),
		animations = true, scroll_lines = 3,
	}
}

config_free :: proc(c: ^Config) {
	delete(c.font)
	delete(c.theme)
	delete(c.shell)
	delete(c.container)
	delete(c.word_chars)
	for u in c.unknown do delete(u)
	delete(c.unknown)
}

@(private) parse_bool :: proc(s: string) -> (v: bool, ok: bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "true", "yes", "on", "1": return true, true
	case "false", "no", "off", "0": return false, true
	}
	return
}

@(private) unquote :: proc(s: string) -> string {
	if len(s) >= 2 && (s[0] == '"' && s[len(s) - 1] == '"' || s[0] == '\'' && s[len(s) - 1] == '\'') do return s[1:len(s) - 1]
	return s
}

@(private) set_string :: proc(dst: ^string, v: string) {
	delete(dst^)
	dst^ = strings.clone(v)
}

/// one setting; false when the key or its value is not understood
config_set :: proc(c: ^Config, key_raw, value_raw: string) -> bool {
	key, _ := strings.replace_all(strings.to_lower(strings.trim_space(key_raw), context.temp_allocator), "-", "_", context.temp_allocator)
	value := unquote(strings.trim_space(value_raw))
	b, bok := parse_bool(value)
	n, nok := strconv.parse_int(value, 10)
	f, fok := strconv.parse_f32(value)
	switch key {
	case "font": set_string(&c.font, value)
	case "font_size":
		if !fok || f < 4 || f > 96 do return false
		c.font_size = f
	case "theme": set_string(&c.theme, strings.to_lower(value, context.temp_allocator))
	case "opacity":
		if !fok || f > 1 || (f < 0 && f != -1) do return false
		c.opacity = f
	case "blur":
		if !bok do return false
		c.blur = b
	case "padding":
		if !nok || n < 0 || n > 200 do return false
		c.padding = n
	case "radius":
		if !nok || n < 0 || n > 100 do return false
		c.radius = n
	case "cursor":
		switch strings.to_lower(value, context.temp_allocator) {
		case "block": c.cursor = .Block
		case "bar", "beam": c.cursor = .Bar
		case "underline": c.cursor = .Underline
		case: return false
		}
	case "cursor_glow":
		if !bok do return false
		c.cursor_glow = b
	case "scrollback":
		if !nok || n < 0 || n > 1_000_000 do return false
		c.scrollback = n
	case "columns":
		if !nok || n < 10 || n > MAX_COLS do return false
		c.columns = n
	case "rows":
		if !nok || n < 3 || n > MAX_ROWS do return false
		c.rows = n
	case "shell": set_string(&c.shell, value)
	case "container": set_string(&c.container, value)
	case "ligatures":
		if !bok do return false
		c.ligatures = b
	case "bold_is_bright":
		if !bok do return false
		c.bold_is_bright = b
	case "bell":
		switch strings.to_lower(value, context.temp_allocator) {
		case "flash", "true", "yes", "on": c.bell = true
		case "none", "false", "no", "off": c.bell = false
		case: return false
		}
	case "osc52":
		if !bok do return false
		c.osc52 = b
	case "copy_on_select":
		if !bok do return false
		c.copy_on_select = b
	case "word_chars": set_string(&c.word_chars, value)
	case "animations":
		if !bok do return false
		c.animations = b
	case "scroll_lines":
		if !nok || n < 1 || n > 50 do return false
		c.scroll_lines = n
	case: return false
	}
	return true
}

/// the text of a settings file, over `c`
config_parse :: proc(c: ^Config, text: string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' || l[0] == ';' do continue
		eq := strings.index_byte(l, '=')
		if eq < 0 {
			append(&c.unknown, strings.clone(l))
			continue
		}
		if !config_set(c, l[:eq], l[eq + 1:]) do append(&c.unknown, strings.clone(l))
	}
}

/// the family names of the `font` setting
font_families :: proc(c: ^Config, allocator := context.temp_allocator) -> []string {
	res := make([dynamic]string, allocator)
	for part in strings.split(c.font, ",", context.temp_allocator) {
		p := unquote(strings.trim_space(part))
		if len(p) > 0 do append(&res, p)
	}
	return res[:]
}

CONFIG_SAMPLE :: `# Iris Terminal: ~/.config/iris-terminal/config
# One setting per line, "key = value". Changes apply at once (the file is watched).
# Lines that start with # are comments. Everything here is the default.

# fonts: the first one installed is the main one, the rest fill in what it lacks.
# (iris-terminal --install-fonts downloads MesloLGS NF, which has the powerline
# and Nerd Font symbols, into ~/.local/share/fonts.)
font = ` + DEFAULT_FONTS + `
font_size = 12

# glass (follows the desktop's light or dark), glass-dark, glass-light, graphite, paper
theme = glass
# 0 clear .. 1 solid; -1 chooses by whether the desktop blurs behind windows
opacity = -1
blur = true
padding = 14
radius = 14

cursor = block
cursor_glow = true
scrollback = 10000
columns = 100
rows = 30

# the shell to start (default: your login shell), and the distrobox/toolbox
# container Ctrl+Shift+T opens
shell =
container =

ligatures = true
bold_is_bright = false
bell = flash
osc52 = true
copy_on_select = true
animations = true
scroll_lines = 3
`
