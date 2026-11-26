// `iris-shell --setup-niri` and `--remove-niri`: the files in niri's
// config folder.
package logic

import "core:os"
import "core:strings"

Setup_Result :: struct {
	added_include: bool,
	hid_bar:       bool,
	backup:        string, // where config.kdl was copied first ("" when it was not)
}

Setup_Error :: enum {
	None,
	No_Config, // niri writes config.kdl when it first starts
	Io,
}

BACKUP_SUFFIX :: ".before-iris-shell"

/// niri's config folder: $XDG_CONFIG_HOME/niri, or ~/.config/niri
niri_config_dir :: proc(allocator := context.allocator) -> string {
	if d := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); len(d) > 0 {
		return strings.concatenate({d, "/niri"}, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return strings.concatenate({home, "/.config/niri"}, allocator)
}

@(private) read_text :: proc(path: string) -> (string, bool) {
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return "", false
	return string(b), true
}

/// writes a file only when its content differs (niri reloads on every write)
write_if_changed :: proc(path, content: string) -> bool {
	if old, ok := read_text(path); ok && old == content do return true
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, content) != nil do return false
	return os.rename(tmp, path) == nil
}

/// puts iris-shell.kdl in the folder, adds its include to config.kdl and
/// hides Waybar, after one backup of config.kdl
setup_niri :: proc(dir: string, dark: bool, hide_bar := true) -> (res: Setup_Result, err: Setup_Error) {
	cfg := strings.concatenate({dir, "/config.kdl"}, context.temp_allocator)
	old, ok := read_text(cfg)
	if !ok do return res, .No_Config
	kdl := theme_kdl(dark, context.temp_allocator)
	if !write_if_changed(strings.concatenate({dir, "/", KDL_NAME}, context.temp_allocator), kdl) do return res, .Io
	text := old
	if !config_has_include(text) {
		text = config_add_include(text, context.temp_allocator)
		res.added_include = true
	}
	if hide_bar {
		if t, changed := config_bar(text, true, context.temp_allocator); changed {
			text = t
			res.hid_bar = true
		}
	}
	if text != old {
		backup := strings.concatenate({cfg, BACKUP_SUFFIX}, context.temp_allocator)
		if !os.exists(backup) {
			if os.write_entire_file(backup, old) != nil do return res, .Io
			res.backup = strings.clone(backup)
		}
		if !write_if_changed(cfg, text) do return res, .Io
	}
	return res, .None
}

/// undoes setup_niri: Waybar's line back, the include and the file gone
remove_niri :: proc(dir: string) -> (res: Setup_Result, err: Setup_Error) {
	cfg := strings.concatenate({dir, "/config.kdl"}, context.temp_allocator)
	if old, ok := read_text(cfg); ok {
		text := config_remove_include(old, context.temp_allocator)
		res.added_include = text != old // (here: it was taken out)
		if t, changed := config_bar(text, false, context.temp_allocator); changed {
			text = t
			res.hid_bar = true
		}
		if text != old && !write_if_changed(cfg, text) do return res, .Io
	}
	os.remove(strings.concatenate({dir, "/", KDL_NAME}, context.temp_allocator))
	return res, .None
}

/// the shell follows light and dark: when the theme file is ours, it is
/// rewritten for the new theme (nothing is written when it is the same)
refresh_theme_file :: proc(dir: string, dark: bool) -> bool {
	p := strings.concatenate({dir, "/", KDL_NAME}, context.temp_allocator)
	cur, ok := read_text(p)
	if !ok || !strings.has_prefix(cur, KDL_MARK) do return false
	return write_if_changed(p, theme_kdl(dark, context.temp_allocator))
}
