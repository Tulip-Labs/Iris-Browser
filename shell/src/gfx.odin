// Drawing: one EGL context and one program for every output. A frame is one
// full-screen triangle: the graphite or white glass, the Iris ring of
// colour, and the halo (the reflection) of each window.
package shell

import "core:strings"
import "vendor:egl"
import gl "vendor:OpenGL"
import wl "../wl"
import "../logic"

EGL_PLATFORM_WAYLAND_KHR :: 0x31D8

Gfx :: struct {
	display: egl.Display,
	config:  egl.Config,
	context_: egl.Context,
	program: u32,
	vao:     u32,
	loc:     struct { size, buf, dark, n, rect, tint: i32 },
	ready:   bool,
}

gfx: Gfx

VERT :: `#version 300 es
void main() {
	vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`

// The picture. Light from above, like the Iris icon: a clear glass ring
// whose spectrum gathers at its lower rim (red, orange, yellow, green, cyan,
// blue, then back through a warm white: never magenta or violet), on a
// colourless graphite (or white) ground. Behind each window a soft halo of
// that window's colour: strongest along its border, as if the glass
// reflected it, fading out across the gap and beyond. A little grain
// (mica) keeps the gradients from banding.
FRAG :: `#version 300 es
precision highp float;
out vec4 o;
uniform vec2 u_size;     // the output, logical pixels
uniform vec2 u_buf;      // the buffer, pixels
uniform float u_dark;    // 0 light, 1 dark
uniform int u_n;
uniform vec4 u_rect[16]; // x, y, w, h of each window
uniform vec4 u_tint[16]; // its colour, and how much it shows

vec3 hsv(float h, float s, float v) {
	vec3 k = clamp(abs(mod(h * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return v * mix(vec3(1.0), k, s);
}
vec3 spectrum(float h) {
	const float span = 0.84;
	vec3 blue = hsv(220.0 / 360.0, 0.55, 1.0);
	vec3 warm = vec3(1.0, 0.97, 0.92);
	vec3 red = hsv(0.0, 0.55, 1.0);
	if (h < span) return hsv(h / span * (220.0 / 360.0), 0.55, 1.0);
	float q = (h - span) / (1.0 - span);
	return q < 0.5 ? mix(blue, warm, q * 2.0) : mix(warm, red, q * 2.0 - 1.0);
}
float sq(float x) { return x * x; }
float rbox(vec2 p, vec4 r, float rad) {
	vec2 c = r.xy + r.zw * 0.5;
	vec2 q = abs(p - c) - (r.zw * 0.5 - vec2(rad));
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}
void main() {
	vec2 p = vec2(gl_FragCoord.x, u_buf.y - gl_FragCoord.y) / u_buf * u_size;
	vec2 uv = p / u_size;
	float m = min(u_size.x, u_size.y);
	// the ground: colourless, a very faint bloom of light
	vec3 top = mix(vec3(0.961, 0.965, 0.973), vec3(0.043, 0.047, 0.055), u_dark);
	vec3 bottom = mix(vec3(0.925, 0.933, 0.949), vec3(0.082, 0.090, 0.106), u_dark);
	vec3 col = mix(top, bottom, smoothstep(0.0, 1.0, uv.y));
	float br = length((uv - vec2(0.5, 0.38)) * vec2(u_size.x / u_size.y, 1.0));
	col += vec3(1.0, 0.995, 0.985) * mix(0.035, 0.03, u_dark) * exp(-br * br * 2.2);

	// the Iris ring: a clear glass band with the spectrum in it
	vec2 c = u_size * vec2(0.5, 0.47);
	float R = m * 0.27;
	float half_w = m * 0.055;
	vec2 d = p - c;
	float r = length(d);
	float h = fract(atan(d.y, d.x) / 6.2831853 + 0.5);
	float lower = smoothstep(-0.35, 1.0, d.y / max(r, 1.0));      // gathered at the lower rim
	float band = exp(-sq((r - R) / half_w));
	float glow = exp(-sq((r - R) / (half_w * 3.2)));
	float sa = mix(0.30, 0.62, u_dark) * (0.30 + 0.70 * lower);
	col = mix(col, spectrum(h), clamp(band * sa, 0.0, 1.0));
	col += spectrum(h) * glow * mix(0.03, 0.10, u_dark) * (0.3 + 0.7 * lower);
	// the glass: a veil of white over the ring, lit along its rims from above
	float veil = exp(-sq((r - R) / (half_w * 1.15)));
	col += vec3(1.0) * veil * mix(0.10, 0.025, u_dark);
	float up = clamp(-d.y / max(r, 1.0), 0.0, 1.0);
	float rim = exp(-sq((abs(r - R) - half_w * 1.05) / (m * 0.006)));
	col += vec3(1.0) * rim * (0.05 + 0.10 * up) * mix(1.6, 1.0, u_dark);

	// each window's reflection, in the gaps
	for (int i = 0; i < 16; i++) {
		if (i >= u_n) break;
		float dd = rbox(p, u_rect[i], 18.0);
		if (dd <= 0.0) continue;                              // the window covers it
		float power = u_tint[i].a;
		vec3 t = mix(u_tint[i].rgb, vec3(1.0), 0.18);
		float near_rim = exp(-dd / 5.0);                      // the reflection on the border
		float halo = 0.55 * exp(-dd / 34.0) + 0.20 * exp(-dd / 120.0);
		float k = (0.65 * near_rim + halo) * power;
		col = mix(col + t * k * 0.30 * u_dark, mix(col, t, 0.30 * k), 1.0 - u_dark);
	}
	// mica: a little grain
	float g = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
	col += g * (2.0 / 255.0);
	o = vec4(clamp(col, 0.0, 1.0), 1.0);
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

/// EGL on the Wayland display, one context. false: no GLES 3 here.
gfx_init :: proc(d: ^wl.Wl_Display) -> bool {
	gfx.display = egl.GetPlatformDisplay(egl.Platform(EGL_PLATFORM_WAYLAND_KHR), d, nil)
	if gfx.display == nil do return false
	major, minor: i32
	if !egl.Initialize(gfx.display, &major, &minor) do return false
	egl.BindAPI(egl.OPENGL_ES_API)
	attrs := [?]i32{
		egl.SURFACE_TYPE, egl.WINDOW_BIT,
		egl.RENDERABLE_TYPE, egl.OPENGL_ES3_BIT,
		egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.ALPHA_SIZE, 0, // opaque: no alpha plane
		egl.NONE,
	}
	n: i32
	if !egl.ChooseConfig(gfx.display, &attrs[0], &gfx.config, 1, &n) || n < 1 do return false
	cattrs := [?]i32{egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE}
	gfx.context_ = egl.CreateContext(gfx.display, gfx.config, egl.NO_CONTEXT, &cattrs[0])
	return gfx.context_ != nil
}

/// the program, compiled once a surface is current
@(private="file") gfx_program :: proc() -> bool {
	if gfx.ready do return true
	gl.load_gles_up_to(3, 0, egl.gl_set_proc_address)
	vs, ok1 := compile_shader(gl.VERTEX_SHADER, VERT)
	fs, ok2 := compile_shader(gl.FRAGMENT_SHADER, FRAG)
	if !ok1 || !ok2 do return false
	gfx.program = gl.CreateProgram()
	gl.AttachShader(gfx.program, vs)
	gl.AttachShader(gfx.program, fs)
	gl.LinkProgram(gfx.program)
	ok: i32
	gl.GetProgramiv(gfx.program, gl.LINK_STATUS, &ok)
	if ok == 0 do return false
	gl.DeleteShader(vs)
	gl.DeleteShader(fs)
	u :: proc(name: cstring) -> i32 { return gl.GetUniformLocation(gfx.program, name) }
	gfx.loc = {u("u_size"), u("u_buf"), u("u_dark"), u("u_n"), u("u_rect"), u("u_tint")}
	gl.GenVertexArrays(1, &gfx.vao)
	gfx.ready = true
	return true
}

gfx_make_surface :: proc(w: ^wl.Egl_Window) -> egl.Surface {
	return egl.CreatePlatformWindowSurface(gfx.display, gfx.config, w, nil)
}

/// draws `f` into the surface (logical size w × h, buffer bw × bh) and swaps
gfx_draw :: proc(surface: egl.Surface, f: ^logic.Frame, w, h, bw, bh: i32) -> bool {
	if !egl.MakeCurrent(gfx.display, surface, surface, gfx.context_) do return false
	if !gfx_program() do return false
	egl.SwapInterval(gfx.display, 0) // frames are paced by the animation, not by the screen
	gl.Viewport(0, 0, bw, bh)
	gl.UseProgram(gfx.program)
	gl.BindVertexArray(gfx.vao)
	gl.Uniform2f(gfx.loc.size, f32(w), f32(h))
	gl.Uniform2f(gfx.loc.buf, f32(bw), f32(bh))
	gl.Uniform1f(gfx.loc.dark, f.dark)
	rects: [logic.MAX_HALOS][4]f32
	tints: [logic.MAX_HALOS][4]f32
	for i in 0 ..< f.n {
		hl := f.halos[i]
		rects[i] = {hl.rect.x, hl.rect.y, hl.rect.w, hl.rect.h}
		tints[i] = {hl.tint.r, hl.tint.g, hl.tint.b, hl.power}
	}
	gl.Uniform1i(gfx.loc.n, i32(f.n))
	gl.Uniform4fv(gfx.loc.rect, logic.MAX_HALOS, &rects[0][0])
	gl.Uniform4fv(gfx.loc.tint, logic.MAX_HALOS, &tints[0][0])
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	return bool(egl.SwapBuffers(gfx.display, surface))
}
