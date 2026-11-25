// Iris is its own WPEPlatform (WPE WebKit 2.54+): a WPEDisplay, WPEView,
// WPEToplevel and WPEClipboard made here as GObject subclasses. WebKit's
// web process renders each frame into a DMA-BUF and hands it to IrisView's
// render_buffer; Iris imports that buffer, as it is, as an EGL image and
// samples it in its own GLES renderer (no copy), so the Liquid Glass bends
// the live page. Input goes the other way: Wayland's pointer, scroll and
// keys become WPEEvents.
package iris

import "base:runtime"
import "core:image"
import "core:image/jpeg"
import "core:image/png"
import "core:log"
import "core:strings"
import "core:unicode/utf8"
import cef "cef"
import plat "../plat"

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
/// the text on the clipboard (the desktop's, or what Iris copied), for the chrome's fields
clipboard_text: string

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
// Engine_Kind is which page engine a tab runs. WPE is the default and
// the only engine the Flatpak ships; CEF is the experiment beside it
// (--engine=cef, slice 2). The choice is made once in main, before any
// tab exists, and never changes while the browser runs.
Engine_Kind :: enum {
	WPE,
	CEF,
}

// engine_kind is the engine the browser was started with. main sets it
// before the first tab; the Tab seam reads it, never the flag itself.
engine_kind: Engine_Kind

Page :: struct {
	web:           ^WebKitWebView,
	/// CEF tab; used when web == nil (a CEF page has no WPE view)
	cef:           ^cef.Browser,
	cef_closing:   bool,
	cef_closed:    bool,
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
	// the engine's callbacks, for the Tab: title, URL and loading state
	// change; favicon fires when the engine reports an icon URL; close
	// fires when the engine has destroyed the tab (CEF only)
	on_title:      proc(p: ^Page),
	on_url:        proc(p: ^Page),
	on_loading:    proc(p: ^Page),
	on_favicon:    proc(p: ^Page),
	on_close:      proc(p: ^Page),
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

/// a page for a CEF tab: no WPE view, no toplevel — the engine owns the
/// surface and hands frames to the on_frame callback (the Tab sets it).
/// The tab is created with cef.create_browser; the callback fires once
/// the engine hands the browser back, and page_new_cef is what the
/// browser calls with it.
page_new_cef :: proc() -> ^Page {
	p := new(Page)
	p.scale = 1
	return p
}

/// the CEF engine handed the browser back: the tab is now a real page.
/// Called from the engine's on_created callback (the Tab sets it).
page_cef_created :: proc(p: ^Page, b: ^cef.Browser) {
	p.cef = b
	b.user = p
	b.on_frame = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		// The engine wrote a new frame (BGRA, premultiplied — the
		// same format texture_upload takes): upload it to the
		// page's texture now, on this thread, while the GL context
		// is current. The renderer picks it up at the next frame.
		if b.frame_dirty && len(b.frame) > 0 {
			texture_upload(&p.tex, raw_data(b.frame), b.frame_w, b.frame_h, b.frame_w * 4)
			b.frame_dirty = false
		}
		if p.on_frame != nil do p.on_frame(p)
	}
	b.on_title = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		if p.on_title != nil do p.on_title(p)
	}
	b.on_url = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		if p.on_url != nil do p.on_url(p)
	}
	b.on_loading = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		if p.on_loading != nil do p.on_loading(p)
	}
	b.on_cursor = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		p.cursor = cef_cursor_to_plat(b.cursor)
		if p.on_cursor != nil do p.on_cursor(p)
	}
	b.on_fullscreen = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		if p.on_fullscreen != nil do p.on_fullscreen(p, b.fullscreen)
	}
	b.on_favicon = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		if p.on_favicon != nil do p.on_favicon(p)
	}
	b.on_close = proc(b: ^cef.Browser) {
		p := cast(^Page)b.user
		p.cef_closed = true
		if p.on_close != nil do p.on_close(p)
	}
}

page_free :: proc(p: ^Page) {
	if p.cef != nil && !p.cef_closed {
		// a live CEF tab: ask the engine to close it. The engine
		// frees the Browser on its own time (on_close), and the Tab
		// frees the Page only after that.
		if !p.cef_closing {
			p.cef_closing = true
			cef.close_browser(p.cef)
		}
		return
	}
	if p.view != nil do g_object_set_data(p.view, "iris-page", nil)
	if p.toplevel != nil do g_object_set_data(p.toplevel, "iris-page", nil)
	flush_rendered(p)
	for b, im in p.images {
		image_free(im)
		wpe_view_buffer_released(p.view, b)
		unref(b)
	}
	delete(p.images)
	delete(p.rendered_due)
	// a software frame owns its texture (the SHM upload and the CEF
	// frame upload both make one); a DMA-BUF frame only borrows it
	if p.tex.owned do texture_free(&p.tex)
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
	if p.web == nil {
		// a CEF page (or one whose creation failed): no WPE view to
		// place; the engine is resized only when it exists
		resized := w != p.w || h != p.h || scale != p.scale
		p.x, p.y = x, y
		p.scale = scale
		if !resized || w <= 0 || h <= 0 do return
		p.w, p.h = w, h
		if p.cef != nil do cef.set_size(p.cef, i32(w * scale), i32(h * scale))
		return
	}
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
	if p.web == nil {
		if p.cef != nil do cef.set_visible(p.cef, on)
		return
	}
	if on do wpe_view_map(p.view)
	wpe_view_set_visible(p.view, on ? 1 : 0)
}

page_set_active :: proc(p: ^Page, on: bool) {
	if p.web == nil do return // CEF has no toplevel state to set
	if p.toplevel == nil do return
	s := wpe_toplevel_get_state(p.toplevel)
	s = on ? s | WPE_TOPLEVEL_STATE_ACTIVE : s & ~WPE_TOPLEVEL_STATE_ACTIVE
	wpe_toplevel_state_changed(p.toplevel, s)
}

page_focus :: proc(p: ^Page, on: bool) {
	if p.web == nil {
		if p.cef != nil do cef.set_focus(p.cef, on)
		return
	}
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
	if p.cef != nil {
		cef_pointer(p, e)
		return
	}
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
	if p.cef != nil {
		cef_key(p, e)
		return
	}
	t := e.pressed ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP
	send(p, wpe_event_keyboard_new(t, p.view, WPE_INPUT_SOURCE_KEYBOARD, e.time, wpe_mods(e.mods, 0), e.code, e.keysym))
}

// ---------------------------------------------------------------- CEF input

@(private="file") cef_mods :: proc(m: plat.Mods, buttons: i32) -> u32 {
	r := u32(buttons)
	if .Ctrl in m do r |= u32(cef.EVENTFLAG_CONTROL_DOWN)
	if .Shift in m do r |= u32(cef.EVENTFLAG_SHIFT_DOWN)
	if .Alt in m do r |= u32(cef.EVENTFLAG_ALT_DOWN)
	if .Logo in m do r |= u32(cef.EVENTFLAG_COMMAND_DOWN)
	return r
}

@(private="file") cef_button_mask :: proc(b: u32) -> u32 {
	switch b {
	case 1: return u32(cef.EVENTFLAG_LEFT_MOUSE_BUTTON)
	case 2: return u32(cef.EVENTFLAG_MIDDLE_MOUSE_BUTTON)
	case 3: return u32(cef.EVENTFLAG_RIGHT_MOUSE_BUTTON)
	}
	return 0
}

@(private="file") cef_pointer :: proc(p: ^Page, e: plat.Pointer_Event) {
	// Wayland gives logical pixels; CEF takes device pixels
	x, y := i32((e.x - p.x) * p.scale), i32((e.y - p.y) * p.scale)
	switch e.kind {
	case .Enter:
		p.pointer = {e.x - p.x, e.y - p.y}
		cef.send_mouse_move(p.cef, x, y, false, cef_mods(e.mods, p.buttons))
	case .Leave:
		cef.send_mouse_move(p.cef, x, y, true, cef_mods(e.mods, p.buttons))
	case .Motion:
		p.pointer = {e.x - p.x, e.y - p.y}
		cef.send_mouse_move(p.cef, x, y, false, cef_mods(e.mods, p.buttons))
	case .Button:
		if e.pressed {
			p.buttons |= i32(cef_button_mask(e.button))
			cef.send_mouse_click(p.cef, x, y, cef_mouse_button(e.button), true, i32(e.clicks), cef_mods(e.mods, p.buttons))
		} else {
			cef.send_mouse_click(p.cef, x, y, cef_mouse_button(e.button), false, i32(e.clicks), cef_mods(e.mods, p.buttons))
			p.buttons &= ~i32(cef_button_mask(e.button))
		}
	case .Scroll:
		// Wayland's deltas point the other way from Chromium's
		dx, dy := -e.dx, -e.dy
		if !e.precise {
			// a wheel notch is 15 units from the compositor: one step of 3 lines
			dx, dy = dx / 15, dy / 15
		}
		cef.send_mouse_wheel(p.cef, x, y, i32(dx), i32(dy), cef_mods(e.mods, p.buttons))
	case .Scroll_Stop:
		// nothing to send: a scroll stop is not a CEF event
	}
}

@(private="file") cef_mouse_button :: proc(b: u32) -> i32 {
	switch b {
	case 2: return cef.MBT_MIDDLE
	case 3: return cef.MBT_RIGHT
	}
	return cef.MBT_LEFT
}

@(private="file") cef_key :: proc(p: ^Page, e: plat.Key_Event) {
	// Chromium wants the whole sequence for a press: RAWKEYDOWN, then
	// KEYDOWN, then CHAR when the key types text. A release is KEYUP
	// alone. The window code is the keysym mapped to a Windows virtual
	// key; the native code is the evdev code the compositor gave.
	vk := keysym_to_vk(e.keysym, e.sym)
	mods := cef_mods(e.mods, 0)
	if e.repeat do mods |= u32(cef.EVENTFLAG_IS_REPEAT)
	if e.pressed {
		cef.send_key(p.cef, cef.KEYEVENT_RAWKEYDOWN, vk, i32(e.code), mods, 0, 0)
		cef.send_key(p.cef, cef.KEYEVENT_KEYDOWN, vk, i32(e.code), mods, 0, 0)
		if len(e.text) > 0 {
			r, _ := utf8.decode_rune_in_string(e.text)
			cef.send_key(p.cef, cef.KEYEVENT_CHAR, vk, i32(e.code), mods, u16(r), u16(r))
		}
	} else {
		cef.send_key(p.cef, cef.KEYEVENT_KEYUP, vk, i32(e.code), mods, 0, 0)
	}
}

// keysym_to_vk maps an XKB keysym to the Windows virtual-key code CEF
// wants. sym is the lower-cased keysym: letters and digits map to
// themselves, shifted punctuation maps to the unshifted key (the
// character itself travels in CHAR). Anything unmapped falls back to
// the keysym, which Chromium treats as an unknown key rather than the
// wrong one.
keysym_to_vk :: proc(keysym, sym: u32) -> i32 {
	if sym >= 'a' && sym <= 'z' do return i32(sym - 'a' + 'A')
	if sym >= 'A' && sym <= 'Z' do return i32(sym)
	if sym >= '0' && sym <= '9' do return i32(sym)
	switch sym {
	case ' ': return 32
	case '!': return '1'
	case '@': return '2'
	case '#': return '3'
	case '$': return '4'
	case '%': return '5'
	case '^': return '6'
	case '&': return '7'
	case '*': return '8'
	case '(': return '9'
	case ')': return '0'
	case '-': return 189
	case '_': return 189
	case '=': return 187
	case '+': return 187
	case '[': return 219
	case '{': return 219
	case ']': return 221
	case '}': return 221
	case ';': return 186
	case ':': return 186
	case '\'': return 222
	case '"': return 222
	case ',': return 188
	case '<': return 188
	case '.': return 190
	case '>': return 190
	case '/': return 191
	case '?': return 191
	case '`': return 192
	case '~': return 192
	case '\\': return 220
	case '|': return 220
	}
	switch keysym {
	case plat.KEY_BackSpace: return 8
	case plat.KEY_Tab: return 9
	case plat.KEY_Return: return 13
	case plat.KEY_Escape: return 27
	case plat.KEY_Delete: return 46
	case plat.KEY_Home: return 36
	case plat.KEY_End: return 35
	case plat.KEY_Page_Up: return 33
	case plat.KEY_Page_Down: return 34
	case plat.KEY_Left: return 37
	case plat.KEY_Up: return 38
	case plat.KEY_Right: return 39
	case plat.KEY_Down: return 40
	// F-keys: XKB keysyms 0xffbe..0xffc9 (F1..F12); only F5, F6 and
	// F11 have plat constants, the rest are literals
	case 0xffbe: return 112
	case 0xffbf: return 113
	case 0xffc0: return 114
	case 0xffc1: return 115
	case plat.KEY_F5: return 116
	case plat.KEY_F6: return 117
	case 0xffc4: return 118
	case 0xffc5: return 119
	case 0xffc6: return 120
	case 0xffc7: return 121
	case plat.KEY_F11: return 122
	case 0xffc9: return 123
	}
	return i32(keysym)
}

// cef_cursor_to_plat maps CEF's cursor id to the platform cursor shape
// the chrome draws. The platform only has six shapes, so wait, cross
// and the diagonal resizes fall back to the default arrow.
cef_cursor_to_plat :: proc(id: i32) -> plat.Cursor_Shape {
	switch id {
	case cef.CURSOR_HAND: return .Pointer
	case cef.CURSOR_IBEAM: return .Text
	case cef.CURSOR_EASTRESIZE, cef.CURSOR_WESTRESIZE, cef.CURSOR_EASTWESTRESIZE, cef.CURSOR_COLUMNRESIZE: return .Ew_Resize
	case cef.CURSOR_NORTHRESIZE, cef.CURSOR_SOUTHRESIZE, cef.CURSOR_NORTHSOUTHRESIZE, cef.CURSOR_ROWRESIZE: return .Ns_Resize
	}
	return .Default
}

// ---------------------------------------------------------------- CEF favicon

@(private="file") favicon_session: ^SoupSession

// cef_favicon_fetch downloads a CEF tab's icon (the engine only reports
// the URL) and stores it as premultiplied BGRA pixels on the tab, for
// the chrome to draw. The fetch is async; the callback looks the tab
// up by id in the browser, so a tab closed before the fetch returns is
// simply skipped (its id is gone from b.tabs). Only PNG and JPEG are
// decoded — ICO files are left blank.
cef_favicon_fetch :: proc(tab_id: int, url: string) {
	if len(url) == 0 do return
	if favicon_session == nil do favicon_session = soup_session_new()
	msg := soup_message_new("GET", cstr(url))
	if msg == nil do return
	h := soup_message_get_request_headers(msg)
	soup_message_headers_append(h, "User-Agent", USER_AGENT)
	f := new(Favicon_Fetch)
	f.id = tab_id
	f.msg = msg
	soup_session_send_and_read_async(favicon_session, msg, 300, nil, rawptr(proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
		context = main_context
		f := cast(^Favicon_Fetch)d
		defer free(f)
		defer unref(f.msg)
		bytes := soup_session_send_and_read_finish(cast(^SoupSession)o, res, nil)
		if bytes == nil do return
		defer g_bytes_unref(bytes)
		if soup_message_get_status(f.msg) != 200 do return
		n: uint
		p := g_bytes_get_data(bytes, &n)
		if p == nil || n == 0 do return
		data := ([^]u8)(p)[:n]
		img, err := png.load_from_bytes(data)
		if err != nil {
			img, err = jpeg.load_from_bytes(data)
			if err != nil do return
		}
		defer image.destroy(img)
		if img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 do return
		// the tab this fetch was for: it may have closed meanwhile
		t: ^Tab
		for tt in b.tabs do if tt.id == f.id { t = tt; break }
		if t == nil || t.page == nil || t.page.cef == nil do return
		px := favicon_to_bgra(img)
		delete(t.favicon_px)
		t.favicon_px = px[:]
		t.favicon_w, t.favicon_h, t.favicon_stride = i32(img.width), i32(img.height), i32(img.width * 4)
		t.favicon_dirty = true
	}), f)
}

@(private="file") Favicon_Fetch :: struct {
	id:  int,
	msg: ^SoupMessage,
}

// favicon_to_bgra converts a decoded image to premultiplied BGRA, the
// chrome's tab icon format. 16-bit channels keep their high byte;
// grey and grey+alpha replicate the grey value into RGB.
@(private="file") favicon_to_bgra :: proc(img: ^image.Image) -> [dynamic]u8 {
	px := make([dynamic]u8, img.width * img.height * 4)
	bytes_per_channel := img.depth == 16 ? 2 : 1
	for y in 0..<img.height {
		for x in 0..<img.width {
			src := (y * img.width + x) * img.channels * bytes_per_channel
			r, g, bb, a: u8 = 0, 0, 0, 255
			switch img.channels {
			case 1:
				r, g, bb = channel_at(img.pixels, src, 0, bytes_per_channel), channel_at(img.pixels, src, 0, bytes_per_channel), channel_at(img.pixels, src, 0, bytes_per_channel)
			case 2:
				r, g, bb, a = channel_at(img.pixels, src, 0, bytes_per_channel), channel_at(img.pixels, src, 0, bytes_per_channel), channel_at(img.pixels, src, 0, bytes_per_channel), channel_at(img.pixels, src, 1, bytes_per_channel)
			case 3:
				r, g, bb = channel_at(img.pixels, src, 0, bytes_per_channel), channel_at(img.pixels, src, 1, bytes_per_channel), channel_at(img.pixels, src, 2, bytes_per_channel)
			case 4:
				r, g, bb, a = channel_at(img.pixels, src, 0, bytes_per_channel), channel_at(img.pixels, src, 1, bytes_per_channel), channel_at(img.pixels, src, 2, bytes_per_channel), channel_at(img.pixels, src, 3, bytes_per_channel)
			}
			// premultiply: a transparent pixel contributes no colour
			dst := (y * img.width + x) * 4
			px[dst + 0] = u8(u16(bb) * u16(a) / 255)
			px[dst + 1] = u8(u16(g) * u16(a) / 255)
			px[dst + 2] = u8(u16(r) * u16(a) / 255)
			px[dst + 3] = a
		}
	}
	return px
}

// channel_at reads one channel of one pixel: the high byte when the
// image is 16 bits per channel, the byte itself when it is 8.
@(private="file") channel_at :: proc(pixels: [dynamic]u8, src, i, bytes_per_channel: int) -> u8 {
	return pixels[src + i*bytes_per_channel]
}
