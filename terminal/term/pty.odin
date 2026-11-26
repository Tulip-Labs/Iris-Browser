// A child process on a pseudo-terminal, made with the kernel's own calls
// (no libc forkpty, so it also runs where the tests do).
package term

import "core:os"
import "core:strings"
import "core:sys/linux"

Pty :: struct {
	master: linux.Fd,
	pid:    linux.Pid,
	exited: bool,
	status: int, // exit code, or 128 + signal
}

@(private) TIOCSWINSZ :: 0x5414
@(private) TIOCSCTTY :: 0x540e
@(private) TIOCGPTN :: 0x80045430
@(private) TIOCSPTLCK :: 0x40045431

@(private) Winsize :: struct {
	rows, cols, xpixel, ypixel: u16,
}

pty_resize :: proc(p: ^Pty, cols, rows, cell_w, cell_h: int) {
	ws := Winsize{u16(rows), u16(cols), u16(cols * cell_w), u16(rows * cell_h)}
	linux.ioctl(p.master, TIOCSWINSZ, uintptr(&ws))
}

/// the environment of the child: ours, with the terminal's own variables
pty_env :: proc(extra: []string, allocator := context.temp_allocator) -> []string {
	env, _ := os.environ(allocator)
	out := make([dynamic]string, allocator)
	drop :: [?]string{"TERM=", "COLORTERM=", "TERM_PROGRAM=", "TERM_PROGRAM_VERSION=", "TERMCAP=", "LINES=", "COLUMNS=", "IRIS_TERMINAL=", "IRIS_TERMINAL_NERD=", "NO_COLOR="}
	for e in env {
		skip := false
		for d in drop do if strings.has_prefix(e, d) do skip = true
		if !skip do append(&out, e)
	}
	append(&out, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=iris-terminal", "TERM_PROGRAM_VERSION=1.0.0", "IRIS_TERMINAL=1.0.0")
	append(&out, ..extra)
	// the characters are UTF-8, whatever the session's locale says
	has_utf8 := false
	lang_set := false
	for e in out {
		if strings.has_prefix(e, "LC_ALL=") || strings.has_prefix(e, "LC_CTYPE=") || strings.has_prefix(e, "LANG=") {
			lang_set = true
			if strings.contains(strings.to_upper(e, context.temp_allocator), "UTF-8") || strings.contains(strings.to_upper(e, context.temp_allocator), "UTF8") do has_utf8 = true
		}
	}
	if !has_utf8 do append(&out, "LC_CTYPE=C.UTF-8")
	_ = lang_set
	return out[:]
}

/// starts argv[0] (found in PATH when it has no slash) on a new pty
pty_spawn :: proc(argv: []string, env: []string, cols, rows: int, cwd := "") -> (p: Pty, ok: bool) {
	if len(argv) == 0 do return
	master, err := linux.open("/dev/ptmx", {.RDWR, .NOCTTY, .CLOEXEC})
	if err != .NONE do return
	zero: i32 = 0
	linux.ioctl(master, TIOCSPTLCK, uintptr(&zero))
	n: u32
	if linux.ioctl(master, TIOCGPTN, uintptr(&n)) != 0 {
		linux.close(master)
		return
	}
	slave_name := strings.clone_to_cstring(join_num("/dev/pts/", int(n)), context.temp_allocator)
	pty := Pty{master = master}
	pty_resize(&pty, cols, rows, 0, 0)

	// everything the child needs is made before the fork
	args := make([dynamic]cstring, context.temp_allocator)
	path := argv[0]
	if !strings.contains_rune(path, '/') {
		append(&args, "env")
		path = "/usr/bin/env"
	}
	for a in argv do append(&args, strings.clone_to_cstring(a, context.temp_allocator))
	append(&args, nil)
	envp := make([dynamic]cstring, context.temp_allocator)
	for e in env do append(&envp, strings.clone_to_cstring(e, context.temp_allocator))
	append(&envp, nil)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	ccwd := cwd == "" ? cstring(nil) : strings.clone_to_cstring(cwd, context.temp_allocator)

	pid, ferr := linux.fork()
	if ferr != .NONE {
		linux.close(master)
		return
	}
	if pid == 0 {
		// the child: a session of its own, the pty as its terminal
		linux.setsid()
		slave, serr := linux.open(slave_name, {.RDWR})
		if serr != .NONE do linux.exit(126)
		linux.ioctl(slave, TIOCSCTTY, 0)
		linux.dup2(slave, 0)
		linux.dup2(slave, 1)
		linux.dup2(slave, 2)
		if slave > 2 do linux.close(slave)
		linux.close(master)
		if ccwd != nil do linux.chdir(ccwd)
		// signals as a program expects them
		set: linux.Sig_Set
		linux.rt_sigprocmask(.SIG_SETMASK, &set, nil)
		linux.execve(cpath, raw_data(args[:]), raw_data(envp[:]))
		linux.exit(127)
	}
	pty.pid = pid
	// the master is read without blocking
	if fl, e := linux.fcntl_getfl(master, .GETFL); e == .NONE do linux.fcntl_setfl(master, .SETFL, fl + {.NONBLOCK})
	return pty, true
}

@(private) join_num :: proc(prefix: string, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, prefix)
	strings.write_int(&b, n)
	return strings.to_string(b)
}

Read_Result :: enum { Data, Empty, Closed }

/// what the child wrote (up to the size of buf)
pty_read :: proc(p: ^Pty, buf: []u8) -> (n: int, res: Read_Result) {
	k, err := linux.read(p.master, buf)
	switch {
	case err == .NONE && k > 0: return k, .Data
	case err == .EAGAIN || err == .EINTR: return 0, .Empty
	}
	return 0, .Closed
}

/// writes all of it (waiting when the child is slow to read)
pty_write :: proc(p: ^Pty, data: []u8) {
	b := data
	spins := 0
	for len(b) > 0 {
		n, err := linux.write(p.master, b)
		switch {
		case err == .NONE && n > 0:
			b = b[n:]
			spins = 0
		case err == .EAGAIN:
			// full: wait for room (the child may be waiting for us to read: give up after a while)
			pfd := [1]linux.Poll_Fd{{fd = p.master, events = {.OUT}}}
			linux.poll(pfd[:], 20)
			spins += 1
			if spins > 500 do return
		case err == .EINTR:
		case:
			return
		}
	}
}

/// has the child ended? (sets exited and status)
pty_reap :: proc(p: ^Pty) -> bool {
	if p.exited do return true
	st: u32
	pid, err := linux.wait4(p.pid, &st, {.WNOHANG}, nil)
	if err == .NONE && pid == p.pid {
		p.exited = true
		if st & 0x7f == 0 { p.status = int((st >> 8) & 0xff) } else { p.status = 128 + int(st & 0x7f) }
	} else if err == .ECHILD {
		p.exited = true
	}
	return p.exited
}

pty_close :: proc(p: ^Pty) {
	if p.master >= 0 do linux.close(p.master)
	p.master = -1
	if !p.exited {
		linux.kill(p.pid, .SIGHUP)
		pty_reap(p)
	}
}
