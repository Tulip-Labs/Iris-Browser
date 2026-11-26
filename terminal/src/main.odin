// Iris Terminal: a terminal for Fedora's immutable desktops and niri.
// Glass, zsh at home, containers one key away, and nothing running when
// nothing happens.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import plat "../plat"
import term "../term"

HELP :: `Iris Terminal ` + VERSION + `

usage: iris-terminal [options] [-e PROGRAM ARGS...]

  --container NAME    open inside a distrobox/toolbox container
  --cwd PATH          start in this folder
  --geometry CxR      the size in characters (default 100x30)
  --shell PATH        the shell to run (default $SHELL, zsh, bash)
  -e PROGRAM ARGS...  run a program instead of the shell

  --setup-niri        write niri's window rule (rounded glass, blur) and include it
  --remove-niri       undo --setup-niri
  --setup-zsh         set up zsh: the refined config and one block in ~/.zshrc
  --remove-zsh        undo --setup-zsh
  --install-fonts     download MesloLGS NF into ~/.local/share/fonts (only when you ask)
  --fonts             which fonts are found
  --write-config      write a commented ~/.config/iris-terminal/config
  --version, --help

for tests: --exec CMD, --dump-screen FILE, --dump-state FILE, --dump-frame FILE,
           --dump-raw FILE, --input TEXT, --input-after MS (without a window), --no-window, --stats, --timeout MS, --debug
`

MESLO_URL :: "https://github.com/romkatv/powerlevel10k-media/raw/master/"
MESLO_FILES :: [?]string{"MesloLGS NF Regular.ttf", "MesloLGS NF Bold.ttf", "MesloLGS NF Italic.ttf", "MesloLGS NF Bold Italic.ttf"}

die :: proc(code: int, format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(code)
}

main :: proc() {
	ignore_sigpipe()
	opt: Options
	args := os.args[1:]
	action := ""
	argv := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		next :: proc(args: []string, i: ^int, name: string) -> string {
			if i^ + 1 >= len(args) do die(2, "iris-terminal: %s needs a value", name)
			i^ += 1
			return args[i^]
		}
		switch arg {
		case "--help", "-h": fmt.print(HELP); return
		case "--version", "-V": fmt.println("iris-terminal", VERSION); return
		case "--setup-niri", "--remove-niri", "--setup-zsh", "--remove-zsh", "--install-fonts", "--fonts", "--write-config":
			action = arg
		case "--container": opt.container = next(args, &i, arg)
		case "--cwd": opt.cwd = next(args, &i, arg)
		case "--shell": opt.shell = next(args, &i, arg)
		case "--exec": opt.exec_cmd = next(args, &i, arg)
		case "--dump-screen": opt.dump_screen = next(args, &i, arg)
		case "--dump-state": opt.dump_state = next(args, &i, arg)
		case "--dump-frame": opt.dump_frame = next(args, &i, arg)
		case "--dump-raw": opt.dump_raw = next(args, &i, arg)
		case "--input": opt.input = next(args, &i, arg)
		case "--input-after":
			v, ok := strconv.parse_int(next(args, &i, arg))
			if !ok do die(2, "iris-terminal: --input-after wants milliseconds")
			opt.input_after = v
		case "--no-window": opt.no_window = true
		case "--stats": opt.stats = true
		case "--debug": debug_on = true
		case "--timeout":
			v, ok := strconv.parse_int(next(args, &i, arg))
			if !ok do die(2, "iris-terminal: --timeout wants milliseconds")
			opt.timeout_ms = v
		case "--geometry":
			g := next(args, &i, arg)
			parts := strings.split(g, "x")
			c, ok1 := strconv.parse_int(parts[0])
			r, ok2 := strconv.parse_int(parts[len(parts) - 1])
			if len(parts) != 2 || !ok1 || !ok2 || c < 2 || r < 1 do die(2, "iris-terminal: --geometry wants COLSxROWS, like 100x30")
			opt.cols, opt.rows = c, r
		case "-e":
			for j in i + 1 ..< len(args) do append(&argv, args[j])
			i = len(args)
		case:
			die(2, "iris-terminal: unknown option %s (try --help)", arg)
		}
	}
	opt.argv = argv[:]
	if env("IRIS_TERMINAL_DEBUG") != "" do debug_on = true

	switch action {
	case "--setup-niri": setup_niri()
	case "--remove-niri": remove_niri()
	case "--setup-zsh": setup_zsh()
	case "--remove-zsh": remove_zsh()
	case "--install-fonts": install_fonts()
	case "--fonts": list_fonts()
	case "--write-config": write_config()
	case:
		if opt.no_window { os.exit(run_headless(opt)) }
		os.exit(run_window(opt))
	}
}

// ---------------------------------------------------------------- the setup commands

load_config_only :: proc() -> term.Config {
	cfg := term.config_default()
	if text, ok := read_file(strings.concatenate({config_dir(), "/config"}, context.temp_allocator)); ok do term.config_parse(&cfg, text)
	return cfg
}

setup_niri :: proc() {
	cfg := load_config_only()
	version, _ := run_capture({"niri", "--version"})
	blur := term.niri_has_blur(version)
	dir := term.niri_config_dir(context.temp_allocator)
	res, err := term.niri_setup(dir, cfg.radius, blur)
	switch err {
	case .None:
	case .No_Config: die(1, "iris-terminal: no niri config at %s/config.kdl (is niri set up for you?)", dir)
	case .Io: die(1, "iris-terminal: could not write in %s", dir)
	}
	fmt.printfln("Wrote %s/%s (rounded glass%s).", dir, term.NIRI_KDL_NAME, blur ? ", blur behind it" : "; this niri has no blur rule, 26.04 and newer do")
	if res.added_include {
		fmt.printfln("Added the include line to %s/config.kdl (a copy of the old file: %s).", dir, res.backup != "" ? res.backup : "kept before")
	} else {
		fmt.println("config.kdl already includes it.")
	}
	fmt.println("niri reloads its config by itself.")
}

remove_niri :: proc() {
	dir := term.niri_config_dir(context.temp_allocator)
	removed, err := term.niri_remove(dir)
	if err != .None do die(1, "iris-terminal: could not write in %s", dir)
	fmt.println(removed ? "Took the include line out of config.kdl and deleted the rule." : "Nothing to remove from config.kdl; deleted the rule file if there was one.")
}

setup_zsh :: proc() {
	res, ok := term.zsh_setup(home_dir(), config_dir())
	if !ok do die(1, "iris-terminal: could not write the zsh files")
	fmt.printfln("Wrote %s.", res.init)
	if res.added_block {
		fmt.printfln("Added one block to %s%s.", res.zshrc, res.backup != "" ? strings.concatenate({" (the old file is kept as ", res.backup, ")"}, context.temp_allocator) : "")
	} else {
		fmt.printfln("%s already has the block.", res.zshrc)
	}
	fmt.println("Open a new terminal (or run: exec zsh). Undo it with: iris-terminal --remove-zsh")
}

remove_zsh :: proc() {
	removed, ok := term.zsh_remove(home_dir(), config_dir())
	if !ok do die(1, "iris-terminal: could not write ~/.zshrc")
	fmt.println(removed ? "Took the block out of ~/.zshrc and deleted the zsh config." : "~/.zshrc has no block; deleted the zsh config if there was one.")
}

install_fonts :: proc() {
	dir := fonts_dir()
	os.make_directory_all(dir)
	fmt.printfln("Downloading MesloLGS NF (the patched font of Powerlevel10k) into %s", dir)
	for f in MESLO_FILES {
		escaped, _ := strings.replace_all(f, " ", "%20", context.temp_allocator)
		url := strings.concatenate({MESLO_URL, escaped}, context.temp_allocator)
		dst := strings.concatenate({dir, "/", f}, context.temp_allocator)
		fmt.printfln("  %s", f)
		if _, ok := run_capture({"curl", "-fsSL", "--retry", "2", "-o", dst, url}); !ok {
			die(1, "iris-terminal: could not download %s (is curl installed, and are you online?)", f)
		}
	}
	run_capture({"fc-cache", "-f", dir})
	fmt.println("Done. New terminals use it right away.")
}

list_fonts :: proc() {
	cfg := load_config_only()
	fonts_init(term.font_families(&cfg), cfg.ligatures)
	for l in fonts_describe() do fmt.println(l)
	have_nerd := false
	if fi := font_for_rune(0xe0b0); fi >= 0 && !fonts.fams[fi].lazy && fonts.fams[fi].path != "builtin" do have_nerd = true
	fmt.printfln("powerline and Nerd symbols: %s", have_nerd ? "yes" : "no (run: iris-terminal --install-fonts)")
}

write_config :: proc() {
	dir := config_dir()
	os.make_directory_all(dir)
	path := strings.concatenate({dir, "/config"}, context.temp_allocator)
	if os.exists(path) do die(1, "iris-terminal: %s exists already", path)
	if err := os.write_entire_file(path, transmute([]u8)string(term.CONFIG_SAMPLE)); err != nil do die(1, "iris-terminal: could not write %s", path)
	fmt.printfln("Wrote %s", path)
}

// ---------------------------------------------------------------- the dumps and the stats

write_dumps :: proc(t: ^term.Term, opt: Options, extra := "") {
	if opt.dump_screen != "" {
		if err := os.write_entire_file(opt.dump_screen, transmute([]u8)term.screen_text(t)); err != nil do fmt.eprintfln("could not write %s", opt.dump_screen)
	}
	if opt.dump_state != "" {
		text := strings.concatenate({term.state_text(t), extra}, context.temp_allocator)
		if err := os.write_entire_file(opt.dump_state, transmute([]u8)text); err != nil do fmt.eprintfln("could not write %s", opt.dump_state)
	}
}

print_stats :: proc(bytes: u64, ms: i64) {
	secs := max(f64(ms) / 1000, 0.001)
	fmt.printfln("bytes=%d ms=%d MB/s=%.1f", bytes, ms, f64(bytes) / 1e6 / secs)
}

// ---------------------------------------------------------------- without a window

run_headless :: proc(opt: Options) -> int {
	cfg := load_config_only()
	cols, rows := opt.cols > 0 ? opt.cols : cfg.columns, opt.rows > 0 ? opt.rows : cfg.rows
	argv := make([dynamic]string, context.temp_allocator)
	switch {
	case len(opt.argv) > 0: append(&argv, ..opt.argv)
	case opt.exec_cmd != "": append(&argv, "/bin/sh", "-c", opt.exec_cmd)
	case: append(&argv, find_shell(opt.shell != "" ? opt.shell : cfg.shell))
	}
	h: term.Headless
	if !term.headless_start(&h, argv[:], term.pty_env({"IRIS_TERMINAL_NERD=0"}), cols, rows, cfg.scrollback) do die(1, "iris-terminal: could not start %s", argv[0])
	theme := term.theme_by_name(cfg.theme, true)
	term.term_apply_theme(&h.term, theme)
	h.capture = opt.dump_raw != ""
	start := time.now()
	timeout := opt.timeout_ms > 0 ? opt.timeout_ms : 30000
	status := term.headless_run(&h, timeout, opt.input, opt.input_after > 0 ? opt.input_after : 1500)
	ms := i64(time.duration_milliseconds(time.since(start)))
	write_dumps(&h.term, opt)
	if opt.dump_raw != "" do _ = os.write_entire_file(opt.dump_raw, h.raw[:])
	if opt.stats do print_stats(u64(h.total), ms)
	term.headless_destroy(&h)
	return status
}

// ---------------------------------------------------------------- the window

run_window :: proc(opt: Options) -> int {
	a := &app
	a.opt = opt
	app_load_config(a)
	a.container = opt.container != "" ? opt.container : a.cfg.container
	a.font_pt = a.cfg.font_size
	a.read_buf = make([]u8, 64 * 1024)
	app_font(a)
	term.term_init(&a.t, a.cfg.columns, a.cfg.rows, a.cfg.scrollback)
	app_apply_theme(a)
	a.t.cell_px = {fonts.cell_w, fonts.cell_h}
	a.last_gen = a.t.gen

	pad := int(f64(a.cfg.padding))
	chrome := a.container != "" ? fonts.cell_h + pad / 2 : 0
	w := &a.win
	w.user = a
	w.resized = on_resized
	w.pointer = on_pointer
	w.key = on_key
	w.focus = on_focus
	w.close = on_close
	if !plat.open(w, {
		app_id = term.APP_ID, title = "Iris Terminal",
		width = i32(a.cfg.columns * fonts.cell_w + 2 * pad), height = i32(a.cfg.rows * fonts.cell_h + 2 * pad + chrome),
		min_width = 240, min_height = 120,
	}) {
		die(1, "iris-terminal: could not open a window (it needs a Wayland session with EGL)")
	}
	a.focused = w.activated
	a.start_ms = now_ms()
	clip_init(w)
	app_detect_blur(a)
	app_apply_theme(a)
	app_set_font_px(a)
	app_layout(a)
	w.draw = draw_frame
	if app_needs_offer(a) {
		a.offer = true
		app_offer_text(a)
	} else {
		app_spawn(a)
	}
	app_watch(a)
	plat.invalidate(w)
	app_run(a)

	// the end
	status := a.status
	if a.spawned && !a.exited do status = 0
	term.pty_close(&a.pty)
	layout := fmt.tprintf("layout: ox=%d oy=%d cell=%dx%d pixel=%dx%d scale=%.2f blur=%v nerd=%v\n", a.ox, a.oy, fonts.cell_w, fonts.cell_h, w.pixel_w, w.pixel_h, w.scale, a.has_blur, a.nerd)
	write_dumps(&a.t, opt, layout)
	if opt.stats do print_stats(a.bytes_in, a.last_byte_ms - a.first_byte_ms)
	plat.close_window(w)
	return status
}
