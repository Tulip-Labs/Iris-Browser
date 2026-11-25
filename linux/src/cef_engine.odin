// The CEF engine (IRIS_ENGINE=cef, see engine_api.odin): Chromium through
// CEF's C API (cef_capi.odin, cef_gen.odin), windowless. This file is the
// engine itself: the process start (CEF runs this binary again for its
// renderers), the message pump driven by Iris's GLib loop, the request
// contexts (one shared by every normal tab, so sign-ins are shared; one a
// container; one for private tabs; a fresh one per sandboxed tab), the
// renderers' process ids, and downloads. A tab's view is cef_view.odin,
// its pixels and input cef_page.odin, Shields cef_shields.odin.
//
// CEF's reference counting, as its C API wants it: a struct CEF passes to
// a callback carries a reference the callback releases (rel); a struct
// handed to CEF, or returned to it, carries one CEF takes (add_ref first
// to keep one's own); what CEF returns is the caller's to release.
package iris

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf16"

// (not indented: the whole file is this engine's)
when ENGINE_CEF {

/// CEF 156's frozen C API (cef_api_versions.h); the bindings are generated
/// and checked with the same version (tools/cef_headers.sh)
CEF_API_VERSION :: 15600
/// where libcef.so and its resources are (icudtl.dat and the .pak files
/// next to it: CEF reads the ICU data from libcef.so's folder); IRIS_CEF_DIR
/// in the environment wins
CEF_DIR_DEFAULT :: #config(IRIS_CEF_DIR, "/app/lib/iris-cef")
/// software frames come at most 60 a second (CEF's limit for windowless
/// views); IRIS_CEF_FPS lowers it
CEF_FPS :: 60

// ---------------------------------------------------------------- strings

/// a CEF string for a call (UTF-16, in the temporary allocator: CEF copies it)
cef_str :: proc(s: string, allocator := context.temp_allocator) -> cef_string_t {
	if len(s) == 0 do return {}
	buf := make([]u16, len(s) + 1, allocator)
	n := utf16.encode_string(buf, s)
	return {str = &buf[0], length = uint(n)}
}

/// a CEF string as Odin text
from_cef :: proc(p: ^cef_string_t, allocator := context.temp_allocator) -> string {
	if p == nil || p.str == nil || p.length == 0 do return ""
	units := ([^]u16)(p.str)[:p.length]
	b := strings.builder_make(0, int(p.length), allocator)
	for i := 0; i < len(units); i += 1 {
		r := rune(units[i])
		if utf16.is_surrogate(r) && i + 1 < len(units) {
			r = utf16.decode_surrogate_pair(r, rune(units[i + 1]))
			i += 1
		}
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

/// a string CEF returned (cef_string_userfree_t): read, then freed
from_userfree :: proc(p: ^cef_string_t, allocator := context.temp_allocator) -> string {
	if p == nil do return ""
	s := from_cef(p, allocator)
	cef_string_userfree_utf16_free(p)
	return s
}

// ---------------------------------------------------------------- references

rel :: proc "contextless" (p: rawptr) {
	if p == nil do return
	base := cast(^cef_base_ref_counted_t)p
	if base.release != nil do base.release(base)
}

add_ref :: proc "contextless" (p: rawptr) {
	if p == nil do return
	base := cast(^cef_base_ref_counted_t)p
	if base.add_ref != nil do base.add_ref(base)
}

// the app's own structs live for the whole run: counting is a no-op
@(private="file") static_add_ref :: proc "c" (self: ^cef_base_ref_counted_t) {}
@(private="file") static_release :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 { return 0 }
@(private="file") static_one :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 { return 1 }

/// a struct of Iris's that lives as long as the program
static_base :: proc(base: ^cef_base_ref_counted_t, size: int) {
	base.size = uint(size)
	base.add_ref = static_add_ref
	base.release = static_release
	base.has_one_ref = static_one
	base.has_at_least_one_ref = static_one
}

// ---------------------------------------------------------------- the process

@(private="file") the_app: cef_app_t
@(private="file") the_bph: cef_browser_process_handler_t
@(private="file") the_rph: cef_render_process_handler_t
@(private="file") main_args: cef_main_args_t
@(private="file") argv_store: [dynamic]cstring
@(private="file") started: bool

PID_MESSAGE :: "iris.pid"

/// in a renderer: this process's id and start time (/proc/self/stat's 22nd
/// field), told to the browser process for the frame (cef_engine.odin's
/// reaper keeps, per view, which processes its frames are in)
@(private="file") report_pid :: proc(frame: ^cef_frame_t) {
	if frame == nil do return
	name := cef_str(PID_MESSAGE)
	msg := cef_process_message_create(&name)
	if msg == nil do return
	args := msg.get_argument_list(msg)
	if args != nil {
		pid := i32(linux.getpid())
		start, _ := proc_start_time(pid)
		args.set_int(args, 0, pid)
		// clock ticks since boot: past an i32, well inside a double's 2^53
		args.set_double(args, 1, f64(start))
		rel(args)
	}
	frame.send_process_message(frame, PID_BROWSER, msg) // takes msg
}

@(private="file") app_init :: proc() {
	static_base(&the_app.base, size_of(cef_app_t))
	the_app.get_browser_process_handler = proc "c" (self: ^cef_app_t) -> ^cef_browser_process_handler_t { return &the_bph }
	the_app.get_render_process_handler = proc "c" (self: ^cef_app_t) -> ^cef_render_process_handler_t { return &the_rph }
	static_base(&the_bph.base, size_of(cef_browser_process_handler_t))
	the_bph.on_schedule_message_pump_work = proc "c" (self: ^cef_browser_process_handler_t, delay_ms: i64) {
		pump_schedule(delay_ms)
	}
	// the request contexts can take settings now: light or dark as Iris is
	the_bph.on_context_initialized = proc "c" (self: ^cef_browser_process_handler_t) {
		context = main_context
		contexts_ready = true
		engine_theme_changed()
	}
	static_base(&the_rph.base, size_of(cef_render_process_handler_t))
	// in a renderer: tell the browser process which process holds each
	// frame of each browser, subframes too (with --site-per-process a
	// cross-site iframe is in another site's renderer, maybe one another
	// tab uses), so a closed tab's renderer is told apart from one still in
	// use (cef_reap). A frame's script context is made once per document,
	// in the process that document runs in: every frame, every navigation.
	the_rph.on_browser_created = proc "c" (self: ^cef_render_process_handler_t, browser: ^cef_browser_t, extra: rawptr) {
		context = runtime.default_context()
		defer rel(browser)
		frame := browser.get_main_frame(browser)
		if frame == nil do return
		defer rel(frame)
		report_pid(frame)
		free_all(context.temp_allocator)
	}
	the_rph.on_context_created = proc "c" (self: ^cef_render_process_handler_t, browser: ^cef_browser_t, frame: ^cef_frame_t, ctx: rawptr) {
		context = runtime.default_context()
		defer { rel(browser); rel(frame); rel(ctx) }
		report_pid(frame)
		free_all(context.temp_allocator)
	}
}

/// first thing in main: the API version (in every process, before any
/// other CEF call), then CEF's own subprocesses stop here
engine_subprocess :: proc() -> (code: int, is_sub: bool) {
	cef_api_hash(CEF_API_VERSION, 0)
	app_init()
	// argv as CEF needs it (it starts this binary again for its renderers),
	// with the switches Iris runs Chromium with
	for a in os.args do append(&argv_store, strings.clone_to_cstring(a))
	is_child := false
	for a in os.args do if strings.has_prefix(a, "--type=") do is_child = true
	if !is_child do for f in cef_switches() do append(&argv_store, strings.clone_to_cstring(f))
	main_args = {argc = i32(len(argv_store)), argv = raw_data(argv_store)}
	c := cef_execute_process(&main_args, &the_app, nil)
	if c >= 0 do return int(c), true
	return 0, false
}

/// how Chromium draws: on the GPU, its frames shared with Iris as
/// DMA-BUFs (the default where there is a Wayland display and a GPU render
/// node), or in software (IRIS_CEF_GPU=0, or neither is there)
@(private="file") gpu_wanted :: proc() -> bool {
	switch env("IRIS_CEF_GPU") {
	case "0": return false
	case "1": return true
	}
	if len(env("WAYLAND_DISPLAY")) == 0 && !os.exists(join({env("XDG_RUNTIME_DIR"), "wayland-0"}, context.temp_allocator)) do return false
	return has_render_node()
}

@(private="file") has_render_node :: proc() -> bool {
	for i in 128 ..< 136 do if os.exists(fmt.tprintf("/dev/dri/renderD%d", i)) do return true
	return false
}

/// the switches: a renderer per site (a closed tab's renderer is its own,
/// not shared with another site's tabs), Chromium's GPU process on the real
/// GPU (its frames come to Iris as DMA-BUFs, cef_osr.odin), none of
/// Chromium's own surfaces, experiments or services, nothing it would
/// fetch or keep running in the background. IRIS_CEF_FLAGS adds more
/// (space separated); IRIS_CEF_OZONE picks Chromium's platform.
cef_switches :: proc() -> []string {
	out: [dynamic]string
	gpu := gpu_wanted()
	cef_gpu_frames = gpu
	disable := []string{
		// Chromium's own features Iris has no use for, or does itself
		"Translate", "MediaRouter", "DialMediaRouteProvider", "GlobalMediaControls", "CastMediaRouteProvider",
		"OptimizationHints", "OptimizationHintsFetching", "OptimizationGuideModelDownloading",
		"OptimizationTargetPrediction", "OptimizationGuideOnDeviceModel", "OnDeviceModelService",
		"InterestFeedContentSuggestions", "SidePanelPinning", "ReadAnythingPermanentAccessibility",
		"CertificateTransparencyComponentUpdater", "AutofillServerCommunication",
		"SafeBrowsingRealTimeUrlLookup", "WebOTP",
		// (kept: FedCM, for "Sign in with Google"; Prerender2, which makes
		// pages a site prerenders open at once; heavy-ad intervention)
	}
	enable := make([dynamic]string, context.temp_allocator)
	append(&enable, "ParallelDownloading", "WebRtcPipeWireCamera")
	if gpu {
		// video decoded on the GPU (VA-API), its frames composited without
		// a copy; both the old and the new names of the switches (a name
		// Chromium does not know is ignored)
		append(&enable, "AcceleratedVideoDecodeLinuxGL", "AcceleratedVideoDecodeLinuxZeroCopyGL", "AcceleratedVideoEncoder",
			"VaapiVideoDecodeLinuxGL", "VaapiVideoDecoder", "VaapiIgnoreDriverChecks", "CanvasOopRasterization")
	}
	append(&out,
		"--site-per-process",
		strings.concatenate({"--disable-features=", strings.join(disable, ",", context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({"--enable-features=", strings.join(enable[:], ",", context.temp_allocator)}, context.temp_allocator),
		// nothing in the background, nothing after Iris closes
		"--disable-background-networking",
		"--disable-component-update",
		"--disable-domain-reliability",
		"--disable-breakpad",
		"--disable-crash-reporter",
		"--disable-client-side-phishing-detection",
		"--disable-default-apps",
		"--disable-sync",
		// (extensions stay: Chromium's PDF viewer is one)
		"--disable-component-extensions-with-background-pages",
		"--metrics-recording-only",
		"--no-pings",
		"--no-first-run",
		"--no-default-browser-check",
		"--no-service-autorun",
		"--safebrowsing-disable-auto-update",
		// no experiments: no field trials, no variations from a server
		"--disable-field-trial-config",
		"--variations-server-url=data:,",
		"--disable-variations-safe-mode",
	)
	if ozone := env("IRIS_CEF_OZONE"); len(ozone) > 0 {
		append(&out, strings.concatenate({"--ozone-platform=", ozone}, context.temp_allocator))
	} else if gpu {
		// the GPU's buffers (GBM, DMA-BUFs) need a real platform: Wayland,
		// though no window of Chromium's is ever made (pages are drawn
		// off-screen, into Iris's own)
		append(&out, "--ozone-platform=wayland")
	} else {
		append(&out, "--ozone-platform=headless")
	}
	if gpu {
		// ANGLE on the desktop's OpenGL through EGL (Chromium's default on
		// Linux), rasterized on the GPU, tiles in GPU memory
		append(&out, "--use-gl=angle", "--use-angle=gl-egl", "--enable-gpu-rasterization", "--enable-zero-copy", "--enable-native-gpu-memory-buffers")
	} else {
		// GL for Chromium's compositor without a window: SwiftShader is the
		// one proved to give frames with the headless platform
		// (experiments/cef-smoke)
		append(&out, "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader")
	}
	for f in strings.fields(env("IRIS_CEF_FLAGS")) do append(&out, f)
	return out[:]
}

/// the pages' frame rate: the display's (IRIS_CEF_FPS lowers or raises
/// it; CEF's windowless limit is 60 unless shared textures: then the
/// display's own, up to 240)
cef_frame_rate :: proc() -> i32 {
	if f, ok := strconv.parse_int(env("IRIS_CEF_FPS")); ok && f > 0 do return i32(clamp(f, 1, 240))
	return CEF_FPS
}

cef_dir :: proc() -> string {
	if d := env("IRIS_CEF_DIR"); len(d) > 0 do return d
	return CEF_DIR_DEFAULT
}

/// where CEF keeps every profile (each request context's cache_path is
/// under it, as CEF requires)
cef_root :: proc() -> string {
	return join({data_dir(), "cef"}, context.temp_allocator)
}

engine_start :: proc() -> bool {
	dir := cef_dir()
	root := cef_root()
	make_dirs(join({root, "default"}, context.temp_allocator))
	s := cef_settings_t{size = size_of(cef_settings_t)}
	// Chromium's own sandbox needs a setuid helper or user namespaces: a
	// Flatpak gives neither, so its renderers run in Flatpak's sandbox only
	s.no_sandbox = 1
	s.multi_threaded_message_loop = 0
	s.external_message_pump = 1
	s.windowless_rendering_enabled = 1
	s.persist_session_cookies = 1
	s.log_severity = LOGSEVERITY_WARNING
	s.background_color = 0xFFFFFFFF
	s.resources_dir_path = cef_str(dir)
	s.locales_dir_path = cef_str(join({dir, "locales"}, context.temp_allocator))
	s.root_cache_path = cef_str(root)
	s.cache_path = cef_str(join({root, "default"}, context.temp_allocator))
	if cef_initialize(&main_args, &s, &the_app, nil) == 0 {
		log.errorf("CEF did not start (exit code %d); libcef and its resources are looked for in %s", cef_get_exit_code(), dir)
		return false
	}
	started = true
	// Chromium's processes are Iris's to the end: one whose parent went
	// (a renderer forked by the zygote) comes to Iris, so none outlives it
	// (engine_stop ends any still there)
	PR_SET_CHILD_SUBREAPER :: 36
	linux.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)
	// a turn of CEF's work now and then even when it asks for none (CEF
	// asks for every turn it needs: this is only a safety net, once a
	// second, never a busy loop)
	g_timeout_add_full(G_PRIORITY_DEFAULT_IDLE, 1000, proc "c" (d: rawptr) -> gboolean {
		pump_now()
		return 1
	}, nil, nil)
	cef_shields_start()
	cef_bench_start()
	return true
}

/// every page closes (each renderer with it), then CEF stops
engine_stop :: proc() {
	if !started do return
	// CEF must never shut down with a browser still open (it aborts): if
	// one would not close in time, Iris leaves without CEF's shutdown
	if !views_close_all() {
		log.warn("CEF: a page did not close in time; leaving without CEF's shutdown")
		started = false
		end_children()
		return
	}
	cef_shutdown()
	started = false
	end_children()
}

/// every process Iris still has under it (Chromium's GPU, utility and
/// renderer processes, should CEF's shutdown have left one) ends with Iris:
/// SIGTERM, a moment, then SIGKILL; only Iris's own descendants, at exit
@(private="file") end_children :: proc() {
	kids := descendants(context.temp_allocator)
	if len(kids) == 0 do return
	for pid in kids do linux.kill(linux.Pid(pid), .SIGTERM)
	for _ in 0 ..< 20 {
		alive := false
		for pid in kids do if pid_alive(pid) && my_descendant(pid) do alive = true
		if !alive do return
		ts := linux.Time_Spec{time_nsec = 25_000_000}
		linux.nanosleep(&ts, nil)
	}
	for pid in kids do if pid_alive(pid) && my_descendant(pid) {
		log.warnf("CEF: process %d did not end with Iris: killed", pid)
		linux.kill(linux.Pid(pid), .SIGKILL)
	}
}

/// the pids under Iris (children and theirs), from /proc
@(private="file") descendants :: proc(allocator := context.allocator) -> []i32 {
	out := make([dynamic]i32, allocator)
	d, err := os.open("/proc")
	if err != nil do return out[:]
	defer os.close(d)
	fis, _ := os.read_dir(d, -1, context.temp_allocator)
	for fi in fis {
		pid, ok := strconv.parse_int(fi.name)
		if !ok || pid <= 1 || i32(pid) == i32(linux.getpid()) do continue
		if my_descendant(i32(pid)) do append(&out, i32(pid))
	}
	return out[:]
}

// ---------------------------------------------------------------- the message pump

@(private="file") pumping: bool
@(private="file") pump_queued: i32 // a reschedule is queued on the main loop (atomic)
@(private="file") pump_delay: i64 // the soonest delay asked for since (atomic)
@(private="file") pump_timer: u32 // the one pending timeout (main thread only)

@(private="file") pump_now :: proc "contextless" () {
	if pumping || !started do return // CEF's work is never re-entered, nor run once it stopped
	pumping = true
	cef_do_message_loop_work()
	pumping = false
}

/// CEF asks for a turn of its work (from any thread): the request goes to
/// the main loop, which keeps one timer at most, the newest request's (as
/// CEF's external pump wants: each call replaces the one before, so timers
/// never pile up and a later, sooner request is not held behind an older one)
@(private="file") pump_schedule :: proc "contextless" (delay_ms: i64) {
	d := max(delay_ms, 0)
	if intrinsics.atomic_exchange(&pump_queued, 1) == 1 {
		// one is queued: it takes the sooner of the two
		for {
			cur := intrinsics.atomic_load(&pump_delay)
			if d >= cur do break
			if _, ok := intrinsics.atomic_compare_exchange_strong(&pump_delay, cur, d); ok do break
		}
		return
	}
	intrinsics.atomic_store(&pump_delay, d)
	g_idle_add_full(G_PRIORITY_DEFAULT, proc "c" (data: rawptr) -> gboolean {
		intrinsics.atomic_store(&pump_queued, 0)
		d := intrinsics.atomic_load(&pump_delay)
		if pump_timer != 0 {
			g_source_remove(pump_timer)
			pump_timer = 0
		}
		if d <= 0 {
			pump_now()
			return 0
		}
		pump_timer = g_timeout_add_full(G_PRIORITY_DEFAULT, u32(min(d, 1000)), proc "c" (data: rawptr) -> gboolean {
			pump_timer = 0
			pump_now()
			return 0
		}, nil, nil)
		return 0
	}, nil, nil)
}

// ---------------------------------------------------------------- request contexts

@(private="file") global_ctx: ^cef_request_context_t
@(private="file") private_ctx: ^cef_request_context_t
@(private="file") container_ctx: map[string]^cef_request_context_t

@(private="file") new_context :: proc(cache_path: string) -> ^cef_request_context_t {
	s := cef_request_context_settings_t{size = size_of(cef_request_context_settings_t)}
	if len(cache_path) > 0 {
		make_dirs(cache_path)
		s.cache_path = cef_str(cache_path)
		s.persist_session_cookies = 1
	}
	return cef_request_context_create_context(&s, nil)
}

/// the request context for a tab (a reference the caller hands on or
/// releases): every normal tab shares one (one cookie jar: a sign-in in one
/// tab is a sign-in in all), a container has its own on disk, private tabs
/// share one in memory, and a sandboxed tab gets a fresh one in memory
/// (none of your cookies, gone with the tab)
tab_context :: proc(t: ^Tab) -> ^cef_request_context_t {
	c: ^cef_request_context_t
	switch {
	case t.sandboxed:
		c = new_context("")
		color_scheme(c)
		return c
	case t.container == "":
		if global_ctx == nil do global_ctx = cef_request_context_get_global_context()
		c = global_ctx
	case t.container == PRIVATE_ID || !valid_container_id(t.container):
		if private_ctx == nil do private_ctx = new_context("")
		c = private_ctx
	case:
		if x, ok := container_ctx[t.container]; ok {
			c = x
		} else {
			c = new_context(join({cef_root(), "containers", t.container}, context.temp_allocator))
			container_ctx[strings.clone(t.container)] = c
		}
	}
	add_ref(c)
	color_scheme(c)
	return c
}

// ---------------------------------------------------------------- light or dark

CEF_COLOR_VARIANT_LIGHT :: 1 // cef_color_variant_t (cef_types.h)
CEF_COLOR_VARIANT_DARK :: 2

/// a request context's pages light or dark as Iris is (theme.odin): what
/// prefers-color-scheme says, and Chromium's own controls and scroll bars
@(private="file") contexts_ready: bool

@(private="file") color_scheme :: proc(c: ^cef_request_context_t) {
	if c == nil || !contexts_ready do return
	c.set_chrome_color_scheme(c, theme.dark ? CEF_COLOR_VARIANT_DARK : CEF_COLOR_VARIANT_LIGHT, 0)
}

/// Iris went light or dark: every page follows (each request context;
/// a sandboxed tab's own one through its view)
engine_theme_changed :: proc() {
	if !contexts_ready do return
	if global_ctx == nil do global_ctx = cef_request_context_get_global_context()
	color_scheme(global_ctx)
	color_scheme(private_ctx)
	for _, c in container_ctx do color_scheme(c)
	views_each_context(color_scheme)
}

/// the last private tab closed: its world goes
end_private :: proc() {
	rel(private_ctx)
	private_ctx = nil
}

/// a container removed: its context goes, and what its sites kept on disk
engine_forget_container :: proc(id: string) {
	if c, ok := container_ctx[id]; ok {
		delete_key(&container_ctx, id)
		rel(c)
	}
	if !valid_container_id(id) do return
	os.remove_all(join({cef_root(), "containers", id}, context.temp_allocator))
}

/// CEF has no call for looking a name up ahead from here; Chromium does
/// its own preconnecting
warm_for_search :: proc() {}

// ---------------------------------------------------------------- renderers: a closed tab's must die

// Why: a closed tab must give its memory back (the WPE bug of 2.2.0-2.2.2,
// in CEF form, would be a renderer kept alive). How, without a request
// context per tab (that would split cookies and sign-ins): every frame of
// every browser, subframes too, tells the browser process which renderer
// it is in and when that process started (the render process handler
// above); each view keeps that per frame, and forgets the frames of a
// document it navigated away from (cef_view.odin). A few seconds after a
// tab's OnBeforeClose (Chromium usually ends the renderer itself by then),
// each process it reported is looked at again, and ended only if all of
// this holds:
//   - it is the same process (its start time is the one reported: a pid
//     used again since is never touched),
//   - it is Iris's own descendant, and a renderer by its command line
//     (--type=renderer, or --type=zygote for one forked from the zygote,
//     which keeps the zygote's; never the GPU or a utility process, whose
//     pids are never reported anyway),
//   - no live view (a tab's, the peek's, a pop-up's) has a frame in it, and
//     none reported it within the last REAP_RECENT_S seconds,
//   - every live view has reported (one not yet heard from could be in it).
// It gets SIGTERM first, SIGKILL only if it is still there (and all of the
// above still holds) a little later. When anything is unsure (the stat or
// the command line cannot be read), it is logged, never ended.

/// a renderer as reported: its pid and start time (clock ticks since boot)
Renderer_Proc :: struct {
	pid:   i32,
	start: u64,
}

@(private="file") Reap :: struct {
	procs: []Reap_Item,
	tries: int,
}

@(private="file") Reap_Item :: struct {
	using r: Renderer_Proc,
	/// SIGTERM sent: SIGKILL at the next look, if it is still there
	termed:  bool,
}

REAP_DELAY_MS :: 4000
REAP_KILL_DELAY_MS :: 2000
REAP_TRIES :: 5
/// a renderer some live view reported this lately is never ended
REAP_RECENT_S :: 10.0

/// when a live view last reported each renderer (pid -> now_s())
@(private="file") last_seen: map[i32]f64

/// a live view reported a frame in this renderer
renderer_seen :: proc(pid: i32) {
	last_seen[pid] = now_s()
}

/// a renderer as it is now, for a report: its start time, and whether it is
/// the process the report says (the pid not used again since)
renderer_check :: proc(pid: i32, start: u64) -> bool {
	s, ok := proc_start_time(pid)
	return ok && s == start
}

/// a tab is gone: the renderers its frames were in are looked at later
cef_reap_later :: proc(procs: []Renderer_Proc) {
	if len(procs) == 0 do return
	r := new(Reap)
	r.procs = make([]Reap_Item, len(procs))
	for p, i in procs do r.procs[i].r = p
	after(REAP_DELAY_MS, reap, r)
}

@(private="file") Verdict :: enum u8 { Gone, Keep, Later, Unsure, End }

/// whether a reported renderer may be ended now
@(private="file") reap_verdict :: proc(p: Renderer_Proc) -> Verdict {
	start, ok := proc_start_time(p.pid)
	if !ok do return pid_alive(p.pid) ? .Unsure : .Gone
	if start != p.start do return .Gone // another process has the pid now
	if p.pid == i32(linux.getpid()) do return .Keep
	if views_use_pid(p.pid) do return .Keep
	if t, seen := last_seen[p.pid]; seen && now_s() - t < REAP_RECENT_S do return .Later
	if !my_descendant(p.pid) do return .Keep
	cmd, err := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", p.pid), context.temp_allocator)
	if err != nil do return .Unsure
	if !cmdline_is_renderer(cmd) do return .Unsure
	return .End
}

@(private="file") reap :: proc(d: rawptr) {
	r := cast(^Reap)d
	// a live view not yet heard from may be in any renderer: wait for it
	if views_unreported() && r.tries < REAP_TRIES {
		r.tries += 1
		after(REAP_DELAY_MS, reap, r)
		return
	}
	pending, killing := false, false
	for &p in r.procs {
		if p.pid == 0 do continue
		v := reap_verdict(p.r)
		if v == .End && views_unreported() do v = .Later
		switch v {
		case .Gone:
			if !pid_alive(p.pid) do delete_key(&last_seen, p.pid)
			p.pid = 0
		case .Keep:
			p.pid = 0
		case .Later:
			if r.tries < REAP_TRIES {
				pending = true
			} else {
				log.infof("CEF: a closed tab's renderer (pid %d) is still running; left to Chromium (a page may still use it)", p.pid)
				p.pid = 0
			}
		case .Unsure:
			log.infof("CEF: a closed tab's process %d is still running; left alone (not sure it is a renderer)", p.pid)
			p.pid = 0
		case .End:
			if !p.termed {
				log.warnf("CEF: a closed tab's renderer (pid %d) was still running: asked to end", p.pid)
				linux.kill(linux.Pid(p.pid), .SIGTERM)
				p.termed = true
				pending, killing = true, true
			} else {
				log.warnf("CEF: a closed tab's renderer (pid %d) did not end: killed", p.pid)
				linux.kill(linux.Pid(p.pid), .SIGKILL)
				p.pid = 0
			}
		}
	}
	if pending {
		r.tries += 1
		after(killing ? REAP_KILL_DELAY_MS : REAP_DELAY_MS, reap, r)
		return
	}
	delete(r.procs)
	free(r)
}

@(private="file") pid_alive :: proc(pid: i32) -> bool {
	return os.exists(fmt.tprintf("/proc/%d", pid))
}

/// a process's start time (field 22 of /proc/pid/stat)
proc_start_time :: proc(pid: i32) -> (u64, bool) {
	stat, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil do return 0, false
	_, start, ok := parse_proc_stat(string(stat))
	return start, ok
}

/// the process descends from Iris (Chromium's renderers are forked from
/// its zygote: grandchildren, not children)
@(private="file") my_descendant :: proc(pid: i32) -> bool {
	me := i32(linux.getpid())
	p := pid
	for _ in 0 ..< 8 {
		stat, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", p), context.temp_allocator)
		if err != nil do return false
		pp, _, ok := parse_proc_stat(string(stat))
		if !ok do return false
		if i32(pp) == me do return true
		if pp <= 1 do return false
		p = i32(pp)
	}
	return false
}

// ---- pure logic, no CEF in it (scratch tests copy it from between the
// markers) ---- BEGIN CEF_LOGIC_REAP

/// "pid (name) state ppid ... starttime ...": the parent's pid (field 4)
/// and the start time (field 22); the name may hold spaces and ')', the
/// last ')' ends it
parse_proc_stat :: proc(s: string) -> (ppid: i64, start: u64, ok: bool) {
	close := strings.last_index_byte(s, ')')
	if close < 0 do return
	f := strings.fields(s[close + 1:], context.temp_allocator)
	// f[0] is field 3 (state): field n is f[n - 3]
	if len(f) < 20 do return
	pp, ok1 := strconv.parse_i64(f[1])
	st, ok2 := strconv.parse_u64(f[19])
	if !ok1 || !ok2 do return
	return pp, st, true
}

/// a NUL-separated command line is a Chromium renderer's: --type=renderer,
/// or --type=zygote (a renderer forked from the zygote keeps its command
/// line); never --type=gpu-process, utility, broker, or the browser
cmdline_is_renderer :: proc(cmd: []u8) -> bool {
	s := string(cmd)
	for len(s) > 0 {
		i := strings.index_byte(s, 0)
		arg := i < 0 ? s : s[:i]
		if arg == "--type=renderer" || arg == "--type=zygote" do return true
		if strings.has_prefix(arg, "--type=") do return false
		if i < 0 do break
		s = s[i + 1:]
	}
	return false
}

// ---- END CEF_LOGIC_REAP

// ---------------------------------------------------------------- downloads

Download_Engine :: struct {
	cef_id: u32,
	/// the newest callback CEF gave for it (to cancel it)
	cef_cb: ^cef_download_item_callback_t,
}

download_release :: proc(d: ^Download) {
	rel(d.cef_cb)
	d.cef_cb = nil
}

download_cancel :: proc(d: ^Download) {
	d.cancelled = true
	if d.cef_cb != nil do d.cef_cb.cancel(d.cef_cb)
}

@(private="file") download_by_id :: proc(id: u32) -> ^Download {
	for d in downloads do if d.cef_id == id do return d
	return nil
}

/// CEF is about to download: the file goes to the Downloads folder under a
/// free name (no dialog)
cef_download_start :: proc(item: ^cef_download_item_t, suggested: string, cb: ^cef_before_download_callback_t) {
	d := new(Download)
	d.id = next_download
	next_download += 1
	d.cef_id = item.get_id(item)
	p := unique_download(len(suggested) > 0 ? suggested : "download")
	d.path = p
	d.name = filepath.base(p)
	inject_at(&downloads, 0, d)
	path := cef_str(p)
	cb.cont(cb, &path, 0)
	download_changed(d)
}

cef_download_update :: proc(item: ^cef_download_item_t, cb: ^cef_download_item_callback_t) {
	d := download_by_id(item.get_id(item))
	if d == nil {
		rel(cb)
		return
	}
	rel(d.cef_cb)
	d.cef_cb = cb // kept: the reference CEF gave
	d.received = u64(max(0, item.get_received_bytes(item)))
	pc := item.get_percent_complete(item)
	if pc >= 0 do d.progress = f64(pc) / 100
	switch {
	case item.is_complete(item) != 0:
		d.done, d.progress = true, 1
	case item.is_canceled(item) != 0 || item.is_interrupted(item) != 0:
		d.failed = true
	}
	if d.cancelled && !d.failed && !d.done do cb.cancel(cb)
	download_changed(d)
}

} // when ENGINE_CEF
