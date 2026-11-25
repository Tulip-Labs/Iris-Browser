// cef-smoke: the smallest proof CEF works on the Odin stack.
//
// A thin harness over the Iris CEF engine (linux/src/cef). Two scenarios,
// both must pass:
//
//  1. tab-close memory: open 3 tabs, close 2, and prove the closed tabs'
//     memory is really gone — fewer renderer processes and total
//     renderer RSS down by a clear margin. This is the WPE WebKit bug
//     (2.2.0-2.2.2) not happening again: a closed tab must really die.
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

import cef "../../linux/src/cef"

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

VIEW_W :: 800
VIEW_H :: 600
TIMEOUT :: 90 * time.Second
URL     :: "https://example.org"
TAB_URLS := [3]string{"https://example.org", "https://example.com", "https://example.net"}

fail :: proc(msg: string, args: ..any) {
	fmt.eprint("FAIL: ")
	fmt.eprintfln(msg, ..args)
	os.exit(1)
}

// Pump CEF's message loop until cond() is true or the deadline passes.
pump_until :: proc(deadline: time.Time, cond: proc() -> bool) -> bool {
	for {
		cef.pump()
		if cond() {
			return true
		}
		if time.since(deadline) >= 0 {
			return false
		}
		time.sleep(10 * time.Millisecond)
	}
}

// --- tab-close scenario state ---

// Tabs are created one at a time so creation order matches; the engine
// drops its own references in OnBeforeClose, and the harness drops its
// pointer in on_close — keeping it would keep the page alive, the same
// trap as the WPE bug (Iris held one reference too many on each page).
tabs:            [3]^cef.Browser
tabs_load_ended: int
tabs_closed:     int
tab_load_failed: bool
tab_load_error:  i32
tab_loaded:      [3]bool
last_load_end_at: time.Time

tab_index :: proc(b: ^cef.Browser) -> int {
	for i in 0..<len(tabs) {
		if tabs[i] == b {
			return i
		}
	}
	return -1
}

tab_on_loading :: proc(b: ^cef.Browser) {
	// Count the first transition to not-loading per tab: that is the
	// page finishing. (on_loading also fires when loading starts.)
	if b.loading {
		return
	}
	i := tab_index(b)
	if i < 0 || tab_loaded[i] {
		return
	}
	tab_loaded[i] = true
	tabs_load_ended += 1
	last_load_end_at = time.now()
	fmt.println("tab load end (", tabs_load_ended, "of 3)")
}

tab_on_load_error :: proc(b: ^cef.Browser) {
	tab_load_failed = true
	tab_load_error = b.load_error
	fmt.println("tab load error", b.load_error)
}

tab_on_close :: proc(b: ^cef.Browser) {
	i := tab_index(b)
	if i < 0 {
		return
	}
	tabs[i] = nil
	tabs_closed += 1
	fmt.println("tab", i, "closed")
}

cond_loads_done :: proc() -> bool { return tabs_load_ended >= 3 }
cond_closed_two :: proc() -> bool { return tabs_closed >= 2 }

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
// the summed RSS falls. A WPE-style leak — closed tabs kept alive by a
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

// Scenario 1: three tabs, each on its own request context (the engine
// gives every tab one), so each gets its own renderer process even if
// two tabs were on the same site. Close two of them and prove the memory
// is really gone. PASS needs BOTH: fewer renderer processes AND total
// renderer RSS down at least 30%. The count alone is not enough
// (Chromium may keep one small warm spare renderer); the RSS drop is the
// real guarantee. Either condition failing means a closed tab is still
// alive somewhere — the WPE bug, in CEF form.
scenario_tab_close :: proc() {
	fmt.println("scenario 1: tab close frees memory")
	for i in 0..<len(TAB_URLS) {
		b := cef.new_browser(TAB_URLS[i], VIEW_W, VIEW_H)
		if b == nil {
			fail("tab %d: new_browser failed", i)
		}
		b.on_loading = tab_on_loading
		b.on_load_error = tab_on_load_error
		b.on_close = tab_on_close
		tabs[i] = b
		if !cef.wait_created(b, 30_000) {
			fail("tab %d: no OnAfterCreated within 30s", i)
		}
		fmt.println("tab", i, "created:", TAB_URLS[i], "id =", b.id)
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
		cef.pump()
		time.sleep(10 * time.Millisecond)
	}

	count_a, rss_a := descendant_snapshot()
	fmt.println("tabs: before close:", count_a, "CEF processes, total RSS", rss_a, "kB")

	for i in 1..<len(TAB_URLS) {
		fmt.println("closing tab", i)
		cef.close_browser(tabs[i]) // force: no unload-handler delay
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
		cef.pump()
		count_b, rss_b = descendant_snapshot()
	}
	settle2 := time.time_add(time.now(), 2*time.Second)
	for time.since(settle2) < 0 {
		cef.pump()
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

// --- single-page scenario state ---

page_got_frame:  bool
page_frame_w:    i32
page_frame_h:    i32
page_load_done:  bool
page_load_failed: bool
page_load_error: i32
page_paints:     int
page_last_paint: time.Time

page_on_frame :: proc(b: ^cef.Browser) {
	// The frame bytes live in b.frame (BGRA); the harness only records
	// that a paint happened and when. The first paint can be partial
	// (text before the box around it), so the loop waits for the paints
	// to settle.
	page_got_frame = true
	page_frame_w, page_frame_h = b.frame_w, b.frame_h
	page_last_paint = time.now()
	page_paints += 1
}

page_on_loading :: proc(b: ^cef.Browser) {
	if b.loading || page_load_done {
		return
	}
	page_load_done = true
	fmt.println("load end")
}

page_on_load_error :: proc(b: ^cef.Browser) {
	page_load_failed = true
	page_load_error = b.load_error
	fmt.println("load error", b.load_error)
}

main :: proc() {
	// argv for CEF: subprocesses re-exec this binary, so the command
	// line must carry the flags they need too.
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

	// Register the API version and run the subprocess check first: this
	// runs in the browser process AND in every subprocess (they re-enter
	// main). A subprocess exits with the code cef returns.
	if code, is_sub := cef.startup(args[:]); is_sub {
		os.exit(code)
	}

	cef_dir := os.get_env_alloc("CEF_DIR", context.allocator)
	if cef_dir == "" {
		fail("CEF_DIR is not set (the extracted CEF minimal distribution)")
	}
	resources := strings.join({cef_dir, "Resources"}, "/")
	locales := strings.join({resources, "locales"}, "/")
	home := os.get_env_alloc("HOME", context.allocator)
	cache_dir := ""
	if home != "" {
		cache_dir = strings.join({home, ".cache", "cef-smoke"}, "/")
	}

	if !cef.init(cef.Init_Options{cache_dir = cache_dir, resources_dir = resources, locales_dir = locales}) {
		fail("cef_initialize (exit code %d)", cef.cef_get_exit_code())
	}
	fmt.println("cef initialized")

	// Scenario 1: tab close must really free the memory.
	scenario_tab_close()

	// The tab-close run leaves tab 0 open; its renderer does not affect
	// the frame scenario, which only checks its own page's paints.
	b := cef.new_browser(URL, VIEW_W, VIEW_H)
	if b == nil {
		cef.shutdown()
		fail("single page: new_browser failed")
	}
	b.on_frame = page_on_frame
	b.on_loading = page_on_loading
	b.on_load_error = page_on_load_error
	if !cef.wait_created(b, 30_000) {
		cef.shutdown()
		fail("single page: no OnAfterCreated within 30s")
	}
	fmt.println("browser created")

	deadline := time.time_add(time.now(), TIMEOUT)
	for {
		cef.pump()
		// Exit once the page has loaded and the paints have settled:
		// no new frame for a second means the compositor is done.
		if page_load_done && page_got_frame && time.since(page_last_paint) >= 1 * time.Second {
			break
		}
		if page_load_failed {
			cef.shutdown()
			fail("page load error %d", page_load_error)
		}
		if time.since(deadline) >= 0 {
			cef.shutdown()
			fail("no settled frame within %v (load done: %v, paints: %v)", TIMEOUT, page_load_done, page_paints)
		}
		time.sleep(10 * time.Millisecond)
	}
	fmt.println("paint: settled frame", page_frame_w, "x", page_frame_h, "after", page_paints, "paints")

	// BGRA -> P6 RGB, so the frame is viewable without any image library.
	rgb := make([]u8, int(page_frame_w*page_frame_h*3))
	for i := 0; i < int(page_frame_w*page_frame_h); i += 1 {
		rgb[i*3+0] = b.frame[i*4+2]
		rgb[i*3+1] = b.frame[i*4+1]
		rgb[i*3+2] = b.frame[i*4+0]
	}
	header := fmt.tprintf("P6\n%d %d\n255\n", page_frame_w, page_frame_h)
	f, ferr := os.open("frame.ppm", os.O_CREATE | os.O_WRONLY | os.O_TRUNC)
	if ferr != nil {
		cef.shutdown()
		fail("could not open frame.ppm: %v", ferr)
	}
	defer os.close(f)
	if _, werr := os.write_string(f, header); werr != nil {
		cef.shutdown()
		fail("could not write frame.ppm: %v", werr)
	}
	if _, werr := os.write(f, rgb); werr != nil {
		cef.shutdown()
		fail("could not write frame.ppm: %v", werr)
	}

	cef.shutdown()
	fmt.println("PASS: single page frame", page_frame_w, "x", page_frame_h, "-> frame.ppm")
}
