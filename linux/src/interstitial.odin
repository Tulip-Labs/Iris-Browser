// A certificate that fails, as Iris says so: a page of Iris's own over the
// tab (glass, as the start page), never the site. "Go back" is the answer
// it offers; "Show anyway (in the sandbox)" waits behind "Details", and is
// never chosen for you. An https try of an http address (https first,
// features.odin) is no such page: it failed, and Iris offers the http one.
// Engine-free: the engines call cert_decide and cert_block from their
// certificate handlers, and give tab_cert_proceed and tab_cert_release.
package iris

import "core:fmt"
import "core:strings"
import "core:testing"
import plat "../plat"

Cert_Error :: struct {
	url, host: string,
	/// what is wrong, in words, and the engine's name for it
	reason, code: string,
	/// the engine's hold on the certificate for
	/// "Show anyway"; tab_cert_release lets it go
	engine:   rawptr,
	details:  bool,
	t0:       f64,
	/// the page committed before the failure (where "Go back" goes)
	back_url: string,
	/// when the page last appeared or changed under the pointer (wall
	/// clock): its buttons wait CLICK_DELAY before taking a click, so a
	/// click meant for the page before cannot land on them
	armed_at: f64,
}

/// seconds Iris's page ignores clicks after it appears or Details opens
CLICK_DELAY :: 0.5

/// whether a click now may act (pure: the times are given)
cert_click_ready :: proc(armed_at, now: f64) -> bool {
	return now - armed_at >= CLICK_DELAY || now < armed_at
}

/// hosts whose failing certificate you chose to see anyway, this run: they
/// open in the sandbox wherever they open (untrusted, search.odin)
@(private="file") cert_sandboxed: map[string]bool

cert_host_sandboxed :: proc(host: string) -> bool {
	return len(cert_sandboxed) > 0 && host in cert_sandboxed
}

Cert_Answer :: enum u8 {
	/// the https try of an http address: Iris offers http (https_failed)
	Upgrade_Failed,
	/// you chose to see this host anyway, in this sandboxed tab
	Allowed,
	/// Iris's page over the tab
	Block,
}

/// what a failing certificate for a tab's main page gets
cert_decide :: proc(t: ^Tab, uri: string) -> Cert_Answer {
	if https_is_upgrade(t, uri) do return .Upgrade_Failed
	h, ok := host_of(uri, context.temp_allocator)
	if ok && t.sandboxed && h in t.allowed_certs do return .Allowed
	return .Block
}

/// Iris's page over the tab: the site is not shown (engine: the engine's
/// hold on the certificate, now the tab's)
cert_block :: proc(t: ^Tab, uri, reason, code: string, engine: rawptr) {
	cert_clear(t)
	h, _ := host_of(uri, context.temp_allocator)
	c := new(Cert_Error)
	c^ = {url = strings.clone(uri), host = strings.clone(h), reason = strings.clone(reason), code = strings.clone(code), engine = engine, t0 = ui.clock,
		back_url = strings.clone(t.committed_url), armed_at = now_s()}
	t.cert_error = c
	if t == b.current || t == b.peek do chrome_set_focus(false)
	browser_tab_changed(t)
}

@(private="file") cert_free :: proc(c: ^Cert_Error) {
	if c.engine != nil do tab_cert_release(c.engine)
	delete(c.url)
	delete(c.host)
	delete(c.reason)
	delete(c.code)
	delete(c.back_url)
	free(c)
}

/// the page goes (you went elsewhere, or the tab closes)
cert_clear :: proc(t: ^Tab) {
	c := t.cert_error
	if c == nil do return
	t.cert_error = nil
	cert_free(c)
	chrome_push()
}

/// a page committed in the tab: one that is not the failing one (the
/// engine's own error page for it, in CEF) ends Iris's page
cert_committed :: proc(t: ^Tab, uri: string) {
	c := t.cert_error
	if c == nil || uri == c.url || strings.has_prefix(uri, "chrome-error:") do return
	cert_clear(t)
}

/// "Go back": where you were (the page before a failed load, if it is
/// still on screen), else back, else the start page (a peek closes)
cert_go_back :: proc(t: ^Tab) {
	c := t.cert_error
	if c == nil do return
	// nothing committed since the failure: the page before is still there
	// (CEF commits its error page in its place, so back is back)
	stayed := tab_has_view(t) && len(c.back_url) > 0 && c.back_url != "about:blank" && c.back_url != c.url && t.committed_url == c.back_url
	if stayed do set_str(&t.url, c.back_url)
	cert_clear(t)
	switch {
	case stayed: browser_tab_changed(t)
	case t == b.peek: peek_close()
	case t.can_back: tab_back(t)
	case: browser_go_start(t)
	}
}

/// "Show anyway (in the sandbox)": your choice, for this tab, this host,
/// this run; its cookies, sign-ins and files stay out of it
cert_proceed :: proc(t: ^Tab) {
	c := t.cert_error
	if c == nil do return
	t.cert_error = nil
	if len(c.host) > 0 && c.host not_in cert_sandboxed do cert_sandboxed[strings.clone(c.host)] = true
	tab_cert_proceed(t, c.url, c.host, c.engine)
	browser_toast(strings.concatenate({display_url(c.url, context.temp_allocator), " is open in the sandbox, its certificate unchecked"}, context.temp_allocator))
	cert_free(c)
	chrome_push()
}

/// a tab, by id, the peek's too
@(private="file") alive_by_id :: proc(id: int) -> ^Tab {
	for t in browser_all_tabs() do if t.id == id do return t
	return nil
}

/// a click on Iris's page (chrome.odin's act)
cert_act :: proc(op: Op, tab_id: int) {
	t := alive_by_id(tab_id)
	if t == nil || t.cert_error == nil do return
	// a click too soon after the page appeared or changed is ignored
	now := now_s()
	if !cert_click_ready(t.cert_error.armed_at, now) do return
	#partial switch op {
	case .Cert_Back: cert_go_back(t)
	case .Cert_Details:
		t.cert_error.details = !t.cert_error.details
		t.cert_error.armed_at = now
		chrome_push()
	case .Cert_Proceed: cert_proceed(t)
	}
}

/// the keys while Iris's page is over the tab: Enter goes back; nothing
/// reaches the page
interstitial_key :: proc(t: ^Tab, e: plat.Key_Event) {
	if !e.pressed do return
	if e.sym == plat.KEY_Return || e.sym == plat.KEY_KP_Enter do cert_go_back(t)
}

/// the page is over this point (the pointer goes to it, not the site)
interstitial_at :: proc(x, y: f64) -> bool {
	for h in ui.hits {
		if wid_of(h.id) != .Cert_Card do continue
		r := h.r
		if f32(x) >= r.x && f32(x) < r.x + r.z && f32(y) >= r.y && f32(y) < r.y + r.w do return true
	}
	return false
}

// ---------------------------------------------------------------- words

/// what GLib's certificate flags say, in words, and the flag's name
tls_flags_text :: proc(flags: u32) -> (reason, code: string) {
	// the one that matters most first
	switch {
	case flags & 2 != 0: return "Its certificate belongs to another site.", "G_TLS_CERTIFICATE_BAD_IDENTITY"
	case flags & 16 != 0: return "Its certificate was revoked.", "G_TLS_CERTIFICATE_REVOKED"
	case flags & 8 != 0: return "Its certificate has expired.", "G_TLS_CERTIFICATE_EXPIRED"
	case flags & 4 != 0: return "Its certificate is not valid yet.", "G_TLS_CERTIFICATE_NOT_ACTIVATED"
	case flags & 1 != 0: return "Its certificate is not from an authority Iris trusts.", "G_TLS_CERTIFICATE_UNKNOWN_CA"
	case flags & 32 != 0: return "Its certificate uses weak cryptography.", "G_TLS_CERTIFICATE_INSECURE"
	}
	return "Its certificate could not be checked.", "G_TLS_CERTIFICATE_GENERIC_ERROR"
}

/// what Chromium's certificate error says, in words, and its name
cef_cert_error_text :: proc(code: i32) -> (reason, name: string) {
	switch code {
	case -200: return "Its certificate belongs to another site.", "ERR_CERT_COMMON_NAME_INVALID"
	case -201: return "Its certificate has expired or is not valid yet.", "ERR_CERT_DATE_INVALID"
	case -202: return "Its certificate is not from an authority Iris trusts.", "ERR_CERT_AUTHORITY_INVALID"
	case -203: return "Its certificate has errors.", "ERR_CERT_CONTAINS_ERRORS"
	case -205: return "Its certificate could not be checked for revocation.", "ERR_CERT_UNABLE_TO_CHECK_REVOCATION"
	case -206: return "Its certificate was revoked.", "ERR_CERT_REVOKED"
	case -207: return "Its certificate is not valid.", "ERR_CERT_INVALID"
	case -208: return "Its certificate is signed with a weak algorithm.", "ERR_CERT_WEAK_SIGNATURE_ALGORITHM"
	case -210: return "Its certificate is for a name that is not unique.", "ERR_CERT_NON_UNIQUE_NAME"
	case -211: return "Its certificate has a weak key.", "ERR_CERT_WEAK_KEY"
	case -212: return "Its certificate breaks its authority's limits.", "ERR_CERT_NAME_CONSTRAINT_VIOLATION"
	case -213: return "Its certificate is valid for too long.", "ERR_CERT_VALIDITY_TOO_LONG"
	case -214: return "Its certificate was not made public as required.", "ERR_CERTIFICATE_TRANSPARENCY_REQUIRED"
	case -215: return "Its certificate is from an authority no longer trusted.", "ERR_CERT_SYMANTEC_LEGACY"
	case -217: return "Its certificate is known to be used for interception.", "ERR_CERT_KNOWN_INTERCEPTION_BLOCKED"
	}
	return "Its certificate could not be checked.", fmt.aprintf("ERR_CERT (%d)", code, allocator = context.temp_allocator)
}

// ---------------------------------------------------------------- drawing

/// Iris's page in the tab's place r: clear glass over the backdrop, as the
/// start page; the site is not drawn under it
draw_interstitial :: proc(t: ^Tab, r: [4]f32, dt: f32, opaque := false) {
	c := t.cert_error
	if c == nil || r.z < 40 || r.w < 40 do return
	k, moving := fade(c.t0, ui.clock)
	if moving do ui.animating = true
	// it takes every click in the tab's place
	if opaque do fill(r, 14, theme.dark ? {0.09, 0.10, 0.11, 1} : {0.96, 0.96, 0.97, 1})
	hit(id(.Cert_Card, t.id), r)

	w := min(520, r.z - 40)
	tw := w - 56
	body := wrap_text(fmt.tprintf("Someone may be pretending to be %s to steal what you send it, such as passwords, messages or card numbers. Iris did not open the page.", c.host), 13.5, tw)
	details: []string
	if c.details {
		details = wrap_text(fmt.tprintf("%s (%s) Only go on if you know why, as with a device or test server of your own. The page then opens in the sandbox: none of your cookies, sign-ins or files, and no downloads.", c.reason, c.code), 12.5, tw)
	}
	h := 64 + 30 + 24 + f32(len(body)) * 19 + 20 + 34 + 24
	if c.details do h += 14 + f32(len(details)) * 17 + 12 + 28
	h = min(h, r.w - 24)
	cr := [4]f32{r.x + (r.z - w) / 2, r.y + max(12, (r.w - h) * 0.42), w, h}
	draw_glass(cr.x, cr.y, cr.z, cr.w, glass_amount(glass_style({r = 24, kind = 1}), k))

	ink, dim := INK, DIM
	ink.a *= k
	dim.a *= k
	warn := WARN
	warn.a *= k
	x := cr.x + 28
	y := cr.y + 28
	draw_icon(.Warn, x, y, 30, warn)
	y += 30 + 34
	draw_text("This connection isn't private", x, y, 20, ink, .Heavy, tw)
	y += 26
	draw_text(c.host, x, y, 14, ink, .Semibold, tw)
	y += 26
	for l in body {
		draw_text(l, x, y, 13.5, dim)
		y += 19
	}
	y += 14
	// Go back is the answer; Details is quieter, and only it shows the way on
	back := "Go back"
	bw := text_width(back, 13, .Bold) + 36
	pill({text = back, act = {op = .Cert_Back, n = t.id}, primary = true}, {cr.x + cr.z - 28 - bw, y, bw, 32}, 20, dt)
	dt_text := c.details ? "Hide details" : "Details"
	dw := text_width(dt_text, 13, .Bold) + 32
	pill({text = dt_text, act = {op = .Cert_Details, n = t.id}}, {x - 4, y, dw, 32}, 21, dt)
	if c.details {
		y += 32 + 26
		for l in details {
			draw_text(l, x, y, 12.5, dim)
			y += 17
		}
		y += 6
		more := "Show anyway (in the sandbox)"
		mw := text_width(more, 12.5, .Semibold)
		mr := [4]f32{x - 4, y - 4, mw + 8, 26}
		hv := hover_of(id(.Cert_Proceed, t.id), dt)
		mc := dim
		mc.a *= 0.8 + 0.2 * hv
		draw_text(more, x, baseline(mr.y, mr.w, 12.5), 12.5, mc, .Semibold)
		draw_fill(x, mr.y + mr.w - 5, mw, 1, 0, {mc.r, mc.g, mc.b, mc.a * 0.5})
		hit(id(.Cert_Proceed, t.id), mr, {op = .Cert_Proceed, n = t.id}, .Pointer)
	}
}

// ---------------------------------------------------------------- tests

@(test) test_cert_decide :: proc(t: ^testing.T) {
	tab: Tab
	defer delete(tab.allowed_certs)
	defer delete(tab.upgraded_from)
	// a failing certificate is Iris's page, never let through on its own
	testing.expect_value(t, cert_decide(&tab, "https://bank.example/login"), Cert_Answer.Block)
	tab.sandboxed = true
	testing.expect_value(t, cert_decide(&tab, "https://bank.example/login"), Cert_Answer.Block)
	// once you chose to see it, in that sandboxed tab
	tab.allowed_certs["bank.example"] = true
	testing.expect_value(t, cert_decide(&tab, "https://bank.example/x"), Cert_Answer.Allowed)
	testing.expect_value(t, cert_decide(&tab, "https://other.example/"), Cert_Answer.Block)
	tab.sandboxed = false
	testing.expect_value(t, cert_decide(&tab, "https://bank.example/x"), Cert_Answer.Block)
	// the https try of an http address: the way back to http instead
	tab.upgraded_from = strings.clone("http://old.example/")
	testing.expect_value(t, cert_decide(&tab, "https://old.example/"), Cert_Answer.Upgrade_Failed)
	testing.expect_value(t, cert_decide(&tab, "https://bank.example/"), Cert_Answer.Block)
}

@(test) test_cert_click_delay :: proc(t: ^testing.T) {
	testing.expect(t, !cert_click_ready(100, 100))
	testing.expect(t, !cert_click_ready(100, 100.49))
	testing.expect(t, cert_click_ready(100, 100.5))
	testing.expect(t, cert_click_ready(100, 200))
	// a clock that went back never locks the buttons
	testing.expect(t, cert_click_ready(100, 50))
}

@(test) test_cert_words :: proc(t: ^testing.T) {
	_, c := tls_flags_text(1 | 8)
	testing.expect_value(t, c, "G_TLS_CERTIFICATE_EXPIRED")
	_, c = tls_flags_text(1 | 2)
	testing.expect_value(t, c, "G_TLS_CERTIFICATE_BAD_IDENTITY")
	_, c = tls_flags_text(0)
	testing.expect_value(t, c, "G_TLS_CERTIFICATE_GENERIC_ERROR")
	_, c = cef_cert_error_text(-202)
	testing.expect_value(t, c, "ERR_CERT_AUTHORITY_INVALID")
	_, c = cef_cert_error_text(-299)
	testing.expect_value(t, c, "ERR_CERT (-299)")
}
