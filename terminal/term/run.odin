// A terminal with no window: runs a command on a pty, feeds what it writes
// to the emulator, and answers its questions. This is what the test mode
// (--exec, --dump-screen) and the tests use, and what the window's loop
// does too, minus the drawing.
package term

import "core:sys/linux"
import "core:time"

Headless :: struct {
	term:  Term,
	pty:   Pty,
	/// bytes read from the child
	total: int,
	/// keep what the child wrote (for --dump-raw)
	capture: bool,
	raw:     [dynamic]u8,
}

/// the child's exit code and the terminal as it ended
headless_start :: proc(h: ^Headless, argv: []string, env: []string, cols, rows: int, scrollback := 1000) -> bool {
	term_init(&h.term, cols, rows, scrollback)
	h.term.cell_px = {8, 16}
	pty, ok := pty_spawn(argv, env, cols, rows)
	if !ok do return false
	h.pty = pty
	pty_resize(&h.pty, cols, rows, 8, 16)
	return true
}

headless_destroy :: proc(h: ^Headless) {
	pty_close(&h.pty)
	delete(h.raw)
	term_destroy(&h.term)
}

/// one round: wait up to `ms` for the child's output, feed it, send the
/// replies. false when the child is gone and its output read.
headless_pump :: proc(h: ^Headless, ms: i32) -> bool {
	pfd := [1]linux.Poll_Fd{{fd = h.pty.master, events = {.IN}}}
	linux.poll(pfd[:], ms)
	buf: [65536]u8
	closed := false
	for {
		n, res := pty_read(&h.pty, buf[:])
		if res == .Data {
			h.total += n
			if h.capture do append(&h.raw, ..buf[:n])
			term_feed(&h.term, buf[:n])
			if len(h.term.out) > 0 {
				pty_write(&h.pty, h.term.out[:])
				clear(&h.term.out)
			}
			continue
		}
		closed = res == .Closed
		break
	}
	if closed {
		pty_reap(&h.pty)
		return false
	}
	return true
}

/// runs until the child ends or `timeout_ms` passes; `input` is typed after
/// `input_after_ms`
headless_run :: proc(h: ^Headless, timeout_ms: int, input := "", input_after_ms := 300) -> int {
	start := time.now()
	sent := len(input) == 0
	for {
		if !headless_pump(h, 20) do break
		el := int(time.duration_milliseconds(time.since(start)))
		if !sent && el >= input_after_ms {
			pty_write(&h.pty, transmute([]u8)input)
			sent = true
		}
		if el > timeout_ms do break
	}
	// a last look at what is left
	headless_pump(h, 0)
	if !h.pty.exited {
		linux.kill(h.pty.pid, .SIGKILL)
		time.sleep(10 * time.Millisecond)
		pty_reap(&h.pty)
	}
	return h.pty.status
}
