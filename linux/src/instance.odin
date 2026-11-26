package iris

// One Iris per app ID. A second launch (a link opened from another app,
// `iris URL` in a terminal, the launcher clicked again) hands its addresses
// to the Iris already running, which opens them as tabs, and exits. Without
// this the CEF build failed outright: Chromium allows one browser process per
// profile, forwarded the launch to it and made cef_initialize return false
// ("Opening in existing browser session" ... "could not start its page
// engine").
//
// The socket lives in $XDG_RUNTIME_DIR/app/<APP_ID>/, which Flatpak shares
// between instances of the same app (and nothing else), or in
// $XDG_RUNTIME_DIR itself outside Flatpak.

import "core:os"
import "core:strings"
import "core:sys/linux"

@(private="file") instance_fd: linux.Fd = -1
@(private="file") instance_path: string

@(private="file") socket_path :: proc() -> string {
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if len(run) == 0 do return ""
	app := strings.join({run, "/app/", APP_ID}, "", context.temp_allocator)
	if os.is_dir(app) do return strings.join({app, "/iris.sock"}, "")
	return strings.join({run, "/", APP_ID, ".sock"}, "")
}

@(private="file") address :: proc(path: string) -> (a: linux.Sock_Addr_Un, ok: bool) {
	if len(path) == 0 || len(path) >= len(a.sun_path) do return
	a.sun_family = .UNIX
	copy(a.sun_path[:], path)
	return a, true
}

/// the message: the working directory, then each argument, one per line
instance_message :: proc(cwd: string, args: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, cwd)
	for a in args {
		if strings.has_prefix(a, "-") do continue
		if strings.contains_any(a, "\n\r") do continue
		strings.write_byte(&b, '\n')
		strings.write_string(&b, a)
	}
	return strings.to_string(b)
}

/// cwd and the addresses out of a message
instance_parse :: proc(msg: string, allocator := context.temp_allocator) -> (cwd: string, args: []string) {
	lines := strings.split(msg, "\n", allocator)
	if len(lines) == 0 do return
	return lines[0], lines[1:]
}

/// true when another Iris took the addresses: this one should exit
instance_forward :: proc(cwd: string, args: []string) -> bool {
	path := socket_path()
	addr, ok := address(path)
	if !ok do return false
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .UNSPECIFIED)
	if err != nil do return false
	defer linux.close(fd)
	if linux.connect(fd, &addr) != nil do return false
	msg := transmute([]u8)instance_message(cwd, args)
	for len(msg) > 0 {
		n, werr := linux.write(fd, msg)
		if werr != nil || n <= 0 do return false
		msg = msg[n:]
	}
	return true
}

/// listen for later launches (call once the browser is up)
instance_listen :: proc() {
	instance_path = socket_path()
	addr, ok := address(instance_path)
	if !ok do return
	cpath := strings.clone_to_cstring(instance_path, context.temp_allocator)
	linux.unlink(cpath) // a stale socket from an Iris that crashed: forward found nobody on it
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .UNSPECIFIED)
	if err != nil do return
	if linux.bind(fd, &addr) != nil || linux.listen(fd, 8) != nil {
		linux.close(fd)
		return
	}
	instance_fd = fd
	g_unix_fd_add_full(G_PRIORITY_DEFAULT, i32(fd), G_IO_IN, proc "c" (fd: i32, cond: u32, data: rawptr) -> gboolean {
		context = main_context
		for {
			peer: linux.Sock_Addr_Un
			c, err := linux.accept(linux.Fd(fd), &peer, {.CLOEXEC})
			if err != nil do break
			instance_take(c)
			linux.close(c)
		}
		return 1
	}, nil, nil)
}

@(private="file") instance_take :: proc(c: linux.Fd) {
	b := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for strings.builder_len(b) < 1 << 16 {
		n, err := linux.read(c, buf[:])
		if err != nil || n <= 0 do break
		strings.write_bytes(&b, buf[:n])
	}
	cwd, args := instance_parse(strings.to_string(b))
	opened := false
	for a in args {
		u := resolve_arg(a, cwd, context.temp_allocator)
		if len(u) == 0 do continue
		browser_new_tab({url = u, select = true})
		opened = true
	}
	// launched again with nothing to open (the launcher clicked twice): a new tab
	if !opened do browser_new_tab({select = true})
}

/// at exit: the socket goes, so the next launch starts fresh
instance_close :: proc() {
	if instance_fd < 0 do return
	linux.close(instance_fd)
	instance_fd = -1
	linux.unlink(strings.clone_to_cstring(instance_path, context.temp_allocator))
}

import "core:testing"

@(test)
test_instance_message :: proc(t: ^testing.T) {
	m := instance_message("/home/a", {"--x", "example.com", "bad\nline", "./b.html"})
	testing.expect_value(t, m, "/home/a\nexample.com\n./b.html")
	cwd, args := instance_parse(m)
	testing.expect_value(t, cwd, "/home/a")
	testing.expect_value(t, len(args), 2)
	testing.expect_value(t, args[1], "./b.html")
	cwd2, args2 := instance_parse("/only")
	testing.expect_value(t, cwd2, "/only")
	testing.expect_value(t, len(args2), 0)
}
