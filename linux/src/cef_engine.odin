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

@(private="file") app_init :: proc() {
	static_base(&the_app.base, size_of(cef_app_t))
	the_app.get_browser_process_handler = proc "c" (self: ^cef_app_t) -> ^cef_browser_process_handler_t { return &the_bph }
	the_app.get_render_process_handler = proc "c" (self: ^cef_app_t) -> ^cef_render_process_handler_t { return &the_rph }
	static_base(&the_bph.base, size_of(cef_browser_process_handler_t))
	the_bph.on_schedule_message_pump_work = proc "c" (self: ^cef_browser_process_handler_t, delay_ms: i64) {
		pump_schedule(delay_ms)
	}
	static_base(&the_rph.base, size_of(cef_render_process_handler_t))
	// in a renderer: tell the browser process which process holds this
	// browser (for every renderer it lands in: a cross-site navigation
	// moves it), so a closed tab's renderer can be told apart (cef_reap)
	the_rph.on_browser_created = proc "c" (self: ^cef_render_process_handler_t, browser: ^cef_browser_t, extra: rawptr) {
		context = runtime.default_context()
		defer rel(browser)
		frame := browser.get_main_frame(browser)
		if frame == nil do return
		defer rel(frame)
		name := cef_str(PID_MESSAGE)
		msg := cef_process_message_create(&name)
		if msg == nil do return
		args := msg.get_argument_list(msg)
		if args != nil {
			args.set_int(args, 0, i32(linux.getpid()))
			rel(args)
		}
		frame.send_process_message(frame, PID_BROWSER, msg) // takes msg
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

/// the switches: a renderer per site (a closed tab's renderer is its own,
/// not shared with another site's tabs), no X11 (the page is drawn
/// off-screen; Iris's window is its own), nothing Chromium would fetch in
/// the background. IRIS_CEF_FLAGS adds more (space separated).
cef_switches :: proc() -> []string {
	out: [dynamic]string
	append(&out,
		"--site-per-process",
		"--ozone-platform=headless",
		"--disable-features=Translate,MediaRouter,OptimizationHints,InterestFeedContentSuggestions",
		"--enable-features=VaapiVideoDecodeLinuxGL,VaapiVideoDecoder,ParallelDownloading",
		"--disable-background-networking",
		"--disable-component-update",
		"--disable-domain-reliability",
		"--no-pings",
	)
	// GL for Chromium's compositor without a window: SwiftShader is the one
	// proved to give frames with the headless platform (experiments/
	// cef-smoke); IRIS_CEF_GPU=1 tries the real GPU through ANGLE instead
	if env("IRIS_CEF_GPU") == "1" {
		append(&out, "--use-gl=angle", "--use-angle=default")
	} else {
		append(&out, "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader")
	}
	for f in strings.fields(env("IRIS_CEF_FLAGS")) do append(&out, f)
	return out[:]
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
	// a turn of CEF's work every so often even when it asks for none
	g_timeout_add_full(G_PRIORITY_DEFAULT, 100, proc "c" (d: rawptr) -> gboolean {
		pump_now()
		return 1
	}, nil, nil)
	cef_shields_start()
	return true
}

/// every page closes (each renderer with it), then CEF stops
engine_stop :: proc() {
	if !started do return
	views_close_all()
	cef_shutdown()
	started = false
}

// ---------------------------------------------------------------- the message pump

@(private="file") pumping: bool
@(private="file") pump_pending: i32 // an immediate pump is already queued (atomic)

@(private="file") pump_now :: proc "contextless" () {
	if pumping do return // CEF's work is never re-entered
	pumping = true
	cef_do_message_loop_work()
	pumping = false
}

/// CEF asks for a turn of its work (from any thread): GLib's loop gives it
@(private="file") pump_schedule :: proc "contextless" (delay_ms: i64) {
	if delay_ms <= 0 {
		if intrinsics.atomic_exchange(&pump_pending, 1) == 1 do return
		g_idle_add_full(G_PRIORITY_DEFAULT, proc "c" (d: rawptr) -> gboolean {
			intrinsics.atomic_store(&pump_pending, 0)
			pump_now()
			return 0
		}, nil, nil)
		return
	}
	g_timeout_add_full(G_PRIORITY_DEFAULT, u32(min(delay_ms, 1000)), proc "c" (d: rawptr) -> gboolean {
		pump_now()
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
		return new_context("")
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
	return c
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
// context per tab (that would split cookies and sign-ins): every renderer
// tells the browser process its pid (the render process handler above);
// --site-per-process keeps different sites' tabs in different renderers;
// and a few seconds after a tab's OnBeforeClose, each pid it reported that
// is still alive, still Iris's own child, and used by no live tab is
// killed. A renderer two tabs of one site share stays while either is open
// (Chromium ends it with the last). Same-site tabs can share a renderer
// even so (Chromium's choice past its process limit): those stay alive
// until the last of them closes, which is correct, not a leak.

@(private="file") Reap :: struct {
	pids:  []i32,
	tries: int,
}

REAP_DELAY_MS :: 4000

/// a tab is gone: its renderers are checked a little later
cef_reap_later :: proc(pids: []i32) {
	if len(pids) == 0 do return
	r := new(Reap)
	r.pids = make([]i32, len(pids))
	copy(r.pids, pids)
	after(REAP_DELAY_MS, reap, r)
}

@(private="file") reap :: proc(d: rawptr) {
	r := cast(^Reap)d
	// a live tab not yet heard from may be in any renderer: wait for it
	if views_unreported() && r.tries < 5 {
		r.tries += 1
		after(REAP_DELAY_MS, reap, r)
		return
	}
	for pid in r.pids {
		if !pid_alive(pid) || views_use_pid(pid) || !my_descendant(pid) do continue
		log.warnf("CEF: a closed tab's renderer (pid %d) was still running: ended", pid)
		linux.kill(linux.Pid(pid), .SIGKILL)
	}
	delete(r.pids)
	free(r)
}

@(private="file") pid_alive :: proc(pid: i32) -> bool {
	return os.exists(fmt.tprintf("/proc/%d", pid))
}

/// the process descends from Iris (Chromium's renderers are forked from
/// its zygote: grandchildren, not children)
@(private="file") my_descendant :: proc(pid: i32) -> bool {
	me := i32(linux.getpid())
	p := pid
	for _ in 0 ..< 8 {
		stat, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", p), context.temp_allocator)
		if err != nil do return false
		// "pid (name) state ppid ...": the name may hold spaces, ')' ends it
		s := string(stat)
		close := strings.last_index_byte(s, ')')
		if close < 0 do return false
		f := strings.fields(s[close + 1:], context.temp_allocator)
		if len(f) < 2 do return false
		pp, ok := strconv.parse_int(f[1])
		if !ok do return false
		if i32(pp) == me do return true
		if pp <= 1 do return false
		p = i32(pp)
	}
	return false
}

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
