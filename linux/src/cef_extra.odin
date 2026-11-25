// The CEF engine's side of Iris 2.3's features (engine_api.odin). Sound
// comes from the page's media watcher (cef_view.odin), commits and loads
// from its load handler; a closed browser's renderers are reaped by
// cef_engine.odin, so a peek leaves no process behind without more here.
package iris

import "core:fmt"

// (not indented: the whole file is this engine's)
when ENGINE_CEF {

tab_set_muted :: proc(t: ^Tab, on: bool) {
	if v := t.cv; v != nil && v.host != nil do v.host.set_audio_muted(v.host, on ? 1 : 0)
}

/// a peek's view: CEF gives each browser its own renderer, ended when it
/// closes (the reaper), so nothing more is needed
tab_isolate :: proc(t: ^Tab) { t.isolated = true }
tab_end_isolated :: proc(t: ^Tab) {}
tab_view_free :: proc(t: ^Tab) {}

/// the reader's page, written over the article's document (CEF has no
/// load-with-base call through Iris's C API; the address stays the
/// article's, and the page Iris writes carries a policy that runs no script)
tab_show_html :: proc(t: ^Tab, html, base: string) {
	if t.cv == nil do return
	tab_run(t, fmt.tprintf("(document.open(), document.write(%s), document.close(), 1)", json_str(html, context.temp_allocator)), proc(t: ^Tab, result: string) {})
	t.reader, t.reader_pending = true, false
	browser_tab_changed(t)
}

/// out of the reader: the article's own page again
tab_reader_exit :: proc(t: ^Tab) {
	t.reader = false
	tab_reload(t)
}

/// CEF runs Iris's scripts in the page's own world (its frames have no
/// world of Iris's through the C API): the same as tab_run
tab_run_isolated :: proc(t: ^Tab, js: string, done: proc(t: ^Tab, result: string)) {
	tab_run(t, js, done)
}

} // when ENGINE_CEF
