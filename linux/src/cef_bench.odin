// A benchmark run for CI: with IRIS_CEF_BENCH_URL set,
// Iris opens that address in a tab of its own, asks the page every few
// seconds for its score (IRIS_CEF_BENCH_JS, an expression that is empty
// until there is one; Speedometer 3's #result-number by default), prints
//   IRIS_CEF_BENCH score=<the score> seconds=<how long it took>
// on standard output and quits. If no score comes in IRIS_CEF_BENCH_TIMEOUT
// seconds (900 by default) it prints score=timeout and quits.
//
// For Speedometer 3:
//   IRIS_CEF_BENCH_URL='https://browserbench.org/Speedometer3.1/?startAutomatically=true'
package iris

import "core:fmt"
import "core:strconv"
import "core:strings"

// (not indented: the whole file is this engine's)

@(private="file") BENCH_JS_DEFAULT :: `(() => { const s = document.getElementById('summary'), r = document.getElementById('result-number'); if (!s || !r) return ''; const v = (r.textContent || '').trim(); return v && getComputedStyle(s).display !== 'none' && s.offsetParent !== null ? v : ''; })()`

@(private="file") Bench :: struct {
	url, js:  string,
	tab:      ^Tab,
	tab_id:   int,
	polls:    int,
	answers:  int,
	started:  f64,
	timeout:  f64,
	done:     bool,
}

@(private="file") bench: Bench

BENCH_POLL_MS :: 3000

/// at the engine's start: a benchmark run, if one is asked for
cef_bench_start :: proc() {
	u := env("IRIS_CEF_BENCH_URL")
	if len(u) == 0 do return
	bench.url = strings.clone(u)
	cef_bench_diag = true
	js := env("IRIS_CEF_BENCH_JS")
	bench.js = strings.clone(len(js) > 0 ? js : BENCH_JS_DEFAULT)
	bench.timeout = 900
	if s, ok := strconv.parse_f64(env("IRIS_CEF_BENCH_TIMEOUT")); ok && s > 0 do bench.timeout = s
	// the window and the tab strip first
	after(1500, proc(d: rawptr) {
		t := browser_new_tab({url = bench.url, select = true})
		if t == nil {
			bench_end("error")
			return
		}
		bench.tab, bench.tab_id = t, t.id
		bench.started = now_s()
		after(BENCH_POLL_MS, bench_poll, nil)
	}, nil)
}

@(private="file") bench_poll :: proc(d: rawptr) {
	if bench.done do return
	t := bench.tab
	if !browser_tab_alive(t) || t.id != bench.tab_id {
		bench_end("tab-closed")
		return
	}
	if now_s() - bench.started > bench.timeout {
		bench_end("timeout")
		return
	}
	if t != b.current do browser_select(t) // the benchmark needs a page in sight
	bench.polls += 1
	// once a minute: where the page is, from the engine's own callbacks and
	// from the page, so a run that never scores says why
	if bench.polls % 20 == 1 {
		fmt.printf("IRIS_CEF_BENCH_STATE t=%.0f url=%s title=%q loading=%v answers=%d/%d gpu_frames=%v\n",
			now_s() - bench.started, t.url, t.title, t.loading, bench.answers, bench.polls - 1, cef_gpu_frames)
		// the plain way, no hidden frame: does a console message arrive at all?
		if t.cv != nil {
			f := main_frame(t.cv)
			run_in(f, `console.info('IRISDIAG raw ' + document.readyState); console.log('IRISDIAG log')`)
			if f != nil do rel(f)
		}
		tab_run(t, `document.readyState + ' ' + location.href + ' ' + ((document.querySelector('#progress-completed, .progress-completed, #info, #summary') || {}).textContent || '').slice(0, 80).replace(/\s+/g, ' ')`, proc(t: ^Tab, result: string) {
			fmt.printf("IRIS_CEF_BENCH_PAGE %s\n", result)
		})
	}
	tab_run(t, bench.js, proc(t: ^Tab, result: string) {
		if bench.done do return
		bench.answers += 1
		if r := strings.trim_space(result); len(r) > 0 && r != "undefined" && r != "null" do bench_end(r)
	})
	after(BENCH_POLL_MS, bench_poll, nil)
}

@(private="file") bench_end :: proc(score: string) {
	if bench.done do return
	bench.done = true
	fmt.printf("IRIS_CEF_BENCH score=%s seconds=%.0f gpu_frames=%v\n", score, bench.started > 0 ? now_s() - bench.started : 0, cef_gpu_frames)
	browser_quit()
}

