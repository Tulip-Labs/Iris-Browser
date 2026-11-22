// Iris's renderer, OpenGL ES 3 through EGL. Each frame:
//   1. the scene: the dawn behind everything and the page (its WPE frame,
//      an EGL image of WebKit's own DMA-BUF: no copy), into a texture;
//   2. a blurred copy of it, small (two halvings);
//   3. the scene on screen, then Liquid Glass wherever the chrome asked for
//      it: what is behind is magnified a little, pulled in from beyond the
//      edge towards the rim (red and blue apart, a little), tinted, lit
//      along its rim and where the pointer is;
//   4. the chrome's own frame (its HTML, transparent around it) on top.
package iris

import "core:math"
import "core:strings"
import "vendor:egl"
import gl "vendor:OpenGL"

Texture :: struct {
	id:            u32,
	w, h:          i32,
	premultiplied: bool,
	bgra:          bool, // software frames are BGRA bytes
	owned:         bool, // made here (freed here)
}

Imported :: struct {
	image: egl.Image,
	tex:   u32,
	w, h:  i32,
}

Glass :: struct {
	radius:     f32,
	tint:       [4]f32, // straight alpha
	bend:       f32, // pixels pulled in at the rim
	rim:        f32, // width of the bending rim
	lens:       f32, // magnification of the middle
	frost:      f32, // 0 clear, 1 the blurred scene
	shadow:     f32,
	rim_light:  f32,
	dispersion: bool,
}

Renderer :: struct {
	egl_display:     egl.Display,
	create_image:    proc "c" (d: egl.Display, c: egl.Context, target: u32, buffer: rawptr, attribs: [^]i32) -> egl.Image,
	destroy_image:   proc "c" (d: egl.Display, image: egl.Image) -> b32,
	target_texture:  proc "c" (target: u32, image: rawptr),
	query_formats:   proc "c" (d: egl.Display, max: i32, formats: ^i32, n: ^i32) -> b32,
	query_modifiers: proc "c" (d: egl.Display, format: i32, max: i32, mods: ^u64, external_only: ^b32, n: ^i32) -> b32,
	vao, vbo:        u32,
	fill, tex, glass, dawn, down: Program,
	scene_fbo:       [3]u32, // full, half, quarter
	scene_tex:       [3]u32,
	sizes:           [3][2]i32,
	sw, sh:          i32, // the screen in pixels
	scale:           f32,
	pointer:         [2]f32, // logical, or -1
	/// where the finished frame goes: 0, the window (an offscreen check sets its own)
	target_fbo:      u32,
}

Program :: struct {
	id:   u32,
	locs: map[string]i32,
}

rnd: Renderer

// ---------------------------------------------------------------- shaders

VERT :: `#version 300 es
in vec2 a_pos;
uniform vec4 u_rect;   // x, y, w, h in pixels (top-left origin)
uniform vec2 u_screen;
out vec2 v_px;
void main() {
	vec2 p = u_rect.xy + a_pos * u_rect.zw;
	v_px = p;
	gl_Position = vec4(p.x / u_screen.x * 2.0 - 1.0, 1.0 - p.y / u_screen.y * 2.0, 0.0, 1.0);
}`

SDF :: `
uniform vec4 u_box;     // the shape: x, y, w, h in pixels
uniform float u_radius;
float sdf(vec2 p) {
	vec2 c = u_box.xy + u_box.zw * 0.5;
	vec2 q = abs(p - c) - (u_box.zw * 0.5 - vec2(u_radius));
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u_radius;
}
vec2 outward(vec2 p) {
	vec2 c = u_box.xy + u_box.zw * 0.5;
	vec2 d = p - c;
	vec2 q = abs(d) - (u_box.zw * 0.5 - vec2(u_radius));
	vec2 n = q.x > 0.0 && q.y > 0.0 ? normalize(q) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
	return n * sign(d + 1e-4);
}`

FILL_FRAG :: `#version 300 es
precision highp float;
in vec2 v_px;
out vec4 o;
uniform vec4 u_color;   // premultiplied, top
uniform vec4 u_color2;  // premultiplied, bottom
uniform float u_soft;   // > 0: a soft shadow of this blur
` + SDF + `
void main() {
	float d = sdf(v_px);
	float t = clamp((v_px.y - u_box.y) / max(u_box.w, 1.0), 0.0, 1.0);
	vec4 c = mix(u_color, u_color2, t);
	float a = u_soft > 0.0 ? 1.0 - smoothstep(-u_soft, u_soft, d) : clamp(0.5 - d, 0.0, 1.0);
	o = c * a;
}`

TEX_FRAG :: `#version 300 es
precision highp float;
in vec2 v_px;
out vec4 o;
uniform sampler2D u_tex;
uniform float u_alpha;
uniform float u_flip;   // 1: rows from the bottom (an FBO)
uniform float u_bgra;
uniform float u_premul;
` + SDF + `
void main() {
	vec2 uv = (v_px - u_box.xy) / u_box.zw;
	if (u_flip > 0.5) uv.y = 1.0 - uv.y;
	vec4 c = texture(u_tex, uv);
	if (u_bgra > 0.5) c = c.bgra;
	if (u_premul < 0.5) c.rgb *= c.a;
	float a = u_radius > 0.0 ? clamp(0.5 - sdf(v_px), 0.0, 1.0) : 1.0;
	o = c * (u_alpha * a);
}`

DAWN_FRAG :: `#version 300 es
precision highp float;
in vec2 v_px;
out vec4 o;
uniform vec2 u_screen;
void main() {
	vec2 uv = v_px / u_screen;
	// a dawn of lilac, rose and peach
	vec3 sky = mix(vec3(0.82, 0.80, 0.97), vec3(0.97, 0.86, 0.90), smoothstep(0.0, 0.7, uv.y));
	sky = mix(sky, vec3(1.0, 0.89, 0.80), smoothstep(0.55, 1.0, uv.y));
	vec2 sun = vec2(0.72, 0.86);
	float r = length((uv - sun) * vec2(u_screen.x / u_screen.y, 1.0));
	sky += vec3(1.0, 0.93, 0.82) * 0.35 * exp(-r * r * 9.0);
	o = vec4(sky, 1.0);
}`

DOWN_FRAG :: `#version 300 es
precision highp float;
in vec2 v_px;
out vec4 o;
uniform sampler2D u_tex;
uniform vec2 u_texel;   // one source pixel
uniform vec2 u_screen;
void main() {
	vec2 uv = vec2(v_px.x / u_screen.x, 1.0 - v_px.y / u_screen.y);
	vec4 c = texture(u_tex, uv) * 4.0;
	c += texture(u_tex, uv + vec2(-1.0, -1.0) * u_texel);
	c += texture(u_tex, uv + vec2( 1.0, -1.0) * u_texel);
	c += texture(u_tex, uv + vec2(-1.0,  1.0) * u_texel);
	c += texture(u_tex, uv + vec2( 1.0,  1.0) * u_texel);
	o = c / 8.0;
}`

GLASS_FRAG :: `#version 300 es
precision highp float;
in vec2 v_px;
out vec4 o;
uniform sampler2D u_scene;
uniform sampler2D u_blurred;
uniform vec2 u_screen;
uniform vec4 u_tint;      // straight alpha
uniform float u_bend;
uniform float u_rim;
uniform float u_lens;
uniform float u_frost;
uniform float u_shadow;
uniform float u_rimlight;
uniform float u_dispersion;
uniform vec2 u_pointer;   // pixels, or negative
uniform float u_scale;
` + SDF + `
vec3 behind(vec2 p) {
	vec2 uv = vec2(p.x / u_screen.x, 1.0 - p.y / u_screen.y);
	return mix(texture(u_scene, uv).rgb, texture(u_blurred, uv).rgb, u_frost);
}
void main() {
	float d = sdf(v_px);
	if (d > 0.5) {
		// the shadow under the glass: soft, a little below it, in the
		// dawn's violet (premultiplied)
		float ds = max(sdf(v_px - vec2(0.0, 3.0 * u_scale)), 0.0) / (9.0 * u_scale);
		float s = u_shadow * 0.085 * exp(-ds * ds) * smoothstep(0.0, 1.5, d);
		o = vec4(vec3(0.14, 0.11, 0.25) * s, s);
		return;
	}
	float inside = clamp(0.5 - d, 0.0, 1.0);
	vec2 c = u_box.xy + u_box.zw * 0.5;
	vec2 n = outward(v_px);
	float e = -d;                                      // depth from the edge
	float t = 1.0 - clamp(e / max(u_rim, 1.0), 0.0, 1.0);
	float pull = u_bend * t * t;                       // more towards the edge
	vec2 p = c + (v_px - c) * (1.0 - u_lens);          // the gentle lens
	vec3 col;
	if (u_dispersion > 0.5 && pull > 0.01) {
		col.r = behind(p + n * pull * 0.86).r;
		col.g = behind(p + n * pull).g;
		col.b = behind(p + n * pull * 1.14).b;
	} else {
		col = behind(p + n * pull);
	}
	col = mix(col, u_tint.rgb, u_tint.a);
	// light from above: a bright line inside the top rim, a soft glow, a
	// faint shade along the bottom
	float top = clamp(-n.y, 0.0, 1.0);
	float line = exp(-e / (1.2 * u_scale));
	col += vec3(1.0) * u_rimlight * (0.55 * line * (0.35 + 0.65 * top) + 0.10 * t * t);
	col -= vec3(0.05) * u_rimlight * line * clamp(n.y, 0.0, 1.0);
	if (u_pointer.x >= 0.0) {
		float r = length(v_px - u_pointer) / (80.0 * u_scale);
		col += vec3(1.0) * 0.10 * exp(-r * r);
	}
	o = vec4(col, 1.0) * inside;
}`

compile :: proc(frag: string, vert := VERT) -> Program {
	sh :: proc(kind: u32, src: string) -> u32 {
		s := gl.CreateShader(kind)
		cs := strings.clone_to_cstring(src, context.temp_allocator)
		gl.ShaderSource(s, 1, &cs, nil)
		gl.CompileShader(s)
		ok: i32
		gl.GetShaderiv(s, gl.COMPILE_STATUS, &ok)
		if ok == 0 {
			buf: [2048]u8
			n: i32
			gl.GetShaderInfoLog(s, len(buf), &n, &buf[0])
			panic(string(buf[:n]))
		}
		return s
	}
	p := gl.CreateProgram()
	gl.AttachShader(p, sh(gl.VERTEX_SHADER, vert))
	gl.AttachShader(p, sh(gl.FRAGMENT_SHADER, frag))
	gl.BindAttribLocation(p, 0, "a_pos")
	gl.LinkProgram(p)
	ok: i32
	gl.GetProgramiv(p, gl.LINK_STATUS, &ok)
	if ok == 0 do panic("a shader did not link")
	return {id = p}
}

loc :: proc(p: ^Program, name: string) -> i32 {
	if l, ok := p.locs[name]; ok do return l
	l := gl.GetUniformLocation(p.id, strings.clone_to_cstring(name, context.temp_allocator))
	p.locs[name] = l
	return l
}

renderer_init :: proc(d: egl.Display) {
	rnd.egl_display = d
	rnd.create_image = auto_cast egl.GetProcAddress("eglCreateImageKHR")
	rnd.destroy_image = auto_cast egl.GetProcAddress("eglDestroyImageKHR")
	rnd.target_texture = auto_cast egl.GetProcAddress("glEGLImageTargetTexture2DOES")
	rnd.query_formats = auto_cast egl.GetProcAddress("eglQueryDmaBufFormatsEXT")
	rnd.query_modifiers = auto_cast egl.GetProcAddress("eglQueryDmaBufModifiersEXT")
	rnd.fill = compile(FILL_FRAG)
	rnd.tex = compile(TEX_FRAG)
	rnd.glass = compile(GLASS_FRAG)
	rnd.dawn = compile(DAWN_FRAG)
	rnd.down = compile(DOWN_FRAG)
	quad := [8]f32{0, 0, 1, 0, 0, 1, 1, 1}
	gl.GenVertexArrays(1, &rnd.vao)
	gl.BindVertexArray(rnd.vao)
	gl.GenBuffers(1, &rnd.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, rnd.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad), &quad[0], gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)
	gl.GenFramebuffers(3, &rnd.scene_fbo[0])
	gl.GenTextures(3, &rnd.scene_tex[0])
	rnd.pointer = {-1, -1}
}

// ---------------------------------------------------------------- frames

/// starts a frame of sw × sh pixels: drawing goes into the scene
frame_begin :: proc(sw, sh: i32, scale: f64) {
	rnd.sw, rnd.sh, rnd.scale = sw, sh, f32(scale)
	for i in 0 ..< 3 {
		w, h := max(1, sw >> uint(i)), max(1, sh >> uint(i))
		if rnd.sizes[i] == {w, h} do continue
		rnd.sizes[i] = {w, h}
		gl.BindTexture(gl.TEXTURE_2D, rnd.scene_tex[i])
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rnd.scene_fbo[i])
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, rnd.scene_tex[i], 0)
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, rnd.scene_fbo[0])
	gl.Viewport(0, 0, sw, sh)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA) // premultiplied
	gl.ClearColor(0, 0, 0, 0)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.BindVertexArray(rnd.vao)
}

/// the scene is done: it is blurred, then drawn on screen
frame_scene_done :: proc() {
	for i in 1 ..< 3 {
		gl.BindFramebuffer(gl.FRAMEBUFFER, rnd.scene_fbo[i])
		w, h := rnd.sizes[i][0], rnd.sizes[i][1]
		gl.Viewport(0, 0, w, h)
		p := &rnd.down
		gl.UseProgram(p.id)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, rnd.scene_tex[i - 1])
		gl.Uniform1i(loc(p, "u_tex"), 0)
		gl.Uniform2f(loc(p, "u_texel"), 1 / f32(rnd.sizes[i - 1][0]), 1 / f32(rnd.sizes[i - 1][1]))
		gl.Uniform2f(loc(p, "u_screen"), f32(w), f32(h))
		gl.Uniform4f(loc(p, "u_rect"), 0, 0, f32(w), f32(h))
		gl.Disable(gl.BLEND)
		gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, rnd.target_fbo)
	gl.Viewport(0, 0, rnd.sw, rnd.sh)
	gl.Enable(gl.BLEND)
	draw_texture({id = rnd.scene_tex[0], w = rnd.sw, h = rnd.sh, premultiplied = true}, 0, 0, f32(rnd.sw) / rnd.scale, f32(rnd.sh) / rnd.scale, flip = true)
}

// ---------------------------------------------------------------- drawing (logical pixels)

@(private="file") common :: proc(p: ^Program, x, y, w, h: f32, margin: f32 = 0) {
	s := rnd.scale
	gl.UseProgram(p.id)
	m := margin * s
	gl.Uniform4f(loc(p, "u_rect"), x * s - m, y * s - m, w * s + 2 * m, h * s + 2 * m)
	gl.Uniform4f(loc(p, "u_box"), x * s, y * s, w * s, h * s)
	gl.Uniform2f(loc(p, "u_screen"), f32(rnd.sw), f32(rnd.sh))
}

draw_dawn :: proc() {
	p := &rnd.dawn
	gl.UseProgram(p.id)
	gl.Uniform4f(loc(p, "u_rect"), 0, 0, f32(rnd.sw), f32(rnd.sh))
	gl.Uniform2f(loc(p, "u_screen"), f32(rnd.sw), f32(rnd.sh))
	gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)
}

premul :: proc(c: [4]f32) -> [4]f32 { return {c.r * c.a, c.g * c.a, c.b * c.a, c.a} }

/// a rounded rectangle, one colour or top to bottom; soft > 0 makes it a shadow
draw_fill :: proc(x, y, w, h, radius: f32, top: [4]f32, bottom: Maybe([4]f32) = nil, soft: f32 = 0) {
	p := &rnd.fill
	common(p, x, y, w, h, soft * 2)
	a := premul(top)
	b := premul(bottom.? or_else top)
	gl.Uniform4f(loc(p, "u_color"), a.r, a.g, a.b, a.a)
	gl.Uniform4f(loc(p, "u_color2"), b.r, b.g, b.b, b.a)
	gl.Uniform1f(loc(p, "u_radius"), min(radius, min(w, h) / 2) * rnd.scale)
	gl.Uniform1f(loc(p, "u_soft"), soft * rnd.scale)
	gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)
}

draw_texture :: proc(t: Texture, x, y, w, h: f32, radius: f32 = 0, alpha: f32 = 1, flip := false) {
	if t.id == 0 do return
	p := &rnd.tex
	common(p, x, y, w, h)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, t.id)
	gl.Uniform1i(loc(p, "u_tex"), 0)
	gl.Uniform1f(loc(p, "u_alpha"), alpha)
	gl.Uniform1f(loc(p, "u_flip"), flip ? 1 : 0)
	gl.Uniform1f(loc(p, "u_bgra"), t.bgra ? 1 : 0)
	gl.Uniform1f(loc(p, "u_premul"), t.premultiplied ? 1 : 0)
	gl.Uniform1f(loc(p, "u_radius"), min(radius, min(w, h) / 2) * rnd.scale)
	gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)
}

/// Liquid Glass over what the scene has behind (x, y, w, h)
draw_glass :: proc(x, y, w, h: f32, g: Glass) {
	if w < 1 || h < 1 do return
	p := &rnd.glass
	s := rnd.scale
	common(p, x, y, w, h, g.shadow > 0 ? 18 : 1)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, rnd.scene_tex[0])
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, rnd.scene_tex[2])
	gl.Uniform1i(loc(p, "u_scene"), 0)
	gl.Uniform1i(loc(p, "u_blurred"), 1)
	gl.Uniform1f(loc(p, "u_radius"), min(g.radius, min(w, h) / 2) * s)
	gl.Uniform4f(loc(p, "u_tint"), g.tint.r, g.tint.g, g.tint.b, g.tint.a)
	gl.Uniform1f(loc(p, "u_bend"), g.bend * s)
	gl.Uniform1f(loc(p, "u_rim"), g.rim * s)
	gl.Uniform1f(loc(p, "u_lens"), g.lens)
	gl.Uniform1f(loc(p, "u_frost"), g.frost)
	gl.Uniform1f(loc(p, "u_shadow"), g.shadow)
	gl.Uniform1f(loc(p, "u_rimlight"), g.rim_light)
	gl.Uniform1f(loc(p, "u_dispersion"), g.dispersion ? 1 : 0)
	gl.Uniform1f(loc(p, "u_scale"), s)
	px := rnd.pointer.x >= 0 ? rnd.pointer * s : [2]f32{-1, -1}
	gl.Uniform2f(loc(p, "u_pointer"), px.x, px.y)
	gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4)
	gl.ActiveTexture(gl.TEXTURE0)
}

// ---------------------------------------------------------------- textures

/// a software frame (BGRA, premultiplied) into a texture
texture_upload :: proc(t: ^Texture, data: rawptr, w, h, stride: i32) {
	if t.id == 0 || !t.owned {
		gl.GenTextures(1, &t.id)
		t.owned = true
	}
	gl.BindTexture(gl.TEXTURE_2D, t.id)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, stride / 4)
	if t.w != w || t.h != h {
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)
	} else {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, data)
	}
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	t.w, t.h, t.bgra, t.premultiplied = w, h, true, true
}

/// a DMA-BUF from WebKit, as an EGL image and a texture over it
image_import :: proc(db: ^WPEBufferDMABuf) -> (Imported, bool) {
	EGL_LINUX_DMA_BUF_EXT :: 0x3270
	EGL_LINUX_DRM_FOURCC_EXT :: 0x3271
	EGL_IMAGE_PRESERVED_KHR :: 0x30D2
	FD := [4]i32{0x3272, 0x3275, 0x3278, 0x3440}
	OFFSET := [4]i32{0x3273, 0x3276, 0x3279, 0x3441}
	PITCH := [4]i32{0x3274, 0x3277, 0x327A, 0x3442}
	MOD_LO := [4]i32{0x3443, 0x3445, 0x3447, 0x3449}
	MOD_HI := [4]i32{0x3444, 0x3446, 0x3448, 0x344A}
	if rnd.create_image == nil || rnd.target_texture == nil do return {}, false
	b := cast(^WPEBuffer)db
	w, h := wpe_buffer_get_width(b), wpe_buffer_get_height(b)
	mod := wpe_buffer_dma_buf_get_modifier(db)
	a: [64]i32
	n := 0
	push :: proc(a: ^[64]i32, n: ^int, k, v: i32) {
		a[n^] = k
		a[n^ + 1] = v
		n^ += 2
	}
	push(&a, &n, egl.WIDTH, w)
	push(&a, &n, egl.HEIGHT, h)
	push(&a, &n, EGL_LINUX_DRM_FOURCC_EXT, i32(wpe_buffer_dma_buf_get_format(db)))
	planes := min(wpe_buffer_dma_buf_get_n_planes(db), 4)
	for i in 0 ..< planes {
		push(&a, &n, FD[i], wpe_buffer_dma_buf_get_fd(db, i))
		push(&a, &n, OFFSET[i], i32(wpe_buffer_dma_buf_get_offset(db, i)))
		push(&a, &n, PITCH[i], i32(wpe_buffer_dma_buf_get_stride(db, i)))
		if mod != DRM_FORMAT_MOD_INVALID {
			push(&a, &n, MOD_LO[i], i32(u32(mod & 0xffffffff)))
			push(&a, &n, MOD_HI[i], i32(u32(mod >> 32)))
		}
	}
	push(&a, &n, EGL_IMAGE_PRESERVED_KHR, 1)
	a[n] = egl.NONE
	img := rnd.create_image(rnd.egl_display, egl.NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nil, &a[0])
	if img == nil do return {}, false
	t: u32
	gl.GenTextures(1, &t)
	gl.BindTexture(gl.TEXTURE_2D, t)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	rnd.target_texture(gl.TEXTURE_2D, rawptr(img))
	return {image = img, tex = t, w = w, h = h}, true
}

image_free :: proc(im: Imported) {
	t := im.tex
	if t != 0 do gl.DeleteTextures(1, &t)
	if im.image != nil && rnd.destroy_image != nil do rnd.destroy_image(rnd.egl_display, im.image)
}

texture_free :: proc(t: ^Texture) {
	if t.owned && t.id != 0 do gl.DeleteTextures(1, &t.id)
	t^ = {}
}

/// a C string for one call (freed with the frame's temporary memory)
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

@(private="file") _m :: math.PI

// ---------------------------------------------------------------- clipping

@(private="file") clips: [dynamic][4]i32

/// what follows is drawn only inside r (logical pixels); clips nest
clip_push :: proc(r: [4]f32) {
	s := rnd.scale
	x0 := i32(math.floor(r.x * s))
	y0 := i32(math.floor(r.y * s))
	x1 := i32(math.ceil((r.x + r.z) * s))
	y1 := i32(math.ceil((r.y + r.w) * s))
	if len(clips) > 0 {
		p := clips[len(clips) - 1]
		x0, y0 = max(x0, p.x), max(y0, p.y)
		x1, y1 = min(x1, p.z), min(y1, p.w)
	}
	append(&clips, [4]i32{x0, y0, max(x0, x1), max(y0, y1)})
	apply_clip()
}

clip_pop :: proc() {
	if len(clips) > 0 do pop(&clips)
	apply_clip()
}

@(private="file") apply_clip :: proc() {
	if len(clips) == 0 {
		gl.Disable(gl.SCISSOR_TEST)
		return
	}
	c := clips[len(clips) - 1]
	gl.Enable(gl.SCISSOR_TEST)
	// GL counts rows from the bottom
	gl.Scissor(c.x, rnd.sh - c.w, c.z - c.x, c.w - c.y)
}
