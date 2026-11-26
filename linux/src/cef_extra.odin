// The CEF engine's side of Iris 2.3's features (engine_api.odin). Sound
// comes from the page's media watcher (cef_view.odin), commits and loads
// from its load handler; a closed browser's renderers are reaped by
// cef_engine.odin, so a peek leaves no process behind without more here.
package iris

// (not indented: the whole file is this engine's)

tab_set_muted :: proc(t: ^Tab, on: bool) {
	if v := t.cv; v != nil && v.host != nil do v.host.set_audio_muted(v.host, on ? 1 : 0)
}

/// a peek's view: CEF gives each browser its own renderer, ended when it
/// closes (the reaper), so nothing more is needed
tab_isolate :: proc(t: ^Tab) { t.isolated = true }
tab_end_isolated :: proc(t: ^Tab) {}
tab_view_free :: proc(t: ^Tab) {}

/// the reader's page, in a fresh document of its own: the tab goes to a
/// blank page (a new history entry; the article's scripts and timers end
/// with its document), and the reader's page is written into it when it
/// has loaded (cef_view.odin's load handler). The address shown stays the
/// article's (a blank page never replaces it), and the page carries a
/// policy that runs no script. (CEF's C API has no load-with-base call, and
/// a data: address would show in the address bar and history.)
tab_show_html :: proc(t: ^Tab, html, base: string) {
	v := t.cv
	if v == nil do return
	set_str(&v.reader_html, html)
	t.reader_pending = true // the blank page's commit makes it the reader
	cef_load(v, "about:blank")
	browser_tab_changed(t)
}

/// out of the reader: the article's own page, as it was (back)
tab_reader_exit :: proc(t: ^Tab) {
	if v := t.cv; v != nil do set_str(&v.reader_html, "")
	t.reader_pending = false
	if t.can_back {
		tab_back(t)
	} else {
		t.reader = false
		tab_load(t, t.url)
	}
}

/// CEF runs Iris's scripts in the page's own world (its frames have no
/// world of Iris's through the C API): the same as tab_run
tab_run_isolated :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
	tab_run(t, js, done)
}

