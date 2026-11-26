// Light or dark, and whether to animate, from the desktop: GNOME's
// color-scheme and enable-animations, read with `gsettings` (a short child
// process, only when the setting may have changed: the dconf database
// changed, watched with inotify), or IRIS_THEME=dark|light.
package shell

import "core:os"
import "core:strings"
import "core:sys/linux"
import "../logic"

Look :: struct {
	dark:    bool,
	animate: bool,
}

/// the value of a GNOME interface setting ("" when gsettings cannot say)
gsettings_get :: proc(key: string) -> string {
	_, out, err_out, err := os.process_exec({command = {"gsettings", "get", logic.GSETTINGS_SCHEMA, key}}, context.temp_allocator)
	_ = err_out
	if err != nil do return ""
	return strings.trim_space(string(out))
}

/// what the desktop wants now. `forced` is a scheme chosen by IRIS_THEME or
/// by `iris-shell --dark|--light` (auto: the desktop decides)
look_read :: proc(forced: logic.Scheme) -> Look {
	l := Look{dark = true, animate = true} // no word from the desktop: the default black glass
	switch forced {
	case .Dark: l.dark = true
	case .Light: l.dark = false
	case .Auto:
		if s := gsettings_get(logic.GSETTINGS_KEY); len(s) > 0 do l.dark = logic.parse_color_scheme(s)
	}
	if env("IRIS_SHELL_ANIM") == "0" {
		l.animate = false
	} else if s := gsettings_get("enable-animations"); s == "false" {
		l.animate = false
	}
	return l
}

/// an inotify fd that becomes readable when the dconf database changes
/// (-1 when it cannot be watched: the theme is then read once)
theme_watch :: proc() -> linux.Fd {
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE do return -1
	dir := env("XDG_CONFIG_HOME")
	path: string
	if len(dir) > 0 {
		path = strings.concatenate({dir, "/dconf"}, context.temp_allocator)
	} else {
		path = strings.concatenate({env("HOME"), "/.config/dconf"}, context.temp_allocator)
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if _, werr := linux.inotify_add_watch(fd, cpath, {.MOVED_TO, .CLOSE_WRITE, .CREATE}); werr != .NONE {
		linux.close(fd)
		return -1
	}
	return fd
}

/// empties the inotify queue
theme_watch_drain :: proc(fd: linux.Fd) {
	buf: [1024]u8
	for {
		n, err := linux.read(fd, buf[:])
		if err != .NONE || n <= 0 do break
	}
}

/// `iris-shell --dark` / `--light` / `--auto`: the desktop's own setting
/// (like Ember: GTK 4 and libadwaita apps, and browsers through the portal,
/// follow color-scheme), so every app changes with the shell
system_scheme :: proc(s: logic.Scheme) -> bool {
	value := "default"
	switch s {
	case .Dark: value = "prefer-dark"
	case .Light: value = "prefer-light"
	case .Auto: value = "default"
	}
	st, _, _, err := os.process_exec({command = {"gsettings", "set", logic.GSETTINGS_SCHEMA, logic.GSETTINGS_KEY, value}}, context.temp_allocator)
	return err == nil && st.exit_code == 0
}
