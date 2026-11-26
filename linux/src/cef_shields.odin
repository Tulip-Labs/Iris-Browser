// Shields in the CEF engine: the
// lists shields.odin fetches, turned by rules.odin's converter into the
// same rules as everywhere (whole hosts as host sets), kept in a file that
// later starts read, matched per request (shield_match.odin) in
// OnBeforeResourceLoad on CEF's IO thread; hiding goes into each page as a
// style sheet (cef_view.odin).
package iris

import "base:intrinsics"

// (not indented: the whole file is this engine's)

@(private="file") the_matcher: ^Matcher

/// the matcher in use (any thread; it is never changed, only replaced)
cef_matcher :: proc "contextless" () -> ^Matcher {
	return intrinsics.atomic_load(&the_matcher)
}

cef_shields_start :: proc() {
	shields.installed = browser_reapply_shields
	shields_start()
}

/// a matcher made (shields.odin): it replaces the one in use, which goes a
/// minute later (a request on the IO thread may hold it). The level is
/// shields.odin's to check: a level asked for meanwhile is made next.
cef_shields_install :: proc(m: ^Matcher) {
	if m == nil do return
	old := intrinsics.atomic_exchange(&the_matcher, m)
	if old != nil do after(60_000, proc(d: rawptr) { matcher_free(cast(^Matcher)d) }, old)
	if shields.installed != nil do shields.installed()
}

engine_shields_level_changed :: proc() { shields_level_changed() }

/// the lists' rules are in place (until then Iris's own domains block)
engine_shields_ready :: proc() -> bool {
	_, ok := shields.have.?
	return ok
}

/// new rules or the switch changed: every open page takes them
browser_reapply_shields :: proc() {
	for t in b.tabs do if tab_has_view(t) {
		h, _ := host_of(t.url, context.temp_allocator)
		tab_shields_apply(t, h)
	}
}

/// the shield for the page the tab shows: on or off for its site, and the
/// page's own exception (matcher_page_ignore), read by the IO thread
tab_shields_apply :: proc(t: ^Tab, host: string) {
	v := t.cv
	if v == nil do return
	on := shields_on_for(host)
	ignore: i32 = -1
	if on do ignore = matcher_page_ignore(cef_matcher(), t.url, host)
	intrinsics.atomic_store(&v.page_ignore, ignore)
	intrinsics.atomic_store(&v.shield_on, on ? 1 : 0)
}

/// a request's type, as the rules name it (from cef_resource_type_t)
req_type_of :: proc "contextless" (rt: i32) -> Req_Type {
	switch rt {
	case RT_MAIN_FRAME, RT_SUB_FRAME: return .document
	case RT_STYLESHEET: return .style_sheet
	case RT_SCRIPT, RT_WORKER, RT_SHARED_WORKER, RT_SERVICE_WORKER: return .script
	case RT_IMAGE, RT_FAVICON: return .image
	case RT_FONT_RESOURCE: return .font
	case RT_MEDIA: return .media
	case RT_XHR: return .fetch
	case RT_PING, RT_CSP_REPORT: return .ping
	}
	return .other
}

