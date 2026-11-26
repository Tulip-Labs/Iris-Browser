// The CEF engine's GPU frames (IRIS_ENGINE=cef, see engine_api.odin):
// Chromium composites on the GPU, and each frame comes to Iris as a
// DMA-BUF (OnAcceleratedPaint, CefWindowInfo.shared_texture_enabled): it is
// imported into Iris's EGL (EGL_EXT_image_dma_buf_import, as render.odin
// does for WPE) and copied, on the GPU, into the page's own texture while
// the callback runs (CEF takes the buffer back to its pool when it
// returns). No pixel crosses the CPU.
//
// When this cannot work, frames come through OnPaint instead (CPU BGRA,
// cef_page.odin): when Iris starts with IRIS_CEF_GPU=0, when Chromium's GPU
// process fails (Chromium falls back to software compositing and calls
// OnPaint itself), or when a DMA-BUF cannot be imported here (logged; the
// tab's browser is made again without shared textures, and so is every
// later one).
package iris

import "core:log"
import "vendor:egl"
import gl "vendor:OpenGL"

// (not indented: the whole file is this engine's)
when ENGINE_CEF {

// CEF 156's include/internal/cef_types_linux.h and cef_types_osr.h (plain C
// structs, not in the generated C API bindings: their sizes and offsets are
// checked below against clang's layout of those headers)

/// struct _cef_accelerated_paint_native_pixmap_plane_info_t
cef_accelerated_paint_native_pixmap_plane_t :: struct {
	stride: u32,
	offset: u64,
	size:   u64,
	fd:     i32,
}

/// struct _cef_accelerated_paint_info_common_t
cef_accelerated_paint_info_common_t :: struct {
	size:                    uint,
	timestamp:               u64,
	coded_size:              cef_size_t,
	visible_rect:            cef_rect_t,
	content_rect:            cef_rect_t,
	source_size:             cef_size_t,
	capture_update_rect:     cef_rect_t,
	region_capture_rect:     cef_rect_t,
	capture_counter:         u64,
	has_capture_update_rect: u8,
	has_region_capture_rect: u8,
	has_source_size:         u8,
	has_capture_counter:     u8,
}

CEF_ACCELERATED_PAINT_MAX_PLANES :: 4 // kAcceleratedPaintMaxPlanes

/// struct _cef_accelerated_paint_info_t (Linux)
cef_accelerated_paint_info_t :: struct {
	size:        uint,
	planes:      [CEF_ACCELERATED_PAINT_MAX_PLANES]cef_accelerated_paint_native_pixmap_plane_t,
	plane_count: i32,
	modifier:    u64,
	format:      i32, // cef_color_type_t
	extra:       cef_accelerated_paint_info_common_t,
}

// clang -Xclang -fdump-record-layouts-complete on CEF 156's headers
#assert(size_of(cef_accelerated_paint_native_pixmap_plane_t) == 32)
#assert(offset_of(cef_accelerated_paint_native_pixmap_plane_t, fd) == 24)
#assert(size_of(cef_accelerated_paint_info_common_t) == 112)
#assert(offset_of(cef_accelerated_paint_info_common_t, capture_counter) == 96)
#assert(offset_of(cef_accelerated_paint_info_common_t, has_capture_counter) == 107)
#assert(size_of(cef_accelerated_paint_info_t) == 272)
#assert(offset_of(cef_accelerated_paint_info_t, plane_count) == 136)
#assert(offset_of(cef_accelerated_paint_info_t, modifier) == 144)
#assert(offset_of(cef_accelerated_paint_info_t, format) == 152)
#assert(offset_of(cef_accelerated_paint_info_t, extra) == 160)
#assert(size_of(cef_window_info_t) == 88)
#assert(offset_of(cef_window_info_t, shared_texture_enabled) == 60)

DRM_FORMAT_ARGB8888 :: 0x34325241 // 'AR24': CEF's BGRA
DRM_FORMAT_ABGR8888 :: 0x34324241 // 'AB24': CEF's RGBA

/// new browsers get GPU frames (shared textures); false once they could
/// not be used here (cef_engine.odin decides it at start)
cef_gpu_frames: bool

@(private="file") read_fbo: u32
@(private="file") warned_import, warned_software: bool

/// a frame's DMA-BUF as an EGL image and a texture over it (for this
/// callback only)
@(private="file") import_frame :: proc(info: ^cef_accelerated_paint_info_t) -> (img: egl.Image, tex: u32, ok: bool) {
	EGL_LINUX_DMA_BUF_EXT :: 0x3270
	EGL_LINUX_DRM_FOURCC_EXT :: 0x3271
	FD := [4]i32{0x3272, 0x3275, 0x3278, 0x3440}
	OFFSET := [4]i32{0x3273, 0x3276, 0x3279, 0x3441}
	PITCH := [4]i32{0x3274, 0x3277, 0x327A, 0x3442}
	MOD_LO := [4]i32{0x3443, 0x3445, 0x3447, 0x3449}
	MOD_HI := [4]i32{0x3444, 0x3446, 0x3448, 0x344A}
	if rnd.create_image == nil || rnd.target_texture == nil || rnd.egl_display == nil do return
	fourcc: i32
	switch info.format {
	case CEF_COLOR_TYPE_BGRA_8888: fourcc = DRM_FORMAT_ARGB8888
	case CEF_COLOR_TYPE_RGBA_8888: fourcc = DRM_FORMAT_ABGR8888
	case: return
	}
	n := int(info.plane_count)
	if n < 1 || n > CEF_ACCELERATED_PAINT_MAX_PLANES do return
	w, h := info.extra.coded_size.width, info.extra.coded_size.height
	if w <= 0 || h <= 0 do return
	a: [64]i32
	k := 0
	push :: proc(a: ^[64]i32, k: ^int, key, v: i32) {
		a[k^] = key
		a[k^ + 1] = v
		k^ += 2
	}
	push(&a, &k, egl.WIDTH, w)
	push(&a, &k, egl.HEIGHT, h)
	push(&a, &k, EGL_LINUX_DRM_FOURCC_EXT, fourcc)
	for i in 0 ..< n {
		pl := info.planes[i]
		if pl.fd < 0 do return
		push(&a, &k, FD[i], pl.fd)
		push(&a, &k, OFFSET[i], i32(pl.offset))
		push(&a, &k, PITCH[i], i32(pl.stride))
		if info.modifier != DRM_FORMAT_MOD_INVALID {
			push(&a, &k, MOD_LO[i], i32(u32(info.modifier & 0xffffffff)))
			push(&a, &k, MOD_HI[i], i32(u32(info.modifier >> 32)))
		}
	}
	a[k] = egl.NONE
	// EGL keeps its own reference to the buffer: the fds stay CEF's
	img = rnd.create_image(rnd.egl_display, egl.NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nil, &a[0])
	if img == nil do return
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	rnd.target_texture(gl.TEXTURE_2D, rawptr(img))
	return img, tex, true
}

@(private="file") release_frame :: proc(img: egl.Image, tex: u32) {
	t := tex
	if t != 0 do gl.DeleteTextures(1, &t)
	if img != nil && rnd.destroy_image != nil do rnd.destroy_image(rnd.egl_display, img)
}

/// t is an RGBA texture of Iris's own of w × h (made again if not)
@(private="file") ensure_texture :: proc(t: ^Texture, w, h: i32) {
	if t.id != 0 && t.owned && t.w == w && t.h == h && !t.bgra do return
	if t.owned && t.id != 0 do gl.DeleteTextures(1, &t.id)
	gl.GenTextures(1, &t.id)
	gl.BindTexture(gl.TEXTURE_2D, t.id)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	t.w, t.h, t.owned, t.bgra, t.premultiplied = w, h, true, false, true
}

/// a rectangle of the texture src (from sx, sy) into dst (at dx, dy), on the GPU
@(private="file") gpu_copy :: proc(src: u32, sx, sy, w, h: i32, dst: ^Texture, dx, dy: i32) -> bool {
	if w <= 0 || h <= 0 do return true
	prev: i32
	gl.GetIntegerv(gl.READ_FRAMEBUFFER_BINDING, &prev)
	if read_fbo == 0 do gl.GenFramebuffers(1, &read_fbo)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, read_fbo)
	gl.FramebufferTexture2D(gl.READ_FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, src, 0)
	ok := gl.CheckFramebufferStatus(gl.READ_FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE
	if ok {
		gl.BindTexture(gl.TEXTURE_2D, dst.id)
		gl.CopyTexSubImage2D(gl.TEXTURE_2D, 0, dx, dy, sx, sy, w, h)
	}
	gl.FramebufferTexture2D(gl.READ_FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, 0, 0)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, u32(prev))
	return ok
}

// the GPU must have read the frame's buffer before the callback returns
// (CEF gives it back to its pool, and Chromium draws the next frame into
// it): a fence, waited for here; glFinish where EGL has no fences
@(private="file") Fences :: struct {
	loaded:  bool,
	create:  proc "c" (d: egl.Display, type: u32, attribs: [^]i32) -> rawptr,
	wait:    proc "c" (d: egl.Display, sync: rawptr, flags: i32, timeout: u64) -> i32,
	destroy: proc "c" (d: egl.Display, sync: rawptr) -> b32,
}
@(private="file") fences: Fences

EGL_SYNC_FENCE_KHR :: 0x30F9
EGL_SYNC_FLUSH_COMMANDS_BIT_KHR :: 0x0001
/// at most this long for one frame's copy (nanoseconds): a frame late is
/// better than a hang
GPU_WAIT_NS :: 100_000_000

@(private="file") wait_for_gpu :: proc() {
	if !fences.loaded {
		fences.loaded = true
		fences.create = auto_cast egl.GetProcAddress("eglCreateSyncKHR")
		fences.wait = auto_cast egl.GetProcAddress("eglClientWaitSyncKHR")
		fences.destroy = auto_cast egl.GetProcAddress("eglDestroySyncKHR")
	}
	if fences.create != nil && fences.wait != nil && fences.destroy != nil {
		if sync := fences.create(rnd.egl_display, EGL_SYNC_FENCE_KHR, nil); sync != nil {
			fences.wait(rnd.egl_display, sync, EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, GPU_WAIT_NS)
			fences.destroy(rnd.egl_display, sync)
			return
		}
	}
	gl.Finish()
}

/// the popup (a <select>'s list) over the page, from its own texture
@(private="file") lay_popup_gpu :: proc(p: ^Page) {
	if !p.popup_on || p.popup_tex.id == 0 || p.tex.id == 0 do return
	x := i32(f64(p.popup.x) * p.scale + 0.5)
	y := i32(f64(p.popup.y) * p.scale + 0.5)
	w := min(p.popup_tex.w, p.tex.w - x)
	h := min(p.popup_tex.h, p.tex.h - y)
	if x < 0 || y < 0 || w <= 0 || h <= 0 do return
	gpu_copy(p.popup_tex.id, 0, 0, w, h, &p.tex, x, y)
}

/// OnAcceleratedPaint (the main thread, in CEF's turn of the loop: Iris's GL
/// context is current); false if the frame could not be imported
page_paint_gpu :: proc(p: ^Page, kind: i32, info: ^cef_accelerated_paint_info_t) -> bool {
	if info == nil do return false
	img, src, ok := import_frame(info)
	if !ok {
		if !warned_import {
			warned_import = true
			log.warnf("CEF: a GPU frame could not be imported (format %d, %d planes, modifier %x, EGL error %x): pages use software frames from now on", info.format, info.plane_count, info.modifier, egl.GetError())
		}
		return false
	}
	defer release_frame(img, src)
	vis := info.extra.visible_rect
	cw, ch := info.extra.coded_size.width, info.extra.coded_size.height
	if vis.width <= 0 || vis.height <= 0 || vis.x < 0 || vis.y < 0 || vis.x + vis.width > cw || vis.y + vis.height > ch {
		vis = {0, 0, cw, ch}
	}
	target := kind == PET_POPUP ? &p.popup_tex : &p.tex
	ensure_texture(target, vis.width, vis.height)
	// the whole visible frame: CEF's pool recycles buffers, so its dirty
	// rectangles are not always against the frame Iris copied last (and a
	// GPU copy of a whole frame costs next to nothing)
	if !gpu_copy(src, vis.x, vis.y, vis.width, vis.height, target, 0, 0) do return false
	// read before CEF takes the buffer back (no tearing, no judder)
	wait_for_gpu()
	lay_popup_gpu(p)
	if p.on_frame != nil do p.on_frame(p)
	return true
}

/// a software frame came while GPU frames were asked for: Chromium's GPU
/// compositing is off (its GPU process failed, or the GPU is blocked)
cef_software_frame_seen :: proc() {
	if cef_gpu_frames && !warned_software {
		warned_software = true
		log.warn("CEF: pages are composited in software (Chromium's GPU process is off or failed): expect more CPU use")
	}
}

page_free_gpu :: proc(p: ^Page) {
	if p.popup_tex.owned do texture_free(&p.popup_tex)
}

} // when ENGINE_CEF
