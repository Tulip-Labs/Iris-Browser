// Iris's text: the desktop's UI font (fontconfig) with fallbacks for
// characters it lacks, shaped by HarfBuzz, each glyph's outline rasterised
// by Iris (raster.odin) at the screen's own pixels into one atlas, and
// drawn in one batch per string. Icons share the atlas (icons.odin).
package iris

import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:unicode/utf8"
import gl "vendor:OpenGL"

Weight :: enum u8 { Regular, Medium, Semibold, Bold, Heavy }

@(private="file") WEIGHTS := [Weight]f32{.Regular = 400, .Medium = 500, .Semibold = 600, .Bold = 700, .Heavy = 800}
@(private="file") FC_WEIGHTS := [Weight]string{.Regular = "regular", .Medium = "medium", .Semibold = "semibold", .Bold = "bold", .Heavy = "extrabold"}

@(private="file") Face :: struct {
	path:  string,
	index: u32,
	upem:  f32,
	hb:    [Weight]^hb_font_t,
	// the file holds the weight itself (a variable font) or it is a fixed one
}

@(private="file") Font_Set :: struct {
	faces: [dynamic]Face, // the UI font first, then fallbacks
	ready: bool,
}

@(private="file") fonts: Font_Set

/// where a glyph sits in the atlas
Atlas_Slot :: struct {
	x, y, w, h: i32, // pixels in the atlas
	ox, oy:     f32, // from the pen to the bitmap's top-left (device pixels)
}

@(private="file") Glyph_Key :: struct {
	face:   i32,
	glyph:  u32,
	size:   u16, // device pixels × 4
	weight: Weight,
}

Atlas :: struct {
	tex:            u32,
	size:           i32,
	shelf_x, shelf_y, shelf_h: i32,
	glyphs:         map[Glyph_Key]Atlas_Slot,
	icons:          map[Icon_Key]Atlas_Slot,
	prog:           Program,
	vao, vbo:       u32,
	verts:          [dynamic]f32,
	draw:           ^hb_draw_funcs_t,
	buf:            ^hb_buffer_t,
}

atlas: Atlas

ATLAS_SIZE :: 2048

TEXT_VERT :: `#version 300 es
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
uniform vec2 u_screen;
out vec2 v_uv;
void main() {
	v_uv = a_uv;
	gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
}`

TEXT_FRAG :: `#version 300 es
precision mediump float;
in vec2 v_uv;
out vec4 o;
uniform sampler2D u_atlas;
uniform vec4 u_color; // premultiplied
void main() {
	float a = texture(u_atlas, v_uv).r;
	o = u_color * pow(a, 0.85); // a touch darker at the edges: dark ink on light glass
}`

// ---------------------------------------------------------------- fonts

@(private="file") fc_file :: proc(p: ^FcPattern) -> (path: string, index: u32, ok: bool) {
	file: cstring
	if FcPatternGetString(p, "file", 0, &file) != FcResultMatch || file == nil do return
	idx: i32
	FcPatternGetInteger(p, "index", 0, &idx)
	return strings.clone(string(file)), u32(idx), true
}

@(private="file") hb_load :: proc(path: string, index: u32, w: Weight) -> ^hb_font_t {
	blob := hb_blob_create_from_file_or_fail(strings.clone_to_cstring(path, context.temp_allocator))
	if blob == nil do return nil
	face := hb_face_create(blob, index)
	hb_blob_destroy(blob)
	font := hb_font_create(face)
	hb_face_destroy(face)
	// a variable font takes the weight; a fixed one ignores it
	v := hb_variation_t{tag = 0x77676874, value = WEIGHTS[w]} // 'wght'
	hb_font_set_variations(font, &v, 1)
	return font
}

/// the UI font of the desktop and its fallbacks, each in the weights Iris uses
fonts_init :: proc() {
	if fonts.ready do return
	fonts.ready = true
	cfg := FcInitLoadConfigAndFonts()
	// the regular face of each font, sorted by fontconfig for "sans-serif"
	pat := FcNameParse("sans-serif:weight=regular")
	FcConfigSubstitute(cfg, pat, FcMatchPattern)
	FcDefaultSubstitute(pat)
	res: i32
	set := FcFontSort(cfg, pat, 1, nil, &res)
	FcPatternDestroy(pat)
	if set == nil do return
	defer FcFontSetDestroy(set)
	seen: map[string]bool
	defer delete(seen)
	for i in 0 ..< min(int(set.nfont), 12) {
		path, index, ok := fc_file(set.fonts[i])
		if !ok || path in seen do continue
		seen[path] = true
		f := Face{path = path, index = index}
		f.hb[.Regular] = hb_load(path, index, .Regular)
		if f.hb[.Regular] == nil do continue
		append(&fonts.faces, f)
	}
	// the other weights: the same family's own files where it has them
	if len(fonts.faces) == 0 do return
	main := &fonts.faces[0]
	for w in Weight {
		if w == .Regular do continue
		name := strings.concatenate({"sans-serif:weight=", FC_WEIGHTS[w]}, context.temp_allocator)
		p := FcNameParse(strings.clone_to_cstring(name, context.temp_allocator))
		FcConfigSubstitute(cfg, p, FcMatchPattern)
		FcDefaultSubstitute(p)
		s := FcFontSort(cfg, p, 1, nil, &res)
		FcPatternDestroy(p)
		path, index := main.path, main.index
		if s != nil {
			if s.nfont > 0 do if fp, fi, ok := fc_file(s.fonts[0]); ok do path, index = fp, fi
			FcFontSetDestroy(s)
		}
		main.hb[w] = hb_load(path, index, w)
	}
	for &f in fonts.faces {
		for w in Weight do if f.hb[w] == nil do f.hb[w] = f.hb[.Regular] == nil ? hb_load(f.path, f.index, w) : f.hb[.Regular]
	}
}

// ---------------------------------------------------------------- the atlas

text_init :: proc() {
	fonts_init()
	a := &atlas
	a.size = ATLAS_SIZE
	gl.GenTextures(1, &a.tex)
	gl.BindTexture(gl.TEXTURE_2D, a.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, a.size, a.size, 0, gl.RED, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	atlas_clear()
	a.prog = compile(TEXT_FRAG, TEXT_VERT)
	gl.GenVertexArrays(1, &a.vao)
	gl.BindVertexArray(a.vao)
	gl.GenBuffers(1, &a.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, a.vbo)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 16, 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 16, 8)
	gl.BindVertexArray(rnd.vao)
	a.buf = hb_buffer_create()
	d := hb_draw_funcs_create()
	hb_draw_funcs_set_move_to_func(d, proc "c" (df: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, x, y: f32, u: rawptr) {
		c := cast(^Outline)data
		c.start, c.pen = {x, y}, {x, y}
	}, nil, nil)
	hb_draw_funcs_set_line_to_func(d, proc "c" (df: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, x, y: f32, u: rawptr) {
		c := cast(^Outline)data
		outline_line(c, {x, y})
	}, nil, nil)
	hb_draw_funcs_set_quadratic_to_func(d, proc "c" (df: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, cx, cy, x, y: f32, u: rawptr) {
		c := cast(^Outline)data
		a, b, e := c.pen, [2]f32{cx, cy}, [2]f32{x, y}
		n := outline_steps(c, linalg.length(b - a) + linalg.length(e - b))
		for i in 1 ..= n {
			t := f32(i) / f32(n)
			s := 1 - t
			outline_line(c, s * s * a + 2 * s * t * b + t * t * e)
		}
	}, nil, nil)
	hb_draw_funcs_set_cubic_to_func(d, proc "c" (df: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, c1x, c1y, c2x, c2y, x, y: f32, u: rawptr) {
		c := cast(^Outline)data
		a, b, cc, e := c.pen, [2]f32{c1x, c1y}, [2]f32{c2x, c2y}, [2]f32{x, y}
		n := outline_steps(c, linalg.length(b - a) + linalg.length(cc - b) + linalg.length(e - cc))
		for i in 1 ..= n {
			t := f32(i) / f32(n)
			s := 1 - t
			outline_line(c, s * s * s * a + 3 * s * s * t * b + 3 * s * t * t * cc + t * t * t * e)
		}
	}, nil, nil)
	hb_draw_funcs_set_close_path_func(d, proc "c" (df: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, u: rawptr) {
		c := cast(^Outline)data
		if c.pen != c.start do outline_line(c, c.start)
	}, nil, nil)
	hb_draw_funcs_make_immutable(d)
	a.draw = d
}

/// a glyph's outline on its way into a raster (font units, y up)
@(private="file") Outline :: struct {
	r:          ^Raster,
	k:          f32, // font units to pixels
	off:        [2]f32,
	pen, start: [2]f32,
}

@(private="file") outline_line :: proc "contextless" (c: ^Outline, to: [2]f32) {
	// y up in the font, down in the raster
	a := [2]f32{c.pen.x * c.k + c.off.x, c.off.y - c.pen.y * c.k}
	b := [2]f32{to.x * c.k + c.off.x, c.off.y - to.y * c.k}
	context = {}
	raster_line(c.r, a, b)
	c.pen = to
}

@(private="file") outline_steps :: proc "contextless" (c: ^Outline, len_units: f32) -> int {
	return clamp(int(len_units * c.k / 1.5), 2, 24)
}

atlas_clear :: proc() {
	a := &atlas
	clear(&a.glyphs)
	clear(&a.icons)
	a.shelf_x, a.shelf_y, a.shelf_h = 1, 1, 0
}

/// room for a w × h bitmap (a new shelf when the row is full; the whole
/// atlas starts again when it is)
atlas_place :: proc(w, h: i32) -> (x, y: i32, ok: bool) {
	a := &atlas
	if w + 2 > a.size || h + 2 > a.size do return
	if a.shelf_x + w + 1 > a.size {
		a.shelf_x = 1
		a.shelf_y += a.shelf_h + 1
		a.shelf_h = 0
	}
	if a.shelf_y + h + 1 > a.size do return
	x, y = a.shelf_x, a.shelf_y
	a.shelf_x += w + 1
	a.shelf_h = max(a.shelf_h, h)
	return x, y, true
}

atlas_upload :: proc(x, y, w, h: i32, px: []u8) {
	gl.BindTexture(gl.TEXTURE_2D, atlas.tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RED, gl.UNSIGNED_BYTE, raw_data(px))
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
}

@(private="file") glyph_slot :: proc(face: int, glyph: u32, px: f32, w: Weight) -> (Atlas_Slot, bool) {
	key := Glyph_Key{i32(face), glyph, u16(px * 4), w}
	if s, ok := atlas.glyphs[key]; ok do return s, true
	f := &fonts.faces[face]
	font := f.hb[w]
	// the outline at this size, with a pixel of room around it
	k := px / font_upem(f)
	ext := hb_font_extents_t{}
	hb_font_get_h_extents(font, &ext)
	bw := i32(math.ceil(px * 2.2)) + 8 // room for the widest glyphs (CJK, ligatures)
	top := f32(ext.ascender) * k
	bh := i32(math.ceil(f32(ext.ascender - ext.descender) * k)) + 8
	bw = max(bw, 4)
	r := raster_make(int(bw), int(bh))
	o := Outline{r = &r, k = k, off = {4, top + 4}}
	hb_font_draw_glyph(font, glyph, atlas.draw, &o)
	cov := make([]u8, int(bw * bh), context.temp_allocator)
	raster_coverage(&r, cov)
	// trim the empty columns and rows
	x0, y0, x1, y1 := bw, bh, i32(-1), i32(-1)
	for y in 0 ..< bh do for x in 0 ..< bw do if cov[y * bw + x] != 0 {
		x0, y0 = min(x0, x), min(y0, y)
		x1, y1 = max(x1, x), max(y1, y)
	}
	slot := Atlas_Slot{ox = 0, oy = 0}
	if x1 >= x0 {
		w, h := x1 - x0 + 1, y1 - y0 + 1
		ax, ay, ok := atlas_place(w, h)
		if !ok {
			atlas_clear()
			ax, ay, ok = atlas_place(w, h)
			if !ok do return {}, false
		}
		trimmed := make([]u8, int(w * h), context.temp_allocator)
		for y in 0 ..< h do copy(trimmed[y * w:][:w], cov[(y0 + y) * bw + x0:][:w])
		atlas_upload(ax, ay, w, h, trimmed)
		slot = {x = ax, y = ay, w = w, h = h, ox = f32(x0) - 4, oy = f32(y0) - 4 - top}
	}
	atlas.glyphs[key] = slot
	return slot, true
}

@(private="file") font_upem :: proc(f: ^Face) -> f32 {
	if f.upem == 0 {
		// HarfBuzz's default scale is the face's units per em
		blob := hb_blob_create_from_file_or_fail(strings.clone_to_cstring(f.path, context.temp_allocator))
		if blob != nil {
			face := hb_face_create(blob, f.index)
			f.upem = f32(hb_face_get_upem(face))
			hb_face_destroy(face)
			hb_blob_destroy(blob)
		}
		if f.upem == 0 do f.upem = 1000
	}
	return f.upem
}

// ---------------------------------------------------------------- shaping

Shaped_Glyph :: struct {
	face:   int,
	glyph:  u32,
	x, y:   f32, // pen position, logical pixels
	adv:    f32,
	byte:   int, // where in the text it came from
}

Shaped :: struct {
	glyphs: [dynamic]Shaped_Glyph,
	width:  f32,
	size:   f32,
	weight: Weight,
}

/// the first face (the UI font, then the fallbacks) that has the character
@(private="file") face_for :: proc(r: rune) -> int {
	for &f, i in fonts.faces {
		g: u32
		if hb_font_get_nominal_glyph(f.hb[.Regular], u32(r), &g) != 0 do return i
	}
	return 0
}

/// text shaped at size (logical pixels), in runs of one face each
shape :: proc(text: string, size: f32, w: Weight = .Regular, allocator := context.temp_allocator) -> (s: Shaped) {
	s.glyphs = make([dynamic]Shaped_Glyph, allocator)
	s.size, s.weight = size, w
	if len(fonts.faces) == 0 || len(text) == 0 do return
	pen: f32
	i := 0
	for i < len(text) {
		r, n := utf8.decode_rune_in_string(text[i:])
		face := r == ' ' ? 0 : face_for(r)
		j := i + n
		for j < len(text) {
			r2, n2 := utf8.decode_rune_in_string(text[j:])
			if r2 != ' ' && r2 != 0x200d && r2 != 0xfe0f && face_for(r2) != face do break
			j += n2
		}
		f := &fonts.faces[face]
		font := f.hb[w]
		k := size / font_upem(f)
		buf := atlas.buf
		hb_buffer_clear_contents(buf)
		hb_buffer_add_utf8(buf, raw_data(text), i32(len(text)), u32(i), i32(j - i))
		hb_buffer_guess_segment_properties(buf)
		hb_shape(font, buf, nil, 0)
		count: u32
		infos := hb_buffer_get_glyph_infos(buf, &count)
		pos := hb_buffer_get_glyph_positions(buf, &count)
		for g in 0 ..< int(count) {
			adv := f32(pos[g].x_advance) * k
			append(&s.glyphs, Shaped_Glyph{face = face, glyph = infos[g].codepoint, x = pen + f32(pos[g].x_offset) * k, y = -f32(pos[g].y_offset) * k, adv = adv, byte = int(infos[g].cluster)})
			pen += adv
		}
		i = j
	}
	s.width = pen
	return
}

/// the width of text at size
text_width :: proc(text: string, size: f32, w: Weight = .Regular) -> f32 {
	return shape(text, size, w).width
}

/// the font's line: how far its top and bottom reach from the baseline
text_metrics :: proc(size: f32) -> (ascent, descent: f32) {
	if len(fonts.faces) == 0 do return size * 0.95, size * 0.25
	f := &fonts.faces[0]
	e := hb_font_extents_t{}
	hb_font_get_h_extents(f.hb[.Regular], &e)
	k := size / font_upem(f)
	return f32(e.ascender) * k, -f32(e.descender) * k
}

// ---------------------------------------------------------------- drawing

@(private="file") push_quad :: proc(x0, y0, x1, y1, u0, v0, u1, v1: f32) {
	append(&atlas.verts, x0, y0, u0, v0, x1, y0, u1, v0, x0, y1, u0, v1, x1, y0, u1, v0, x1, y1, u1, v1, x0, y1, u0, v1)
}

/// draws what was batched, in one colour
@(private="file") flush :: proc(color: [4]f32) {
	if len(atlas.verts) == 0 do return
	p := &atlas.prog
	gl.UseProgram(p.id)
	gl.BindVertexArray(atlas.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, atlas.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(atlas.verts) * 4, raw_data(atlas.verts), gl.STREAM_DRAW)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, atlas.tex)
	gl.Uniform1i(loc(p, "u_atlas"), 0)
	gl.Uniform2f(loc(p, "u_screen"), f32(rnd.sw), f32(rnd.sh))
	c := premul(color)
	gl.Uniform4f(loc(p, "u_color"), c.r, c.g, c.b, c.a)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(len(atlas.verts) / 4))
	clear(&atlas.verts)
	gl.BindVertexArray(rnd.vao)
}

/// shaped text with its baseline at (x, y), logical pixels; clipped to
/// max_w (and faded out at the end) when it is wider
draw_shaped :: proc(s: Shaped, x, y: f32, color: [4]f32, max_w: f32 = -1) {
	sc := rnd.scale
	px := s.size * sc
	// the pen on whole device pixels, so text is sharp at any scale
	bx := math.round(x * sc)
	by := math.round(y * sc)
	inv := 1 / f32(atlas.size)
	limit := max_w > 0 ? max_w * sc : max(f32)
	for g in s.glyphs {
		gx := g.x * sc
		if gx > limit do break
		slot, ok := glyph_slot(g.face, g.glyph, px, s.weight)
		if !ok || slot.w == 0 do continue
		x0 := math.round(bx + gx) + slot.ox
		y0 := by + g.y * sc + slot.oy
		x1 := x0 + f32(slot.w)
		y1 := y0 + f32(slot.h)
		u0, v0 := f32(slot.x) * inv, f32(slot.y) * inv
		u1, v1 := f32(slot.x + slot.w) * inv, f32(slot.y + slot.h) * inv
		if max_w > 0 && x1 > bx + limit {
			// the last glyph that fits only in part: cut at the limit
			cut := bx + limit
			if cut <= x0 do break
			u1 = u0 + (u1 - u0) * (cut - x0) / (x1 - x0)
			x1 = cut
		}
		push_quad(x0, y0, x1, y1, u0, v0, u1, v1)
	}
	flush(color)
}

/// text in one line with its baseline at (x, y); an ellipsis when wider
/// than max_w; returns its width
draw_text :: proc(text: string, x, y, size: f32, color: [4]f32, w: Weight = .Regular, max_w: f32 = -1) -> f32 {
	s := shape(text, size, w)
	if max_w > 0 && s.width > max_w {
		e := shape("…", size, w)
		cut := max_w - e.width
		n := 0
		for g, i in s.glyphs {
			if g.x + g.adv > cut do break
			n = i + 1
		}
		end := n < len(s.glyphs) ? s.glyphs[n].byte : len(text)
		trimmed := strings.trim_right_space(text[:end])
		s2 := shape(strings.concatenate({trimmed, "…"}, context.temp_allocator), size, w)
		draw_shaped(s2, x, y, color)
		return s2.width
	}
	draw_shaped(s, x, y, color)
	return s.width
}

/// text wrapped at max_w into lines (by words); the lines
wrap_text :: proc(text: string, size: f32, max_w: f32, w: Weight = .Regular) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	for para in strings.split(text, "\n", context.temp_allocator) {
		line_start := 0
		last_break := -1
		i := 0
		for i <= len(para) {
			at_end := i == len(para)
			if at_end || para[i] == ' ' {
				if text_width(para[line_start:i], size, w) > max_w && last_break > line_start {
					append(&lines, para[line_start:last_break])
					line_start = last_break + 1
				}
				last_break = i
			}
			if at_end do break
			i += 1
		}
		append(&lines, para[line_start:])
	}
	return lines[:]
}
