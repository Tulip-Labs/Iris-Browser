package term

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private="file") run :: proc(cmd: string, cols := 80, rows := 24, input := "", timeout := 5000) -> (h: ^Headless, status: int) {
	h = new(Headless)
	ok := headless_start(h, {"/bin/sh", "-c", cmd}, pty_env({}), cols, rows)
	if !ok do return h, -1
	status = headless_run(h, timeout, input)
	return
}

@(private="file") fin :: proc(h: ^Headless) {
	headless_destroy(h)
	free(h)
}

@(test)
test_pty_runs_a_command :: proc(tt: ^testing.T) {
	h, st := run("printf 'hi\\n'; exit 3")
	defer fin(h)
	testing.expect_value(tt, st, 3)
	testing.expect_value(tt, screen_text(&h.term), "hi")
	// the child's terminal is a terminal
	h2, st2 := run("test -t 0 && test -t 1 && printf 'tty'; echo $TERM $COLORTERM")
	defer fin(h2)
	testing.expect_value(tt, st2, 0)
	testing.expect_value(tt, screen_text(&h2.term), "ttyxterm-256color truecolor")
}

@(test)
test_pty_size_and_resize :: proc(tt: ^testing.T) {
	h, st := run("stty size", 100, 30)
	defer fin(h)
	testing.expect_value(tt, st, 0)
	testing.expect_value(tt, screen_text(&h.term), "30 100")
}

@(test)
test_pty_sigwinch :: proc(tt: ^testing.T) {
	h := new(Headless)
	defer fin(h)
	ok := headless_start(h, {"/bin/sh", "-c", "trap 'stty size' WINCH; echo ready; while :; do sleep 0.05; done"}, pty_env({}), 80, 24)
	testing.expect(tt, ok)
	start := time.now()
	for time.since(start) < 3 * time.Second && !strings.contains(screen_text(&h.term), "ready") do headless_pump(h, 50)
	term_resize(&h.term, 50, 12)
	pty_resize(&h.pty, 50, 12, 8, 16)
	for time.since(start) < 5 * time.Second && !strings.contains(screen_text(&h.term), "12 50") do headless_pump(h, 50)
	testing.expect(tt, strings.contains(screen_text(&h.term), "12 50"))
}

@(test)
test_pty_colors_and_sequences :: proc(tt: ^testing.T) {
	h, st := run("printf '\\033[31mred\\033[0m \\033[38;2;1;2;3mtc\\033[0m\\n\\033[1;4mbold\\033[0m\\n'")
	defer fin(h)
	testing.expect_value(tt, st, 0)
	t := &h.term
	testing.expect_value(tt, t.grid.rows[0].cells[0].fg, color_idx(1))
	testing.expect_value(tt, t.grid.rows[0].cells[4].fg, color_rgb(1, 2, 3))
	testing.expect(tt, has_attr(t.grid.rows[1].cells[0], .Bold))
	testing.expect_value(tt, cell_underline(t.grid.rows[1].cells[0]), Underline.Single)
}

@(test)
test_pty_answers_queries :: proc(tt: ^testing.T) {
	// the child asks where the cursor is, and gets the answer through the pty
	if !have("/usr/bin/bash") do return
	h := new(Headless)
	defer fin(h)
	ok := headless_start(h, {"/usr/bin/bash", "-c", "printf 'ab\\033[6n'; IFS='[;' read -r -s -d R _x r c; echo; echo \"row=$r col=$c\""}, pty_env({}), 80, 24)
	testing.expect(tt, ok)
	headless_run(h, 5000)
	testing.expect(tt, strings.contains(screen_text(&h.term), "row=1 col=3"), screen_text(&h.term))
}

@(private="file") have :: proc(path: string) -> bool { return os.exists(path) }

@(test)
test_pty_vim :: proc(tt: ^testing.T) {
	if !have("/usr/bin/vim") do return
	h := new(Headless)
	defer fin(h)
	env := pty_env({"VIMRUNTIME=" + "" , "HOME=/tmp"})
	_ = env
	ok := headless_start(h, {"/usr/bin/vim", "-u", "NONE", "-i", "NONE", "-N", "-c", "call setline(1, ['hello vim', 'second line'])", "-c", "redraw"}, pty_env({"HOME=/tmp"}), 60, 12)
	testing.expect(tt, ok)
	start := time.now()
	for time.since(start) < 3 * time.Second && !strings.contains(screen_text(&h.term), "second line") do headless_pump(h, 50)
	testing.expect(tt, h.term.modes.alt_screen)
	text := screen_text(&h.term)
	testing.expect(tt, strings.contains(text, "hello vim\nsecond line\n~"), text)
	// quit: the screen of the shell comes back
	pty_write(&h.pty, transmute([]u8)string(":q!\r"))
	for time.since(start) < 6 * time.Second && h.term.modes.alt_screen do headless_pump(h, 50)
	testing.expect(tt, !h.term.modes.alt_screen)
}

@(test)
test_pty_less_scrolls :: proc(tt: ^testing.T) {
	if !have("/usr/bin/less") do return
	h := new(Headless)
	defer fin(h)
	ok := headless_start(h, {"/bin/sh", "-c", "seq 1 200 | less"}, pty_env({}), 40, 10)
	testing.expect(tt, ok)
	start := time.now()
	for time.since(start) < 3 * time.Second && !strings.contains(screen_text(&h.term), "9\n") do headless_pump(h, 50)
	pty_write(&h.pty, transmute([]u8)string("G"))
	for time.since(start) < 5 * time.Second && !strings.contains(screen_text(&h.term), "200") do headless_pump(h, 50)
	text := screen_text(&h.term)
	testing.expect(tt, strings.contains(text, "200"), text)
	pty_write(&h.pty, transmute([]u8)string("q"))
}

@(test)
test_pty_tmux_draws :: proc(tt: ^testing.T) {
	if !have("/usr/bin/tmux") do return
	h := new(Headless)
	defer fin(h)
	ok := headless_start(h, {"/usr/bin/tmux", "-L", "iris-test", "-f", "/dev/null", "new-session", "echo from-tmux; sleep 1"}, pty_env({"HOME=/tmp"}), 60, 12)
	testing.expect(tt, ok)
	start := time.now()
	for time.since(start) < 4 * time.Second && !strings.contains(screen_text(&h.term), "from-tmux") do headless_pump(h, 50)
	text := screen_text(&h.term)
	testing.expect(tt, strings.contains(text, "from-tmux"), text)
	// tmux's status line is on the last row, with its own colours
	testing.expect(tt, h.term.grid.rows[11].cells[0].bg != COLOR_DEFAULT || strings.contains(text, "[0]"))
	pty_write(&h.pty, transmute([]u8)string("\x02:kill-server\r"))
	for time.since(start) < 6 * time.Second && !h.pty.exited do headless_pump(h, 50)
}

@(test)
test_pty_bash_interactive :: proc(tt: ^testing.T) {
	if !have("/usr/bin/bash") do return
	h := new(Headless)
	defer fin(h)
	ok := headless_start(h, {"/usr/bin/bash", "--norc", "--noprofile", "-i"}, pty_env({"PS1=$ "}), 60, 10)
	testing.expect(tt, ok)
	st := headless_run(h, 5000, "echo $((6*7)) é世\nexit 5\n", 300)
	text := screen_text(&h.term)
	testing.expect(tt, strings.contains(text, "42 é世"), text)
	testing.expect_value(tt, st, 5)
}

@(test)
test_pty_big_output_throughput :: proc(tt: ^testing.T) {
	// 30 MB through a pty and the parser, with the child ended cleanly
	h := new(Headless)
	defer fin(h)
	ok := headless_start(h, {"/bin/sh", "-c", "yes 'the quick brown fox jumps over the lazy dog 0123456789 the quick brown fox' | head -c 30000000"}, pty_env({}), 100, 30, 10000)
	testing.expect(tt, ok)
	start := time.now()
	st := headless_run(h, 30000)
	el := time.duration_seconds(time.since(start))
	testing.expect_value(tt, st, 0)
	testing.expect(tt, h.total >= 29_000_000, "output was cut")
	mbs := f64(h.total) / 1e6 / el
	testing.expectf(tt, mbs > 3, "%.1f MB/s", mbs) // (an unoptimised test build; the release build is checked in CI at 50)
	_ = mbs
}
