// Bindings to Iris's Rust core (core/, include/iris_core.h): Brave's
// adblock-rust and the Mozilla add-on installer, behind flat C functions.
// Each opaque pointer has a create and a destroy; the wrappers below are
// what the rest of Iris calls, so the raw functions stay in this file.
package iris

import "core:encoding/json"
import "core:strings"

/// an engine: immutable, any thread may ask (opaque: the Rust core's)
Adblock :: struct {}
Adblock_Builder :: struct {}

when ENGINE_CEF {

foreign import iris_core "system:iris_core"

Core_Verdict :: struct {
	action:  u32,
	payload: [^]u8, // char*, freed with iris_verdict_free
}
#assert(size_of(Core_Verdict) == 16)

CORE_ALLOW :: 0
CORE_BLOCK :: 1
CORE_REDIRECT :: 2
CORE_REWRITE :: 3

@(default_calling_convention = "c")
foreign iris_core {
	iris_core_version :: proc() -> cstring ---
	iris_string_free :: proc(s: [^]u8) ---
	iris_bytes_free :: proc(p: [^]u8, n: uint) ---

	iris_adblock_builder_create :: proc() -> ^Adblock_Builder ---
	iris_adblock_builder_destroy :: proc(b: ^Adblock_Builder) ---
	iris_adblock_builder_add_list :: proc(b: ^Adblock_Builder, text: [^]u8, n: uint) -> bool ---
	iris_adblock_builder_set_resources :: proc(b: ^Adblock_Builder, json: [^]u8, n: uint) -> bool ---
	iris_adblock_build :: proc(b: ^Adblock_Builder) -> ^Adblock ---
	iris_adblock_destroy :: proc(e: ^Adblock) ---
	iris_adblock_check :: proc(e: ^Adblock, url, source_url, request_type: cstring, out: ^Core_Verdict) -> bool ---
	iris_verdict_free :: proc(v: ^Core_Verdict) ---
	iris_adblock_cosmetic :: proc(e: ^Adblock, url: cstring) -> [^]u8 ---
	iris_adblock_class_id_css :: proc(e: ^Adblock, classes, ids, exceptions: cstring) -> [^]u8 ---
	iris_adblock_serialize :: proc(e: ^Adblock, n: ^uint) -> [^]u8 ---
	iris_adblock_deserialize :: proc(p: [^]u8, n: uint) -> ^Adblock ---

	iris_xpi_inspect :: proc(xpi: [^]u8, n: uint) -> [^]u8 ---
	iris_xpi_install :: proc(xpi: [^]u8, n: uint, dest_dir, sha256: cstring, out: ^[^]u8) -> i32 ---
	iris_xpi_uninstall :: proc(dest_dir, dir: cstring) -> bool ---

	iris_url_classify :: proc(url: cstring) -> [^]u8 ---
}

/// a string the core returned, copied; the core's is freed
@(private="file") take_string :: proc(p: [^]u8, allocator := context.allocator) -> string {
	if p == nil do return ""
	defer iris_string_free(p)
	return strings.clone(string(cstring(p)), allocator)
}

/// a verdict for a request: what to do and what with (a payload the
/// caller owns), or CORE_ALLOW
core_adblock_check :: proc(e: ^Adblock, url, page, request_type: string, allocator := context.temp_allocator) -> (action: u32, payload: string) {
	if e == nil do return CORE_ALLOW, ""
	v: Core_Verdict
	if !iris_adblock_check(e, strings.clone_to_cstring(url, context.temp_allocator), strings.clone_to_cstring(page, context.temp_allocator), strings.clone_to_cstring(request_type, context.temp_allocator), &v) {
		return CORE_ALLOW, ""
	}
	defer iris_verdict_free(&v)
	if v.payload != nil do payload = strings.clone(string(cstring(v.payload)), allocator)
	return v.action, payload
}

/// the same, with the request type as a C string (CEF's IO thread)
core_adblock_check_c :: proc(e: ^Adblock, url, page: string, request_type: cstring, allocator := context.temp_allocator) -> (action: u32, payload: string) {
	if e == nil do return CORE_ALLOW, ""
	v: Core_Verdict
	if !iris_adblock_check(e, strings.clone_to_cstring(url, context.temp_allocator), strings.clone_to_cstring(page, context.temp_allocator), request_type, &v) {
		return CORE_ALLOW, ""
	}
	defer iris_verdict_free(&v)
	if v.payload != nil do payload = strings.clone(string(cstring(v.payload)), allocator)
	return v.action, payload
}

/// what a page at url needs: the hiding style sheet and the scriptlets
core_adblock_cosmetic :: proc(e: ^Adblock, url: string, allocator := context.temp_allocator) -> (css, script: string, generichide: bool) {
	if e == nil do return
	j := take_string(iris_adblock_cosmetic(e, strings.clone_to_cstring(url, context.temp_allocator)), context.temp_allocator)
	return cosmetic_fields(j, allocator)
}

Cosmetic :: struct {
	css:         string,
	script:      string,
	generichide: bool,
}

/// {"css": "...", "script": "...", "generichide": true} (the core's JSON)
cosmetic_fields :: proc(j: string, allocator := context.temp_allocator) -> (css, script: string, generichide: bool) {
	c: Cosmetic
	if json.unmarshal(transmute([]u8)j, &c, allocator = allocator) != nil do return
	return c.css, c.script, c.generichide
}

core_xpi_install :: proc(data: []u8, dest_dir: string, sha256: string) -> (summary: string, code: i32) {
	out: [^]u8
	sum := len(sha256) > 0 ? strings.clone_to_cstring(sha256, context.temp_allocator) : nil
	code = iris_xpi_install(raw_data(data), uint(len(data)), strings.clone_to_cstring(dest_dir, context.temp_allocator), sum, &out)
	if code == 0 do summary = take_string(out, context.temp_allocator)
	return
}

core_url_classify :: proc(url: string, allocator := context.temp_allocator) -> string {
	return take_string(iris_url_classify(strings.clone_to_cstring(url, context.temp_allocator)), allocator)
}

}
