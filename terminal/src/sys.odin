// The few system calls around the window: a clock, folders, inotify, the
// child processes the terminal starts (a new window, xdg-open), gsettings.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

debug_on: bool

logf :: proc(format: string, args: ..any) {
	if debug_on do fmt.eprintfln(format, ..args)
}

env :: proc(name: string) -> string {
	return os.get_env(name, context.temp_allocator)
}

now_ms :: proc() -> i64 {
	ts, err := linux.clock_gettime(.MONOTONIC)
	if err != .NONE do return 0
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec / 1_000_000)
}

home_dir :: proc() -> string {
	if h := env("HOME"); len(h) > 0 do return h
	return "/"
}

/// ~/.config/iris-terminal
config_dir :: proc() -> string {
	base := env("XDG_CONFIG_HOME")
	if len(base) == 0 do base = strings.concatenate({home_dir(), "/.config"}, context.temp_allocator)
	return strings.concatenate({base, "/iris-terminal"}, context.temp_allocator)
}

state_dir :: proc() -> string {
	base := env("XDG_STATE_HOME")
	if len(base) == 0 do base = strings.concatenate({home_dir(), "/.local/state"}, context.temp_allocator)
	return strings.concatenate({base, "/iris-terminal"}, context.temp_allocator)
}

fonts_dir :: proc() -> string {
	base := env("XDG_DATA_HOME")
	if len(base) == 0 do base = strings.concatenate({home_dir(), "/.local/share"}, context.temp_allocator)
	return strings.concatenate({base, "/fonts"}, context.temp_allocator)
}

ignore_sigpipe :: proc() {
	act: linux.Sig_Action
	act.special = .SIG_IGN
	linux.rt_sigaction(.SIGPIPE, &act, nil)
}

/// starts a program that carries on without us (double fork: no zombie, no
/// terminal); false when it could not be started
spawn_detached :: proc(argv: []string, cwd := "") -> bool {
	args := make([dynamic]cstring, context.temp_allocator)
	path := argv[0]
	if !strings.contains_rune(path, '/') {
		append(&args, "env")
		path = "/usr/bin/env"
	}
	for a in argv do append(&args, strings.clone_to_cstring(a, context.temp_allocator))
	append(&args, nil)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	ccwd := cwd == "" ? cstring(nil) : strings.clone_to_cstring(cwd, context.temp_allocator)
	envs, _ := os.environ(context.temp_allocator)
	envp := make([dynamic]cstring, context.temp_allocator)
	for e in envs do append(&envp, strings.clone_to_cstring(e, context.temp_allocator))
	append(&envp, nil)
	pid, err := linux.fork()
	if err != .NONE do return false
	if pid == 0 {
		pid2, err2 := linux.fork()
		if err2 != .NONE || pid2 != 0 do linux.exit(0)
		linux.setsid()
		if null, e := linux.open("/dev/null", {.RDWR}); e == .NONE {
			linux.dup2(null, 0)
			linux.dup2(null, 1)
			linux.dup2(null, 2)
		}
		if ccwd != nil do linux.chdir(ccwd)
		linux.execve(cpath, raw_data(args[:]), raw_data(envp[:]))
		linux.exit(127)
	}
	st: u32
	linux.wait4(pid, &st, {}, nil)
	return true
}

/// runs a short program and reads what it prints (gsettings, niri --version)
run_capture :: proc(argv: []string) -> (out: string, ok: bool) {
	st, so, _, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil || st.exit_code != 0 do return "", false
	return strings.trim_space(string(so)), true
}

/// the desktop's colour scheme: true when it wants dark (and no word: dark, the house default)
desktop_dark :: proc() -> bool {
	switch env("IRIS_THEME") {
	case "dark": return true
	case "light": return false
	}
	if s, ok := run_capture({"gsettings", "get", "org.gnome.desktop.interface", "color-scheme"}); ok {
		if strings.contains(s, "prefer-light") do return false
	}
	return true
}

/// an inotify fd watching a folder for files that were written or moved in
watch_dir :: proc(fd: linux.Fd, path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	_, err := linux.inotify_add_watch(fd, cpath, {.MOVED_TO, .CLOSE_WRITE, .CREATE})
	return err == .NONE
}

/// reads the pending inotify events: the names of what changed
drain_inotify :: proc(fd: linux.Fd) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	buf: [4096]u8
	for {
		n, err := linux.read(fd, buf[:])
		if err != .NONE || n <= 0 do break
		i := 0
		for i + size_of(linux.Inotify_Event) <= n {
			ev := (^linux.Inotify_Event)(&buf[i])
			if ev.len > 0 {
				name := cstring(&buf[i + size_of(linux.Inotify_Event)])
				append(&names, strings.clone(string(name), context.temp_allocator))
			}
			i += size_of(linux.Inotify_Event) + int(ev.len)
		}
	}
	return names[:]
}

read_file :: proc(path: string) -> (string, bool) {
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return "", false
	return string(b), true
}
