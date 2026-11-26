// `iris-terminal --setup-niri`: ~/.config/niri/iris-terminal.kdl (a window
// rule for the glass: rounded corners, no border background, blur when
// niri can) and the one include line in config.kdl, after a backup.
package term

import "core:os"
import "core:strings"

NIRI_KDL_NAME :: "iris-terminal.kdl"
NIRI_INCLUDE :: `include "iris-terminal.kdl"`
NIRI_KDL_MARK :: "// Written by Iris Terminal"
NIRI_BACKUP_SUFFIX :: ".before-iris-terminal"
APP_ID :: "io.github.tulip_labs.IrisTerminal"

/// niri's config folder: $XDG_CONFIG_HOME/niri, or ~/.config/niri
niri_config_dir :: proc(allocator := context.allocator) -> string {
	if d := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); len(d) > 0 {
		return strings.concatenate({d, "/niri"}, allocator)
	}
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config/niri"}, allocator)
}

/// "niri 26.04 (abc123)" -> 26, 4
parse_niri_version :: proc(s: string) -> (major, minor: int, ok: bool) {
	rest := strings.trim_space(s)
	if strings.has_prefix(rest, "niri ") do rest = rest[5:]
	i := 0
	for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
		major = major * 10 + int(rest[i] - '0')
		i += 1
	}
	if i == 0 || i >= len(rest) || rest[i] != '.' do return 0, 0, false
	i += 1
	j := i
	for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {
		minor = minor * 10 + int(rest[j] - '0')
		j += 1
	}
	return major, minor, j > i
}

/// does this niri blur behind a window by a rule? (26.04 and newer)
niri_has_blur :: proc(version_text: string) -> bool {
	major, minor, ok := parse_niri_version(version_text)
	return ok && (major > 26 || (major == 26 && minor >= 4))
}

niri_kdl :: proc(radius: int, blur: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w :: strings.write_string
	w(&b, NIRI_KDL_MARK + " 1.0.\n")
	w(&b, "// `iris-terminal --setup-niri` adds the include of this file to config.kdl;\n")
	w(&b, "// `iris-terminal --remove-niri` takes it out again.\n\n")
	w(&b, "window-rule {\n    match app-id=\"^io.github.tulip_labs.IrisTerminal$\"\n")
	w(&b, "    // the terminal draws its own translucent glass: niri only rounds and clips it\n")
	w(&b, "    draw-border-with-background false\n    clip-to-geometry true\n")
	w(&b, "    geometry-corner-radius ")
	strings.write_int(&b, radius)
	w(&b, "\n")
	if blur {
		w(&b, "    // niri 26.04 and newer blur what is behind the glass\n")
		w(&b, "    background-effect {\n        blur true\n    }\n")
	}
	w(&b, "}\n")
	return strings.to_string(b)
}

niri_has_include :: proc(cfg: string) -> bool {
	rest := cfg
	for line in strings.split_lines_iterator(&rest) do if strings.trim_space(line) == NIRI_INCLUDE do return true
	return false
}

niri_add_include :: proc(cfg: string, allocator := context.allocator) -> string {
	if niri_has_include(cfg) do return strings.clone(cfg, allocator)
	body := strings.trim_right(cfg, "\n")
	return strings.concatenate({body, "\n\n", NIRI_INCLUDE, "\n"}, allocator)
}

niri_remove_include :: proc(cfg: string, allocator := context.allocator) -> string {
	lines := strings.split(cfg, "\n", context.temp_allocator)
	out := make([dynamic]string, 0, len(lines), context.temp_allocator)
	last_was_include := false
	for l in lines {
		if strings.trim_space(l) == NIRI_INCLUDE {
			last_was_include = true
			continue
		}
		if len(strings.trim_space(l)) > 0 do last_was_include = false
		append(&out, l)
	}
	s := strings.join(out[:], "\n", context.temp_allocator)
	if !last_was_include do return strings.clone(s, allocator)
	return strings.concatenate({strings.trim_right(s, "\n"), "\n"}, allocator)
}

Niri_Result :: struct {
	added_include: bool,
	backup:        string,
	blur:          bool,
}

Niri_Error :: enum { None, No_Config, Io }

niri_setup :: proc(dir: string, radius: int, blur: bool) -> (res: Niri_Result, err: Niri_Error) {
	cfg := strings.concatenate({dir, "/config.kdl"}, context.temp_allocator)
	old, ok := read_text(cfg)
	if !ok do return res, .No_Config
	kdl := niri_kdl(radius, blur, context.temp_allocator)
	if !write_if_changed(strings.concatenate({dir, "/", NIRI_KDL_NAME}, context.temp_allocator), kdl) do return res, .Io
	res.blur = blur
	if !niri_has_include(old) {
		backup := strings.concatenate({cfg, NIRI_BACKUP_SUFFIX}, context.temp_allocator)
		if !os.exists(backup) {
			if os.write_entire_file(backup, old) != nil do return res, .Io
			res.backup = strings.clone(backup)
		}
		if !write_if_changed(cfg, niri_add_include(old, context.temp_allocator)) do return res, .Io
		res.added_include = true
	}
	return res, .None
}

niri_remove :: proc(dir: string) -> (removed_include: bool, err: Niri_Error) {
	cfg := strings.concatenate({dir, "/config.kdl"}, context.temp_allocator)
	if old, ok := read_text(cfg); ok {
		text := niri_remove_include(old, context.temp_allocator)
		if text != old {
			if !write_if_changed(cfg, text) do return false, .Io
			removed_include = true
		}
	}
	os.remove(strings.concatenate({dir, "/", NIRI_KDL_NAME}, context.temp_allocator))
	return removed_include, .None
}
