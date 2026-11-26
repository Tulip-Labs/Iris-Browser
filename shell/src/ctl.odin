// One shell at a time. The running shell listens on a unix socket in
// $XDG_RUNTIME_DIR; a new one asks it to quit (and waits until it has) before
// it takes over, so starting it again restarts it cleanly. The same socket
// carries `iris-shell --dark` and the like to the running shell.
package shell

import "core:fmt"
import "core:strings"
import "core:sys/linux"

ctl_path :: proc() -> string {
	if d := env("XDG_RUNTIME_DIR"); len(d) > 0 do return fmt.tprintf("%s/iris-shell.sock", d)
	return fmt.tprintf("/tmp/iris-shell-%d.sock", linux.getuid())
}

/// sends one command to the running shell; its one-line answer
ctl_send :: proc(cmd: string, wait_ms: i32 = 1500) -> (reply: string, ok: bool) {
	fd, c := connect_unix(ctl_path())
	if !c do return "", false
	defer linux.close(fd)
	line := fmt.tprintf("%s\n", cmd)
	if _, err := linux.write(fd, transmute([]u8)line); err != .NONE do return "", false
	buf: [512]u8
	n := 0
	for n < len(buf) && wait_readable(fd, wait_ms) {
		r, err := linux.read(fd, buf[n:])
		if err != .NONE || r <= 0 do break
		n += r
	}
	return strings.clone(string(buf[:n]), context.temp_allocator), true
}

/// is a shell running? Asks it to quit, waits for it to be gone.
ctl_take_over :: proc() {
	fd, ok := connect_unix(ctl_path())
	if !ok do return
	defer linux.close(fd)
	line := "quit\n"
	linux.write(fd, transmute([]u8)line)
	// it closes the connection when it has cleaned up
	buf: [64]u8
	for i := 0; i < 20 && wait_readable(fd, 200); i += 1 {
		r, err := linux.read(fd, buf[:])
		if err != .NONE || r <= 0 do break
	}
}

/// one connection of the control socket: the command, and the answer
ctl_serve :: proc(listen_fd: linux.Fd, handle: proc(cmd: string) -> (reply: string, quit: bool)) -> (quit: bool) {
	addr: linux.Sock_Addr_Un
	cfd, err := linux.accept(listen_fd, &addr, {.CLOEXEC})
	if err != .NONE do return false
	defer linux.close(cfd)
	buf: [256]u8
	n := 0
	for n < len(buf) && wait_readable(cfd, 200) {
		r, rerr := linux.read(cfd, buf[n:])
		if rerr != .NONE || r <= 0 do break
		n += r
		if buf[n - 1] == '\n' do break
	}
	cmd := string(buf[:n])
	for len(cmd) > 0 && (cmd[len(cmd) - 1] == '\n' || cmd[len(cmd) - 1] == ' ') do cmd = cmd[:len(cmd) - 1]
	reply, q := handle(cmd)
	out := fmt.tprintf("%s\n", reply)
	linux.write(cfd, transmute([]u8)out)
	return q
}
