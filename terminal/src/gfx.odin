// Drawing: two programs. The glass is one full-window triangle (a
// translucent fill with a soft rim of light, rounded to the window's
// corners); everything else (cell backgrounds, text, the cursor, the
// chrome) is quads sampled from the atlas, in one buffer and one draw call.
// The window is a premultiplied-alpha surface: what is not drawn is clear.
package main

import "core:strings"
import gl "vendor:OpenGL"

Vertex :: struct {
	x, y, u, v: f32,
	r, g, b, a: u8,
}

Gfx :: struct {
	glass, quad:   u32,
	vao_g, vao_q:  u32,
	vbo:           u32,
	ready:         bool,
	verts:         [dynamic]Vertex,
	// uniforms
	g_size, g_bg, g_dark, g_radius, g_scale, g_rim, g_flash, g_fade, g_focus: i32,
	q_screen, q_atlas, q_gamma, q_fade: i32,
}

gfx: Gfx

GLASS_VERT :: `#version 300 es
void main() {
	vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`

// Clear liquid glass: a colourless translucent fill, a touch lighter
// toward the top (light from above), a thin rim of light along the edge
// that is brightest at the top, a soft glow just inside it, a faint
// highlight at the top left, and a little grain against banding. Outside
// the rounded corners nothing is drawn.
GLASS_FRAG :: `#version 300 es
precision highp float;
out vec4 o;
uniform vec2 u_size;
uniform vec4 u_bg;       // the glass's tint and how much of it there is
uniform float u_dark;
uniform float u_radius;
uniform float u_scale;
uniform float u_rim;
uniform float u_flash;
uniform float u_fade;
uniform float u_focus;

float rbox(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - (half_size - vec2(r));
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
	vec2 p = vec2(gl_FragCoord.x, u_size.y - gl_FragCoord.y);
	vec2 c = u_size * 0.5;
	float d = rbox(p - c, c, u_radius);
	float cover = clamp(0.5 - d, 0.0, 1.0);
	if (cover <= 0.0) { o = vec4(0.0); return; }
	vec2 uv = p / u_size;
	float inside = -d;
	vec3 white = vec3(1.0);
	vec3 edge = mix(vec3(0.0), white, u_dark);

	vec3 base = u_bg.rgb + vec3((1.0 - uv.y) * mix(0.012, 0.04, u_dark));
	vec4 col = vec4(base * u_bg.a, u_bg.a);

	// the sheen along the top
	float sheen = smoothstep(0.30, 0.0, uv.y) * mix(0.025, 0.05, u_dark);
	col = vec4(white * sheen + col.rgb * (1.0 - sheen), sheen + col.a * (1.0 - sheen));
	// a soft glow just inside the edge
	float glow = exp(-inside / (9.0 * u_scale)) * u_rim * 0.22 * (0.6 + 0.4 * u_focus);
	col = vec4(edge * glow + col.rgb * (1.0 - glow), glow + col.a * (1.0 - glow));
	// the rim: about one pixel of light at the edge, stronger toward the top
	float bw = max(1.0, u_scale);
	float line = clamp(1.0 - abs(inside - 0.5 * bw) / (0.9 * bw), 0.0, 1.0);
	float rim = line * u_rim * (0.30 + 0.70 * (1.0 - uv.y)) * (0.55 + 0.45 * u_focus);
	col = vec4(edge * rim + col.rgb * (1.0 - rim), rim + col.a * (1.0 - rim));
	// a highlight at the top left
	vec2 w = (p - vec2(u_size.x * 0.12, 0.0)) / (u_size.y * 0.5);
	float hl = exp(-dot(w, w) * 3.0) * mix(0.02, 0.06, u_dark);
	col = vec4(white * hl + col.rgb * (1.0 - hl), hl + col.a * (1.0 - hl));
	// the bell: a flash of light (or of shade) over everything
	float fl = u_flash * 0.16;
	col = vec4(edge * fl + col.rgb * (1.0 - fl), fl + col.a * (1.0 - fl));
	// grain
	float g = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
	col.rgb += g * (1.5 / 255.0) * col.a;
	o = col * cover * u_fade;
}`

QUAD_VERT :: `#version 300 es
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_col;
uniform vec2 u_screen;
out vec2 v_uv;
out vec4 v_col;
void main() {
	v_uv = a_uv;
	v_col = a_col;
	gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
}`

QUAD_FRAG :: `#version 300 es
precision highp float;
in vec2 v_uv;
in vec4 v_col;
out vec4 o;
uniform sampler2D u_atlas;
uniform float u_gamma;
uniform float u_fade;
void main() {
	float a = texture(u_atlas, v_uv).r;
	a = pow(a, u_gamma) * v_col.a;
	o = vec4(v_col.rgb * a, a) * u_fade;
}`

@(private="file") compile_shader :: proc(kind: u32, src: string) -> (u32, bool) {
	s := gl.CreateShader(kind)
	cs := strings.clone_to_cstring(src, context.temp_allocator)
	gl.ShaderSource(s, 1, &cs, nil)
	gl.CompileShader(s)
	ok: i32
	gl.GetShaderiv(s, gl.COMPILE_STATUS, &ok)
	if ok == 0 {
		buf: [1024]u8
		n: i32
		gl.GetShaderInfoLog(s, len(buf), &n, &buf[0])
		logf("shader: %s", string(buf[:n]))
		return 0, false
	}
	return s, true
}

@(private="file") make_program :: proc(vs_src, fs_src: string) -> (u32, bool) {
	vs, ok1 := compile_shader(gl.VERTEX_SHADER, vs_src)
	fs, ok2 := compile_shader(gl.FRAGMENT_SHADER, fs_src)
	if !ok1 || !ok2 do return 0, false
	p := gl.CreateProgram()
	gl.AttachShader(p, vs)
	gl.AttachShader(p, fs)
	gl.LinkProgram(p)
	ok: i32
	gl.GetProgramiv(p, gl.LINK_STATUS, &ok)
	gl.DeleteShader(vs)
	gl.DeleteShader(fs)
	return p, ok != 0
}

/// the programs and buffers (once the surface is current)
gfx_init :: proc() -> bool {
	if gfx.ready do return true
	g, okg := make_program(GLASS_VERT, GLASS_FRAG)
	q, okq := make_program(QUAD_VERT, QUAD_FRAG)
	if !okg || !okq do return false
	gfx.glass, gfx.quad = g, q
	u :: proc(p: u32, n: cstring) -> i32 { return gl.GetUniformLocation(p, n) }
	gfx.g_size, gfx.g_bg, gfx.g_dark, gfx.g_radius = u(g, "u_size"), u(g, "u_bg"), u(g, "u_dark"), u(g, "u_radius")
	gfx.g_scale, gfx.g_rim, gfx.g_flash, gfx.g_fade, gfx.g_focus = u(g, "u_scale"), u(g, "u_rim"), u(g, "u_flash"), u(g, "u_fade"), u(g, "u_focus")
	gfx.q_screen, gfx.q_atlas, gfx.q_gamma, gfx.q_fade = u(q, "u_screen"), u(q, "u_atlas"), u(q, "u_gamma"), u(q, "u_fade")
	gl.GenVertexArrays(1, &gfx.vao_g)
	gl.GenVertexArrays(1, &gfx.vao_q)
	gl.GenBuffers(1, &gfx.vbo)
	gl.BindVertexArray(gfx.vao_q)
	gl.BindBuffer(gl.ARRAY_BUFFER, gfx.vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(Vertex), 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Vertex), 8)
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, size_of(Vertex), 16)
	gl.BindVertexArray(0)
	atlas_init()
	gfx.ready = true
	return true
}

Glass_Params :: struct {
	w, h:   f32,
	tint:   [3]f32,
	alpha:  f32,
	dark:   bool,
	radius: f32,
	scale:  f32,
	rim:    f32,
	flash:  f32,
	fade:   f32,
	focus:  bool,
}

draw_glass :: proc(p: Glass_Params) {
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	gl.UseProgram(gfx.glass)
	gl.BindVertexArray(gfx.vao_g)
	gl.Uniform2f(gfx.g_size, p.w, p.h)
	gl.Uniform4f(gfx.g_bg, p.tint.r, p.tint.g, p.tint.b, p.alpha)
	gl.Uniform1f(gfx.g_dark, p.dark ? 1 : 0)
	gl.Uniform1f(gfx.g_radius, p.radius)
	gl.Uniform1f(gfx.g_scale, p.scale)
	gl.Uniform1f(gfx.g_rim, p.rim)
	gl.Uniform1f(gfx.g_flash, p.flash)
	gl.Uniform1f(gfx.g_fade, p.fade)
	gl.Uniform1f(gfx.g_focus, p.focus ? 1 : 0)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.BindVertexArray(0)
}

/// draws the quads collected in gfx.verts
draw_quads :: proc(w, h: f32, gamma, fade: f32) {
	if len(gfx.verts) == 0 do return
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	gl.UseProgram(gfx.quad)
	gl.BindVertexArray(gfx.vao_q)
	gl.BindBuffer(gl.ARRAY_BUFFER, gfx.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(gfx.verts) * size_of(Vertex), raw_data(gfx.verts), gl.STREAM_DRAW)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, atlas.tex)
	gl.Uniform1i(gfx.q_atlas, 0)
	gl.Uniform2f(gfx.q_screen, w, h)
	gl.Uniform1f(gfx.q_gamma, gamma)
	gl.Uniform1f(gfx.q_fade, fade)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(gfx.verts)))
	gl.BindVertexArray(0)
	clear(&gfx.verts)
}

/// one quad: the atlas rectangle `s` (or part of it) at x, y with size w × h
push_quad :: proc(x, y, w, h: f32, s: Atlas_Slot, col: [4]u8) {
	if w <= 0 || h <= 0 do return
	iw, ih := 1 / f32(atlas.w), 1 / f32(atlas.h)
	u0, v0 := f32(s.x) * iw, f32(s.y) * ih
	u1, v1 := f32(s.x + s.w) * iw, f32(s.y + s.h) * ih
	push_uv(x, y, x + w, y + h, u0, v0, u1, v1, col)
}

push_uv :: proc(x0, y0, x1, y1, u0, v0, u1, v1: f32, c: [4]u8) {
	append(&gfx.verts,
		Vertex{x0, y0, u0, v0, c.r, c.g, c.b, c.a}, Vertex{x1, y0, u1, v0, c.r, c.g, c.b, c.a}, Vertex{x0, y1, u0, v1, c.r, c.g, c.b, c.a},
		Vertex{x1, y0, u1, v0, c.r, c.g, c.b, c.a}, Vertex{x1, y1, u1, v1, c.r, c.g, c.b, c.a}, Vertex{x0, y1, u0, v1, c.r, c.g, c.b, c.a})
}

/// a solid rectangle (the middle of the white block, so no neighbour bleeds in)
push_rect :: proc(x, y, w, h: f32, col: [4]u8) {
	if w <= 0 || h <= 0 || col.a == 0 do return
	iw, ih := 1 / f32(atlas.w), 1 / f32(atlas.h)
	cx, cy := (f32(atlas.white.x) + 2) * iw, (f32(atlas.white.y) + 2) * ih
	push_uv(x, y, x + w, y + h, cx, cy, cx, cy, col)
}
