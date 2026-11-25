// What the engines tell Iris 2.3's features (engine_api.odin lists the
// calls both make): sound starting and stopping, a page committed or done,
// a load that failed. Engine-free: the reader, the privacy report and https
// first act on them.
package iris

import "core:strings"

/// the page started or stopped playing sound
browser_page_audio :: proc(t: ^Tab, on: bool) {
	if t.audio == on do return
	t.audio = on
	browser_tab_changed(t)
}

/// a new page is in the tab: what Iris knew of the last one goes
browser_page_committed :: proc(t: ^Tab, uri: string) {
	set_str(&t.committed_url, uri)
	cert_committed(t, uri)
	t.article = false
	for h in t.trackers do delete(h)
	clear(&t.trackers)
	if t.reader_pending {
		t.reader, t.reader_pending = true, false
	} else {
		t.reader = false
	}
	// over https at last: an upgrade that worked is forgotten
	if len(t.upgraded_from) > 0 && strings.has_prefix(uri, "https://") {
		delete(t.upgraded_from)
		t.upgraded_from = ""
	}
	browser_session_changed()
	browser_tab_changed(t)
}

/// the page finished loading: one look at it (article? trackers stopped?)
browser_page_finished :: proc(t: ^Tab) {
	if t.reader do return
	page_keys_watch(t)
	survey_page(t)
}

/// the main page failed to load (cancelled: stopped or replaced, no failure)
browser_load_failed :: proc(t: ^Tab, uri: string, cancelled: bool) {
	if cancelled do return
	https_failed(t, uri)
}

/// what a tab leaves behind that 2.3 added
tab_free_extra :: proc(t: ^Tab) {
	for h in t.trackers do delete(h)
	delete(t.trackers)
	delete(t.space)
	delete(t.upgraded_from)
	delete(t.committed_url)
	tab_view_free(t)
}
