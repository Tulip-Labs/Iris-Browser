// The terminal window: what the keyboard, the pointer, the child and the
// files do to the emulator, and the one loop that waits for all of them.
// Nothing here runs on a timer: the loop sleeps in poll until something
// happens, and the glass animations (the fade-in, the bell) ask for frames
// only while they last.
package main

import "core:math"
import "core:os"
import "core:strings"
import "core:sys/linux"
import plat "../plat"
import term "../term"

Options :: struct {
	container:   string,
	cwd:         string,
	exec_cmd:    string,
	dump_screen: string,
	dump_state:  string,
	dump_frame:  string,
	dump_raw:    string,
	input:       string, // typed into the program (without a window)
	input_after: int,
	no_window:   bool,
	stats:       bool,
	cols, rows:  int,
	timeout_ms:  int,
	shell:       string,
	argv:        []string, // -e PROGRAM ARGS...
}

App :: struct {
	win:        plat.Window,
	t:          term.Term,
	pty:        term.Pty,
	cfg:        term.Config,
	opt:        Options,
	theme:      term.Theme,
	dark:       bool,
	compose:    Compose,
	has_blur:   bool,
	nerd:       bool,
	container:  string,
	// layout, in device pixels
	pad, ox, oy, chrome_h: int,
	font_pt:    f32,
	font_px:    f32,
	atlas_stale: bool,
	focused:    bool,
	// the pointer
	px, py:     f64,
	col, row:   int,
	buttons:    u8,
	last_report: [2]int,
	selecting:  bool,
	sel:        term.Selection,
	scroll_acc: f64,
	hover_ok:   bool,
	hover:      [4]int, // line0, col0, line1, col1 of the link under the pointer
	ctrl_down:  bool,
	// the search
	searching:  bool,
	query:      [dynamic]u8,
	matches:    []term.Match,
	cur_match:  int,
	// time
	start_ms, bell_ms, sync_deadline: i64,
	// the child
	spawned:    bool,
	offer:      bool, // asking whether to set zsh up
	exited:     bool,
	finishing:  bool,
	finish_ms:  i64,
	frame_dumped: bool,
	quit:       bool,
	status:     int,
	ino:        linux.Fd,
	bytes_in:   u64,
	first_byte_ms, last_byte_ms: i64,
	last_gen:   u64,
	// a flood of output (cat of a big file): the picture waits, it would only slow the reading
	flood:      bool,
	hold_until: i64,
	draw_pending: bool,
	title_set:  string,
	read_buf:   []u8,
}

app: App

tmods :: proc(m: plat.Mods) -> term.Mods {
	r: term.Mods
	if .Shift in m do r += {.Shift}
	if .Ctrl in m do r += {.Ctrl}
	if .Alt in m do r += {.Alt}
	if .Logo in m do r += {.Logo}
	return r
}

// ---------------------------------------------------------------- configuration

app_load_config :: proc(a: ^App) {
	term.config_free(&a.cfg)
	a.cfg = term.config_default()
	path := strings.concatenate({config_dir(), "/config"}, context.temp_allocator)
	if text, ok := read_file(path); ok do term.config_parse(&a.cfg, text)
	if a.opt.cols > 0 do a.cfg.columns = a.opt.cols
	if a.opt.rows > 0 do a.cfg.rows = a.opt.rows
	a.cfg.font_size = clamp(a.cfg.font_size, 6, 48)
}

/// the colours for the config and the desktop's scheme
app_apply_theme :: proc(a: ^App) {
	a.dark = desktop_dark()
	a.theme = term.theme_by_name(a.cfg.theme, a.dark)
	term.term_apply_theme(&a.t, a.theme)
	a.t.gen += 1
}

/// is there a blur behind the glass? (the compositor's protocol, or niri's rule that --setup-niri wrote)
app_detect_blur :: proc(a: ^App) {
	a.has_blur = false
	if !a.cfg.blur do return
	if a.win.blur != nil {
		a.has_blur = true
		return
	}
	path := strings.concatenate({term.niri_config_dir(context.temp_allocator), "/", term.NIRI_KDL_NAME}, context.temp_allocator)
	if text, ok := read_file(path); ok && strings.contains(text, "blur true") do a.has_blur = true
}

app_font :: proc(a: ^App) {
	fonts_init(term.font_families(&a.cfg), a.cfg.ligatures)
	// the Nerd Font symbols: from a font that is not the built in one
	a.nerd = false
	if fi := font_for_rune(0xe0b0); fi >= 0 && fi < len(fonts.fams) && !fonts.fams[fi].lazy && fonts.fams[fi].path != "builtin" {
		if fj := font_for_rune(0xf07c); fj >= 0 && !fonts.fams[fj].lazy && fonts.fams[fj].path != "builtin" do a.nerd = true
	}
	a.font_px = 0
	app_set_font_px(a)
}

/// the font at the size and scale; true when it changed
app_set_font_px :: proc(a: ^App) -> bool {
	px := math.round(a.font_pt * 96 / 72 * f32(a.win.scale > 0 ? a.win.scale : 1) * 4) / 4
	if px == a.font_px do return false
	a.font_px = px
	fonts_set_size(px)
	a.atlas_stale = true
	return true
}

/// the grid from the window's size, and the blur region
app_layout :: proc(a: ^App) {
	w := &a.win
	s := w.scale > 0 ? w.scale : 1
	a.pad = int(math.round(f64(a.cfg.padding) * s))
	a.chrome_h = 0
	if a.container != "" do a.chrome_h = fonts.cell_h + a.pad / 2
	a.ox, a.oy = a.pad, a.pad + a.chrome_h
	cols := max((int(w.pixel_w) - 2 * a.pad) / fonts.cell_w, 2)
	rows := max((int(w.pixel_h) - a.oy - a.pad) / fonts.cell_h, 1)
	a.t.cell_px = {fonts.cell_w, fonts.cell_h}
	if cols != a.t.cols || rows != a.t.rows {
		term.term_resize(&a.t, cols, rows)
		a.sel = {}
		a.selecting = false
		a.matches = nil
		if a.spawned && !a.exited do term.pty_resize(&a.pty, cols, rows, fonts.cell_w, fonts.cell_h)
		a.t.view = min(a.t.view, a.t.sb.count)
	}
	app_blur_region(a)
}

/// the blur follows the rounded corners: strips, one row of pixels at the corners
app_blur_region :: proc(a: ^App) {
	w := &a.win
	if w.blur == nil do return
	if !a.cfg.blur {
		plat.set_blur(w, nil)
		return
	}
	r := a.cfg.radius
	if w.maximized || w.fullscreen || w.tiled do r = 0
	rects := make([dynamic][4]i32, context.temp_allocator)
	W, H := w.width, w.height
	if r <= 0 {
		append(&rects, [4]i32{0, 0, W, H})
	} else {
		rr := f32(r)
		for i in 0 ..< r {
			dy := rr - f32(i) - 0.5
			inset := i32(math.ceil(rr - math.sqrt(max(rr * rr - dy * dy, 0))))
			append(&rects, [4]i32{inset, i32(i), W - 2 * inset, 1})
			append(&rects, [4]i32{inset, H - 1 - i32(i), W - 2 * inset, 1})
		}
		append(&rects, [4]i32{0, i32(r), W, H - 2 * i32(r)})
	}
	plat.set_blur(w, rects[:])
}

app_title :: proc(a: ^App) {
	title := a.t.title
	if title == "" do title = "Iris Terminal"
	if a.container != "" do title = strings.concatenate({title, " (", a.container, ")"}, context.temp_allocator)
	if title == a.title_set do return
	delete(a.title_set)
	a.title_set = strings.clone(title)
	plat.set_title(&a.win, title)
}

// ---------------------------------------------------------------- the child

find_shell :: proc(cfg_shell: string) -> string {
	if cfg_shell != "" do return cfg_shell
	if s := env("SHELL"); s != "" && os.exists(s) do return s
	for p in ([?]string{"/usr/bin/zsh", "/bin/zsh", "/usr/local/bin/zsh", "/usr/bin/bash", "/bin/bash", "/bin/sh"}) {
		if os.exists(p) do return p
	}
	return "/bin/sh"
}

app_spawn :: proc(a: ^App) {
	argv := make([dynamic]string, context.temp_allocator)
	extra := make([dynamic]string, context.temp_allocator)
	nerd := a.nerd ? "1" : "0"
	append(&extra, strings.concatenate({"IRIS_TERMINAL_NERD=", nerd}, context.temp_allocator))
	switch {
	case len(a.opt.argv) > 0:
		append(&argv, ..a.opt.argv)
	case a.opt.exec_cmd != "":
		append(&argv, "/bin/sh", "-c", a.opt.exec_cmd)
	case a.container != "":
		append(&argv, "distrobox", "enter", a.container, "--", "env", "IRIS_TERMINAL=1")
		append(&argv, strings.concatenate({"IRIS_TERMINAL_NERD=", nerd}, context.temp_allocator))
		append(&argv, "COLORTERM=truecolor", "TERM=xterm-256color", "sh", "-c", "exec ${SHELL:-sh} -l")
	case:
		append(&argv, find_shell(a.opt.shell != "" ? a.opt.shell : a.cfg.shell))
	}
	// the state the zsh prompt reads: does the font have the symbols?
	os.make_directory_all(state_dir())
	_ = os.write_entire_file(strings.concatenate({state_dir(), "/nerd"}, context.temp_allocator), transmute([]u8)string(nerd))
	p, ok := term.pty_spawn(argv[:], term.pty_env(extra[:]), a.t.cols, a.t.rows, a.opt.cwd)
	if !ok {
		term.term_feed(&a.t, transmute([]u8)string("\x1b[31mcould not start the shell\x1b[0m\r\n"))
		a.exited, a.status = true, 127
		return
	}
	a.pty = p
	a.spawned = true
	term.pty_resize(&a.pty, a.t.cols, a.t.rows, fonts.cell_w, fonts.cell_h)
}

/// the first time zsh is the shell: offer the refined setup (once)
app_needs_offer :: proc(a: ^App) -> bool {
	if a.opt.exec_cmd != "" || len(a.opt.argv) > 0 || a.container != "" do return false
	sh := find_shell(a.opt.shell != "" ? a.opt.shell : a.cfg.shell)
	if !strings.has_suffix(sh, "zsh") do return false
	if os.exists(strings.concatenate({state_dir(), "/zsh-offered"}, context.temp_allocator)) do return false
	if os.exists(strings.concatenate({config_dir(), "/zsh/init.zsh"}, context.temp_allocator)) do return false
	return true
}

app_offer_text :: proc(a: ^App) {
	msg := "\x1b[1mIris Terminal\x1b[0m\r\n\r\n" +
		"It can set up zsh for you: history, a completion menu, suggestions and\r\n" +
		"highlighting (when their plugins are installed) and a fast prompt with\r\n" +
		"the git branch, the exit status and the container.\r\n\r\n" +
		"Your ~/.zshrc gets one block (a backup is kept); `iris-terminal --remove-zsh`\r\n" +
		"takes it out again.\r\n\r\n" +
		"Set it up now? [y/N] "
	term.term_feed(&a.t, transmute([]u8)msg)
}

app_answer_offer :: proc(a: ^App, yes: bool) {
	a.offer = false
	os.make_directory_all(state_dir())
	_ = os.write_entire_file(strings.concatenate({state_dir(), "/zsh-offered"}, context.temp_allocator), transmute([]u8)string("1\n"))
	if yes {
		if _, ok := term.zsh_setup(home_dir(), config_dir()); ok {
			term.term_feed(&a.t, transmute([]u8)string("y\r\n\r\nzsh is set up.\r\n"))
		} else {
			term.term_feed(&a.t, transmute([]u8)string("y\r\n\r\nCould not write the files.\r\n"))
		}
	} else {
		term.term_feed(&a.t, transmute([]u8)string("n\r\n\r\nAsk again with `iris-terminal --setup-zsh`.\r\n"))
	}
	term.term_feed(&a.t, transmute([]u8)string("\x1b[2J\x1b[H"))
	app_spawn(a)
	plat.invalidate(&a.win)
}

// ---------------------------------------------------------------- the child's output

send :: proc(a: ^App, data: []u8) {
	if a.spawned && !a.exited && len(data) > 0 do term.pty_write(&a.pty, data)
}

/// reads what the child wrote (up to a budget, so the window stays lively)
app_read_pty :: proc(a: ^App) {
	if !a.spawned || a.exited do return
	budget := 4 << 20
	changed := false
	start_budget := budget
	for budget > 0 {
		n, res := term.pty_read(&a.pty, a.read_buf)
		if res == .Data {
			now := now_ms()
			if a.bytes_in == 0 do a.first_byte_ms = now
			a.last_byte_ms = now
			a.bytes_in += u64(n)
			budget -= n
			term.term_feed(&a.t, a.read_buf[:n])
			changed = true
			if len(a.t.out) > 0 {
				term.pty_write(&a.pty, a.t.out[:])
				clear(&a.t.out)
			}
			continue
		}
		if res == .Closed do app_child_gone(a)
		break
	}
	// 128 KB in one go: a flood
	a.flood = start_budget - budget >= 128 * 1024
	if a.flood do a.hold_until = now_ms() + 100
	if changed do app_after_feed(a)
}

app_after_feed :: proc(a: ^App) {
	t := &a.t
	if t.events != {} {
		ev := t.events
		t.events = {}
		if .Title in ev do app_title(a)
		if .Bell in ev && a.cfg.bell {
			a.bell_ms = now_ms()
			t.gen += 1
		}
		if .Clipboard in ev {
			if a.cfg.osc52 && len(t.clip_write) > 0 {
				text := string(t.clip_write[:])
				if t.clip_target == 'p' { clip_primary(text) } else { clip_copy(text) }
			}
			clear(&t.clip_write)
		}
	}
	// synchronized output: the frame waits until the program says it is whole
	if t.modes.sync {
		if a.sync_deadline == 0 do a.sync_deadline = now_ms() + 150
		return
	}
	a.sync_deadline = 0
	if t.gen != a.last_gen {
		a.last_gen = t.gen
		a.hover_ok = false
		if a.flood && now_ms() < a.hold_until {
			a.draw_pending = true
			return
		}
		a.draw_pending = false
		plat.invalidate(&a.win)
	}
}

app_child_gone :: proc(a: ^App) {
	term.pty_reap(&a.pty)
	// a moment for the status
	for _ in 0 ..< 50 {
		if a.pty.exited do break
		linux.nanosleep(&linux.Time_Spec{time_nsec = 2_000_000}, nil)
		term.pty_reap(&a.pty)
	}
	a.exited = true
	a.status = a.pty.status
	logf("the child ended with status %d (reaped: %v)", a.status, a.pty.exited)
	if a.opt.exec_cmd != "" {
		a.finishing = true
		a.finish_ms = now_ms()
		a.t.gen += 1
		plat.invalidate(&a.win)
		return
	}
	if a.status == 0 {
		a.quit = true
		return
	}
	// a failure stays on screen to be read
	msg := strings.concatenate({"\r\n\x1b[2m[the shell exited with status ", itoa(a.status), "; press any key to close]\x1b[0m"}, context.temp_allocator)
	term.term_feed(&a.t, transmute([]u8)msg)
	a.t.gen += 1
	plat.invalidate(&a.win)
}

itoa :: proc(n: int) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	if n == 0 do return "0"
	v := n
	neg := v < 0
	if neg do v = -v
	for v > 0 {
		append(&b, u8('0' + v % 10))
		v /= 10
	}
	if neg do append(&b, '-')
	for i in 0 ..< len(b) / 2 do b[i], b[len(b) - 1 - i] = b[len(b) - 1 - i], b[i]
	return string(b[:])
}

// ---------------------------------------------------------------- pasting and copying

app_paste_text :: proc(a: ^App, text: string) {
	logf("paste: %d bytes to the program", len(text))
	if len(text) == 0 do return
	out := make([dynamic]u8, context.temp_allocator)
	term.paste_bytes(&a.t, &out, text)
	a.t.view = 0
	send(a, out[:])
	plat.invalidate(&a.win)
}

app_paste :: proc(a: ^App, primary: bool) {
	if text, now := clip_paste(primary); now do app_paste_text(a, text)
}

app_copy_selection :: proc(a: ^App) {
	if !term.sel_active(a.sel) do return
	text := term.sel_text(&a.t, a.sel, a.cfg.word_chars)
	if len(text) > 0 do clip_copy(text)
}

// ---------------------------------------------------------------- keyboard

app_font_zoom :: proc(a: ^App, delta: f32, reset: bool) {
	if reset { a.font_pt = a.cfg.font_size } else { a.font_pt = clamp(a.font_pt + delta, 6, 48) }
	app_set_font_px(a)
	app_layout(a)
	a.t.gen += 1
	plat.invalidate(&a.win)
}

app_scroll_to_line :: proc(a: ^App, line: int) {
	term.view_line_at_top(&a.t, max(line - a.t.rows / 2, 0))
	plat.invalidate(&a.win)
}

app_new_window :: proc(a: ^App, container: string) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "/proc/self/exe")
	if container != "" do append(&argv, "--container", container)
	cwd := a.t.cwd
	if cwd != "" && os.is_dir(cwd) do append(&argv, "--cwd", cwd)
	spawn_detached(argv[:])
}

/// the first container `distrobox list` shows (when none is configured)
first_container :: proc() -> string {
	out, ok := run_capture({"distrobox", "list", "--no-color"})
	if !ok do return ""
	lines := strings.split_lines(out, context.temp_allocator)
	for l, i in lines {
		if i == 0 do continue
		parts := strings.split(l, "|", context.temp_allocator)
		if len(parts) >= 2 {
			name := strings.trim_space(parts[1])
			if name != "" do return strings.clone(name, context.temp_allocator)
		}
	}
	return ""
}

app_open_container :: proc(a: ^App) {
	name := a.container
	if name == "" do name = a.cfg.container
	if name == "" do name = first_container()
	if name == "" {
		a.bell_ms = now_ms()
		plat.invalidate(&a.win)
		return
	}
	app_new_window(a, name)
}

app_search_update :: proc(a: ^App) {
	delete(a.matches)
	a.matches = nil
	if len(a.query) > 0 do a.matches = term.search(&a.t, string(a.query[:]))
	a.cur_match = len(a.matches) - 1
	if a.cur_match >= 0 do app_scroll_to_line(a, term.line_from_id(&a.t, a.matches[a.cur_match].line))
	plat.invalidate(&a.win)
}

app_search_step :: proc(a: ^App, delta: int) {
	if len(a.matches) == 0 do return
	a.cur_match = (a.cur_match + delta + len(a.matches)) % len(a.matches)
	app_scroll_to_line(a, term.line_from_id(&a.t, a.matches[a.cur_match].line))
}

app_search_close :: proc(a: ^App) {
	a.searching = false
	delete(a.matches)
	a.matches = nil
	plat.invalidate(&a.win)
}

on_key :: proc(w: ^plat.Window, e: plat.Key_Event) {
	a := cast(^App)w.user
	was := a.ctrl_down
	a.ctrl_down = .Ctrl in e.mods
	if was != a.ctrl_down do update_hover(a)
	if !e.pressed do return
	if !a.compose.tried {
		a.compose.tried = true
		compose_init(&a.compose, w.xkb_ctx)
	}
	if a.offer {
		switch e.sym {
		case 'y': app_answer_offer(a, true)
		case term.KS_Return, term.KS_KP_Enter, 'n': app_answer_offer(a, false)
		}
		return
	}
	if a.exited && a.opt.exec_cmd == "" {
		if e.sym >= 0xffe1 && e.sym <= 0xffee do return
		a.quit = true
		return
	}
	ctrl, shift, alt := .Ctrl in e.mods, .Shift in e.mods, .Alt in e.mods
	if a.searching {
		app_search_key(a, e)
		return
	}
	if ctrl && shift && !alt {
		switch e.sym {
		case 'c': app_copy_selection(a); return
		case 'v': app_paste(a, false); return
		case 'f':
			a.searching = true
			clear(&a.query)
			plat.invalidate(w)
			return
		case 'n': app_new_window(a, a.container); return
		case 't': app_open_container(a); return
		case term.KS_Up:
			l := term.prev_prompt(&a.t, term.view_top_line(&a.t))
			if l >= 0 do term.view_line_at_top(&a.t, l)
			plat.invalidate(w)
			return
		case term.KS_Down:
			l := term.next_prompt(&a.t, term.view_top_line(&a.t))
			if l >= 0 { term.view_line_at_top(&a.t, l) } else { a.t.view = 0 }
			plat.invalidate(w)
			return
		}
	}
	if ctrl && !alt {
		switch e.sym {
		case '=', '+', plat.KEY_KP_Add: app_font_zoom(a, 1, false); return
		case '-', '_', plat.KEY_KP_Subtract: app_font_zoom(a, -1, false); return
		case '0', ')', plat.KEY_KP_0: app_font_zoom(a, 0, true); return
		}
	}
	if shift && !ctrl && !alt && !a.t.modes.alt_screen {
		switch e.sym {
		case term.KS_Page_Up:
			a.t.view = min(a.t.view + max(a.t.rows - 1, 1), a.t.sb.count)
			a.t.gen += 1
			plat.invalidate(w)
			return
		case term.KS_Page_Down:
			a.t.view = max(a.t.view - max(a.t.rows - 1, 1), 0)
			a.t.gen += 1
			plat.invalidate(w)
			return
		case term.KS_Home:
			a.t.view = a.t.sb.count
			a.t.gen += 1
			plat.invalidate(w)
			return
		case term.KS_End:
			a.t.view = 0
			a.t.gen += 1
			plat.invalidate(w)
			return
		}
	}
	if shift && !ctrl && !alt && e.sym == term.KS_Insert {
		app_paste(a, true)
		return
	}
	// the key goes to the program
	text := e.text
	if !ctrl && !alt {
		switch res, ct := compose_key(&a.compose, e.keysym); res {
		case .Swallow: return
		case .Text: text = ct
		case .Pass:
		}
	}
	if a.t.view != 0 {
		a.t.view = 0
		a.t.gen += 1
		plat.invalidate(w)
	}
	if term.sel_active(a.sel) && (len(text) > 0 || ctrl) {
		a.sel = {}
		plat.invalidate(w)
	}
	out := make([dynamic]u8, context.temp_allocator)
	sym := ctrl ? e.sym : e.keysym
	term.encode_key(&a.t, &out, sym, tmods(e.mods), text)
	send(a, out[:])
}

app_search_key :: proc(a: ^App, e: plat.Key_Event) {
	ctrl, shift := .Ctrl in e.mods, .Shift in e.mods
	switch {
	case e.sym == term.KS_Escape, ctrl && shift && e.sym == 'f':
		app_search_close(a)
	case e.sym == term.KS_Return, e.sym == term.KS_KP_Enter, e.sym == term.KS_Up, e.sym == term.KS_Down:
		up := shift || e.sym == term.KS_Up
		app_search_step(a, up ? -1 : 1)
	case e.sym == term.KS_BackSpace:
		if len(a.query) > 0 {
			// drop one whole character
			n := len(a.query) - 1
			for n > 0 && a.query[n] & 0xc0 == 0x80 do n -= 1
			resize(&a.query, n)
			app_search_update(a)
		}
	case ctrl && e.sym == 'v':
		if text, now := clip_paste(false); now {
			append(&a.query, ..transmute([]u8)text)
			app_search_update(a)
		}
	case len(e.text) > 0 && !ctrl:
		append(&a.query, ..transmute([]u8)e.text)
		app_search_update(a)
	}
}

// ---------------------------------------------------------------- pointer

app_cell :: proc(a: ^App, x, y: f64) -> (col, row: int) {
	col = clamp(int(math.floor((x - f64(a.ox)) / f64(fonts.cell_w))), 0, a.t.cols - 1)
	row = clamp(int(math.floor((y - f64(a.oy)) / f64(fonts.cell_h))), 0, a.t.rows - 1)
	return
}

app_point :: proc(a: ^App) -> term.Point {
	return {line = term.line_id(&a.t, term.view_top_line(&a.t) + a.row), col = a.col}
}

mouse_reporting :: proc(a: ^App, mods: plat.Mods) -> bool {
	return a.t.modes.mouse != .None && .Shift not_in mods
}

update_hover :: proc(a: ^App) {
	was := a.hover_ok
	a.hover_ok = false
	if a.ctrl_down {
		li := term.view_top_line(&a.t) + a.row
		if hit, ok := term.link_at(&a.t, li, a.col); ok {
			a.hover_ok = true
			a.hover = {hit.line0, hit.col0, hit.line1, hit.col1}
		}
	}
	if was != a.hover_ok || a.hover_ok {
		plat.set_cursor(&a.win, a.hover_ok ? .Pointer : .Text)
		plat.invalidate(&a.win)
	}
}

report_mouse :: proc(a: ^App, e: term.Mouse_Event) -> bool {
	out := make([dynamic]u8, context.temp_allocator)
	if !term.encode_mouse(&a.t, &out, e) do return false
	send(a, out[:])
	return true
}

on_pointer :: proc(w: ^plat.Window, e: plat.Pointer_Event) {
	a := cast(^App)w.user
	switch e.kind {
	case .Enter:
		plat.set_cursor(w, .Text)
	case .Leave:
		if a.hover_ok {
			a.hover_ok = false
			plat.invalidate(w)
		}
	case .Motion:
		a.px, a.py = e.x * w.scale, e.y * w.scale
		oc, or := a.col, a.row
		a.col, a.row = app_cell(a, a.px, a.py)
		moved := oc != a.col || or != a.row
		if mouse_reporting(a, e.mods) {
			if moved {
				held := a.buttons != 0
				b := u8(0)
				if a.buttons & 1 != 0 { b = 0 } else if a.buttons & 2 != 0 { b = 1 } else if a.buttons & 4 != 0 { b = 2 } else { b = 3 }
				report_mouse(a, {kind = .Motion, button = b, held = held, x = a.col, y = a.row, mods = tmods(e.mods)})
			}
			return
		}
		if a.selecting && a.buttons & 1 != 0 {
			a.sel.head = app_point(a)
			plat.invalidate(w)
		}
		if moved do update_hover(a)
	case .Button:
		a.px, a.py = e.x * w.scale, e.y * w.scale
		a.col, a.row = app_cell(a, a.px, a.py)
		bit := u8(0)
		switch e.button {
		case 1: bit = 1
		case 2: bit = 2
		case 3: bit = 4
		}
		if e.pressed { a.buttons |= bit } else { a.buttons &= ~bit }
		if a.offer || a.exited do return
		if mouse_reporting(a, e.mods) {
			b := u8(e.button - 1)
			if e.button > 3 do return
			report_mouse(a, {kind = e.pressed ? .Press : .Release, button = b, x = a.col, y = a.row, mods = tmods(e.mods)})
			return
		}
		switch e.button {
		case 1:
			if e.pressed {
				if .Ctrl in e.mods {
					li := term.view_top_line(&a.t) + a.row
					if hit, ok := term.link_at(&a.t, li, a.col); ok && term.url_allowed(hit.url) {
						spawn_detached({"xdg-open", hit.url})
					}
					return
				}
				kind: term.Sel_Kind = .Chars
				switch e.clicks {
				case 2: kind = .Word
				case 3: kind = .Line
				}
				if kind == .Chars && .Alt in e.mods do kind = .Block
				p := app_point(a)
				a.sel = {kind = kind, anchor = p, head = p}
				a.selecting = true
				plat.invalidate(w)
			} else if a.selecting {
				a.selecting = false
				a.sel.head = app_point(a)
				if a.sel.kind == .Chars && a.sel.anchor == a.sel.head {
					a.sel = {}
				} else if a.cfg.copy_on_select {
					if text := term.sel_text(&a.t, a.sel, a.cfg.word_chars); len(text) > 0 do clip_primary(text)
				}
				plat.invalidate(w)
			}
		case 2:
			if e.pressed do app_paste(a, true)
		}
	case .Scroll:
		app_scroll(a, e)
	case .Scroll_Stop:
		a.scroll_acc = 0
	}
}

app_scroll :: proc(a: ^App, e: plat.Pointer_Event) {
	if a.offer || e.dy == 0 do return
	if e.precise {
		a.scroll_acc += e.dy / (f64(fonts.cell_h) / a.win.scale)
	} else {
		notches := e.dy / 15
		if abs(notches) < 1 do notches = notches < 0 ? -1 : 1
		a.scroll_acc += notches * f64(a.cfg.scroll_lines)
	}
	n := int(a.scroll_acc)
	if n == 0 do return
	a.scroll_acc -= f64(n)
	up := n < 0
	n = abs(n)
	t := &a.t
	switch {
	case mouse_reporting(a, e.mods):
		for _ in 0 ..< min(n, 10) {
			report_mouse(a, {kind = up ? .Wheel_Up : .Wheel_Down, x = a.col, y = a.row, mods = tmods(e.mods)})
		}
	case t.modes.alt_screen:
		if t.modes.alt_scroll {
			out := make([dynamic]u8, context.temp_allocator)
			for _ in 0 ..< min(n, 20) {
				if t.modes.app_cursor { append(&out, 0x1b, 'O', up ? 'A' : 'B') } else { append(&out, 0x1b, '[', up ? 'A' : 'B') }
			}
			send(a, out[:])
		}
	case:
		if up { t.view = min(t.view + n, t.sb.count) } else { t.view = max(t.view - n, 0) }
		t.gen += 1
		plat.invalidate(&a.win)
	}
}

on_focus :: proc(w: ^plat.Window, on: bool) {
	a := cast(^App)w.user
	a.focused = on
	if !on do compose_reset(&a.compose)
	if a.t.modes.focus_events do send(a, on ? transmute([]u8)string("\x1b[I") : transmute([]u8)string("\x1b[O"))
	a.t.gen += 1
	plat.invalidate(w)
}

on_resized :: proc(w: ^plat.Window) {
	a := cast(^App)w.user
	app_set_font_px(a)
	app_layout(a)
}

on_close :: proc(w: ^plat.Window) {
	a := cast(^App)w.user
	a.quit = true
}

// ---------------------------------------------------------------- files that change

app_reload :: proc(a: ^App) {
	old := a.cfg.font
	oldsize, oldlig := a.cfg.font_size, a.cfg.ligatures
	oldpt := a.font_pt
	app_load_config(a)
	if a.cfg.font != old || a.cfg.ligatures != oldlig {
		app_font(a)
	}
	if a.cfg.font_size != oldsize || oldpt == oldsize {
		a.font_pt = a.cfg.font_size
		app_set_font_px(a)
	}
	a.t.sb.max = max(a.cfg.scrollback, 0)
	app_apply_theme(a)
	app_detect_blur(a)
	app_layout(a)
	plat.invalidate(&a.win)
}

app_watch :: proc(a: ^App) {
	fd, err := linux.inotify_init1({.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		a.ino = -1
		return
	}
	a.ino = fd
	watch_dir(fd, config_dir()) // when it exists
	// the desktop's colour scheme lives in dconf's file
	base := env("XDG_CONFIG_HOME")
	if base == "" do base = strings.concatenate({home_dir(), "/.config"}, context.temp_allocator)
	watch_dir(fd, strings.concatenate({base, "/dconf"}, context.temp_allocator))
	if !os.exists(config_dir()) do watch_dir(fd, base)
}

app_files_changed :: proc(a: ^App) {
	names := drain_inotify(a.ino)
	reload, scheme := false, false
	for n in names {
		switch n {
		case "config", "iris-terminal": reload = true
		case "user": scheme = true
		}
	}
	if reload {
		watch_dir(a.ino, config_dir())
		app_reload(a)
	} else if scheme && a.cfg.theme == "glass" {
		if desktop_dark() != a.dark {
			app_apply_theme(a)
			plat.invalidate(&a.win)
		}
	}
}

// ---------------------------------------------------------------- the loop

app_run :: proc(a: ^App) {
	for !a.quit && !a.win.closed {
		timeout := i32(-1)
		now := now_ms()
		if a.sync_deadline != 0 do timeout = i32(max(a.sync_deadline - now, 0))
		if a.finishing do timeout = 50
		if a.draw_pending do timeout = i32(max(a.hold_until - now, 1))
		// a paste on its way: look again soon (a pipe that closes without data wakes poll only with HUP)
		if clip_waiting() do timeout = 20
		if a.opt.timeout_ms > 0 && a.opt.exec_cmd != "" && !a.exited do timeout = 100
		extra := [3]linux.Fd{-1, a.ino, clip_fd()}
		if a.spawned && !a.exited do extra[0] = a.pty.master
		ready, ok := plat.wait(&a.win, timeout, extra[:])
		if !ok do break
		now = now_ms()
		if ready & 1 != 0 do app_read_pty(a)
		if ready & 2 != 0 do app_files_changed(a)
		if clip_waiting() {
			if text, done := clip_read(); done do app_paste_text(a, text)
		}
		if a.draw_pending && now >= a.hold_until {
			a.draw_pending = false
			plat.invalidate(&a.win)
		}
		if a.sync_deadline != 0 && now >= a.sync_deadline {
			a.t.modes.sync = false
			a.sync_deadline = 0
			a.t.gen += 1
			app_after_feed(a)
		}
		if a.finishing && now - a.finish_ms > 3000 do a.quit = true
		if a.opt.timeout_ms > 0 && a.opt.exec_cmd != "" && !a.exited && now - a.start_ms > i64(a.opt.timeout_ms) {
			linux.kill(a.pty.pid, .SIGKILL)
			a.status = 124
			term.pty_reap(&a.pty)
			a.exited = true
			a.finishing = true
			a.finish_ms = now
			plat.invalidate(&a.win)
		}
		free_all(context.temp_allocator)
	}
}
