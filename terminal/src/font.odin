// The terminal's fonts and glyph atlas. Fonts come from fontconfig (the
// families of the `font` setting, in order, then the built-in DejaVu Sans
// Mono, then whatever fontconfig offers for what is still missing), are
// shaped by HarfBuzz (ligatures), and each glyph's outline is rasterised
// here at the screen's own pixels into one atlas. The cell is a whole
// number of device pixels, so text is sharp at any scale.
package main

import "core:math"
import "core:strings"
import gl "vendor:OpenGL"
import term "../term"

EMBEDDED_FONT :: #load("../assets/DejaVuSansMono.ttf")

Style :: enum u8 { Regular, Bold, Italic, Bold_Italic }

Slot :: struct {
	hb:           ^hb_font_t,
	path:         string, // "" for the built in
	index:        u32,
	upem:         f32,
	id:           i32, // unique: the atlas key
	synth_bold:   bool,
	synth_italic: bool,
	ok:           bool,
	tried:        bool,
}

Family :: struct {
	name:  string,
	slots: [Style]Slot,
	/// a fallback found by fontconfig, loaded when a character needs it
	lazy:  bool,
	path:  string,
	index: u32,
	loaded: bool,
}

Fonts :: struct {
	cfg:        ^FcConfig,
	fams:       [dynamic]Family,
	next_id:    i32,
	draw:       ^hb_draw_funcs_t,
	buf:        ^hb_buffer_t,
	ligatures:  bool,
	// the size
	px:         f32,
	cell_w, cell_h, baseline: int,
	ul_pos, ul_th, strike_pos: int,
	/// which family has a character: -1 none (cached)
	cache:      map[rune]i16,
	// the primary font has the powerline and Nerd Font symbols
	nerd:       bool,
	described:  [dynamic]string,
}

fonts: Fonts

Glyph_Key :: struct {
	slot:  i32,
	gid:   u32,
	size:  i32,
	synth: u8,
}

Special_Key :: struct {
	r:    rune,
	w, h: i32,
	kind: u8, // 0 a special character, 1 a pill (w, h, radius in r)
}

Atlas_Slot :: struct {
	x, y, w, h: i32,
	ox, oy:     f32, // from the pen (on the baseline) to the bitmap's top left
}

Atlas :: struct {
	tex:          u32,
	w, h:         i32,
	shelf_x, shelf_y, shelf_h: i32,
	glyphs:       map[Glyph_Key]Atlas_Slot,
	specials:     map[Special_Key]Atlas_Slot,
	white:        Atlas_Slot, // a solid texel block, for rectangles
	glow:         Atlas_Slot, // a soft round blob, for the cursor's glow
	full:         bool,
}

atlas: Atlas

ATLAS_W :: 2048
ATLAS_H :: 1024

// ---------------------------------------------------------------- loading

@(private="file") hb_tag :: proc(a, b, c, d: u8) -> u32 {
	return u32(a) << 24 | u32(b) << 16 | u32(c) << 8 | u32(d)
}

@(private="file") fc_file :: proc(p: ^FcPattern) -> (path: string, index: u32, ok: bool) {
	file: cstring
	if FcPatternGetString(p, "file", 0, &file) != FcResultMatch || file == nil do return
	idx: i32
	FcPatternGetInteger(p, "index", 0, &idx)
	return strings.clone(string(file)), u32(idx), true
}

@(private="file") hb_from_path :: proc(path: string, index: u32) -> (^hb_font_t, f32) {
	blob := hb_blob_create_from_file_or_fail(strings.clone_to_cstring(path, context.temp_allocator))
	if blob == nil do return nil, 0
	face := hb_face_create(blob, index)
	hb_blob_destroy(blob)
	upem := f32(hb_face_get_upem(face))
	font := hb_font_create(face)
	hb_face_destroy(face)
	return font, upem == 0 ? 1000 : upem
}

@(private="file") hb_from_memory :: proc(data: []u8) -> (^hb_font_t, f32) {
	blob := hb_blob_create(raw_data(data), u32(len(data)), HB_MEMORY_MODE_READONLY, nil, nil)
	if blob == nil do return nil, 0
	face := hb_face_create(blob, 0)
	hb_blob_destroy(blob)
	upem := f32(hb_face_get_upem(face))
	font := hb_font_create(face)
	hb_face_destroy(face)
	return font, upem == 0 ? 1000 : upem
}

@(private="file") new_slot :: proc(font: ^hb_font_t, upem: f32, path: string, index: u32) -> Slot {
	fonts.next_id += 1
	return {hb = font, upem = upem, path = path, index = index, id = fonts.next_id, ok = font != nil, tried = true}
}

@(private="file") STYLE_PATTERN := [Style]string{
	.Regular = ":weight=regular:slant=roman", .Bold = ":weight=bold:slant=roman",
	.Italic = ":weight=regular:slant=italic", .Bold_Italic = ":weight=bold:slant=italic",
}

/// the file fontconfig has for a family in a style; ok only when it is that family
@(private="file") fc_family_file :: proc(name: string, style: Style) -> (path: string, index: u32, ok: bool) {
	pat := FcNameParse(strings.clone_to_cstring(strings.concatenate({name, STYLE_PATTERN[style]}, context.temp_allocator), context.temp_allocator))
	if pat == nil do return
	defer FcPatternDestroy(pat)
	FcConfigSubstitute(fonts.cfg, pat, FcMatchPattern)
	FcDefaultSubstitute(pat)
	res: i32
	m := FcFontMatch(fonts.cfg, pat, &res)
	if m == nil do return
	defer FcPatternDestroy(m)
	// fontconfig always answers: only a font of the family asked for counts
	found := false
	for i in 0 ..< i32(8) {
		fam: cstring
		if FcPatternGetString(m, "family", i, &fam) != FcResultMatch do break
		if strings.equal_fold(string(fam), name) do found = true
	}
	if !found do return
	return fc_file(m)
}

/// loads a style of a family (regular first: the others look for their own
/// file, or make bold and italic from the regular one)
@(private="file") slot_load :: proc(f: ^Family, s: Style) {
	sl := &f.slots[s]
	if sl.tried do return
	sl.tried = true
	if f.lazy {
		if f.path == "" do return
		font, upem := hb_from_path(f.path, f.index)
		if font == nil do return
		sl^ = new_slot(font, upem, f.path, f.index)
		if s != .Regular {
			sl.synth_bold = s == .Bold || s == .Bold_Italic
			sl.synth_italic = s == .Italic || s == .Bold_Italic
		}
		return
	}
	if f.path == "builtin" {
		font, upem := hb_from_memory(EMBEDDED_FONT)
		if font == nil do return
		sl^ = new_slot(font, upem, "", 0)
		sl.synth_bold = s == .Bold || s == .Bold_Italic
		sl.synth_italic = s == .Italic || s == .Bold_Italic
		return
	}
	reg := &f.slots[.Regular]
	if s != .Regular {
		if path, idx, ok := fc_family_file(f.name, s); ok && path != reg.path {
			if font, upem := hb_from_path(path, idx); font != nil {
				sl^ = new_slot(font, upem, path, idx)
				return
			}
		}
		// no file of its own: the regular one, thickened or slanted
		if reg.ok {
			sl^ = reg^
			sl.synth_bold = s == .Bold || s == .Bold_Italic
			sl.synth_italic = s == .Italic || s == .Bold_Italic
			sl.tried = true
		}
		return
	}
	path, idx, ok := fc_family_file(f.name, .Regular)
	if !ok do return
	font, upem := hb_from_path(path, idx)
	if font == nil do return
	sl^ = new_slot(font, upem, path, idx)
}

@(private="file") family_slot :: proc(fi: int, s: Style) -> ^Slot {
	f := &fonts.fams[fi]
	if !f.slots[.Regular].tried do slot_load(f, .Regular)
	if !f.slots[s].tried do slot_load(f, s)
	if f.slots[s].ok do return &f.slots[s]
	if f.slots[.Regular].ok do return &f.slots[.Regular]
	return nil
}

/// the families of the setting that are installed, the built in one, and the
/// fallbacks fontconfig knows; `families` are names from the `font` setting
fonts_init :: proc(families: []string, ligatures: bool) {
	fonts.ligatures = ligatures
	if fonts.cfg == nil {
		fonts.cfg = FcInitLoadConfigAndFonts()
		fonts.buf = hb_buffer_create()
		fonts.draw = make_draw_funcs()
	}
	// forget the old
	clear(&fonts.cache)
	clear(&fonts.fams)
	clear(&fonts.described)
	for name in families {
		if strings.equal_fold(name, "DejaVu Sans Mono") do continue // (the built in one is the same font)
		f := Family{name = strings.clone(name)}
		slot_load(&f, .Regular)
		if f.slots[.Regular].ok {
			append(&fonts.fams, f)
			append(&fonts.described, strings.clone(strings.concatenate({name, ": ", f.slots[.Regular].path}, context.temp_allocator)))
		} else {
			append(&fonts.described, strings.clone(strings.concatenate({name, ": not installed"}, context.temp_allocator)))
		}
	}
	// the built in DejaVu Sans Mono (the same family when it is installed)
	b := Family{name = "DejaVu Sans Mono", path = "builtin"}
	slot_load(&b, .Regular)
	append(&fonts.fams, b)
	append(&fonts.described, "DejaVu Sans Mono: built in")
	// what fontconfig offers for the characters still missing: monospace, then sans
	seen := make(map[string]bool, context.temp_allocator)
	for fam in fonts.fams do if fam.slots[.Regular].path != "" do seen[fam.slots[.Regular].path] = true
	for pattern in ([2]cstring{"monospace", "sans-serif"}) {
		pat := FcNameParse(pattern)
		FcConfigSubstitute(fonts.cfg, pat, FcMatchPattern)
		FcDefaultSubstitute(pat)
		res: i32
		set := FcFontSort(fonts.cfg, pat, 1, nil, &res)
		FcPatternDestroy(pat)
		if set == nil do continue
		for i in 0 ..< min(int(set.nfont), 10) {
			path, index, ok := fc_file(set.fonts[i])
			if !ok || path in seen {
				continue
			}
			seen[path] = true
			append(&fonts.fams, Family{name = path, lazy = true, path = path, index = index})
		}
		FcFontSetDestroy(set)
	}
	// does the main font have the powerline and Nerd Font symbols?
	if len(fonts.fams) > 0 {
		fonts.nerd = false
		if fi := font_for_rune(0xe0b0); fi >= 0 && fi == 0 {
			if fj := font_for_rune(0xf07c); fj == 0 do fonts.nerd = true
		}
	}
}

/// what was found, for `iris-terminal --fonts`
fonts_describe :: proc() -> []string { return fonts.described[:] }

@(private="file") make_draw_funcs :: proc() -> ^hb_draw_funcs_t {
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
		n := outline_steps(c, dist2(a, b) + dist2(b, e))
		for i in 1 ..= n {
			t := f32(i) / f32(n)
			s := 1 - t
			outline_line(c, s * s * a + 2 * s * t * b + t * t * e)
		}
	}, nil, nil)
	hb_draw_funcs_set_cubic_to_func(d, proc "c" (df: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, c1x, c1y, c2x, c2y, x, y: f32, u: rawptr) {
		c := cast(^Outline)data
		a, b, cc, e := c.pen, [2]f32{c1x, c1y}, [2]f32{c2x, c2y}, [2]f32{x, y}
		n := outline_steps(c, dist2(a, b) + dist2(b, cc) + dist2(cc, e))
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
	return d
}

@(private="file") dist2 :: proc "contextless" (a, b: [2]f32) -> f32 {
	return math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y))
}

/// a glyph's outline on its way into a raster (font units, y up)
@(private="file") Outline :: struct {
	r:          ^Raster,
	k:          f32, // font units to pixels
	off:        [2]f32,
	shear:      f32,
	pen, start: [2]f32,
}

@(private="file") outline_line :: proc "contextless" (c: ^Outline, to: [2]f32) {
	// y up in the font, down in the raster
	a := [2]f32{c.pen.x * c.k + c.off.x + c.shear * c.pen.y * c.k, c.off.y - c.pen.y * c.k}
	b := [2]f32{to.x * c.k + c.off.x + c.shear * to.y * c.k, c.off.y - to.y * c.k}
	context = {}
	raster_line(c.r, a, b)
	c.pen = to
}

@(private="file") outline_steps :: proc "contextless" (c: ^Outline, len_units: f32) -> int {
	return clamp(int(len_units * c.k / 1.5), 2, 24)
}

// ---------------------------------------------------------------- characters to fonts

/// the family that has a character (-1: none does)
font_for_rune :: proc(r: rune) -> int {
	if v, ok := fonts.cache[r]; ok do return int(v)
	res := -1
	for i in 0 ..< len(fonts.fams) {
		sl := family_slot(i, .Regular)
		if sl == nil do continue
		g: u32
		if hb_font_get_nominal_glyph(sl.hb, u32(r), &g) != 0 {
			res = i
			break
		}
	}
	fonts.cache[r] = i16(res)
	return res
}

// ---------------------------------------------------------------- the size

/// the font at a size in device pixels: the cell, the baseline, the lines
fonts_set_size :: proc(px: f32) {
	fonts.px = px
	clear(&fonts.cache)
	fonts.cell_w, fonts.cell_h, fonts.baseline = 8, 16, 12
	if len(fonts.fams) == 0 do return
	sl := family_slot(0, .Regular)
	if sl == nil do return
	k := px / sl.upem
	ext: hb_font_extents_t
	hb_font_get_h_extents(sl.hb, &ext)
	g: u32
	adv := f32(0.6) * px
	if hb_font_get_nominal_glyph(sl.hb, 'M', &g) != 0 do adv = f32(hb_font_get_glyph_h_advance(sl.hb, g)) * k
	asc := int(math.round(f32(ext.ascender) * k))
	desc := int(math.round(-f32(ext.descender) * k))
	gap := int(math.round(f32(ext.line_gap) * k))
	fonts.cell_w = max(1, int(math.round(adv)))
	fonts.cell_h = max(asc + desc + gap, 2)
	fonts.baseline = gap / 2 + asc
	fonts.ul_th = max(1, int(math.round(px / 14)))
	fonts.ul_pos = min(fonts.baseline + max(1, desc / 3), fonts.cell_h - fonts.ul_th)
	fonts.strike_pos = fonts.baseline - max(2, asc * 3 / 10)
}

// ---------------------------------------------------------------- the atlas

atlas_init :: proc() {
	a := &atlas
	a.w, a.h = ATLAS_W, ATLAS_H
	gl.GenTextures(1, &a.tex)
	gl.BindTexture(gl.TEXTURE_2D, a.tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, a.w, a.h, 0, gl.RED, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	atlas_clear()
}

/// empties the atlas (a new size, or it filled up); the two fixed pieces are made again
atlas_clear :: proc() {
	a := &atlas
	clear(&a.glyphs)
	clear(&a.specials)
	a.shelf_x, a.shelf_y, a.shelf_h = 1, 1, 0
	a.full = false
	// a block of full coverage (4 x 4) with a margin, for rectangles
	if x, y, ok := atlas_place(4, 4); ok {
		px: [16]u8
		for &p in px do p = 255
		atlas_upload(x, y, 4, 4, px[:])
		a.white = {x = x, y = y, w = 4, h = 4}
	}
	// a soft blob (a gaussian), for the glow of the cursor
	N :: 48
	if x, y, ok := atlas_place(N, N); ok {
		px: [N * N]u8
		for j in 0 ..< N {
			for i in 0 ..< N {
				dx, dy := (f32(i) + 0.5 - N / 2) / (N / 2), (f32(j) + 0.5 - N / 2) / (N / 2)
				d2 := dx * dx + dy * dy
				v := d2 >= 1 ? f32(0) : math.exp(-d2 * 4.5) * (1 - d2)
				px[j * N + i] = u8(clamp(v * 255, 0, 255))
			}
		}
		atlas_upload(x, y, N, N, px[:])
		a.glow = {x = x, y = y, w = N, h = N}
	}
}

/// room for a w × h bitmap (a new shelf when the row is full)
atlas_place :: proc(w, h: i32) -> (x, y: i32, ok: bool) {
	a := &atlas
	if w + 2 > a.w || h + 2 > a.h do return
	if a.shelf_x + w + 1 > a.w {
		a.shelf_x = 1
		a.shelf_y += a.shelf_h + 1
		a.shelf_h = 0
	}
	if a.shelf_y + h + 1 > a.h {
		a.full = true
		return
	}
	x, y = a.shelf_x, a.shelf_y
	a.shelf_x += w + 1
	a.shelf_h = max(a.shelf_h, h)
	return x, y, true
}

atlas_upload :: proc(x, y, w, h: i32, px: []u8) {
	gl.BindTexture(gl.TEXTURE_2D, atlas.tex)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RED, gl.UNSIGNED_BYTE, raw_data(px))
}

/// a glyph of a family in a style, as a bitmap in the atlas
atlas_glyph :: proc(fi: int, style: Style, gid: u32) -> (s: Atlas_Slot, sl: ^Slot, ok: bool) {
	sl = family_slot(fi, style)
	if sl == nil do return
	synth := u8(0)
	if sl.synth_bold do synth |= 1
	if sl.synth_italic do synth |= 2
	key := Glyph_Key{sl.id, gid, i32(fonts.px * 8), synth}
	if cached, found := atlas.glyphs[key]; found do return cached, sl, true
	k := fonts.px / sl.upem
	ext: hb_font_extents_t
	hb_font_get_h_extents(sl.hb, &ext)
	top := f32(ext.ascender) * k
	bw := int(math.ceil(fonts.px * 2.6)) + 12
	bh := int(math.ceil(f32(ext.ascender - ext.descender) * k)) + 12
	bw, bh = max(bw, 8), max(bh, 8)
	r := raster_make(bw, bh)
	o := Outline{r = &r, k = k, off = {6, top + 6}}
	if sl.synth_italic do o.shear = 0.21
	hb_font_draw_glyph(sl.hb, gid, fonts.draw, &o)
	if sl.synth_bold {
		o2 := Outline{r = &r, k = k, off = {6 + max(0.6, fonts.px / 20), top + 6}}
		if sl.synth_italic do o2.shear = 0.21
		hb_font_draw_glyph(sl.hb, gid, fonts.draw, &o2)
	}
	cov := make([]u8, bw * bh, context.temp_allocator)
	raster_coverage(&r, cov)
	x0, y0, x1, y1 := bw, bh, -1, -1
	for y in 0 ..< bh do for x in 0 ..< bw do if cov[y * bw + x] != 0 {
		x0, y0 = min(x0, x), min(y0, y)
		x1, y1 = max(x1, x), max(y1, y)
	}
	slot := Atlas_Slot{}
	if x1 >= x0 {
		w, h := x1 - x0 + 1, y1 - y0 + 1
		ax, ay, placed := atlas_place(i32(w), i32(h))
		if !placed do return {}, sl, false
		trimmed := make([]u8, w * h, context.temp_allocator)
		for y in 0 ..< h do copy(trimmed[y * w:][:w], cov[(y0 + y) * bw + x0:][:w])
		atlas_upload(ax, ay, i32(w), i32(h), trimmed)
		slot = {x = ax, y = ay, w = i32(w), h = i32(h), ox = f32(x0) - 6, oy = f32(y0) - 6 - top}
	}
	atlas.glyphs[key] = slot
	return slot, sl, true
}

/// a character the terminal draws itself, one cell in size
atlas_special :: proc(r: rune, w, h: int) -> (Atlas_Slot, bool) {
	key := Special_Key{r, i32(w), i32(h), 0}
	if s, found := atlas.specials[key]; found do return s, true
	px := make([]u8, w * h, context.temp_allocator)
	if !term.draw_special(r, term.Bitmap{w, h, px}) do return {}, false
	x, y, ok := atlas_place(i32(w), i32(h))
	if !ok do return {}, false
	atlas_upload(x, y, i32(w), i32(h), px)
	s := Atlas_Slot{x = x, y = y, w = i32(w), h = i32(h)}
	atlas.specials[key] = s
	return s, true
}

/// a rounded rectangle of full coverage (a pill behind text)
atlas_pill :: proc(w, h, radius: int) -> (Atlas_Slot, bool) {
	key := Special_Key{rune(radius), i32(w), i32(h), 1}
	if s, found := atlas.specials[key]; found do return s, true
	px := make([]u8, w * h, context.temp_allocator)
	rad := f32(min(radius, min(w, h) / 2))
	for y in 0 ..< h {
		for x in 0 ..< w {
			// the distance to the rounded rectangle's edge, at the pixel's centre
			qx := abs(f32(x) + 0.5 - f32(w) / 2) - (f32(w) / 2 - rad)
			qy := abs(f32(y) + 0.5 - f32(h) / 2) - (f32(h) / 2 - rad)
			d := math.sqrt(max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)) + min(max(qx, qy), 0) - rad
			px[y * w + x] = u8(clamp(0.5 - d, 0, 1) * 255)
		}
	}
	x, y, ok := atlas_place(i32(w), i32(h))
	if !ok do return {}, false
	atlas_upload(x, y, i32(w), i32(h), px)
	s := Atlas_Slot{x = x, y = y, w = i32(w), h = i32(h)}
	atlas.specials[key] = s
	return s, true
}

// ---------------------------------------------------------------- shaping

Placed :: struct {
	fi:    int,
	style: Style,
	gid:   u32,
	col:   int, // the cell it belongs to, counted from the start of the run
	dx, dy: f32, // device pixels
}

/// shapes the characters of a run of cells (`texts`: the runes of each cell)
/// in one family and style; the glyphs, each with the cell it starts in
shape_run :: proc(fi: int, style: Style, cells: []term.Cell, t: ^term.Term, out: ^[dynamic]Placed) {
	sl := family_slot(fi, style)
	if sl == nil do return
	k := fonts.px / sl.upem
	text := make([dynamic]u8, 0, len(cells) * 2, context.temp_allocator)
	starts := make([dynamic]int, 0, len(cells), context.temp_allocator)
	for c in cells {
		append(&starts, len(text))
		buf: [7]rune
		for r in term.cell_runes(t, c, &buf) {
			enc, n := encode_rune(r)
			append(&text, ..enc[:n])
		}
	}
	buf := fonts.buf
	hb_buffer_clear_contents(buf)
	hb_buffer_add_utf8(buf, raw_data(text[:]), i32(len(text)), 0, i32(len(text)))
	hb_buffer_guess_segment_properties(buf)
	if fonts.ligatures {
		hb_shape(sl.hb, buf, nil, 0)
	} else {
		feats := [4]hb_feature_t{
			{hb_tag('l', 'i', 'g', 'a'), 0, 0, max(u32)}, {hb_tag('c', 'l', 'i', 'g'), 0, 0, max(u32)},
			{hb_tag('c', 'a', 'l', 't'), 0, 0, max(u32)}, {hb_tag('d', 'l', 'i', 'g'), 0, 0, max(u32)},
		}
		hb_shape(sl.hb, buf, &feats[0], 4)
	}
	count: u32
	infos := hb_buffer_get_glyph_infos(buf, &count)
	pos := hb_buffer_get_glyph_positions(buf, &count)
	for g in 0 ..< int(count) {
		// the cell whose text starts at or before this cluster
		cluster := int(infos[g].cluster)
		lo, hi := 0, len(starts) - 1
		for lo < hi {
			mid := (lo + hi + 1) / 2
			if starts[mid] <= cluster { lo = mid } else { hi = mid - 1 }
		}
		append(out, Placed{fi = fi, style = style, gid = infos[g].codepoint, col = lo, dx = f32(pos[g].x_offset) * k, dy = -f32(pos[g].y_offset) * k})
	}
}

/// a single character's glyph with no shaping (the plain case)
plain_glyph :: proc(fi: int, style: Style, r: rune) -> (gid: u32, ok: bool) {
	sl := family_slot(fi, style)
	if sl == nil do return
	return gid, hb_font_get_nominal_glyph(sl.hb, u32(r), &gid) != 0
}

@(private="file") encode_rune :: proc(r: rune) -> (b: [4]u8, n: int) {
	c := u32(r)
	switch {
	case c < 0x80: return {u8(c), 0, 0, 0}, 1
	case c < 0x800: return {u8(0xc0 | c >> 6), u8(0x80 | c & 0x3f), 0, 0}, 2
	case c < 0x10000: return {u8(0xe0 | c >> 12), u8(0x80 | (c >> 6) & 0x3f), u8(0x80 | c & 0x3f), 0}, 3
	}
	return {u8(0xf0 | c >> 18), u8(0x80 | (c >> 12) & 0x3f), u8(0x80 | (c >> 6) & 0x3f), u8(0x80 | c & 0x3f)}, 4
}
