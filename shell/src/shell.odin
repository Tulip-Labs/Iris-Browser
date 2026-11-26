// The shell itself: the Wayland connection, one background surface per
// output, niri's event stream, the theme, and one poll loop that sleeps
// until something happens (nothing runs on a timer while the picture is
// still).
package shell

import "base:runtime"
import "core:fmt"
import "core:c/libc"
import "core:strings"
import "core:sys/linux"
import "vendor:egl"
import wl "../wl"
import "../logic"

Output :: struct {
	shell:        ^Shell,
	proxy:        ^wl.Wl_Output,
	reg_name:     u32,
	name:         string,
	surface:      ^wl.Wl_Surface,
	layer:        ^wl.Zwlr_Layer_Surface_V1,
	viewport:     ^wl.Wp_Viewport,
	egl_window:   ^wl.Egl_Window,
	egl_surface:  egl.Surface,
	w, h:         i32, // logical
	bw, bh:       i32, // buffer
	configured:   bool,
	have_frame:   bool,
	frame_pending: bool,
	anim:         logic.Anim,
}

Shell :: struct {
	ctx:          runtime.Context,
	display:      ^wl.Wl_Display,
	registry:     ^wl.Wl_Registry,
	compositor:   ^wl.Wl_Compositor,
	shm:          ^wl.Wl_Shm,
	viewporter:   ^wl.Wp_Viewporter,
	layer_shell:  ^wl.Zwlr_Layer_Shell_V1,
	outputs:      [dynamic]^Output,
	ready:        bool,
	model:        logic.Model,
	look:         Look,
	forced:       logic.Scheme,
	niri_fd:      linux.Fd,
	niri_buf:     [dynamic]u8,
	ctl_fd:       linux.Fd,
	watch_fd:     linux.Fd,
	sig_fd:       linux.Fd, // read end of the self-pipe the signal handlers write to
	quit:         bool,
	check:        bool,
	debug:        bool,
	frames:       int,
	cap:          Capture,
	niri_dir:     string,
}

G: Shell

logf :: proc(format: string, args: ..any) {
	fmt.eprintf("iris-shell: ")
	fmt.eprintfln(format, ..args)
}

debugf :: proc(format: string, args: ..any) {
	if !G.debug do return
	logf(format, ..args)
}

// ---------------------------------------------------------------- registry

registry_listener := wl.Wl_Registry_Listener {
	global = proc "c" (data: rawptr, r: ^wl.Wl_Registry, name: u32, iface: cstring, version: u32) {
		context = G.ctx
		switch string(iface) {
		case "wl_compositor":
			G.compositor = cast(^wl.Wl_Compositor)wl.wl_registry_bind(r, name, &wl.wl_compositor_interface, min(version, 4))
		case "wl_shm":
			G.shm = cast(^wl.Wl_Shm)wl.wl_registry_bind(r, name, &wl.wl_shm_interface, 1)
		case "wp_viewporter":
			G.viewporter = cast(^wl.Wp_Viewporter)wl.wl_registry_bind(r, name, &wl.wp_viewporter_interface, 1)
		case "zwlr_layer_shell_v1":
			G.layer_shell = cast(^wl.Zwlr_Layer_Shell_V1)wl.wl_registry_bind(r, name, &wl.zwlr_layer_shell_v1_interface, min(version, 4))
		case "wl_output":
			o := new(Output)
			o.shell = &G
			o.reg_name = name
			o.proxy = cast(^wl.Wl_Output)wl.wl_registry_bind(r, name, &wl.wl_output_interface, min(version, 4))
			wl.wl_output_add_listener(o.proxy, &output_listener, o)
			append(&G.outputs, o)
			if G.ready do output_open(o)
		case:
			capture_global(r, name, string(iface), version)
		}
	},
	global_remove = proc "c" (data: rawptr, r: ^wl.Wl_Registry, name: u32) {
		context = G.ctx
		for o, i in G.outputs {
			if o.reg_name == name {
				output_close(o)
				ordered_remove(&G.outputs, i)
				free(o)
				break
			}
		}
	},
}

output_listener := wl.Wl_Output_Listener {
	geometry = proc "c" (data: rawptr, self: ^wl.Wl_Output, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {},
	mode = proc "c" (data: rawptr, self: ^wl.Wl_Output, flags: u32, width, height, refresh: i32) {},
	done = proc "c" (data: rawptr, self: ^wl.Wl_Output) {},
	scale = proc "c" (data: rawptr, self: ^wl.Wl_Output, factor: i32) {},
	name = proc "c" (data: rawptr, self: ^wl.Wl_Output, name: cstring) {
		context = G.ctx
		o := cast(^Output)data
		delete(o.name)
		o.name = strings.clone(string(name))
		debugf("output %s", o.name)
		if G.ready do refresh_all()
	},
	description = proc "c" (data: rawptr, self: ^wl.Wl_Output, description: cstring) {},
}

// ---------------------------------------------------------------- the background surface

layer_listener := wl.Zwlr_Layer_Surface_V1_Listener {
	configure = proc "c" (data: rawptr, ls: ^wl.Zwlr_Layer_Surface_V1, serial: u32, width, height: u32) {
		context = G.ctx
		o := cast(^Output)data
		wl.zwlr_layer_surface_v1_ack_configure(ls, serial)
		if width == 0 || height == 0 do return
		o.w, o.h = i32(width), i32(height)
		// the glass is soft: half the pixels (a quarter of the memory and
		// the work) and the compositor scales it up, when it can
		div: i32 = G.viewporter != nil && env("IRIS_SHELL_FULLRES") != "1" ? 2 : 1
		o.bw, o.bh = max(1, o.w / div), max(1, o.h / div)
		if o.viewport != nil do wl.wp_viewport_set_destination(o.viewport, o.w, o.h)
		if o.egl_window == nil {
			o.egl_window = wl.egl_window_create(o.surface, o.bw, o.bh)
			o.egl_surface = gfx_make_surface(o.egl_window)
			if o.egl_surface == nil {
				logf("no EGL surface for %s", o.name)
				return
			}
			// nothing shows through the background: the compositor need not draw under it
			r := wl.wl_compositor_create_region(G.compositor)
			wl.wl_region_add(r, 0, 0, o.w, o.h)
			wl.wl_surface_set_opaque_region(o.surface, r)
			wl.wl_region_destroy(r)
		} else {
			wl.egl_window_resize(o.egl_window, o.bw, o.bh, 0, 0)
		}
		o.configured = true
		o.have_frame = false
		output_update(o, true)
	},
	closed = proc "c" (data: rawptr, ls: ^wl.Zwlr_Layer_Surface_V1) {
		context = G.ctx
		output_close(cast(^Output)data)
	},
}

frame_listener := wl.Wl_Callback_Listener {
	done = proc "c" (data: rawptr, cb: ^wl.Wl_Callback, time: u32) {
		context = G.ctx
		wl.wl_callback_destroy(cb)
		o := cast(^Output)data
		o.frame_pending = false
		// only while the one animation runs is there another frame
		if o.anim.running do output_draw(o)
	},
}

/// the surface on the background layer: the whole output, no input,
/// nothing reserved
output_open :: proc(o: ^Output) {
	if o.surface != nil || G.layer_shell == nil do return
	o.surface = wl.wl_compositor_create_surface(G.compositor)
	// no input at all: an empty input region
	r := wl.wl_compositor_create_region(G.compositor)
	wl.wl_surface_set_input_region(o.surface, r)
	wl.wl_region_destroy(r)
	if G.viewporter != nil do o.viewport = wl.wp_viewporter_get_viewport(G.viewporter, o.surface)
	o.layer = wl.zwlr_layer_shell_v1_get_layer_surface(G.layer_shell, o.surface, o.proxy, wl.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "iris-shell")
	wl.zwlr_layer_surface_v1_add_listener(o.layer, &layer_listener, o)
	wl.zwlr_layer_surface_v1_set_anchor(o.layer, wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | wl.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT)
	wl.zwlr_layer_surface_v1_set_size(o.layer, 0, 0)
	wl.zwlr_layer_surface_v1_set_exclusive_zone(o.layer, -1)
	wl.zwlr_layer_surface_v1_set_keyboard_interactivity(o.layer, wl.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE)
	wl.wl_surface_commit(o.surface)
}

output_close :: proc(o: ^Output) {
	if o.egl_surface != nil {
		egl.MakeCurrent(gfx.display, egl.NO_SURFACE, egl.NO_SURFACE, egl.NO_CONTEXT)
		egl.DestroySurface(gfx.display, o.egl_surface)
		o.egl_surface = nil
	}
	if o.egl_window != nil {
		wl.egl_window_destroy(o.egl_window)
		o.egl_window = nil
	}
	if o.viewport != nil {
		wl.wp_viewport_destroy(o.viewport)
		o.viewport = nil
	}
	if o.layer != nil {
		wl.zwlr_layer_surface_v1_destroy(o.layer)
		o.layer = nil
	}
	if o.surface != nil {
		wl.wl_surface_destroy(o.surface)
		o.surface = nil
	}
	o.configured = false
}

/// the scene for this output now
output_target :: proc(o: ^Output) -> logic.Frame {
	return logic.scene_for_output(&G.model, o.name, f32(o.w), f32(o.h), G.look.dark)
}

/// the model or the theme changed: ease to the new scene, draw only when the
/// picture is different from what is on screen
output_update :: proc(o: ^Output, first: bool) {
	if !o.configured || o.egl_surface == nil do return
	target := output_target(o)
	now := now_ms()
	if !o.have_frame || first {
		logic.anim_jump(&o.anim, target)
		output_draw(o)
		return
	}
	dur: i64 = G.look.animate ? logic.ANIM_MS : 0
	if logic.anim_to(&o.anim, now, target, dur) do output_draw(o)
}

output_draw :: proc(o: ^Output) {
	if !o.configured || o.egl_surface == nil do return
	now := now_ms()
	f, done := logic.anim_value(&o.anim, now)
	if done do o.anim.running = false
	if !done && !o.frame_pending {
		cb := wl.wl_surface_frame(o.surface)
		wl.wl_callback_add_listener(cb, &frame_listener, o)
		o.frame_pending = true
	}
	if !gfx_draw(o.egl_surface, &f, o.w, o.h, o.bw, o.bh) {
		logf("drawing failed on %s", o.name)
		return
	}
	o.have_frame = true
	G.frames += 1
	if G.frames == 1 do debugf("first frame: %dx%d (buffer %dx%d)", o.w, o.h, o.bw, o.bh)
}

refresh_all :: proc() {
	for o in G.outputs do output_update(o, false)
}

// ---------------------------------------------------------------- niri

niri_connect :: proc() {
	path := env("NIRI_SOCKET")
	if len(path) == 0 {
		logf("NIRI_SOCKET is not set: the background shows, the windows' glass does not")
		return
	}
	fd, ok := connect_unix(path)
	if !ok {
		logf("cannot connect to niri at %s", path)
		return
	}
	req := logic.EVENT_STREAM_REQUEST
	if _, err := linux.write(fd, transmute([]u8)req); err != .NONE {
		linux.close(fd)
		return
	}
	set_nonblock(fd)
	G.niri_fd = fd
	debugf("niri event stream open")
}

niri_close :: proc() {
	if G.niri_fd >= 0 do linux.close(G.niri_fd)
	G.niri_fd = -1
}

/// reads what niri sent: whole lines, each an event
niri_readable :: proc() {
	chunk: [16384]u8
	for {
		n, err := linux.read(G.niri_fd, chunk[:])
		if err == .EAGAIN do break
		if err != .NONE || n <= 0 {
			// niri went away (the session is ending)
			debugf("niri event stream closed")
			niri_close()
			break
		}
		append(&G.niri_buf, ..chunk[:n])
		if n < len(chunk) do break
	}
	changed := false
	for {
		nl := -1
		for b, i in G.niri_buf do if b == '\n' {nl = i; break}
		if nl < 0 do break
		line := string(G.niri_buf[:nl])
		if ev, ok := logic.parse_event(line, context.temp_allocator); ok {
			logic.model_apply(&G.model, ev)
			changed = true
		}
		remove_range(&G.niri_buf, 0, nl + 1)
	}
	if changed do refresh_all()
	cap_refresh()
}

// ---------------------------------------------------------------- theme and control

/// what the desktop says about light and dark: the shell and niri's settings follow
look_changed :: proc() {
	l := look_read(G.forced)
	if l == G.look do return
	G.look = l
	debugf("theme: dark=%v animate=%v", l.dark, l.animate)
	if len(G.niri_dir) > 0 do logic.refresh_theme_file(G.niri_dir, l.dark)
	refresh_all()
}

ctl_command :: proc(cmd: string) -> (reply: string, quit: bool) {
	switch cmd {
	case "quit":
		// the socket goes first: whoever asked (a shell that is starting) may
		// bind it again as soon as this connection closes
		if G.ctl_fd >= 0 {
			linux.unlink(strings.clone_to_cstring(ctl_path(), context.temp_allocator))
			linux.close(G.ctl_fd)
			G.ctl_fd = -1
		}
		return "bye", true
	case "ping": return "iris-shell " + VERSION, false
	case "status":
		return fmt.tprintf("iris-shell %s: %d output(s), %d window(s), dark=%v, capture=%v", VERSION, len(G.outputs), len(G.model.windows), G.look.dark, G.cap.enabled), false
	case "dark", "light", "auto":
		G.forced = cmd == "dark" ? .Dark : cmd == "light" ? .Light : .Auto
		look_changed()
		return "ok", false
	case "reload":
		look_changed()
		return "ok", false
	}
	return "unknown command", false
}

// ---------------------------------------------------------------- signals

sig_write_fd: linux.Fd = -1

sig_handler :: proc "c" (sig: i32) {
	b := [1]u8{1}
	linux.write(sig_write_fd, b[:])
}

// ---------------------------------------------------------------- run

/// the loop, then the clean-up. Returns the exit code.
run :: proc(check: bool) -> int {
	code := run_loop(check)
	if G.ctl_fd >= 0 {
		linux.close(G.ctl_fd)
		linux.unlink(strings.clone_to_cstring(ctl_path(), context.temp_allocator))
	}
	if G.watch_fd >= 0 do linux.close(G.watch_fd)
	return code
}

run_loop :: proc(check: bool) -> int {
	G.ctx = context
	G.check = check
	G.debug = env("IRIS_SHELL_DEBUG") == "1" || check
	G.niri_fd, G.ctl_fd, G.watch_fd, G.sig_fd = -1, -1, -1, -1
	G.cap.timer = -1

	if v := env("IRIS_THEME"); len(v) > 0 do G.forced = logic.parse_scheme(v)
	G.look = look_read(G.forced)

	G.display = wl.display_connect(nil)
	if G.display == nil {
		logf("no Wayland display (WAYLAND_DISPLAY is %q)", env("WAYLAND_DISPLAY"))
		return 1
	}
	if !check {
		ctl_take_over()
		G.ctl_fd, _ = listen_unix(ctl_path())
	}
	G.registry = wl.wl_display_get_registry(G.display)
	wl.wl_registry_add_listener(G.registry, &registry_listener, nil)
	wl.display_roundtrip(G.display)
	if G.compositor == nil || G.layer_shell == nil {
		logf("this compositor has no wlr-layer-shell: the shell needs it (niri, sway, Hyprland have it)")
		return 1
	}
	if !gfx_init(G.display) {
		logf("no EGL with OpenGL ES 3 on this display")
		return 1
	}
	G.ready = true
	for o in G.outputs do output_open(o)
	wl.display_roundtrip(G.display)
	wl.display_roundtrip(G.display)
	capture_start()

	if !check {
		G.niri_dir = logic.niri_config_dir()
		logic.refresh_theme_file(G.niri_dir, G.look.dark) // the file follows the theme
		niri_connect()
		G.watch_fd = theme_watch()
		// signals: the loop wakes, cleans up and leaves
		p: [2]linux.Fd
		if linux.pipe2(&p, {.CLOEXEC, .NONBLOCK}) == .NONE {
			G.sig_fd, sig_write_fd = p[0], p[1]
			libc_signal(15, sig_handler)
			libc_signal(2, sig_handler)
			libc_signal(1, sig_handler)
		}
	}
	started := now_ms()

	for !G.quit {
		free_all(context.temp_allocator)
		if check && G.frames > 0 && all_drawn() {
			fmt.printfln("iris-shell: check ok: %d output(s) mapped, %d frame(s) drawn", len(G.outputs), G.frames)
			break
		}
		for wl.display_prepare_read(G.display) != 0 do wl.display_dispatch_pending(G.display)
		wl.display_flush(G.display)
		fds: [6]linux.Poll_Fd
		n := 0
		add :: proc(fds: ^[6]linux.Poll_Fd, n: ^int, fd: linux.Fd) -> int {
			if fd < 0 do return -1
			fds[n^] = {fd = fd, events = {.IN}}
			n^ += 1
			return n^ - 1
		}
		i_wl := add(&fds, &n, linux.Fd(wl.display_get_fd(G.display)))
		i_niri := add(&fds, &n, G.niri_fd)
		i_ctl := add(&fds, &n, G.ctl_fd)
		i_watch := add(&fds, &n, G.watch_fd)
		i_sig := add(&fds, &n, G.sig_fd)
		i_cap := add(&fds, &n, G.cap.timer)
		timeout: i32 = -1
		if check do timeout = i32(max(0, 10000 - (now_ms() - started)))
		cnt, perr := linux.poll(fds[:n], timeout)
		if perr == .EINTR {
			wl.display_cancel_read(G.display)
			continue
		}
		if i_wl >= 0 && .IN in fds[i_wl].revents {
			if wl.display_read_events(G.display) < 0 {
				logf("lost the Wayland connection")
				return 1
			}
		} else {
			wl.display_cancel_read(G.display)
		}
		if wl.display_dispatch_pending(G.display) < 0 {
			logf("Wayland error %d", wl.display_get_error(G.display))
			return 1
		}
		if i_niri >= 0 && fds[i_niri].revents != {} do niri_readable()
		if i_ctl >= 0 && .IN in fds[i_ctl].revents {
			if ctl_serve(G.ctl_fd, ctl_command) do G.quit = true
		}
		if i_watch >= 0 && fds[i_watch].revents != {} {
			theme_watch_drain(G.watch_fd)
			look_changed()
		}
		if i_sig >= 0 && fds[i_sig].revents != {} do G.quit = true
		if i_cap >= 0 && fds[i_cap].revents != {} do capture_tick()
		if check && cnt == 0 {
			logf("check failed: no frame was drawn in 10 seconds (%d output(s), %d frame(s))", len(G.outputs), G.frames)
			return 1
		}
	}
	for o in G.outputs do output_close(o)
	wl.display_flush(G.display)
	niri_close()
	return 0
}

all_drawn :: proc() -> bool {
	if len(G.outputs) == 0 do return false
	for o in G.outputs do if !o.have_frame do return false
	return true
}

libc_signal :: proc(sig: i32, handler: proc "c" (i32)) {
	libc.signal(libc.int(sig), handler)
}
