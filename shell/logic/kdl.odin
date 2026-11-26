// The niri settings the shell writes (iris-shell.kdl), and the edits of
// niri's config.kdl: the include line, and Waybar's start line.
package logic

import "core:strings"

KDL_NAME :: "iris-shell.kdl"
INCLUDE_LINE :: `include "iris-shell.kdl"`
BAR_MARK :: "// hidden by Iris Shell: "
KDL_MARK :: "// Written by Iris Shell"

/// niri's settings for the shell: it starts with niri, gaps for the glass
/// to show in, rounded windows, a clear glass focus ring, soft shadows, and
/// colours that follow light or dark. The shell rewrites this file when the
/// theme changes (niri reloads it by itself).
theme_kdl :: proc(dark: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w :: strings.write_string
	w(&b, KDL_MARK + ` 1.0 for the `)
	w(&b, dark ? "dark" : "light")
	w(&b, " theme.\n")
	w(&b, "// `iris-shell --setup-niri` adds the include of this file to config.kdl;\n")
	w(&b, "// `iris-shell --remove-niri` takes it out again. The shell rewrites this\n")
	w(&b, "// file when light or dark changes, so put your own settings in config.kdl.\n\n")
	w(&b, "spawn-at-startup \"iris-shell\"\n\n")
	w(&b, "layout {\n    gaps 16\n")
	// the backdrop under the shell's own background: the same graphite or white
	w(&b, dark ? "    background-color \"#0b0c0e\"\n" : "    background-color \"#eef0f4\"\n")
	w(&b, "    focus-ring {\n        width 2\n")
	// clear glass: white light on dark, smoked glass on light
	w(&b, dark ? "        active-gradient from=\"#ffffffa6\" to=\"#ffffff38\" angle=160\n" : "        active-gradient from=\"#1d1d1f8c\" to=\"#1d1d1f38\" angle=160\n")
	w(&b, dark ? "        inactive-color \"#ffffff1a\"\n" : "        inactive-color \"#1d1d1f24\"\n")
	w(&b, "    }\n    border {\n        off\n    }\n")
	w(&b, "    shadow {\n        on\n        softness 40\n        spread 2\n        offset x=0 y=10\n")
	w(&b, dark ? "        color \"#00000099\"\n" : "        color \"#0000003d\"\n")
	w(&b, "    }\n}\n\n")
	w(&b, "overview {\n")
	w(&b, dark ? "    backdrop-color \"#08090b\"\n" : "    backdrop-color \"#e4e7ec\"\n")
	w(&b, "}\n\n")
	w(&b, "window-rule {\n    geometry-corner-radius 18\n    clip-to-geometry true\n}\n\n")
	w(&b, "// the shell's background is also what shows behind the overview\n")
	w(&b, "layer-rule {\n    match namespace=\"^iris-shell$\"\n    place-within-backdrop true\n}\n")
	return strings.to_string(b)
}

/// does config.kdl already include iris-shell.kdl?
config_has_include :: proc(cfg: string) -> bool {
	rest := cfg
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) == INCLUDE_LINE do return true
	}
	return false
}

/// config.kdl with the include at its end (the later setting wins in niri)
config_add_include :: proc(cfg: string, allocator := context.allocator) -> string {
	if config_has_include(cfg) do return strings.clone(cfg, allocator)
	body := strings.trim_right(cfg, "\n")
	return strings.concatenate({body, "\n\n", INCLUDE_LINE, "\n"}, allocator)
}

config_remove_include :: proc(cfg: string, allocator := context.allocator) -> string {
	lines := strings.split(cfg, "\n", context.temp_allocator)
	out := make([dynamic]string, 0, len(lines), context.temp_allocator)
	last_was_include := false // the include was the last thing in the file
	for l in lines {
		if strings.trim_space(l) == INCLUDE_LINE {
			last_was_include = true
			continue
		}
		if len(strings.trim_space(l)) > 0 do last_was_include = false
		append(&out, l)
	}
	s := strings.join(out[:], "\n", allocator)
	if !last_was_include do return s
	// put the file back as it was before the include was added after it
	trimmed := strings.trim_right(s, "\n")
	res := strings.concatenate({trimmed, "\n"}, allocator)
	delete(s, allocator)
	return res
}

@(private) is_bar_line :: proc(t: string) -> bool {
	return (strings.has_prefix(t, "spawn-at-startup") || strings.has_prefix(t, "spawn-sh-at-startup")) && strings.contains(t, "waybar")
}

/// config.kdl with the lines that start Waybar turned into comments marked
/// as the shell's (or, with hide false, turned back exactly)
config_bar :: proc(cfg: string, hide: bool, allocator := context.allocator) -> (out: string, changed: bool) {
	lines := strings.split(cfg, "\n", context.temp_allocator)
	for &l in lines {
		rest := strings.trim_left(l, " \t")
		ind := l[:len(l) - len(rest)]
		switch {
		case hide && is_bar_line(rest):
			l = strings.concatenate({ind, BAR_MARK, rest}, context.temp_allocator)
			changed = true
		case !hide && strings.has_prefix(rest, BAR_MARK):
			l = strings.concatenate({ind, rest[len(BAR_MARK):]}, context.temp_allocator)
			changed = true
		}
	}
	return strings.join(lines, "\n", allocator), changed
}

config_bar_hidden :: proc(cfg: string) -> bool {
	return strings.contains(cfg, BAR_MARK)
}
