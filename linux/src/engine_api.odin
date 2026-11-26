// The page engine: CEF (Chromium), windowless (cef_*.odin).
//
// Everything else in linux/src (the chrome, the tabs' list, history,
// containers' data, downloads' list, Shields' lists) calls only the
// procedures below, which the engine provides; one missing is a compile
// error, so `odin check src` is the contract's test.
//
// Process and engine
//   engine_subprocess() -> (code, is_sub)  first thing in main (CEF re-runs
//                                          the binary for its renderers)
//   engine_start() -> bool, engine_stop()  around the main loop
//   engine_shields_level_changed(), engine_shields_ready() -> bool,
//   browser_reapply_shields(), tab_shields_apply(t, host)
//   engine_forget_container(id), end_private()
// A tab's view (Tab_View is embedded in Tab with `using`)
//   tab_has_view, tab_ensure_web(t, related), tab_release_web, tab_load,
//   tab_back, tab_forward, tab_reload, tab_reload_bypass, tab_stop,
//   tab_set_zoom, tab_run(t, js, done), tab_find(t, text, dir),
//   tab_find_stop, tab_download(t, url), tab_edit(t, cmd), tab_warm_dns
// What pages asked for (Browser_Asks is embedded in Browser)
//   engine_answer_option(id, index), engine_answer_permission(id, allow),
//   engine_answer_dialog(id, yes, text)
//   (asked through chrome_dialog, chrome_permission, chrome_option_menu,
//   chrome_context_menu with b.context_info; pop-ups and new windows come
//   back as browser_new_tab, never as a blank tab)
// Downloads (Download_Engine is embedded in Download)
//   download_cancel(d), download_release(d)
// The page on screen and its input (Page)
//   Page{tex, cursor, user, on_frame, on_cursor, on_fullscreen},
//   page_latch, flush_rendered, page_place, page_set_visible,
//   page_set_active, page_focus, page_pointer, page_key, set_keymap,
//   clipboard_from_desktop
// Iris 2.3's features (cef_extra.odin)
//   tab_set_muted(t, on), tab_run_isolated(t, js, done) (a world of Iris's
//   own where the engine has one), tab_show_html(t, html, base) and
//   tab_reader_exit(t) (the reader), engine_theme_changed() (Iris went
//   light or dark, theme.dark: pages follow where the engine can; call
//   it wherever theme.dark changes), tab_isolate(t) (a peek: processes
//   of its own), tab_end_isolated(t), tab_view_free(t); and they call
//   browser_page_audio, browser_page_committed, browser_page_finished,
//   browser_load_failed (page_events.odin), https_first/https_wanted/
//   https_is_upgrade (features.odin) where they load and decide
// A failing certificate (interstitial.odin; the engine's certificate
// handler calls cert_decide, then cert_block or https_failed)
//   tab_cert_proceed(t, url, host, engine) ("Show anyway": the tab in the
//   sandbox, the certificate let through there), tab_cert_release(engine)
// The engines tell the browser through browser_tab_changed,
// browser_page_frame, browser_page_cursor, browser_fullscreen,
// browser_hover_link, browser_toast and the history/download procedures.
package iris

import "core:strings"

/// the editing commands a context menu sends (tab_edit)
EDIT_CUT :: "Cut"
EDIT_COPY :: "Copy"
EDIT_PASTE :: "Paste"
EDIT_SELECT_ALL :: "SelectAll"

/// whether a page's script dialog may show now: over its own tab only, one
/// at a time, and not from a page that keeps opening them (it is told once)
browser_dialog_admit :: proc(t: ^Tab) -> bool {
	if t == b.current && b.dialog_tab == nil && dialog_allowed(t, now_s()) do return true
	if t.dialogs_blocked && t.dialogs_n == DIALOGS_BURST + 1 {
		t.dialogs_n += 1 // said once
		host := display_url(t.url, context.temp_allocator)
		browser_toast(strings.concatenate({len(host) > 0 ? host : "This page", " kept opening dialogs: Iris stopped them"}, context.temp_allocator))
	}
	return false
}
