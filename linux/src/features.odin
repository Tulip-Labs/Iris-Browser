// Iris 2.3's everyday tab features, with no engine in them: pinned tabs,
// sound and muting, the closed-tab stack, https first with a one-click way
// back, clean links, and forgetting everything when Iris closes. Each costs
// nothing until used: no timers, no polling, no drawing.
package iris

import "core:os"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------- tabs alive

/// a tab Iris still has: in the strip, or the peek
browser_tab_alive :: proc(t: ^Tab) -> bool {
	return t != nil && (browser_has_tab(t) || t == b.peek)
}

// ---------------------------------------------------------------- pinned tabs

/// how many tabs are pinned (they come first in b.tabs, always)
pinned_count :: proc() -> int {
	n := 0
	for t in b.tabs do if t.pinned do n += 1
	return n
}

/// a tab pinned (to the end of the pinned ones) or unpinned (to the start
/// of the others): pinned tabs stay at the left, small, with no close button
tab_set_pinned :: proc(t: ^Tab, on: bool) {
	if t.pinned == on || !browser_has_tab(t) do return
	for x, i in b.tabs do if x == t {
		ordered_remove(&b.tabs, i)
		break
	}
	t.pinned = on
	inject_at(&b.tabs, pinned_count() - (on ? 1 : 0), t)
	chrome_push()
}

/// where a new tab may go: pinned ones first, then the rest
clamp_insert :: proc(at: int, pinned: bool, n_pinned, n: int) -> int {
	if pinned do return clamp(at, 0, n_pinned)
	return clamp(at, n_pinned, n)
}

// ---------------------------------------------------------------- sound

tab_toggle_mute :: proc(t: ^Tab) {
	if t == nil do return
	t.muted = !t.muted
	tab_set_muted(t, t.muted)
	chrome_push()
}

// ---------------------------------------------------------------- closed tabs

Closed_Tab :: struct {
	tab:   Saved_Tab,
	index: int,
}

/// a closed tab kept for Ctrl+Shift+T (the last CLOSED_MAX, never private
/// or sandboxed ones); forgotten with everything else on a clear exit
closed_push :: proc(t: ^Tab, index: int) {
	if tab_is_private(t) || t.sandboxed || len(t.url) == 0 do return
	if len(b.closed) >= CLOSED_MAX {
		closed_free(b.closed[0])
		ordered_remove(&b.closed, 0)
	}
	append(&b.closed, Closed_Tab{tab = {url = strings.clone(t.url), title = strings.clone(t.title), container = strings.clone(t.container), pinned = t.pinned, space = strings.clone(t.space)}, index = index})
}

closed_free :: proc(c: Closed_Tab) {
	delete(c.tab.url)
	delete(c.tab.title)
	delete(c.tab.container)
	delete(c.tab.space)
}

closed_clear :: proc() {
	for c in b.closed do closed_free(c)
	clear(&b.closed)
}

// ---------------------------------------------------------------- clean links

/// the address with its tracking parameters taken off, on the clipboard
copy_clean_link :: proc(u: string) {
	if len(u) == 0 do return
	clean, stripped := strip_tracking(u, context.temp_allocator)
	clipboard_offer(stripped ? clean : u)
	browser_toast(stripped ? "Link copied, without its tracking" : "Link copied")
}

// ---------------------------------------------------------------- https first

@(private="file") Upgrades :: struct {
	n:     int,
	since: f64,
}
/// hosts with no working https, this run (you chose http for them)
@(private="file") http_ok: map[string]bool
@(private="file") upgrades: map[string]Upgrades

/// hosts that are never tried over https: your own network, single names,
/// addresses, and http on a port of its own
https_host_ok :: proc(host: string) -> bool {
	h := strings.to_lower(strings.trim_suffix(host, "."), context.temp_allocator)
	if len(h) == 0 || strings.index_byte(h, '.') < 0 || strings.index_byte(h, ':') >= 0 || is_private_host(h) do return false
	if _, ip := ipv4_parse(h); ip do return false
	for s in ([?]string{".local", ".lan", ".home.arpa", ".internal", ".test", ".localhost", ".onion", ".i2p"}) do if strings.has_suffix(h, s) do return false
	return true
}

/// the https address for an http one ("" when there is none to try)
https_upgrade_url :: proc(u: string, allocator := context.temp_allocator) -> string {
	if len(u) < 8 || !strings.equal_fold(u[:7], "http://") do return ""
	rest := u[7:]
	end := strings.index_any(rest, "/?#")
	if end < 0 do end = len(rest)
	hostport := rest[:end]
	if strings.index_byte(hostport, '@') >= 0 do return "" // user:password@: as it is
	host := hostport
	if c := strings.last_index_byte(hostport, ':'); c >= 0 {
		if hostport[c + 1:] != "80" do return "" // http on a port of its own
		host = hostport[:c]
	}
	if !https_host_ok(host) do return ""
	return strings.concatenate({"https://", host, rest[end:]}, allocator)
}

/// whether Iris tries this http address over https (decide-policy): not
/// when https led back to it, nor for a host you opened over http
https_wanted :: proc(t: ^Tab, u: string) -> bool {
	if !settings().httpsOnly do return false
	up := https_upgrade_url(u)
	if len(up) == 0 do return false
	h, _ := host_of(u, context.temp_allocator)
	if h in http_ok do return false
	// the https site sent us back to http: it has none worth the name
	if len(t.upgraded_from) > 0 {
		if fh, _ := host_of(t.upgraded_from, context.temp_allocator); fh == h {
			http_ok[strings.clone(h)] = true
			return false
		}
	}
	// a page that keeps going back to http (a script) is let be
	now := now_s()
	c := upgrades[h]
	if now - c.since > 20 do c = {0, now}
	if c.n >= 3 {
		http_ok[strings.clone(h)] = true
		return false
	}
	return true
}

/// the address a tab loads: https in place of http where it is wanted
/// (temporary; u itself otherwise)
https_first :: proc(t: ^Tab, u: string) -> string {
	if !https_wanted(t, u) do return u
	up := https_upgrade_url(u)
	h, _ := host_of(u, context.temp_allocator)
	now := now_s()
	c := upgrades[h]
	if now - c.since > 20 do c = {0, now}
	c.n += 1
	if h in upgrades {
		upgrades[h] = c
	} else {
		upgrades[strings.clone(h)] = c
	}
	set_str(&t.upgraded_from, u)
	return up
}

/// a failure (uri) is the https try of an http address
https_is_upgrade :: proc(t: ^Tab, uri: string) -> bool {
	if len(t.upgraded_from) == 0 || !strings.has_prefix(uri, "https://") do return false
	a, _ := host_of(uri, context.temp_allocator)
	z, _ := host_of(t.upgraded_from, context.temp_allocator)
	return len(a) > 0 && a == z
}

/// the https try failed: WebKit shows why, and one click opens the http
/// address you asked for (in the sandbox, as every http site)
https_failed :: proc(t: ^Tab, uri: string) {
	if !https_is_upgrade(t, uri) do return
	from := strings.clone(t.upgraded_from, context.temp_allocator)
	delete(t.upgraded_from)
	t.upgraded_from = ""
	host := display_url(from, context.temp_allocator)
	chrome_toast(strings.concatenate({host, " has no secure version"}, context.temp_allocator), "Open over HTTP", url = from, tab = t.id, life_ms = 9000)
}

/// the toast's button: this host over http from now on, in its tab
https_fallback :: proc(t: ^Tab, u: string) {
	if !browser_tab_alive(t) do return
	if h, ok := host_of(u, context.temp_allocator); ok && h not_in http_ok do http_ok[strings.clone(h)] = true
	tab_load(t, strings.clone(u, context.temp_allocator))
}

// ---------------------------------------------------------------- clear on exit

/// Iris closing with "forget everything" on: the session, the closed tabs
/// and the history go now; cookies, site data and caches when Iris next
/// starts, before any page (nothing of them is in use then)
clear_on_exit :: proc() {
	if !settings().clearOnExit do return
	closed_clear()
	history_clear()
	privacy_forget()
	s := settings()
	clear(&s.session)
	settings_save()
}

/// at start, before any network session: what sites kept last time goes
clear_on_start :: proc() {
	if !settings().clearOnExit do return
	// WPE's sessions (web/) and CEF's profiles (cef/), on disk and in the cache
	for base in ([?]string{data_dir(), cache_dir()}) do for sub in ([?]string{"web", "cef"}) do os.remove_all(join({base, sub}, context.temp_allocator))
	history_clear()
	privacy_forget()
}

// ---------------------------------------------------------------- tests

@(test) test_https_upgrade :: proc(t: ^testing.T) {
	testing.expect_value(t, https_upgrade_url("http://example.com/a?b#c"), "https://example.com/a?b#c")
	testing.expect_value(t, https_upgrade_url("HTTP://Example.com"), "https://Example.com")
	testing.expect_value(t, https_upgrade_url("http://example.com:80/x"), "https://example.com/x")
	// never: a port of its own, your network, a bare address, a single name
	testing.expect_value(t, https_upgrade_url("http://example.com:8080/"), "")
	testing.expect_value(t, https_upgrade_url("http://192.168.1.1/"), "")
	testing.expect_value(t, https_upgrade_url("http://2130706433/"), "")
	testing.expect_value(t, https_upgrade_url("http://router/"), "")
	testing.expect_value(t, https_upgrade_url("http://printer.local/"), "")
	testing.expect_value(t, https_upgrade_url("http://localhost:3000/"), "")
	testing.expect_value(t, https_upgrade_url("http://[::1]/"), "")
	testing.expect_value(t, https_upgrade_url("http://user:pw@example.com/"), "")
	testing.expect_value(t, https_upgrade_url("https://example.com/"), "")
	testing.expect_value(t, https_upgrade_url("ftp://example.com/"), "")
}

@(test) test_clamp_insert :: proc(t: ^testing.T) {
	// three pinned tabs of five: a plain tab never goes among them
	testing.expect_value(t, clamp_insert(1, false, 3, 5), 3)
	testing.expect_value(t, clamp_insert(5, false, 3, 5), 5)
	testing.expect_value(t, clamp_insert(4, true, 3, 5), 3)
	testing.expect_value(t, clamp_insert(0, true, 3, 5), 0)
}
