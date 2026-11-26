// cef-smoke: the smallest proof CEF works on the Odin stack.
//
// Two scenarios, both must pass:
//
//  1. tab-close memory: open 3 tabs (each with its own request context,
//     so each gets its own renderer process), close 2, and prove the
//     closed tabs' memory is really gone — fewer renderer processes and
//     total renderer RSS down by a clear margin. This is the guarantee
//     a closed tab gives: it must really die.
//  2. single page: open https://example.org, wait for one OnPaint frame,
//     dump it to frame.ppm (P6 RGB) and print PASS.
//
// Any failure prints FAIL and exits non-zero. No window, no Wayland, no
// Iris code.
//
//   CEF_DIR=<cef-binary-dir> ./build.sh   # builds ./cef-smoke
//   CEF_DIR=<cef-binary-dir> ./run.sh     # runs it (90 s timeout per scenario)
//
// CEF_DIR is the extracted minimal distribution, e.g.
// cef_binary_156.0.32+g3d1f4ab+chromium-156.0.8078.109_linux64_minimal
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

VIEW_W :: 800
VIEW_H :: 600
TIMEOUT :: 90 * time.Second
URL     :: "https://example.org"

// state the CEF callbacks write; the pump loop reads
got_frame:       bool
frame_w:         i32
frame_h:         i32
frame_buf:       []u8 // BGRA, copied out of OnPaint
browser_created: bool
load_done:       bool
load_failed:     bool
load_error_code: i32

// which scenario the callbacks are serving: 2 = tab-close, 1 = single page
phase: int

// tab-close scenario state. Tabs are created one at a time so OnAfterCreated
// order matches creation order; the browser pointer is dropped in
// OnBeforeClose (below) — keeping it would keep the page alive: a
// leak (one reference too many on a page).
Tab :: struct {
	browser: ^cef_browser_t,
	id:      i32,
	url:     string,
}
tabs:            [3]Tab
tabs_created:    int
tabs_load_ended: int
tabs_closed:     int
tab_load_failed: bool
tab_load_error:  i32
wait_target:     int
last_load_end_at: time.Time

// CEF calls these on every handler struct; the handlers are globals that
// live for the whole run, so the refcount is a no-op by design.
cef_add_ref :: proc "c" (self: ^cef_base_ref_counted_t) {}
cef_release :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 { return 1 }
cef_has_one_ref :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 { return 1 }
cef_has_at_least_one_ref :: proc "c" (self: ^cef_base_ref_counted_t) -> i32 { return 1 }

base_fill :: proc(base: ^cef_base_ref_counted_t, $T: typeid) {
	base.size = size_of(T)
	base.add_ref = cef_add_ref
	base.release = cef_release
	base.has_one_ref = cef_has_one_ref
	base.has_at_least_one_ref = cef_has_at_least_one_ref
}

// --- client: hands CEF the three handlers it needs, nothing else ---

client_get_nil :: proc "c" (self: ^cef_client_t) -> rawptr { return nil }

client_get_render_handler :: proc "c" (self: ^cef_client_t) -> ^cef_render_handler_t {
	return &render_handler
}

client_get_life_span_handler :: proc "c" (self: ^cef_client_t) -> ^cef_life_span_handler_t {
	return &life_span_handler
}

client_get_load_handler :: proc "c" (self: ^cef_client_t) -> ^cef_load_handler_t {
	return &load_handler
}

client_on_process_message_received :: proc "c" (self: ^cef_client_t, browser: rawptr, frame: rawptr, source_process: i32, message: rawptr) -> i32 {
	return 0
}

// --- render handler: the view rectangle and the frame itself ---

render_get_nil :: proc "c" (self: ^cef_render_handler_t) -> rawptr { return nil }

render_get_root_screen_rect :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t) -> i32 {
	rect^ = cef_rect_t{0, 0, VIEW_W, VIEW_H}
	return 1
}

render_get_view_rect :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t) {
	rect^ = cef_rect_t{0, 0, VIEW_W, VIEW_H}
}

render_get_screen_point :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, viewX, viewY: i32, screenX, screenY: ^i32) -> i32 {
	return 0
}

render_get_screen_info :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, screen_info: rawptr) -> i32 {
	return 0
}

render_on_popup_show :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, show: i32) {}
render_on_popup_size :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, rect: ^cef_rect_t) {}

paint_calls:    int
last_paint_at:  time.Time

render_on_paint :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, type: i32, dirtyRectsCount: uint, dirtyRects: ^cef_rect_t, buffer: rawptr, width, height: i32) {
	context = runtime.default_context()
	if type != PET_VIEW || buffer == nil || width <= 0 || height <= 0 {
		return
	}
	// The buffer is only valid during this call: copy the whole view.
	// Keep the latest frame: the first paint can be partial (text before
	// the box around it), so the loop waits for the paints to settle.
	n := int(width * height * 4)
	frame_buf = make([]u8, n)
	copy(frame_buf, ([^]u8)(buffer)[:n])
	frame_w, frame_h = width, height
	got_frame = true
	last_paint_at = time.now()
	paint_calls += 1
}

render_on_accelerated_paint :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, type: i32, dirtyRectsCount: uint, dirtyRects: ^cef_rect_t, info: rawptr) {}

render_get_touch_handle_size :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, orientation: i32, size: rawptr) {}
render_on_touch_handle_state_changed :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, state: rawptr) {}

render_start_dragging :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, drag_data: rawptr, allowed_ops: u32, x, y: i32) -> i32 {
	return 0
}

render_update_drag_cursor :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, operation: u32) {}
render_on_scroll_offset_changed :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, x, y: f64) {}
render_on_ime_composition_range_changed :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, selected_range: rawptr, character_boundsCount: uint, character_bounds: ^cef_rect_t) {}
render_on_text_selection_changed :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, selected_text: ^cef_string_t, selected_range: rawptr) {}
render_on_virtual_keyboard_requested :: proc "c" (self: ^cef_render_handler_t, browser: rawptr, input_mode: i32) {}

// --- life span handler: know when the browser exists ---

life_on_before_popup :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr, frame: rawptr, popup_id: i32, target_url: ^cef_string_t, target_frame_name: ^cef_string_t, target_disposition: i32, user_gesture: i32, popupFeatures: rawptr, windowInfo: ^cef_window_info_t, client: ^^cef_client_t, settings: ^cef_browser_settings_t, extra_info: rawptr, no_javascript_access: ^i32) -> i32 {
	return 1 // no popups in the smoke test
}

life_on_before_popup_aborted :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr, popup_id: i32) {}
life_on_before_dev_tools_popup :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr, windowInfo: ^cef_window_info_t, client: ^^cef_client_t, settings: ^cef_browser_settings_t, extra_info: rawptr, use_default_window: ^i32) {}

life_on_after_created :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr) {
	context = runtime.default_context()
	if phase == 2 {
		if tabs_created < len(tabs) {
			b := (^cef_browser_t)(browser)
			tabs[tabs_created].browser = b
			// The identifier is stable for the browser; the C wrapper
			// pointer is NOT — OnBeforeClose hands us a different
			// cef_browser_t* for the same tab, so matching must use the id.
			tabs[tabs_created].id = b.get_identifier(b)
			fmt.println("tab", tabs_created, "created:", tabs[tabs_created].url, "id =", tabs[tabs_created].id)
			tabs_created += 1
		}
		return
	}
	browser_created = true
	fmt.println("browser created")
}

life_do_close :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr) -> i32 {
	context = runtime.default_context()
	return 0
}

life_on_before_close :: proc "c" (self: ^cef_life_span_handler_t, browser: rawptr) {
	context = runtime.default_context()
	if phase == 2 {
		// Drop our reference: the browser object is about to be destroyed,
		// and anything still pointing at it keeps the page (and its
		// renderer) alive. This is the leak trap. Match by
		// identifier, not pointer: CEF hands OnBeforeClose a different
		// cef_browser_t* wrapper than OnAfterCreated did for the same tab.
		closing_id := (^cef_browser_t)(browser).get_identifier((^cef_browser_t)(browser))
		for i in 0..<len(tabs) {
			if tabs[i].id == closing_id {
				tabs[i].browser = nil
				tabs_closed += 1
				fmt.println("tab", i, "closed, id =", closing_id)
				break
			}
		}
		return
	}
	fmt.println("browser closing")
}

// --- load handler: know when the page finished or failed ---

load_on_loading_state_change :: proc "c" (self: ^cef_load_handler_t, browser: rawptr, isLoading, canGoBack, canGoForward: i32) {}

load_on_load_start :: proc "c" (self: ^cef_load_handler_t, browser: rawptr, frame: rawptr, transition_type: i32) {
	context = runtime.default_context()
	fmt.println("load start")
}

load_on_load_end :: proc "c" (self: ^cef_load_handler_t, browser: rawptr, frame: rawptr, httpStatusCode: i32) {
	context = runtime.default_context()
	if phase == 2 {
		tabs_load_ended += 1
		last_load_end_at = time.now()
		fmt.println("tab load end, http", httpStatusCode, "(", tabs_load_ended, "of 3)")
		return
	}
	load_done = true
	fmt.println("load end, http", httpStatusCode)
}

load_on_load_error :: proc "c" (self: ^cef_load_handler_t, browser: rawptr, frame: rawptr, errorCode: i32, errorText: ^cef_string_t, failedUrl: ^cef_string_t) {
	context = runtime.default_context()
	if phase == 2 {
		tab_load_failed = true
		tab_load_error = errorCode
		fmt.println("tab load error", errorCode)
		return
	}
	load_failed = true
	load_error_code = errorCode
	fmt.println("load error", errorCode)
}

render_handler:    cef_render_handler_t
life_span_handler: cef_life_span_handler_t
load_handler:      cef_load_handler_t
client:            cef_client_t

handlers_init :: proc() {
	base_fill(&render_handler.base, cef_render_handler_t)
	render_handler.get_accessibility_handler = render_get_nil
	render_handler.get_root_screen_rect = render_get_root_screen_rect
	render_handler.get_view_rect = render_get_view_rect
	render_handler.get_screen_point = render_get_screen_point
	render_handler.get_screen_info = render_get_screen_info
	render_handler.on_popup_show = render_on_popup_show
	render_handler.on_popup_size = render_on_popup_size
	render_handler.on_paint = render_on_paint
	render_handler.on_accelerated_paint = render_on_accelerated_paint
	render_handler.get_touch_handle_size = render_get_touch_handle_size
	render_handler.on_touch_handle_state_changed = render_on_touch_handle_state_changed
	render_handler.start_dragging = render_start_dragging
	render_handler.update_drag_cursor = render_update_drag_cursor
	render_handler.on_scroll_offset_changed = render_on_scroll_offset_changed
	render_handler.on_ime_composition_range_changed = render_on_ime_composition_range_changed
	render_handler.on_text_selection_changed = render_on_text_selection_changed
	render_handler.on_virtual_keyboard_requested = render_on_virtual_keyboard_requested

	base_fill(&life_span_handler.base, cef_life_span_handler_t)
	life_span_handler.on_before_popup = life_on_before_popup
	life_span_handler.on_before_popup_aborted = life_on_before_popup_aborted
	life_span_handler.on_before_dev_tools_popup = life_on_before_dev_tools_popup
	life_span_handler.on_after_created = life_on_after_created
	life_span_handler.do_close = life_do_close
	life_span_handler.on_before_close = life_on_before_close

	base_fill(&load_handler.base, cef_load_handler_t)
	load_handler.on_loading_state_change = load_on_loading_state_change
	load_handler.on_load_start = load_on_load_start
	load_handler.on_load_end = load_on_load_end
	load_handler.on_load_error = load_on_load_error

	base_fill(&client.base, cef_client_t)
	client.get_audio_handler = client_get_nil
	client.get_command_handler = client_get_nil
	client.get_context_menu_handler = client_get_nil
	client.get_dialog_handler = client_get_nil
	client.get_display_handler = client_get_nil
	client.get_download_handler = client_get_nil
	client.get_drag_handler = client_get_nil
	client.get_find_handler = client_get_nil
	client.get_focus_handler = client_get_nil
	client.get_frame_handler = client_get_nil
	client.get_permission_handler = client_get_nil
	client.get_jsdialog_handler = client_get_nil
	client.get_keyboard_handler = client_get_nil
	client.get_life_span_handler = client_get_life_span_handler
	client.get_load_handler = client_get_load_handler
	client.get_print_handler = client_get_nil
	client.get_render_handler = client_get_render_handler
	client.get_request_handler = client_get_nil
	client.on_process_message_received = client_on_process_message_received
}

cef_string :: proc(s: string) -> cef_string_utf16_t {
	str: cef_string_utf16_t
	c := strings.clone_to_cstring(s)
	if cef_string_utf8_to_utf16(c, uint(len(s)), &str) == 0 {
		fmt.eprintln("FAIL: could not convert string:", s)
		os.exit(1)
	}
	return str
}

fail :: proc(msg: string, args: ..any) {
	fmt.eprint("FAIL: ")
	fmt.eprintfln(msg, ..args)
	os.exit(1)
}

// CEF_API_VERSION_EXPERIMENTAL (the default in cef_api_hash.h). Since CEF
// 133 the C API requires cef_api_hash() to be called first in EVERY process,
// before any other CEF function, or the CToCpp wrappers fail with
// "called with invalid version -1".
CEF_API_VERSION :: 999999

// --- tab-close scenario helpers ---

// Pump CEF's message loop until cond() is true or the deadline passes.
pump_until :: proc(deadline: time.Time, cond: proc() -> bool) -> bool {
	for {
		cef_do_message_loop_work()
		if cond() {
			return true
		}
		if time.since(deadline) >= 0 {
			return false
		}
		time.sleep(10 * time.Millisecond)
	}
}

cond_created_target :: proc() -> bool { return tabs_created >= wait_target }
cond_loads_done     :: proc() -> bool { return tabs_load_ended >= 3 }
cond_closed_two     :: proc() -> bool { return tabs_closed >= 2 }

// Snapshot of CEF's process tree: every process descended from this one,
// and their summed resident memory.
//
// Why not count "--type=renderer" processes directly? In this CEF 156
// build there ARE none: Chromium spawns its subprocesses by forking the
// zygote, and the forked child never execs, so its /proc/PID/cmdline keeps
// the zygote's text ("--type=zygote") even after it becomes a renderer or
// the GPU process. (Verified 2026-11-24: 6 descendants, all named
// cef-smoke with --type=zygote cmdlines; the 4 grandchildren hold the
// pages at ~45-122 MB RSS each.) The honest measurement is therefore the
// whole subtree: when tabs really die, their processes leave the tree and
// the summed RSS falls. A leak — closed tabs kept alive by a
// stray reference — would show up here as processes that never leave.
descendant_snapshot :: proc() -> (count: int, rss_kb: int) {
	my_pid := os.get_pid()
	seen := make(map[int]bool, context.temp_allocator)
	queue: [dynamic]int
	defer delete(queue)
	append(&queue, my_pid)
	seen[my_pid] = true
	for len(queue) > 0 {
		pid := pop(&queue)
		children_path := fmt.tprintf("/proc/%d/task/%d/children", pid, pid)
		data, err := os.read_entire_file(children_path, context.temp_allocator)
		if err != nil {
			continue
		}
		for pid_str in strings.fields(string(data), context.temp_allocator) {
			child, ok := strconv.parse_int(pid_str)
			if !ok || child in seen {
				continue
			}
			seen[child] = true
			append(&queue, child)
			count += 1
			status, serr := os.read_entire_file(fmt.tprintf("/proc/%d/status", child), context.temp_allocator)
			if serr != nil {
				continue // exited while we looked
			}
			for line in strings.split_lines(string(status), context.temp_allocator) {
				if strings.has_prefix(line, "VmRSS:") {
					fields := strings.fields(line, context.temp_allocator)
					if len(fields) >= 2 {
						if rss, ok := strconv.parse_int(fields[1]); ok {
							rss_kb += rss
						}
					}
					break
				}
			}
		}
	}
	return count, rss_kb
}

TAB_URLS := [3]string{"https://example.org", "https://example.com", "https://example.net"}

// Scenario 1: three tabs, each on its own request context (empty cache_path
// = in-memory storage, its own partition), so each gets its own renderer
// process even if two tabs were on the same site. Close two of them and
// prove the memory is really gone. PASS needs BOTH: fewer renderer
// processes AND total renderer RSS down at least 30%. The count alone is
// not enough (Chromium may keep one small warm spare renderer); the RSS
// drop is the real guarantee. Either condition failing means a closed
// tab is still alive somewhere — a leak.
scenario_tab_close :: proc(window_info: ^cef_window_info_t, browser_settings: ^cef_browser_settings_t) {
	phase = 2
	fmt.println("scenario 1: tab close frees memory")
	for i in 0..<len(TAB_URLS) {
		tabs[i].url = TAB_URLS[i]
		// A separate request context per tab: distinct storage partitions
		// cannot share a renderer process, so closing a tab can kill
		// exactly that tab's renderer. With the shared global context,
		// same-site tabs share one renderer and closing one frees nothing.
		ctx_settings := cef_request_context_settings_t{size = size_of(cef_request_context_settings_t)}
		ctx := cef_request_context_create_context(&ctx_settings, nil)
		if ctx == nil {
			fail("tab %d: could not create request context", i)
		}
		url := cef_string(TAB_URLS[i])
		if cef_browser_host_create_browser(window_info, &client, &url, browser_settings, nil, ctx) == 0 {
			cef_string_utf16_clear(&url)
			fail("tab %d: create_browser failed", i)
		}
		cef_string_utf16_clear(&url)
		wait_target = i + 1
		if !pump_until(time.time_add(time.now(), 30*time.Second), cond_created_target) {
			fail("tab %d: no OnAfterCreated within 30s", i)
		}
	}
	if !pump_until(time.time_add(time.now(), 60*time.Second), cond_loads_done) {
		fail("tabs did not all load within 60s (loaded: %d of 3)", tabs_load_ended)
	}
	if tab_load_failed {
		fail("a tab failed to load (error %d)", tab_load_error)
	}
	// Let the pages settle so the RSS reading is representative.
	settle := time.time_add(time.now(), 2*time.Second)
	for time.since(settle) < 0 {
		cef_do_message_loop_work()
		time.sleep(10 * time.Millisecond)
	}

	count_a, rss_a := descendant_snapshot()
	fmt.println("tabs: before close:", count_a, "CEF processes, total RSS", rss_a, "kB")

	for i in 1..<len(TAB_URLS) {
		b := tabs[i].browser
		if b == nil {
			fail("tab %d: no browser to close", i)
		}
		host := b.get_host(b)
		if host == nil {
			fail("tab %d: no host", i)
		}
		fmt.println("closing tab", i)
		host.close_browser(host, 1) // force: no unload-handler delay
	}
	if !pump_until(time.time_add(time.now(), 30*time.Second), cond_closed_two) {
		fail("closed tabs did not report OnBeforeClose within 30s (closed: %d of 2)", tabs_closed)
	}
	// Renderer processes exit asynchronously after OnBeforeClose: poll
	// until the count drops, up to 30 s, then settle once more so the
	// final RSS reading reflects the freed memory, not the exit transient.
	count_b, rss_b := descendant_snapshot()
	poll_deadline := time.time_add(time.now(), 30*time.Second)
	for count_b >= count_a {
		if time.since(poll_deadline) >= 0 {
			break
		}
		time.sleep(500 * time.Millisecond)
		cef_do_message_loop_work()
		count_b, rss_b = descendant_snapshot()
	}
	settle2 := time.time_add(time.now(), 2*time.Second)
	for time.since(settle2) < 0 {
		cef_do_message_loop_work()
		time.sleep(10 * time.Millisecond)
	}
	count_b, rss_b = descendant_snapshot()
	fmt.println("tabs: after close:", count_b, "CEF processes, total RSS", rss_b, "kB")
	if count_b < count_a && rss_b * 100 <= 70 * rss_a {
		fmt.println("PASS: tab close frees memory: CEF processes", count_a, "->", count_b, ", RSS", rss_a, "->", rss_b, "kB")
		return
	}
	fail("tab close did not free memory: CEF processes %d -> %d, RSS %d -> %d kB (need fewer processes and RSS <= 70%%)", count_a, count_b, rss_a, rss_b)
}

main :: proc() {
	// Register the API version before anything else touches CEF. This runs
	// in the browser process AND in every subprocess (they re-enter main).
	cef_api_hash(CEF_API_VERSION, 0)

	cef_dir := os.get_env_alloc("CEF_DIR", context.allocator)
	if cef_dir == "" {
		fail("CEF_DIR is not set (the extracted CEF minimal distribution)")
	}
	resources := strings.join({cef_dir, "Resources"}, "/")
	locales := strings.join({resources, "locales"}, "/")
	home := os.get_env_alloc("HOME", context.allocator)

	// argv for CefExecuteProcess: CEF re-execs this binary for its
	// subprocesses, so it needs the real command line.
	args := make([dynamic]string, len(os.args))
	copy(args[:], os.args)
	if os.get_env_alloc("DISPLAY", context.allocator) == "" {
		// No X server (CI runner, this VM): run the headless ozone
		// platform instead of X11, or CefInitialize fails with
		// "Missing X server or $DISPLAY". The egress proxy also MITMs
		// TLS with its own CA, which CEF/NSS does not trust, so
		// certificate errors are ignored too (this is a smoke test of
		// the paint path, not a TLS check). SwiftShader gives the GPU
		// process a working GL without a display: without it the
		// compositor never produces a frame (paints stay at 0).
		append(&args, "--headless=new", "--ozone-platform=headless", "--ignore-certificate-errors", "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader")
	}
	c_argv := make([]cstring, len(args))
	for arg, i in args {
		c_argv[i] = strings.clone_to_cstring(arg)
	}
	main_args := cef_main_args_t{argc = i32(len(args)), argv = raw_data(c_argv)}

	// Subprocesses (renderer etc.) run this same binary: if this is one,
	// CefExecuteProcess handles it and returns its exit code.
	if code := cef_execute_process(&main_args, nil, nil); code >= 0 {
		os.exit(int(code))
	}

	handlers_init()

	settings := cef_settings_t{}
	settings.size = size_of(cef_settings_t)
	settings.no_sandbox = 1 // no setuid helper inside a container/Flatpak
	settings.multi_threaded_message_loop = 0
	settings.external_message_pump = 1 // we pump with CefDoMessageLoopWork
	settings.windowless_rendering_enabled = 1
	settings.log_severity = LOGSEVERITY_INFO
	settings.background_color = 0xFFFFFFFF
	settings.resources_dir_path = cef_string(resources)
	settings.locales_dir_path = cef_string(locales)
	if home != "" {
		settings.root_cache_path = cef_string(strings.join({home, ".cache", "cef-smoke"}, "/"))
	}

	if cef_initialize(&main_args, &settings, nil, nil) == 0 {
		fail("cef_initialize (exit code %d)", cef_get_exit_code())
	}
	fmt.println("cef initialized")

	window_info := cef_window_info_t{}
	window_info.size = size_of(cef_window_info_t)
	window_info.bounds = cef_rect_t{0, 0, VIEW_W, VIEW_H}
	window_info.windowless_rendering_enabled = 1
	window_info.shared_texture_enabled = 0 // frames come through OnPaint
	window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY

	browser_settings := cef_browser_settings_t{}
	browser_settings.size = size_of(cef_browser_settings_t)
	browser_settings.windowless_frame_rate = 30
	browser_settings.background_color = 0xFFFFFFFF

	// Scenario 1: tab close must really free the memory.
	scenario_tab_close(&window_info, &browser_settings)

	// The tab-close run leaves paint/load state in the shared globals;
	// reset them so the single-page scenario measures only itself. The
	// survivor tab (tab 0) stays open; its renderer does not affect the
	// frame scenario, which only checks its own page's paints.
	phase = 1
	got_frame = false
	load_done = false
	load_failed = false
	paint_calls = 0
	frame_buf = nil

	url := cef_string(URL)
	defer cef_string_utf16_clear(&url)

	if cef_browser_host_create_browser(&window_info, &client, &url, &browser_settings, nil, nil) == 0 {
		cef_shutdown()
		fail("cef_browser_host_create_browser")
	}

	deadline := time.now()
	deadline = time.time_add(deadline, TIMEOUT)
	for {
		cef_do_message_loop_work()
		// Exit once the page has loaded and the paints have settled:
		// no new frame for a second means the compositor is done.
		if load_done && got_frame && time.since(last_paint_at) >= 1 * time.Second {
			break
		}
		if load_failed {
			cef_shutdown()
			fail("page load error %d", load_error_code)
		}
		if time.since(deadline) >= 0 {
			cef_shutdown()
			fail("no settled frame within %v (browser created: %v, load done: %v, paints: %v)", TIMEOUT, browser_created, load_done, paint_calls)
		}
		time.sleep(10 * time.Millisecond)
	}
	fmt.println("paint: settled frame", frame_w, "x", frame_h, "after", paint_calls, "paints")

	// BGRA -> P6 RGB, so the frame is viewable without any image library.
	rgb := make([]u8, int(frame_w*frame_h*3))
	for i := 0; i < int(frame_w*frame_h); i += 1 {
		rgb[i*3+0] = frame_buf[i*4+2]
		rgb[i*3+1] = frame_buf[i*4+1]
		rgb[i*3+2] = frame_buf[i*4+0]
	}
	header := fmt.tprintf("P6\n%d %d\n255\n", frame_w, frame_h)
	f, ferr := os.open("frame.ppm", os.O_CREATE | os.O_WRONLY | os.O_TRUNC)
	if ferr != nil {
		cef_shutdown()
		fail("could not open frame.ppm: %v", ferr)
	}
	defer os.close(f)
	if _, werr := os.write_string(f, header); werr != nil {
		cef_shutdown()
		fail("could not write frame.ppm: %v", werr)
	}
	if _, werr := os.write(f, rgb); werr != nil {
		cef_shutdown()
		fail("could not write frame.ppm: %v", werr)
	}

	cef_shutdown()
	fmt.println("PASS: single page frame", frame_w, "x", frame_h, "-> frame.ppm")
}
