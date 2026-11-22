// iris --render-check OUT.ppm: one frame of Iris's renderer, drawn without
// a window (Mesa's surfaceless EGL) and written as a picture: the dawn, a
// stand-in page and Liquid Glass of every kind over it. CI runs it so a
// shader that does not compile, or glass that draws nothing, fails the
// build; people look at the picture.
package iris

import "core:fmt"
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

	frame_begin(W, H, SCALE)
	draw_dawn()
	// a stand-in page: white, a heading, lines of text and coloured blocks
	card := [4]f32{8, 100, lw - 16, lh - 108}
	draw_fill(card.x, card.y + 4, card.z, card.w, 14, {0.14, 0.11, 0.25, 0.16}, soft = 12)
	draw_fill(card.x, card.y, card.z, card.w, 14, {1, 1, 1, 1})
	draw_fill(card.x + 40, card.y + 30, 420, 28, 6, {0.14, 0.11, 0.25, 0.9})
	for i in 0 ..< 14 {
		y := card.y + 80 + f32(i) * 22
		w := card.z * 0.55 - f32((i * 37) % 160)
		draw_fill(card.x + 40, y, w, 9, 4, {0.14, 0.11, 0.25, 0.35})
	}
	colors := [4][4]f32{{0.42, 0.30, 0.96, 1}, {0.22, 0.74, 0.97, 1}, {0.98, 0.55, 0.36, 1}, {0.99, 0.80, 0.30, 1}}
	for c, i in colors do draw_fill(card.x + card.z * 0.62 + f32(i % 2) * 190, card.y + 40 + f32(i / 2) * 150, 170, 130, 16, c)
	frame_scene_done()

	// the chrome's glass, of every kind, where the chrome puts it
	draw_glass(10, 50, 128, 44, glass_style({r = 22, kind = 0}))                         // the buttons' bar
	draw_glass(148, 50, lw - 148 - 150, 44, glass_style({r = 22, kind = 0}))             // the address
	draw_glass(lw - 140, 50, 130, 44, glass_style({r = 22, kind = 0}))                   // the actions
	draw_glass(12, 9, 200, 32, glass_style({r = 16, kind = 2}))                          // the tab
	draw_glass(216, 9, 32, 32, glass_style({r = 16, kind = 3}))                          // a hovered button
	draw_glass(lw * 0.55, 150, 320, 260, glass_style({r = 18, kind = 1}))                // a panel over the page
	draw_glass(lw * 0.5 - 180, lh - 70, 360, 44, glass_style({r = 20, kind = 1}))        // a note

	px := make([]u8, int(W * H * 4))
	defer delete(px)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
	gl.ReadPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, &px[0])
	if e := gl.GetError(); e != gl.NO_ERROR {
		fmt.eprintfln("render check: OpenGL error 0x%x", e)
		return 1
	}
	// the glass changed what is behind it: the address bar's middle is not the scene's
	ppm := make([dynamic]u8, 0, int(W * H * 3) + 32)
	defer delete(ppm)
	append(&ppm, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", W, H))
	distinct_colors := map[u32]bool{}
	defer delete(distinct_colors)
	for y := H - 1; y >= 0; y -= 1 do for x in 0 ..< W {
		i := int((y * W + x) * 4)
		append(&ppm, px[i], px[i + 1], px[i + 2])
		if x % 7 == 0 && y % 7 == 0 do distinct_colors[u32(px[i]) << 16 | u32(px[i + 1]) << 8 | u32(px[i + 2])] = true
	}
	if !write_all(out, ppm[:]) {
		fmt.eprintln("render check: cannot write", out)
		return 1
	}
	if len(distinct_colors) < 500 {
		fmt.eprintfln("render check: the frame is nearly flat (%d colours)", len(distinct_colors))
		return 1
	}
	fmt.printfln("render check: %d×%d frame, %d colours, written to %s", W, H, len(distinct_colors), out)
	return 0
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
