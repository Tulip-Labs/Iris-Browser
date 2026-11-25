// cef-check: the headless proof that the real binary works with CEF.
// One browser, one real page: load, title, one JS eval with a result,
// one settled frame. It runs before any window exists, so there is no
// GL context — the engine's frame buffer is read directly, never
// uploaded to a texture. Prints PASS lines and returns 0 when every
// step passes, 1 otherwise.
package iris

import "core:fmt"
import "core:strings"
import "core:time"
import cef "cef"

CEF_CHECK_URL :: "https://example.org"
CEF_CHECK_TIMEOUT :: 60 * time.Second
CEF_CHECK_EVAL_TIMEOUT :: 15 * time.Second

@(private="file") Cef_Check_Eval :: struct {
	result: string,
	done:   bool,
}

cef_check_run :: proc() -> int {
	b := cef.new_browser(CEF_CHECK_URL, 800, 600)
	if b == nil {
		fmt.eprintln("cef-check: FAIL new_browser failed")
		return 1
	}
	// count paints from the start: the first paint can arrive while
	// creation is still being waited for
	paints := 0
	b.on_frame = proc(b: ^cef.Browser) {
		c := cast(^int)b.user
		c^ += 1
	}
	b.user = &paints
	if !cef.wait_created(b, 30_000) {
		fmt.eprintln("cef-check: FAIL no OnAfterCreated within 30s")
		return 1
	}
	fmt.println("cef-check: browser created")

	// wait for the load to finish and a frame to settle (two paints,
	// like the smoke test: the first paint can be partial text)
	deadline := time.time_add(time.now(), CEF_CHECK_TIMEOUT)
	loaded := false
	for {
		if !b.loading && paints >= 2 && b.frame_w == 800 && b.frame_h == 600 {
			loaded = true
			break
		}
		if time.since(deadline) >= 0 {
			break
		}
		cef.pump()
		time.sleep(10 * time.Millisecond)
	}
	if !loaded {
		fmt.eprintf("cef-check: FAIL page did not load (loading=%v paints=%d frame=%dx%d)\n", b.loading, paints, b.frame_w, b.frame_h)
		return 1
	}
	fmt.println("cef-check: loaded", CEF_CHECK_URL)

	// one JS eval with a result: the title, then a value
	title := Cef_Check_Eval{}
	if cef.eval_js(b, "document.title", cef_check_eval_done, &title) < 0 {
		fmt.eprintln("cef-check: FAIL eval document.title was not started")
		return 1
	}
	if !cef_check_wait_eval(&title) {
		fmt.eprintln("cef-check: FAIL eval document.title never answered")
		return 1
	}
	if title.result != "Example Domain" {
		fmt.eprintf("cef-check: FAIL title is %q, want %q\n", title.result, "Example Domain")
		return 1
	}
	fmt.println("cef-check: eval document.title ->", title.result)

	sum := Cef_Check_Eval{}
	if cef.eval_js(b, "1+1", cef_check_eval_done, &sum) < 0 {
		fmt.eprintln("cef-check: FAIL eval 1+1 was not started")
		return 1
	}
	if !cef_check_wait_eval(&sum) {
		fmt.eprintln("cef-check: FAIL eval 1+1 never answered")
		return 1
	}
	if sum.result != "2" {
		fmt.eprintf("cef-check: FAIL 1+1 is %q, want %q\n", sum.result, "2")
		return 1
	}
	fmt.println("cef-check: eval 1+1 ->", sum.result)
	fmt.println("cef-check: frame", b.frame_w, "x", b.frame_h, "after", paints, "paints")
	fmt.println("PASS: cef-check")
	return 0
}

@(private="file") cef_check_eval_done :: proc(result: string, user: rawptr) {
	s := cast(^Cef_Check_Eval)user
	s.result = strings.clone(result)
	s.done = true
}

@(private="file") cef_check_wait_eval :: proc(s: ^Cef_Check_Eval) -> bool {
	deadline := time.time_add(time.now(), CEF_CHECK_EVAL_TIMEOUT)
	for !s.done {
		if time.since(deadline) >= 0 {
			return false
		}
		cef.pump()
		time.sleep(10 * time.Millisecond)
	}
	return true
}
