// The C functions Iris's text engine calls: fontconfig finds the desktop's
// fonts, HarfBuzz shapes text and hands over each glyph's outline (Iris
// rasterises it itself, raster.odin). abi/check.sh checks every one.
package iris

foreign import fontconfig "system:fontconfig"
foreign import harfbuzz "system:harfbuzz"

FcConfig :: struct {}
FcPattern :: struct {}
FcCharSet :: struct {}

/// struct _FcFontSet
FcFontSet :: struct {
	nfont: i32,
	sfont: i32,
	fonts: [^]^FcPattern,
}

FcMatchPattern :: i32(0)
FcResultMatch :: i32(0)

@(default_calling_convention = "c")
foreign fontconfig {
	FcInitLoadConfigAndFonts :: proc() -> ^FcConfig ---
	FcNameParse :: proc(name: cstring) -> ^FcPattern ---
	FcConfigSubstitute :: proc(config: ^FcConfig, p: ^FcPattern, kind: i32) -> i32 ---
	FcDefaultSubstitute :: proc(pattern: ^FcPattern) ---
	FcFontSort :: proc(config: ^FcConfig, p: ^FcPattern, trim: i32, csp: ^^FcCharSet, result: ^i32) -> ^FcFontSet ---
	FcPatternGetString :: proc(p: ^FcPattern, object: cstring, n: i32, s: ^cstring) -> i32 ---
	FcPatternGetInteger :: proc(p: ^FcPattern, object: cstring, n: i32, i: ^i32) -> i32 ---
	FcFontSetDestroy :: proc(s: ^FcFontSet) ---
	FcPatternDestroy :: proc(p: ^FcPattern) ---
}

hb_blob_t :: struct {}
hb_face_t :: struct {}
hb_font_t :: struct {}
hb_buffer_t :: struct {}
hb_draw_funcs_t :: struct {}
hb_draw_state_t :: struct {}

/// typedef hb_glyph_info_t
hb_glyph_info_t :: struct {
	codepoint: u32,
	mask:      u32,
	cluster:   u32,
	var1:      u32,
	var2:      u32,
}

/// typedef hb_glyph_position_t
hb_glyph_position_t :: struct {
	x_advance: i32,
	y_advance: i32,
	x_offset:  i32,
	y_offset:  i32,
	var:       u32,
}

/// typedef hb_font_extents_t
hb_font_extents_t :: struct {
	ascender:  i32,
	descender: i32,
	line_gap:  i32,
	reserved9, reserved8, reserved7, reserved6, reserved5, reserved4, reserved3, reserved2, reserved1: i32,
}

/// typedef hb_variation_t
hb_variation_t :: struct {
	tag:   u32,
	value: f32,
}

hb_move_to_func :: proc "c" (dfuncs: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, x, y: f32, user: rawptr)
hb_quadratic_to_func :: proc "c" (dfuncs: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, cx, cy, x, y: f32, user: rawptr)
hb_cubic_to_func :: proc "c" (dfuncs: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, c1x, c1y, c2x, c2y, x, y: f32, user: rawptr)
hb_close_path_func :: proc "c" (dfuncs: ^hb_draw_funcs_t, data: rawptr, st: ^hb_draw_state_t, user: rawptr)

@(default_calling_convention = "c")
foreign harfbuzz {
	hb_blob_create_from_file_or_fail :: proc(file_name: cstring) -> ^hb_blob_t ---
	hb_blob_destroy :: proc(blob: ^hb_blob_t) ---
	hb_face_create :: proc(blob: ^hb_blob_t, index: u32) -> ^hb_face_t ---
	hb_face_get_upem :: proc(face: ^hb_face_t) -> u32 ---
	hb_face_destroy :: proc(face: ^hb_face_t) ---
	hb_font_create :: proc(face: ^hb_face_t) -> ^hb_font_t ---
	hb_font_set_scale :: proc(font: ^hb_font_t, x_scale, y_scale: i32) ---
	hb_font_set_variations :: proc(font: ^hb_font_t, variations: ^hb_variation_t, n: u32) ---
	hb_font_get_nominal_glyph :: proc(font: ^hb_font_t, unicode: u32, glyph: ^u32) -> i32 ---
	hb_font_get_h_extents :: proc(font: ^hb_font_t, extents: ^hb_font_extents_t) -> i32 ---
	hb_font_draw_glyph :: proc(font: ^hb_font_t, glyph: u32, dfuncs: ^hb_draw_funcs_t, draw_data: rawptr) ---
	hb_buffer_create :: proc() -> ^hb_buffer_t ---
	hb_buffer_clear_contents :: proc(buffer: ^hb_buffer_t) ---
	hb_buffer_add_utf8 :: proc(buffer: ^hb_buffer_t, text: [^]u8, text_length: i32, item_offset: u32, item_length: i32) ---
	hb_buffer_guess_segment_properties :: proc(buffer: ^hb_buffer_t) ---
	hb_buffer_get_glyph_infos :: proc(buffer: ^hb_buffer_t, length: ^u32) -> [^]hb_glyph_info_t ---
	hb_buffer_get_glyph_positions :: proc(buffer: ^hb_buffer_t, length: ^u32) -> [^]hb_glyph_position_t ---
	hb_shape :: proc(font: ^hb_font_t, buffer: ^hb_buffer_t, features: rawptr, num_features: u32) ---
	hb_draw_funcs_create :: proc() -> ^hb_draw_funcs_t ---
	hb_draw_funcs_set_move_to_func :: proc(dfuncs: ^hb_draw_funcs_t, f: hb_move_to_func, user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_set_line_to_func :: proc(dfuncs: ^hb_draw_funcs_t, f: hb_move_to_func, user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_set_quadratic_to_func :: proc(dfuncs: ^hb_draw_funcs_t, f: hb_quadratic_to_func, user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_set_cubic_to_func :: proc(dfuncs: ^hb_draw_funcs_t, f: hb_cubic_to_func, user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_set_close_path_func :: proc(dfuncs: ^hb_draw_funcs_t, f: hb_close_path_func, user: rawptr, destroy: rawptr) ---
	hb_draw_funcs_make_immutable :: proc(dfuncs: ^hb_draw_funcs_t) ---
}
