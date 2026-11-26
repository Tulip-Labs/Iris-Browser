// The few system calls the shell makes besides Wayland: unix sockets (niri's
// IPC, the control socket of the running shell), a monotonic clock, shared
// memory for capture.
package shell

import "core:os"
import "core:strings"
import "core:sys/linux"

unix_addr :: proc(path: string) -> (a: linux.Sock_Addr_Un, ok: bool) {
	if len(path) == 0 || len(path) >= len(a.sun_path) do return {}, false
	a.sun_family = .UNIX
	copy(a.sun_path[:], path)
	return a, true
}

/// a connected, non-blocking stream socket to a unix socket path
connect_unix :: proc(path: string) -> (linux.Fd, bool) {
	addr, ok := unix_addr(path)
	if !ok do return -1, false
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .UNSPECIFIED)
	if err != .NONE do return -1, false
	if linux.connect(fd, &addr) != .NONE {
		linux.close(fd)
		return -1, false
	}
	return fd, true
}

set_nonblock :: proc(fd: linux.Fd) {
	fl, err := linux.fcntl_getfl(fd, .GETFL)
	if err == .NONE do linux.fcntl_setfl(fd, .SETFL, fl + {.NONBLOCK})
}

/// a listening unix socket (a stale file of a dead shell is replaced)
listen_unix :: proc(path: string) -> (linux.Fd, bool) {
	addr, ok := unix_addr(path)
	if !ok do return -1, false
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .UNSPECIFIED)
	if err != .NONE do return -1, false
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	linux.unlink(cpath)
	if linux.bind(fd, &addr) != .NONE || linux.listen(fd, 4) != .NONE {
		linux.close(fd)
		return -1, false
	}
	return fd, true
}

now_ms :: proc() -> i64 {
	ts, err := linux.clock_gettime(.MONOTONIC)
	if err != .NONE do return 0
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec / 1_000_000)
}

/// waits up to `ms` for the fd to be readable
wait_readable :: proc(fd: linux.Fd, ms: i32) -> bool {
	p := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
	n, _ := linux.poll(p[:], ms)
	return n > 0
}

env :: proc(name: string) -> string {
	return os.get_env(name, context.temp_allocator)
}
