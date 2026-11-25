// The WPE engine's page (IRIS_ENGINE=wpe, see engine_api.odin).
//
// Iris is its own WPEPlatform (WPE WebKit 2.54+): a WPEDisplay, WPEView,
// WPEToplevel and WPEClipboard made here as GObject subclasses. WebKit's
// web process renders each frame into a DMA-BUF and hands it to IrisView's
// render_buffer; Iris imports that buffer, as it is, as an EGL image and
// samples it in its own GLES renderer (no copy), so the Liquid Glass bends
// the live page. Input goes the other way: Wayland's pointer, scroll and
// keys become WPEEvents.
package iris

import "base:runtime"
import "core:log"
import "core:strings"
import plat "../plat"

// (not indented: the whole file is this engine's)
when !ENGINE_CEF {

@(private="file") display_type, view_type, toplevel_type, clipboard_type: GType
@(private="file") shared_display, headless_display: ^WPEDisplay
@(private="file") the_keymap: ^WPEKeymap
@(private="file") the_clipboard: ^WPEClipboard
@(private="file") pctx: runtime.Context

// ---------------------------------------------------------------- display

@(private="file") display_class_init :: proc "c" (klass, data: rawptr) {
	dc := cast(^WPEDisplayClass)klass
	dc.connect = proc "c" (d: ^WPEDisplay, err: ^^GError) -> gboolean {
		// EGL and the GPU are found the way WPE's headless platform finds them
		h := wpe_display_headless_new()
		if h == nil do return 0
		if wpe_display_connect(h, err) == 0 {
			unref(h)
			return 0
		}
		headless_display = h
		return 1
	}
	dc.create_view = proc "c" (d: ^WPEDisplay) -> ^WPEView {
		context = pctx
		return cast(^WPEView)gnew(view_type, {name = "display", value = rawptr(d), type = wpe_display_get_type()})
	}
	dc.create_toplevel = proc "c" (d: ^WPEDisplay, max_views: u32) -> ^WPEToplevel {
		context = pctx
		return cast(^WPEToplevel)gnew(toplevel_type, {name = "display", value = rawptr(d), type = wpe_display_get_type()}, {name = "max-views", value = max_views})
	}
	dc.get_egl_display = proc "c" (d: ^WPEDisplay, err: ^^GError) -> rawptr {
		return wpe_display_get_egl_display(headless_display, err)
	}
	dc.get_drm_device = proc "c" (d: ^WPEDisplay) -> ^WPEDRMDevice {
		return wpe_display_get_drm_device(headless_display)
	}
	dc.get_keymap = proc "c" (d: ^WPEDisplay) -> ^WPEKeymap {
		if the_keymap == nil do the_keymap = wpe_keymap_xkb_new()
		return the_keymap
	}
	dc.get_clipboard = proc "c" (d: ^WPEDisplay) -> ^WPEClipboard {
		context = pctx
		if the_clipboard == nil {
			the_clipboard = cast(^WPEClipboard)gnew(clipboard_type, {name = "display", value = rawptr(d), type = wpe_display_get_type()})
		}
		return the_clipboard
	}
	dc.get_preferred_buffer_formats = proc "c" (d: ^WPEDisplay) -> ^WPEBufferFormats {
		context = pctx
		return importable_formats()
	}
}

/// the formats and modifiers Iris's EGL display can import, so every frame
/// WebKit makes, Iris can show without a copy
@(private="file") importable_formats :: proc() -> ^WPEBufferFormats {
	if rnd.query_formats == nil || rnd.query_modifiers == nil do return nil
	n: i32
	if !rnd.query_formats(rnd.egl_display, 0, nil, &n) || n == 0 do return nil
	formats := make([]i32, n, context.temp_allocator)
	rnd.query_formats(rnd.egl_display, n, &formats[0], &n)
	dev := wpe_display_get_drm_device(headless_display)
	b := wpe_buffer_formats_builder_new(dev)
	wpe_buffer_formats_builder_append_group(b, dev, WPE_BUFFER_FORMAT_USAGE_RENDERING)
	for f in formats[:n] {
		m: i32
		rnd.query_modifiers(rnd.egl_display, f, 0, nil, nil, &m)
		if m == 0 {
			wpe_buffer_formats_builder_append_format(b, u32(f), DRM_FORMAT_MOD_INVALID)
			continue
		}
		mods := make([]u64, m, context.temp_allocator)
		ext := make([]b32, m, context.temp_allocator)
		rnd.query_modifiers(rnd.egl_display, f, m, &mods[0], &ext[0], &m)
		for k in 0 ..< int(m) do if !ext[k] do wpe_buffer_formats_builder_append_format(b, u32(f), mods[k])
	}
	out := wpe_buffer_formats_builder_end(b)
	wpe_buffer_formats_builder_unref(b)
	return out
}

/// the display every page uses (made on first use)
display :: proc() -> ^WPEDisplay {
	if shared_display != nil do return shared_display
	pctx = context
	display_type = register_type(wpe_display_get_type(), "IrisDisplay", display_class_init)
	view_type = register_type(wpe_view_get_type(), "IrisView", view_class_init)
	toplevel_type = register_type(wpe_toplevel_get_type(), "IrisToplevel", toplevel_class_init)
	clipboard_type = register_type(wpe_clipboard_get_type(), "IrisClipboard", clipboard_class_init)
	d := cast(^WPEDisplay)gnew(display_type)
	err: ^GError
	if wpe_display_connect(d, &err) == 0 {
		if err != nil {
			log.errorf("WPE display: %s", err.message)
			g_error_free(err)
		}
	}
	// WebKit picks this display for views made without one
	wpe_display_set_primary(d)
	shared_display = d
	return d
}

/// the compositor's keymap, so WebKit reads keys as the desktop does
set_keymap :: proc(format: u32, fd: i32, size: u32) {
	if the_keymap == nil do the_keymap = wpe_keymap_xkb_new()
	wpe_keymap_xkb_update(cast(^WPEKeymapXKB)the_keymap, format, fd, size)
}

// ---------------------------------------------------------------- view

@(private="file") view_class_init :: proc "c" (klass, data: rawptr) {
	vc := cast(^WPEViewClass)klass
	vc.render_buffer = proc "c" (v: ^WPEView, b: ^WPEBuffer, damage: [^]WPERectangle, n: u32, err: ^^GError) -> gboolean {
		context = pctx
		p := page_of(v)
		if p == nil {
			// no page (yet, or any more): the frame goes straight back
			wpe_view_buffer_rendered(v, b)
			wpe_view_buffer_released(v, b)
			return 1
		}
		return page_frame(p, b) ? 1 : 0
	}
	vc.set_cursor_from_name = proc "c" (v: ^WPEView, name: cstring) {
		context = pctx
		p := page_of(v)
		if p == nil do return
		p.cursor = cursor_for(string(name))
		if p.on_cursor != nil do p.on_cursor(p)
	}
}

cursor_for :: proc(css: string) -> plat.Cursor_Shape {
	switch css {
	case "pointer", "hand": return .Pointer
	case "text", "vertical-text": return .Text
	case "grab", "grabbing", "move", "all-scroll": return .Grab
	case "ew-resize", "col-resize", "e-resize", "w-resize": return .Ew_Resize
	case "ns-resize", "row-resize", "n-resize", "s-resize": return .Ns_Resize
	}
	return .Default
}

// ---------------------------------------------------------------- toplevel

@(private="file") toplevel_class_init :: proc "c" (klass, data: rawptr) {
	tc := cast(^WPEToplevelClass)klass
	tc.resize = proc "c" (t: ^WPEToplevel, w, h: i32) -> gboolean {
		wpe_toplevel_resized(t, w, h)
		return 1
	}
	// a page's video asks for full screen; the browser answers
	tc.set_fullscreen = proc "c" (t: ^WPEToplevel, on: gboolean) -> gboolean {
		context = pctx
		p := cast(^Page)g_object_get_data(t, "iris-page")
		if p == nil do return 0
		if p.on_fullscreen != nil do p.on_fullscreen(p, on != 0)
		state := wpe_toplevel_get_state(t)
		state = on != 0 ? state | WPE_TOPLEVEL_STATE_FULLSCREEN : state & ~WPE_TOPLEVEL_STATE_FULLSCREEN
		wpe_toplevel_state_changed(t, state)
		return 1
	}
}

// ---------------------------------------------------------------- clipboard

/// WPE's clipboard, kept in step with the desktop's (clipboard.odin)
@(private="file") clipboard_class_init :: proc "c" (klass, data: rawptr) {
	cc := cast(^WPEClipboardClass)klass
	cc.changed = proc "c" (c: ^WPEClipboard, formats: ^GPtrArray, is_local: gboolean, content: ^WPEClipboardContent) {
		context = pctx
		if is_local == 0 || content == nil || clipboard_mirroring do return
		text := wpe_clipboard_content_get_text(content)
		if text != nil do clipboard_offer(string(text))
	}
}

clipboard_mirroring: bool

/// the desktop copied something: pages can paste it
clipboard_from_desktop :: proc(text: string) {
	delete(clipboard_text)
	clipboard_text = strings.clone(text)
	if the_clipboard == nil do return
	c := wpe_clipboard_content_new()
	t := cstr(text)
	wpe_clipboard_content_set_text(c, t)
	clipboard_mirroring = true
	wpe_clipboard_set_content(the_clipboard, c)
	clipboard_mirroring = false
	wpe_clipboard_content_unref(c)
}

// ---------------------------------------------------------------- the page

/// One web view on screen: its newest frame as a GL texture, and the input
/// it is sent.
Page :: struct {
	web:           ^WebKitWebView,
	view:          ^WPEView,
	toplevel:      ^WPEToplevel,
	/// where it is in the window (logical pixels)
	x, y, w, h:    f64,
	scale:         f64,
	tex:           Texture,
	/// the buffer on screen, and one waiting to be
	shown:         ^WPEBuffer,
	next:          ^WPEBuffer,
	/// buffers shown but not yet reported as rendered
	rendered_due:  [dynamic]^WPEBuffer,
	images:        map[^WPEBuffer]Imported,
	buttons:       i32,
	pointer:       [2]f64,
	cursor:        plat.Cursor_Shape,
	user:          rawptr,
	on_frame:      proc(p: ^Page),
	on_cursor:     proc(p: ^Page),
	on_fullscreen: proc(p: ^Page, on: bool),
}

@(private="file") page_of :: proc "contextless" (v: rawptr) -> ^Page {
	return cast(^Page)g_object_get_data(v, "iris-page")
}

/// a page for a web view made with Iris's display
page_new :: proc(web: ^WebKitWebView) -> ^Page {
	p := new(Page)
	p.web = web
	p.view = webkit_web_view_get_wpe_view(web)
	p.scale = 1
	g_object_set_data(p.view, "iris-page", p)
	p.toplevel = wpe_view_get_toplevel(p.view)
	if p.toplevel != nil do g_object_set_data(p.toplevel, "iris-page", p)
	return p
}

page_free :: proc(p: ^Page) {
	g_object_set_data(p.view, "iris-page", nil)
	if p.toplevel != nil do g_object_set_data(p.toplevel, "iris-page", nil)
	flush_rendered(p)
	for b, im in p.images {
		image_free(im)
		wpe_view_buffer_released(p.view, b)
		unref(b)
	}
	delete(p.images)
	delete(p.rendered_due)
	free(p)
}

/// a frame arrived: it is imported now and drawn at the next frame
@(private="file") page_frame :: proc(p: ^Page, b: ^WPEBuffer) -> bool {
	if p.next != nil && p.next != b {
		// a newer frame came before the last was drawn: that one goes back
		wpe_view_buffer_rendered(p.view, p.next)
		wpe_view_buffer_released(p.view, p.next)
	}
	if is_a(b, wpe_buffer_shm_get_type()) {
		// software rendering: copied once, and the buffer goes back at once
		sb := cast(^WPEBufferSHM)b
		size: uint
		data := g_bytes_get_data(wpe_buffer_shm_get_data(sb), &size)
		texture_upload(&p.tex, data, wpe_buffer_get_width(b), wpe_buffer_get_height(b), i32(wpe_buffer_shm_get_stride(sb)))
		append(&p.rendered_due, cast(^WPEBuffer)g_object_ref(b))
		wpe_view_buffer_released(p.view, b)
		if p.on_frame != nil do p.on_frame(p)
		return true
	}
	if !is_a(b, wpe_buffer_dma_buf_get_type()) do return false
	if b not_in p.images {
		im, ok := image_import(cast(^WPEBufferDMABuf)b)
		if !ok do return false
		p.images[cast(^WPEBuffer)g_object_ref(b)] = im
	}
	p.next = b
	if p.on_frame != nil do p.on_frame(p)
	return true
}

/// the renderer is about to draw: the newest frame becomes the one shown,
/// and the one it replaces goes back to WebKit
page_latch :: proc(p: ^Page) {
	if p.next == nil do return
	if p.shown != nil && p.shown != p.next do wpe_view_buffer_released(p.view, p.shown)
	p.shown = p.next
	p.next = nil
	im := p.images[p.shown]
	p.tex = {id = im.tex, w = im.w, h = im.h, premultiplied = true}
	append(&p.rendered_due, cast(^WPEBuffer)g_object_ref(p.shown))
}

/// the frame is on screen: WebKit makes its next one
flush_rendered :: proc(p: ^Page) {
	for b in p.rendered_due {
		wpe_view_buffer_rendered(p.view, b)
		unref(b)
	}
	clear(&p.rendered_due)
}

/// the page's place in the window, and the window's scale
page_place :: proc(p: ^Page, x, y, w, h: f64, scale: f64) {
	resized := w != p.w || h != p.h
	p.x, p.y = x, y
	if p.toplevel != nil && scale != p.scale {
		wpe_toplevel_scale_changed(p.toplevel, scale)
	}
	p.scale = scale
	if !resized || w <= 0 || h <= 0 do return
	p.w, p.h = w, h
	if p.toplevel != nil do wpe_toplevel_resized(p.toplevel, i32(w), i32(h))
	wpe_view_resized(p.view, i32(w), i32(h))
}

page_set_visible :: proc(p: ^Page, on: bool) {
	if on do wpe_view_map(p.view)
	wpe_view_set_visible(p.view, on ? 1 : 0)
}

page_set_active :: proc(p: ^Page, on: bool) {
	if p.toplevel == nil do return
	s := wpe_toplevel_get_state(p.toplevel)
	s = on ? s | WPE_TOPLEVEL_STATE_ACTIVE : s & ~WPE_TOPLEVEL_STATE_ACTIVE
	wpe_toplevel_state_changed(p.toplevel, s)
}

page_focus :: proc(p: ^Page, on: bool) {
	if on { wpe_view_focus_in(p.view) } else { wpe_view_focus_out(p.view) }
}

// ---------------------------------------------------------------- input

@(private="file") wpe_mods :: proc(m: plat.Mods, buttons: i32) -> i32 {
	r := buttons
	if .Ctrl in m do r |= WPE_MODIFIER_KEYBOARD_CONTROL
	if .Shift in m do r |= WPE_MODIFIER_KEYBOARD_SHIFT
	if .Alt in m do r |= WPE_MODIFIER_KEYBOARD_ALT
	if .Logo in m do r |= WPE_MODIFIER_KEYBOARD_META
	return r
}

@(private="file") button_mask :: proc(b: u32) -> i32 {
	switch b {
	case 1: return WPE_MODIFIER_POINTER_BUTTON1
	case 2: return WPE_MODIFIER_POINTER_BUTTON2
	case 3: return WPE_MODIFIER_POINTER_BUTTON3
	}
	return 0
}

@(private="file") send :: proc(p: ^Page, e: ^WPEEvent) {
	if e == nil do return
	wpe_view_event(p.view, e)
	wpe_event_unref(e)
}

/// a pointer event in window coordinates, for this page
page_pointer :: proc(p: ^Page, e: plat.Pointer_Event) {
	x, y := e.x - p.x, e.y - p.y
	switch e.kind {
	case .Enter:
		p.pointer = {x, y}
		send(p, wpe_event_pointer_move_new(WPE_EVENT_POINTER_ENTER, p.view, WPE_INPUT_SOURCE_MOUSE, e.time, wpe_mods(e.mods, p.buttons), x, y, 0, 0))
	case .Leave:
		send(p, wpe_event_pointer_move_new(WPE_EVENT_POINTER_LEAVE, p.view, WPE_INPUT_SOURCE_MOUSE, e.time, wpe_mods(e.mods, p.buttons), p.pointer.x, p.pointer.y, 0, 0))
	case .Motion:
		dx, dy := x - p.pointer.x, y - p.pointer.y
		p.pointer = {x, y}
		send(p, wpe_event_pointer_move_new(WPE_EVENT_POINTER_MOVE, p.view, WPE_INPUT_SOURCE_MOUSE, e.time, wpe_mods(e.mods, p.buttons), x, y, dx, dy))
	case .Button:
		if e.pressed {
			p.buttons |= button_mask(e.button)
			n := wpe_view_compute_press_count(p.view, x, y, e.button, e.time)
			send(p, wpe_event_pointer_button_new(WPE_EVENT_POINTER_DOWN, p.view, WPE_INPUT_SOURCE_MOUSE, e.time, wpe_mods(e.mods, p.buttons), e.button, x, y, n))
		} else {
			p.buttons &= ~button_mask(e.button)
			send(p, wpe_event_pointer_button_new(WPE_EVENT_POINTER_UP, p.view, WPE_INPUT_SOURCE_MOUSE, e.time, wpe_mods(e.mods, p.buttons), e.button, x, y, 0))
		}
	case .Scroll:
		// WebKit's deltas point the other way from Wayland's
		src := e.precise ? WPE_INPUT_SOURCE_TOUCHPAD : WPE_INPUT_SOURCE_MOUSE
		dx, dy := -e.dx, -e.dy
		if !e.precise {
			// a wheel notch is 15 units from the compositor: one step of 3 lines
			dx, dy = dx / 15, dy / 15
		}
		send(p, wpe_event_scroll_new(p.view, src, e.time, wpe_mods(e.mods, p.buttons), dx, dy, e.precise ? 1 : 0, 0, p.pointer.x, p.pointer.y))
	case .Scroll_Stop:
		send(p, wpe_event_scroll_new(p.view, WPE_INPUT_SOURCE_TOUCHPAD, e.time, wpe_mods(e.mods, p.buttons), 0, 0, 1, 1, p.pointer.x, p.pointer.y))
	}
}

page_key :: proc(p: ^Page, e: plat.Key_Event) {
	t := e.pressed ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP
	send(p, wpe_event_keyboard_new(t, p.view, WPE_INPUT_SOURCE_KEYBOARD, e.time, wpe_mods(e.mods, 0), e.code, e.keysym))
}

} // when !ENGINE_CEF
