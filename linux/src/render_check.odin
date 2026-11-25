// iris --render-check OUT.ppm: one frame of Iris's renderer, drawn without
// a window (Mesa's surfaceless EGL) and written as a picture: the dawn, a
// stand-in page and Liquid Glass of every kind over it, then the start
// page (its glass ring and search) in light and dark. CI runs it so a
// shader that does not compile, or glass that draws nothing, fails the
// build; people look at the picture.
package iris

import "core:fmt"
import plat "../plat"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "vendor:egl"
import gl "vendor:OpenGL"

render_check :: proc(out: string) -> int {
	EGL_PLATFORM_SURFACELESS_MESA :: 0x31DD
	d := egl.GetPlatformDisplay(egl.Platform(EGL_PLATFORM_SURFACELESS_MESA), nil, nil)
	major, minor: i32
	if d == nil || !egl.Initialize(d, &major, &minor) {
		fmt.eprintln("render check: no surfaceless EGL display (Mesa)")
		return 1
	}
	egl.BindAPI(egl.OPENGL_ES_API)
	attrs := [?]i32{egl.SURFACE_TYPE, egl.PBUFFER_BIT, egl.RENDERABLE_TYPE, egl.OPENGL_ES3_BIT, egl.NONE}
	config: egl.Config
	n: i32
	if !egl.ChooseConfig(d, &attrs[0], &config, 1, &n) || n < 1 {
		fmt.eprintln("render check: no OpenGL ES 3 config")
		return 1
	}
	cattrs := [?]i32{egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE}
	ctx := egl.CreateContext(d, config, egl.NO_CONTEXT, &cattrs[0])
	if ctx == nil || !egl.MakeCurrent(d, egl.NO_SURFACE, egl.NO_SURFACE, ctx) {
		fmt.eprintln("render check: no OpenGL ES 3 context")
		return 1
	}
	gl.load_gles_up_to(3, 0, egl.gl_set_proc_address)
	renderer_init(d) // compiles every shader (a failure panics with the log)

	SCALE :: 1.25
	W, H :: i32(1600), i32(1000)
	lw, lh := f32(W) / SCALE, f32(H) / SCALE
	tex, fbo: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, W, H, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.GenFramebuffers(1, &fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0)
	rnd.target_fbo = fbo
	rnd.pointer = {lw * 0.42, 70}
	text_init()

	// a sample state: four tabs (one in a container, one in the sandbox),
	// a page loading, a note, and the containers panel open
	os.set_env("XDG_DATA_HOME", "/tmp/iris-render-check")
	os.set_env("XDG_CACHE_HOME", "/tmp/iris-render-check")
	containers_ensure()
	b.win.width, b.win.height, b.win.scale = i32(lw), i32(lh), SCALE
	b.win.server_frame = false
	mk :: proc(title, url, container: string) -> ^Tab {
		t := tab_new(container)
		t.title = title
		t.url = url
		append(&b.tabs, t)
		return t
	}
	mk("Google AI Mode", HOME, "")
	cur := mk("Odin Programming Language", "https://odin-lang.org/docs/overview/", "")
	cur.can_back = true
	cur.loading = true
	cur.progress = 0.62
	// Iris starts with no containers: one made here, its tab in its colour
	work := len(containers) > 0 ? containers[0] : container_add("Work", "")
	mk("Pull requests · Tulip-Labs/Iris-Browser", "https://github.com/Tulip-Labs/Iris-Browser/pulls", work.id)
	sb := mk("example.com", "http://example.com/", "")
	sb.sandboxed = true
	b.current = cur
	chrome_start()
	chrome_toast("Shields: Aggressive. Pages pick it up as they load.", "Undo")
	ui.panel = .Containers
	ui.panel_right = true
	ui_test_dt = 1.0 / 30
	frames := 40
	for f in 0 ..< frames {
		b.card = chrome_card(lw, lh)
		if f == 1 do ui.panel_anchor = button_rect_for_check(.Containers)
		frame_begin(W, H, SCALE)
		draw_dawn()
		draw_sample_page(b.card)
		frame_scene_done()
		chrome_draw(lw, lh)
		free_all(context.temp_allocator)
	}

	if !save_frame(fbo, W, H, out) do return 1

	// the chrome answers the pointer and keys
	redraw :: proc(W, H: i32, lw, lh: f32) {
		for _ in 0 ..< 12 {
			frame_begin(W, H, f64(rnd.scale))
			draw_dawn()
			draw_sample_page(b.card)
			frame_scene_done()
			chrome_draw(lw, lh)
			free_all(context.temp_allocator)
		}
	}
	click :: proc(k: Wid) -> bool {
		r := button_rect_for_check(k)
		if r.z == 0 do return false
		x, y := f64(r.x + r.z / 2), f64(r.y + r.w / 2)
		chrome_pointer({kind = .Motion, x = x, y = y})
		chrome_pointer({kind = .Button, button = 1, pressed = true, clicks = 1, x = x, y = y})
		chrome_pointer({kind = .Button, button = 1, pressed = false, x = x, y = y})
		return true
	}
	type :: proc(text: string) {
		for r in text {
			buf: [4]u8
			s := string(buf[:copy(buf[:], transmute([]u8)fmt.tprint(r))])
			chrome_key({sym = u32(r), keysym = u32(r), text = s, pressed = true})
		}
	}
	problems := 0
	expect :: proc(ok: bool, what: string, problems: ^int) {
		if !ok {
			fmt.eprintln("render check:", what)
			problems^ += 1
		}
	}
	chrome_close_all()
	redraw(W, H, lw, lh)
	expect(ui.panel == .None, "Escape did not close the panel", &problems)
	expect(click(.Shield), "no Shields button", &problems)
	expect(ui.panel == .Shields, "the Shields button did not open its panel", &problems)
	redraw(W, H, lw, lh)
	expect(click(.Shield), "the Shields button went", &problems)
	expect(ui.panel == .None, "a second click did not close the panel", &problems)
	redraw(W, H, lw, lh)
	expect(click(.Address), "no address", &problems)
	expect(ui.focus == .Address, "a click in the address did not give it the keys", &problems)
	expect(line_has_selection(&ui.address), "the first click did not select the address", &problems)
	type("what is odin")
	expect(line_string(&ui.address) == "what is odin", fmt.tprintf("typing gave %q", line_string(&ui.address)), &problems)
	expect(len(ui.suggestions) > 1 && ui.suggestions[0].icon == .Search && ui.suggestions[1].icon == .Sparkle, "no Search Google and Ask Google AI Mode suggestions", &problems)
	chrome_key({sym = plat.KEY_Left, pressed = true, mods = {.Ctrl}})
	chrome_key({sym = plat.KEY_Left, pressed = true, mods = {.Ctrl, .Shift}})
	redraw(W, H, lw, lh)
	out2 := strings.concatenate({strings.trim_suffix(out, ".ppm"), "-typing.ppm"}, context.temp_allocator)
	if !save_frame(fbo, W, H, out2) do return 1
	chrome_key({sym = plat.KEY_Escape, pressed = true})
	expect(len(ui.suggestions) == 0, "Escape did not hide the suggestions", &problems)
	chrome_key({sym = plat.KEY_Escape, pressed = true})
	expect(ui.focus == .None, "a second Escape did not leave the address", &problems)
	// the start page: a new tab draws Iris's own page (no web view), its
	// search takes the keys, in light and in dark
	st := browser_new_tab({select = true})
	expect(tab_is_start(st) && !tab_has_view(st), "a new tab is not the start page", &problems)
	expect(ui.focus == .Start, "the start page's search did not take the keys", &problems)
	for dark in ([2]bool{false, true}) {
		theme.dark = dark
		palette_apply()
		for _ in 0 ..< 30 {
			frame_begin(W, H, f64(rnd.scale))
			draw_dawn()
			frame_scene_done()
			chrome_draw(lw, lh)
			free_all(context.temp_allocator)
		}
		expect(button_rect_for_check(.Start_Field).z > 0, "no search on the start page", &problems)
		name := strings.concatenate({strings.trim_suffix(out, ".ppm"), dark ? "-start-dark.ppm" : "-start.ppm"}, context.temp_allocator)
		// a calm page by design: fewer colours than a page under glass
		if !save_frame(fbo, W, H, name, 120) do return 1
	}
	theme.dark = false
	palette_apply()

	// 2.3: the command palette (Ctrl+K) over a page, a pinned and a playing
	// tab in the strip, then the privacy report and compact mode's bars
	// (no engine runs here: the tab is put on screen by hand, never loaded)
	b.current = cur
	chrome_leave_start()
	tab_set_pinned(b.tabs[0], true)
	cur.audio = true
	palette_open()
	expect(ui.palette_open && ui.focus == .Palette, "Ctrl+K's palette did not open with the keys", &problems)
	type("split")
	expect(len(ui.palette_items) > 0 && ui.palette_items[0].act.op == .Command && Command(ui.palette_items[0].act.n) == .Split, "the palette's first answer to \"split\" is not Split View", &problems)
	redraw(W, H, lw, lh)
	if !save_frame(fbo, W, H, strings.concatenate({strings.trim_suffix(out, ".ppm"), "-palette.ppm"}, context.temp_allocator)) do return 1
	chrome_key({sym = plat.KEY_Escape, pressed = true})
	expect(!ui.palette_open, "Escape did not close the palette", &problems)
	cur.trackers = make([dynamic]string)
	append(&cur.trackers, "securepubads.g.doubleclick.net", "connect.facebook.net")
	privacy_open(button_rect_for_check(.Shield))
	redraw(W, H, lw, lh)
	expect(ui.panel == .Report, "the privacy report did not open", &problems)
	if !save_frame(fbo, W, H, strings.concatenate({strings.trim_suffix(out, ".ppm"), "-report.ppm"}, context.temp_allocator)) do return 1
	chrome_close_all()
	settings().compact = true
	ui.compact_hold = true
	b.card = chrome_card(lw, lh)
	redraw(W, H, lw, lh)
	expect(button_rect_for_check(.Address).z > 0, "compact mode's bars did not show at the top edge", &problems)
	if !save_frame(fbo, W, H, strings.concatenate({strings.trim_suffix(out, ".ppm"), "-compact.ppm"}, context.temp_allocator)) do return 1
	settings().compact = false
	ui.compact_hold = false
	if problems > 0 do return 1
	fmt.println("render check: the chrome answers clicks and keys")
	return 0
}

/// the frame in fbo, as a picture (PPM); fails when it is nearly flat
@(private="file") save_frame :: proc(fbo: u32, W, H: i32, out: string, min_colours := 200) -> bool {
	px := make([]u8, int(W * H * 4))
	defer delete(px)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.ReadPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, &px[0])
	if e := gl.GetError(); e != gl.NO_ERROR {
		fmt.eprintfln("render check: OpenGL error 0x%x", e)
		return false
	}
	ppm := make([dynamic]u8, 0, int(W * H * 3) + 32)
	defer delete(ppm)
	append(&ppm, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", W, H))
	colours := map[u32]bool{}
	defer delete(colours)
	for y := H - 1; y >= 0; y -= 1 do for x in 0 ..< W {
		i := int((y * W + x) * 4)
		append(&ppm, px[i], px[i + 1], px[i + 2])
		if x % 7 == 0 && y % 7 == 0 do colours[u32(px[i]) << 16 | u32(px[i + 1]) << 8 | u32(px[i + 2])] = true
	}
	if !write_all(out, ppm[:]) {
		fmt.eprintln("render check: cannot write", out)
		return false
	}
	if len(colours) < min_colours {
		fmt.eprintfln("render check: the frame is nearly flat (%d colours)", len(colours))
		return false
	}
	fmt.printfln("render check: %d×%d frame, %d colours, written to %s", W, H, len(colours), out)
	return true
}

/// the whole of data into a new file at path
write_all :: proc(path: string, data: []u8) -> bool {
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if err != .NONE do return false
	defer linux.close(fd)
	rest := data
	for len(rest) > 0 {
		n, e := linux.write(fd, rest)
		if e != .NONE || n <= 0 do return false
		rest = rest[n:]
	}
	return true
}

/// where a chrome button was drawn last frame (for the check's panel)
@(private="file") button_rect_for_check :: proc(k: Wid) -> [4]f32 {
	for h in ui.hits do if wid_of(h.id) == k do return h.r
	return {}
}

/// a stand-in page: white, a heading, lines of text and coloured blocks
@(private="file") draw_sample_page :: proc(card: [4]f32) {
	draw_fill(card.x, card.y + 4, card.z, card.w, 14, {0, 0, 0, 0.12}, soft = 16)
	draw_fill(card.x, card.y, card.z, card.w, 14, {1, 1, 1, 1})
	draw_fill(card.x + 40, card.y + 30, 420, 28, 6, {0.10, 0.11, 0.13, 0.9})
	for i in 0 ..< 14 {
		y := card.y + 80 + f32(i) * 22
		w := card.z * 0.55 - f32((i * 37) % 160)
		draw_fill(card.x + 40, y, w, 9, 4, {0.10, 0.11, 0.13, 0.35})
	}
	colors := [4][4]f32{{0.20, 0.62, 0.42, 1}, {0.22, 0.74, 0.97, 1}, {0.98, 0.55, 0.36, 1}, {0.99, 0.80, 0.30, 1}}
	for c, i in colors do draw_fill(card.x + card.z * 0.42 + f32(i % 2) * 190, card.y + 40 + f32(i / 2) * 150, 170, 130, 16, c)
}
