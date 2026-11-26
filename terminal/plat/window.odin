// One Wayland window drawn with OpenGL ES 3 through EGL: what Iris and
// Ember both stand on (no GTK, no X11). It keeps the window sharp at every
// scale (fractional-scale and viewporter, or integer buffer scales), reads
// the keyboard through xkbcommon, sets the cursor by name, asks the
// compositor to blur behind the window, and paces drawing with frame
// callbacks.
package plat

import "base:runtime"
import "core:c"
import "core:math"
import "core:strings"
import "core:sys/linux"
import "vendor:egl"
import gl "vendor:OpenGL"
import wl "../wl"

Mod :: enum u8 { Shift, Ctrl, Alt, Logo }
Mods :: bit_set[Mod; u8]

Pointer_Kind :: enum u8 { Enter, Leave, Motion, Button, Scroll, Scroll_Stop }

Pointer_Event :: struct {
	kind:    Pointer_Kind,
	x, y:    f64, // logical pixels
	button:  u32, // 1 left, 2 middle, 3 right, 8 back, 9 forward
	pressed: bool,
	clicks:  int, // 1, 2 or 3 for quick presses in one place
	dx, dy:  f64, // scroll, in logical pixels (wheel notches give 3 lines)
	precise: bool, // a touchpad (smooth scrolling)
	time:    u32,
	mods:    Mods,
}

Key_Event :: struct {
	sym:     u32, // keysym, lower-cased (for shortcuts)
	keysym:  u32, // keysym as typed (for the page)
	code:    u32, // evdev keycode + 8 (xkb)
	text:    string, // what the key types (empty for control keys)
	pressed: bool,
	repeat:  bool,
	mods:    Mods,
	time:    u32,
}

Cursor_Shape :: enum u8 { Default, Pointer, Text, Grab, Ew_Resize, Ns_Resize }

Handler :: struct {
	user:      rawptr,
	draw:      proc(w: ^Window),
	resized:   proc(w: ^Window),
	pointer:   proc(w: ^Window, e: Pointer_Event),
	key:       proc(w: ^Window, e: Key_Event),
	focus:     proc(w: ^Window, on: bool),
	/// the compositor's keymap (fd stays open until this returns)
	keymap:    proc(w: ^Window, format: u32, fd: i32, size: u32),
	close:     proc(w: ^Window),
	/// the last frame drawn is on screen
	presented: proc(w: ^Window),
}

Window :: struct {
	using handler: Handler,
	display:       ^wl.Wl_Display,
	registry:      ^wl.Wl_Registry,
	compositor:    ^wl.Wl_Compositor,
	shm:           ^wl.Wl_Shm,
	wm_base:       ^wl.Xdg_Wm_Base,
	seat:          ^wl.Wl_Seat,
	pointer_dev:   ^wl.Wl_Pointer,
	keyboard_dev:  ^wl.Wl_Keyboard,
	viewporter:    ^wl.Wp_Viewporter,
	fractional:    ^wl.Wp_Fractional_Scale_Manager_V1,
	cursor_shapes: ^wl.Wp_Cursor_Shape_Manager_V1,
	decorations:   ^wl.Zxdg_Decoration_Manager_V1,
	blur_manager:  ^wl.Ext_Background_Effect_Manager_V1,
	data_devices:  ^wl.Wl_Data_Device_Manager,

	surface:       ^wl.Wl_Surface,
	xdg_surface:   ^wl.Xdg_Surface,
	toplevel:      ^wl.Xdg_Toplevel,
	viewport:      ^wl.Wp_Viewport,
	frac:          ^wl.Wp_Fractional_Scale_V1,
	cursor_device: ^wl.Wp_Cursor_Shape_Device_V1,
	blur:          ^wl.Ext_Background_Effect_Surface_V1,
	cursor_theme:  ^Cursor_Theme,
	cursor_surface: ^wl.Wl_Surface,

	egl_display:   egl.Display,
	egl_config:    egl.Config,
	egl_context:   egl.Context,
	egl_surface:   egl.Surface,
	egl_window:    ^wl.Egl_Window,

	/// logical size and the scale (1.25 on a 1.25 screen)
	width, height: i32,
	scale:         f64,
	scale120:      u32,
	int_scale:     i32,
	/// the buffer's size in pixels
	pixel_w, pixel_h: i32,

	configured:    bool,
	closed:        bool,
	fullscreen:    bool,
	maximized:     bool,
	tiled:         bool,
	/// the compositor draws the window's frame (with xdg-decoration); when
	/// not, the app draws its own close, minimise and maximise buttons
	server_frame:  bool,
	activated:     bool,
	frame_pending: bool,
	dirty:         bool,

	// input
	pointer_x, pointer_y: f64,
	pointer_serial: u32,
	last_serial:    u32,
	cursor_shape:   Cursor_Shape,
	scroll_dx, scroll_dy: f64,
	scroll_precise: bool,
	scroll_any:     bool,
	click_time:     u32,
	click_x, click_y: f64,
	click_button:   u32,
	clicks:         int,
	xkb_ctx:        ^Xkb_Context,
	xkb_keymap:     ^Xkb_Keymap,
	xkb_state:      ^Xkb_State,
	mods:           Mods,
	repeat_rate:    i32,
	repeat_delay:   i32,
	repeat_fd:      linux.Fd,
	repeat_key:     u32,
	repeat_time:    u32,
	text_buf:       [16]u8,

	ctx:            runtime.Context,
}

@(private) ctx_of :: proc "contextless" (data: rawptr) -> (^Window, runtime.Context) {
	w := cast(^Window)data
	return w, w.ctx
}

// ---------------------------------------------------------------- registry

@(private) registry_listener := wl.Wl_Registry_Listener {
	global = proc "c" (data: rawptr, r: ^wl.Wl_Registry, name: u32, iface: cstring, version: u32) {
		w := cast(^Window)data
		switch string(iface) {
		case "wl_compositor":
			w.compositor = cast(^wl.Wl_Compositor)wl.wl_registry_bind(r, name, &wl.wl_compositor_interface, min(version, 6))
		case "wl_shm":
			w.shm = cast(^wl.Wl_Shm)wl.wl_registry_bind(r, name, &wl.wl_shm_interface, 1)
		case "xdg_wm_base":
			w.wm_base = cast(^wl.Xdg_Wm_Base)wl.wl_registry_bind(r, name, &wl.xdg_wm_base_interface, min(version, 6))
			wl.xdg_wm_base_add_listener(w.wm_base, &wm_base_listener, w)
		case "wl_seat":
			if w.seat == nil {
				w.seat = cast(^wl.Wl_Seat)wl.wl_registry_bind(r, name, &wl.wl_seat_interface, min(version, 7))
				wl.wl_seat_add_listener(w.seat, &seat_listener, w)
			}
		case "wp_viewporter":
			w.viewporter = cast(^wl.Wp_Viewporter)wl.wl_registry_bind(r, name, &wl.wp_viewporter_interface, 1)
		case "wp_fractional_scale_manager_v1":
			w.fractional = cast(^wl.Wp_Fractional_Scale_Manager_V1)wl.wl_registry_bind(r, name, &wl.wp_fractional_scale_manager_v1_interface, 1)
		case "wp_cursor_shape_manager_v1":
			w.cursor_shapes = cast(^wl.Wp_Cursor_Shape_Manager_V1)wl.wl_registry_bind(r, name, &wl.wp_cursor_shape_manager_v1_interface, 1)
		case "zxdg_decoration_manager_v1":
			w.decorations = cast(^wl.Zxdg_Decoration_Manager_V1)wl.wl_registry_bind(r, name, &wl.zxdg_decoration_manager_v1_interface, 1)
		case "ext_background_effect_manager_v1":
			w.blur_manager = cast(^wl.Ext_Background_Effect_Manager_V1)wl.wl_registry_bind(r, name, &wl.ext_background_effect_manager_v1_interface, 1)
		case "wl_data_device_manager":
			w.data_devices = cast(^wl.Wl_Data_Device_Manager)wl.wl_registry_bind(r, name, &wl.wl_data_device_manager_interface, min(version, 3))
		}
	},
	global_remove = proc "c" (data: rawptr, r: ^wl.Wl_Registry, name: u32) {},
}

@(private) wm_base_listener := wl.Xdg_Wm_Base_Listener {
	ping = proc "c" (data: rawptr, b: ^wl.Xdg_Wm_Base, serial: u32) { wl.xdg_wm_base_pong(b, serial) },
}

// ---------------------------------------------------------------- the surface

@(private) surface_listener := wl.Wl_Surface_Listener {
	enter = proc "c" (data: rawptr, s: ^wl.Wl_Surface, o: ^wl.Wl_Output) {},
	leave = proc "c" (data: rawptr, s: ^wl.Wl_Surface, o: ^wl.Wl_Output) {},
	preferred_buffer_scale = proc "c" (data: rawptr, s: ^wl.Wl_Surface, factor: i32) {
		w, c := ctx_of(data)
		context = c
		if w.frac != nil || factor == w.int_scale do return
		w.int_scale = factor
		apply_size(w)
	},
	preferred_buffer_transform = proc "c" (data: rawptr, s: ^wl.Wl_Surface, t: u32) {},
}

@(private) frac_listener := wl.Wp_Fractional_Scale_V1_Listener {
	preferred_scale = proc "c" (data: rawptr, f: ^wl.Wp_Fractional_Scale_V1, scale: u32) {
		w, c := ctx_of(data)
		context = c
		if scale == w.scale120 do return
		w.scale120 = scale
		apply_size(w)
	},
}

@(private) xdg_surface_listener := wl.Xdg_Surface_Listener {
	configure = proc "c" (data: rawptr, s: ^wl.Xdg_Surface, serial: u32) {
		w, c := ctx_of(data)
		context = c
		wl.xdg_surface_ack_configure(s, serial)
		first := !w.configured
		w.configured = true
		apply_size(w)
		// the first frame waits until the app can draw it (invalidate)
		if first && w.draw != nil do draw_now(w)
	},
}

@(private) toplevel_listener := wl.Xdg_Toplevel_Listener {
	configure = proc "c" (data: rawptr, t: ^wl.Xdg_Toplevel, width, height: i32, states: ^wl.Array) {
		w, c := ctx_of(data)
		context = c
		if width > 0 && height > 0 {
			w.width = width
			w.height = height
		}
		w.fullscreen, w.maximized, w.tiled, w.activated = false, false, false, false
		st := ([^]u32)(states.data)[:states.size / 4]
		for s in st {
			switch s {
			case wl.XDG_TOPLEVEL_STATE_FULLSCREEN: w.fullscreen = true
			case wl.XDG_TOPLEVEL_STATE_MAXIMIZED: w.maximized = true
			case wl.XDG_TOPLEVEL_STATE_ACTIVATED: w.activated = true
			case wl.XDG_TOPLEVEL_STATE_TILED_LEFT, wl.XDG_TOPLEVEL_STATE_TILED_RIGHT,
			     wl.XDG_TOPLEVEL_STATE_TILED_TOP, wl.XDG_TOPLEVEL_STATE_TILED_BOTTOM:
				w.tiled = true
			}
		}
	},
	close = proc "c" (data: rawptr, t: ^wl.Xdg_Toplevel) {
		w, c := ctx_of(data)
		context = c
		if w.close != nil { w.close(w) } else { w.closed = true }
	},
	configure_bounds = proc "c" (data: rawptr, t: ^wl.Xdg_Toplevel, width, height: i32) {},
	wm_capabilities = proc "c" (data: rawptr, t: ^wl.Xdg_Toplevel, caps: ^wl.Array) {},
}

/// the scale as a number (1.25), from whichever the compositor gives
effective_scale :: proc(w: ^Window) -> f64 {
	if w.frac != nil && w.scale120 > 0 do return f64(w.scale120) / 120
	return f64(max(1, w.int_scale))
}

/// the buffer's size for the logical size and the scale
@(private) apply_size :: proc(w: ^Window) {
	if !w.configured do return
	w.scale = effective_scale(w)
	pw := i32(math.round(f64(w.width) * w.scale))
	ph := i32(math.round(f64(w.height) * w.scale))
	if w.viewport != nil {
		wl.wp_viewport_set_destination(w.viewport, w.width, w.height)
		wl.wl_surface_set_buffer_scale(w.surface, 1)
	} else {
		// no viewporter: whole scales only
		s := i32(math.ceil(w.scale))
		pw, ph = w.width * s, w.height * s
		w.scale = f64(s)
		wl.wl_surface_set_buffer_scale(w.surface, s)
	}
	if pw == w.pixel_w && ph == w.pixel_h do return
	w.pixel_w, w.pixel_h = pw, ph
	if w.egl_window != nil do wl.egl_window_resize(w.egl_window, pw, ph, 0, 0)
	if w.resized != nil do w.resized(w)
	w.dirty = true
}

// ---------------------------------------------------------------- opening

Options :: struct {
	app_id:     cstring,
	title:      cstring,
	width:      i32,
	height:     i32,
	fullscreen: bool,
	min_width:  i32,
	min_height: i32,
}

/// connects to the compositor and opens the window; false when there is
/// no Wayland display (Iris and Ember need one: there is no X11)
open :: proc(w: ^Window, o: Options) -> bool {
	w.ctx = context
	w.display = wl.display_connect(nil)
	if w.display == nil do return false
	w.registry = wl.wl_display_get_registry(w.display)
	wl.wl_registry_add_listener(w.registry, &registry_listener, w)
	wl.display_roundtrip(w.display)
	if w.compositor == nil || w.wm_base == nil do return false
	wl.display_roundtrip(w.display) // the seat's capabilities

	w.width, w.height = max(o.width, 320), max(o.height, 240)
	w.int_scale = 1
	w.scale = 1
	w.surface = wl.wl_compositor_create_surface(w.compositor)
	wl.wl_surface_add_listener(w.surface, &surface_listener, w)
	if w.viewporter != nil do w.viewport = wl.wp_viewporter_get_viewport(w.viewporter, w.surface)
	if w.fractional != nil && w.viewport != nil {
		w.frac = wl.wp_fractional_scale_manager_v1_get_fractional_scale(w.fractional, w.surface)
		wl.wp_fractional_scale_v1_add_listener(w.frac, &frac_listener, w)
	}
	w.xdg_surface = wl.xdg_wm_base_get_xdg_surface(w.wm_base, w.surface)
	wl.xdg_surface_add_listener(w.xdg_surface, &xdg_surface_listener, w)
	w.toplevel = wl.xdg_surface_get_toplevel(w.xdg_surface)
	wl.xdg_toplevel_add_listener(w.toplevel, &toplevel_listener, w)
	wl.xdg_toplevel_set_app_id(w.toplevel, o.app_id)
	wl.xdg_toplevel_set_title(w.toplevel, o.title)
	if o.min_width > 0 do wl.xdg_toplevel_set_min_size(w.toplevel, o.min_width, o.min_height)
	if o.fullscreen do wl.xdg_toplevel_set_fullscreen(w.toplevel, nil)
	if w.decorations != nil {
		// the compositor's own frame (niri draws none, and Iris's chrome is its titlebar)
		d := wl.zxdg_decoration_manager_v1_get_toplevel_decoration(w.decorations, w.toplevel)
		wl.zxdg_toplevel_decoration_v1_set_mode(d, wl.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
		w.server_frame = true
	}
	if w.blur_manager != nil do w.blur = wl.ext_background_effect_manager_v1_get_background_effect(w.blur_manager, w.surface)

	if !init_egl(w) do return false
	wl.wl_surface_commit(w.surface)
	tfd, err := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
	w.repeat_fd = err == .NONE ? tfd : linux.Fd(-1)
	for !w.configured && wl.display_dispatch(w.display) >= 0 {}
	return w.configured
}

@(private) init_egl :: proc(w: ^Window) -> bool {
	EGL_PLATFORM_WAYLAND_KHR :: 0x31D8
	w.egl_display = egl.GetPlatformDisplay(egl.Platform(EGL_PLATFORM_WAYLAND_KHR), w.display, nil)
	if w.egl_display == nil do return false
	major, minor: i32
	if !egl.Initialize(w.egl_display, &major, &minor) do return false
	egl.BindAPI(egl.OPENGL_ES_API)
	attrs := [?]i32{
		egl.SURFACE_TYPE, egl.WINDOW_BIT,
		egl.RENDERABLE_TYPE, egl.OPENGL_ES3_BIT,
		egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.ALPHA_SIZE, 8,
		egl.NONE,
	}
	n: i32
	if !egl.ChooseConfig(w.egl_display, &attrs[0], &w.egl_config, 1, &n) || n < 1 do return false
	cattrs := [?]i32{egl.CONTEXT_MAJOR_VERSION, 3, egl.NONE}
	w.egl_context = egl.CreateContext(w.egl_display, w.egl_config, egl.NO_CONTEXT, &cattrs[0])
	if w.egl_context == nil do return false
	w.pixel_w, w.pixel_h = w.width, w.height
	w.egl_window = wl.egl_window_create(w.surface, w.width, w.height)
	w.egl_surface = egl.CreatePlatformWindowSurface(w.egl_display, w.egl_config, w.egl_window, nil)
	if w.egl_surface == nil do return false
	if !egl.MakeCurrent(w.egl_display, w.egl_surface, w.egl_surface, w.egl_context) do return false
	egl.SwapInterval(w.egl_display, 0) // frame callbacks pace drawing
	gl.load_gles_up_to(3, 0, egl.gl_set_proc_address)
	return true
}

// ---------------------------------------------------------------- drawing

@(private) frame_listener := wl.Wl_Callback_Listener {
	done = proc "c" (data: rawptr, cb: ^wl.Wl_Callback, time: u32) {
		w, c := ctx_of(data)
		context = c
		wl.wl_callback_destroy(cb)
		w.frame_pending = false
		if w.presented != nil do w.presented(w)
		if w.dirty do draw_now(w)
	},
}

/// something changed: the window draws again at the next frame
invalidate :: proc(w: ^Window) {
	w.dirty = true
	if !w.frame_pending && w.configured && w.draw != nil do draw_now(w)
}

@(private) draw_now :: proc(w: ^Window) {
	w.dirty = false
	cb := wl.wl_surface_frame(w.surface)
	wl.wl_callback_add_listener(cb, &frame_listener, w)
	w.frame_pending = true
	egl.MakeCurrent(w.egl_display, w.egl_surface, w.egl_surface, w.egl_context)
	gl.Viewport(0, 0, w.pixel_w, w.pixel_h)
	if w.draw != nil do w.draw(w)
	egl.SwapBuffers(w.egl_display, w.egl_surface)
}

/// the compositor blurs what is behind these rectangles (logical pixels);
/// none clears it
set_blur :: proc(w: ^Window, rects: [][4]i32) {
	if w.blur == nil do return
	if len(rects) == 0 {
		wl.ext_background_effect_surface_v1_set_blur_region(w.blur, nil)
		return
	}
	r := wl.wl_compositor_create_region(w.compositor)
	for x in rects do wl.wl_region_add(r, x[0], x[1], x[2], x[3])
	wl.ext_background_effect_surface_v1_set_blur_region(w.blur, r)
	wl.wl_region_destroy(r)
}

/// the parts of the window nothing shows through (lets the compositor skip
/// drawing what is behind them)
set_opaque :: proc(w: ^Window, rects: [][4]i32) {
	r := wl.wl_compositor_create_region(w.compositor)
	for x in rects do wl.wl_region_add(r, x[0], x[1], x[2], x[3])
	wl.wl_surface_set_opaque_region(w.surface, r)
	wl.wl_region_destroy(r)
}

// ---------------------------------------------------------------- the loop

/// reads and handles what the compositor sent; false when the connection is gone
pump :: proc(w: ^Window) -> bool {
	for wl.display_prepare_read(w.display) != 0 {
		if wl.display_dispatch_pending(w.display) < 0 do return false
	}
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(wl.display_get_fd(w.display)), events = {.IN}}}
	n, _ := linux.poll(fds[:], 0)
	if n > 0 && .IN in fds[0].revents {
		if wl.display_read_events(w.display) < 0 do return false
	} else {
		wl.display_cancel_read(w.display)
	}
	if wl.display_dispatch_pending(w.display) < 0 do return false
	wl.display_flush(w.display)
	return wl.display_get_error(w.display) == 0
}

/// the file descriptors to wait on: the compositor's socket and key repeat
fds :: proc(w: ^Window) -> (display: linux.Fd, repeat: linux.Fd) {
	return linux.Fd(wl.display_get_fd(w.display)), w.repeat_fd
}

/// waits for the compositor or the timeout (ms, -1 forever), with extra fds
/// (Ember's socket); returns the extra fds that became readable as a mask
wait :: proc(w: ^Window, timeout: i32, extra: []linux.Fd = nil) -> (ready: u64, ok: bool) {
	wl.display_flush(w.display)
	pfds: [16]linux.Poll_Fd
	pfds[0] = {fd = linux.Fd(wl.display_get_fd(w.display)), events = {.IN}}
	pfds[1] = {fd = w.repeat_fd, events = {.IN}}
	n := 2
	for f in extra {
		if n >= len(pfds) do break
		pfds[n] = {fd = f, events = {.IN}}
		n += 1
	}
	linux.poll(pfds[:n], timeout)
	if .IN in pfds[1].revents do repeat_fired(w)
	for i in 2 ..< n do if .IN in pfds[i].revents do ready |= 1 << u64(i - 2)
	return ready, pump(w)
}

// ---------------------------------------------------------------- the cursor

set_cursor :: proc(w: ^Window, s: Cursor_Shape) {
	w.cursor_shape = s
	if w.pointer_dev == nil || w.pointer_serial == 0 do return
	if w.cursor_device != nil {
		shapes := [Cursor_Shape]u32 {
			.Default   = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT,
			.Pointer   = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER,
			.Text      = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT,
			.Grab      = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB,
			.Ew_Resize = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE,
			.Ns_Resize = wl.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE,
		}
		wl.wp_cursor_shape_device_v1_set_shape(w.cursor_device, w.pointer_serial, shapes[s])
		return
	}
	// no cursor-shape protocol: the cursor theme's picture
	if w.cursor_theme == nil && w.shm != nil {
		w.cursor_theme = wl_cursor_theme_load(nil, i32(24 * max(1, math.ceil(w.scale))), w.shm)
		w.cursor_surface = wl.wl_compositor_create_surface(w.compositor)
	}
	if w.cursor_theme == nil do return
	names := [Cursor_Shape][2]cstring {
		.Default = {"default", "left_ptr"}, .Pointer = {"pointer", "hand2"}, .Text = {"text", "xterm"},
		.Grab = {"grabbing", "fleur"}, .Ew_Resize = {"ew-resize", "sb_h_double_arrow"}, .Ns_Resize = {"ns-resize", "sb_v_double_arrow"},
	}
	cur := wl_cursor_theme_get_cursor(w.cursor_theme, names[s][0])
	if cur == nil do cur = wl_cursor_theme_get_cursor(w.cursor_theme, names[s][1])
	if cur == nil || cur.image_count == 0 do return
	img := cur.images[0]
	k := i32(max(1, math.ceil(w.scale)))
	wl.wl_surface_set_buffer_scale(w.cursor_surface, k)
	wl.wl_surface_attach(w.cursor_surface, wl_cursor_image_get_buffer(img), 0, 0)
	wl.wl_surface_damage(w.cursor_surface, 0, 0, i32(img.width), i32(img.height))
	wl.wl_surface_commit(w.cursor_surface)
	wl.wl_pointer_set_cursor(w.pointer_dev, w.pointer_serial, w.cursor_surface, i32(img.hotspot_x) / k, i32(img.hotspot_y) / k)
}

/// the window follows the pointer (a drag on the chrome)
begin_move :: proc(w: ^Window) {
	if w.seat != nil do wl.xdg_toplevel_move(w.toplevel, w.seat, w.last_serial)
}

begin_resize :: proc(w: ^Window, edges: u32) {
	if w.seat != nil do wl.xdg_toplevel_resize(w.toplevel, w.seat, w.last_serial, edges)
}

minimize :: proc(w: ^Window) {
	wl.xdg_toplevel_set_minimized(w.toplevel)
}

toggle_maximized :: proc(w: ^Window) {
	if w.maximized { wl.xdg_toplevel_unset_maximized(w.toplevel) } else { wl.xdg_toplevel_set_maximized(w.toplevel) }
}

set_fullscreen :: proc(w: ^Window, on: bool) {
	if on { wl.xdg_toplevel_set_fullscreen(w.toplevel, nil) } else { wl.xdg_toplevel_unset_fullscreen(w.toplevel) }
}

set_title :: proc(w: ^Window, title: string) {
	t := strings.clone_to_cstring(title, context.temp_allocator)
	wl.xdg_toplevel_set_title(w.toplevel, t)
}

// ---------------------------------------------------------------- the seat

@(private) seat_listener := wl.Wl_Seat_Listener {
	capabilities = proc "c" (data: rawptr, s: ^wl.Wl_Seat, caps: u32) {
		w, c := ctx_of(data)
		context = c
		if caps & wl.WL_SEAT_CAPABILITY_POINTER != 0 && w.pointer_dev == nil {
			w.pointer_dev = wl.wl_seat_get_pointer(s)
			wl.wl_pointer_add_listener(w.pointer_dev, &pointer_listener, w)
			if w.cursor_shapes != nil do w.cursor_device = wl.wp_cursor_shape_manager_v1_get_pointer(w.cursor_shapes, w.pointer_dev)
		}
		if caps & wl.WL_SEAT_CAPABILITY_KEYBOARD != 0 && w.keyboard_dev == nil {
			w.keyboard_dev = wl.wl_seat_get_keyboard(s)
			wl.wl_keyboard_add_listener(w.keyboard_dev, &keyboard_listener, w)
		}
	},
	name = proc "c" (data: rawptr, s: ^wl.Wl_Seat, name: cstring) {},
}

@(private) send_pointer :: proc(w: ^Window, e: Pointer_Event) {
	ev := e
	ev.x, ev.y = w.pointer_x, w.pointer_y
	ev.mods = w.mods
	if w.pointer != nil do w.pointer(w, ev)
}

@(private) pointer_listener := wl.Wl_Pointer_Listener {
	enter = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, serial: u32, s: ^wl.Wl_Surface, x, y: wl.Fixed) {
		w, c := ctx_of(data)
		context = c
		w.pointer_serial = serial
		w.pointer_x, w.pointer_y = wl.fixed_to_f64(x), wl.fixed_to_f64(y)
		set_cursor(w, w.cursor_shape)
		send_pointer(w, {kind = .Enter})
	},
	leave = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, serial: u32, s: ^wl.Wl_Surface) {
		w, c := ctx_of(data)
		context = c
		send_pointer(w, {kind = .Leave})
	},
	motion = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, time: u32, x, y: wl.Fixed) {
		w, c := ctx_of(data)
		context = c
		w.pointer_x, w.pointer_y = wl.fixed_to_f64(x), wl.fixed_to_f64(y)
		send_pointer(w, {kind = .Motion, time = time})
	},
	button = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, serial, time, button, state: u32) {
		w, c := ctx_of(data)
		context = c
		w.last_serial = serial
		// evdev BTN_LEFT 0x110, RIGHT 0x111, MIDDLE 0x112, SIDE 0x113, EXTRA 0x114
		b: u32
		switch button {
		case 0x110: b = 1
		case 0x111: b = 3
		case 0x112: b = 2
		case 0x113: b = 8
		case 0x114: b = 9
		case: b = button - 0x110 + 1
		}
		pressed := state == wl.WL_POINTER_BUTTON_STATE_PRESSED
		if pressed {
			near := abs(w.pointer_x - w.click_x) < 5 && abs(w.pointer_y - w.click_y) < 5
			if b == w.click_button && near && time - w.click_time < 400 && w.clicks < 3 {
				w.clicks += 1
			} else {
				w.clicks = 1
			}
			w.click_time, w.click_x, w.click_y, w.click_button = time, w.pointer_x, w.pointer_y, b
		}
		send_pointer(w, {kind = .Button, button = b, pressed = pressed, clicks = w.clicks, time = time})
	},
	axis = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, time, axis: u32, value: wl.Fixed) {
		w := cast(^Window)data
		v := wl.fixed_to_f64(value)
		if axis == wl.WL_POINTER_AXIS_VERTICAL_SCROLL { w.scroll_dy += v } else { w.scroll_dx += v }
		w.scroll_any = true
	},
	frame = proc "c" (data: rawptr, p: ^wl.Wl_Pointer) {
		w, c := ctx_of(data)
		context = c
		if !w.scroll_any do return
		send_pointer(w, {kind = .Scroll, dx = w.scroll_dx, dy = w.scroll_dy, precise = w.scroll_precise})
		w.scroll_dx, w.scroll_dy, w.scroll_any = 0, 0, false
	},
	axis_source = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, source: u32) {
		w := cast(^Window)data
		w.scroll_precise = source == wl.WL_POINTER_AXIS_SOURCE_FINGER || source == wl.WL_POINTER_AXIS_SOURCE_CONTINUOUS
	},
	axis_stop = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, time, axis: u32) {
		w, c := ctx_of(data)
		context = c
		send_pointer(w, {kind = .Scroll_Stop, time = time})
	},
	axis_discrete = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, axis: u32, discrete: i32) {},
	axis_value120 = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, axis: u32, v120: i32) {},
	axis_relative_direction = proc "c" (data: rawptr, p: ^wl.Wl_Pointer, axis, direction: u32) {},
}

// ---------------------------------------------------------------- the keyboard

@(private) keyboard_listener := wl.Wl_Keyboard_Listener {
	keymap = proc "c" (data: rawptr, k: ^wl.Wl_Keyboard, format: u32, fd: i32, size: u32) {
		w, c := ctx_of(data)
		context = c
		defer linux.close(linux.Fd(fd))
		if w.keymap != nil do w.keymap(w, format, fd, size)
		if format != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 do return
		m, err := linux.mmap(0, uint(size), {.READ}, {.PRIVATE}, linux.Fd(fd), 0)
		if err != .NONE do return
		defer linux.munmap(m, uint(size))
		if w.xkb_ctx == nil do w.xkb_ctx = xkb_context_new(0)
		km := xkb_keymap_new_from_string(w.xkb_ctx, cstring(m), XKB_KEYMAP_FORMAT_TEXT_V1, 0)
		if km == nil do return
		if w.xkb_state != nil do xkb_state_unref(w.xkb_state)
		if w.xkb_keymap != nil do xkb_keymap_unref(w.xkb_keymap)
		w.xkb_keymap = km
		w.xkb_state = xkb_state_new(km)
	},
	enter = proc "c" (data: rawptr, k: ^wl.Wl_Keyboard, serial: u32, s: ^wl.Wl_Surface, keys: ^wl.Array) {
		w, c := ctx_of(data)
		context = c
		w.last_serial = serial
		if w.focus != nil do w.focus(w, true)
	},
	leave = proc "c" (data: rawptr, k: ^wl.Wl_Keyboard, serial: u32, s: ^wl.Wl_Surface) {
		w, c := ctx_of(data)
		context = c
		stop_repeat(w)
		if w.focus != nil do w.focus(w, false)
	},
	key = proc "c" (data: rawptr, k: ^wl.Wl_Keyboard, serial, time, key, state: u32) {
		w, c := ctx_of(data)
		context = c
		w.last_serial = serial
		code := key + 8
		pressed := state == wl.WL_KEYBOARD_KEY_STATE_PRESSED
		send_key(w, code, pressed, false, time)
		if pressed && w.xkb_keymap != nil && xkb_keymap_key_repeats(w.xkb_keymap, code) != 0 {
			start_repeat(w, code, time)
		} else if !pressed && code == w.repeat_key {
			stop_repeat(w)
		}
	},
	modifiers = proc "c" (data: rawptr, k: ^wl.Wl_Keyboard, serial, depressed, latched, locked, group: u32) {
		w := cast(^Window)data
		if w.xkb_state == nil do return
		xkb_state_update_mask(w.xkb_state, depressed, latched, locked, 0, 0, group)
		w.mods = {}
		if xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0 do w.mods += {.Shift}
		if xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0 do w.mods += {.Ctrl}
		if xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0 do w.mods += {.Alt}
		if xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0 do w.mods += {.Logo}
	},
	repeat_info = proc "c" (data: rawptr, k: ^wl.Wl_Keyboard, rate, delay: i32) {
		w := cast(^Window)data
		w.repeat_rate, w.repeat_delay = rate, delay
	},
}

@(private) send_key :: proc(w: ^Window, code: u32, pressed, repeat: bool, time: u32) {
	if w.xkb_state == nil || w.key == nil do return
	sym := xkb_state_key_get_one_sym(w.xkb_state, code)
	n := xkb_state_key_get_utf8(w.xkb_state, code, &w.text_buf[0], len(w.text_buf))
	text := string(w.text_buf[:clamp(int(n), 0, len(w.text_buf) - 1)])
	// control characters type nothing
	if len(text) == 1 && (text[0] < 0x20 || text[0] == 0x7f) do text = ""
	if .Ctrl in w.mods || .Alt in w.mods do text = ""
	w.key(w, {sym = xkb_keysym_to_lower(sym), keysym = sym, code = code, text = text, pressed = pressed, repeat = repeat, mods = w.mods, time = time})
}

@(private) start_repeat :: proc(w: ^Window, code, time: u32) {
	if w.repeat_rate <= 0 || w.repeat_fd < 0 do return
	w.repeat_key, w.repeat_time = code, time
	interval := 1000 / w.repeat_rate
	spec := linux.ITimer_Spec {
		value    = {time_sec = uint(w.repeat_delay / 1000), time_nsec = uint(w.repeat_delay % 1000) * 1_000_000},
		interval = {time_sec = uint(interval / 1000), time_nsec = uint(interval % 1000) * 1_000_000},
	}
	linux.timerfd_settime(w.repeat_fd, {}, &spec, nil)
}

@(private) stop_repeat :: proc(w: ^Window) {
	w.repeat_key = 0
	if w.repeat_fd < 0 do return
	spec: linux.ITimer_Spec
	linux.timerfd_settime(w.repeat_fd, {}, &spec, nil)
}

/// the repeat timer fired: the held key types again
repeat_fired :: proc(w: ^Window) {
	buf: [8]u8
	linux.read(w.repeat_fd, buf[:])
	if w.repeat_key != 0 do send_key(w, w.repeat_key, true, true, w.repeat_time)
}

close_window :: proc(w: ^Window) {
	if w.egl_display != nil {
		egl.MakeCurrent(w.egl_display, egl.NO_SURFACE, egl.NO_SURFACE, egl.NO_CONTEXT)
		if w.egl_surface != nil do egl.DestroySurface(w.egl_display, w.egl_surface)
		if w.egl_context != nil do egl.DestroyContext(w.egl_display, w.egl_context)
	}
	if w.egl_window != nil do wl.egl_window_destroy(w.egl_window)
	if w.toplevel != nil do wl.xdg_toplevel_destroy(w.toplevel)
	if w.xdg_surface != nil do wl.xdg_surface_destroy(w.xdg_surface)
	if w.surface != nil do wl.wl_surface_destroy(w.surface)
	if w.display != nil {
		wl.display_flush(w.display)
		wl.display_disconnect(w.display)
	}
	if w.repeat_fd >= 0 do linux.close(w.repeat_fd)
}

@(private) _unused_c :: c.int
