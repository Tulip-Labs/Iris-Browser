// New versions: Iris asks GitHub once a day and says when there is one. It
// never installs anything itself. Iris (Chromium) has releases of its own
// (cef-vX.Y.Z) and points to the new bundle.
package iris

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"

// Iris (Chromium) ships on its own tags, cef-vX.Y.Z, marked never latest
// (Android ships on vX.Y.Z and reads the latest release), so it reads the
// list and takes its newest cef-v* one.
RELEASES_LIST :: "https://api.github.com/repos/Tulip-Labs/Iris-Browser/releases?per_page=20"
RELEASES_PAGE :: "https://github.com/Tulip-Labs/Iris-Browser/releases"
CEF_TAG_PREFIX :: "cef-v"
CEF_BUNDLE :: "Iris-Cef-x86_64.flatpak"

/// a is newer than b ("2.10" > "2.9.9")
version_newer :: proc(a, b: string) -> bool {
	pa := strings.split(a, ".", context.temp_allocator)
	pb := strings.split(b, ".", context.temp_allocator)
	for i in 0 ..< max(len(pa), len(pb)) {
		x := i < len(pa) ? strconv.parse_int(pa[i]) or_else 0 : 0
		y := i < len(pb) ? strconv.parse_int(pb[i]) or_else 0 : 0
		if x != y do return x > y
	}
	return false
}

Gh_Release_Asset :: struct {
	name:                 string,
	browser_download_url: string,
}

Gh_Release :: struct {
	tag_name: string,
	html_url: string,
	draft:    bool,
	prerelease: bool, // (CEF engine agent) a test build: never offered
	assets:   []Gh_Release_Asset,
}

/// The release this build updates to, from GitHub's answer (temp memory):
/// the newest non-draft, non-pre-release cef-v* release in the list, with
/// the link to its Iris-Cef-x86_64.flatpak when it has one. ok is false
/// when there is none.
release_pick :: proc(data: []u8) -> (version, link: string, ok: bool) {
	{
		list: []Gh_Release
		if json.unmarshal(data, &list, allocator = context.temp_allocator) != nil do return
		best: ^Gh_Release
		best_v: string
		for &r in list {
			if r.draft || r.prerelease || !strings.has_prefix(r.tag_name, CEF_TAG_PREFIX) do continue
			v := strings.trim_prefix(r.tag_name, CEF_TAG_PREFIX)
			if len(v) == 0 do continue
			if best == nil || version_newer(v, best_v) {
				best, best_v = &r, v
			}
		}
		if best == nil do return
		link = len(best.html_url) > 0 ? best.html_url : RELEASES_PAGE
		for a in best.assets {
			if a.name == CEF_BUNDLE && len(a.browser_download_url) > 0 do link = a.browser_download_url
		}
		return best_v, link, true
	}
}

@(private="file") update_session: ^SoupSession
@(private="file") release_page: string

updates_check :: proc() {
	s := settings()
	now := now_s()
	// a check dated in the future (the clock was wrong once) would stop
	// every check until that day came: it counts as never made
	if s.lastUpdateCheck > now do s.lastUpdateCheck = 0
	if now - s.lastUpdateCheck < 86400 do return
	s.lastUpdateCheck = now
	settings_save()
	if update_session == nil do update_session = soup_session_new()
	msg := soup_message_new("GET", RELEASES_LIST)
	if msg == nil do return
	h := soup_message_get_request_headers(msg)
	soup_message_headers_append(h, "Accept", "application/vnd.github+json")
	soup_message_headers_append(h, "User-Agent", USER_AGENT)
	soup_session_send_and_read_async(update_session, msg, 300, nil, rawptr(proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
		context = main_context
		msg := cast(^SoupMessage)d
		defer unref(msg)
		bytes := soup_session_send_and_read_finish(cast(^SoupSession)o, res, nil)
		if bytes == nil do return
		defer g_bytes_unref(bytes)
		if soup_message_get_status(msg) != 200 do return
		n: uint
		p := g_bytes_get_data(bytes, &n)
		if p == nil do return
		v, link, ok := release_pick(([^]u8)(p)[:n])
		if !ok || !version_newer(v, BUILD_VERSION) do return
		delete(release_page)
		release_page = strings.clone(link)
		// a bundle, not a repository: the new one is downloaded and installed over it
		chrome_toast(fmt.tprintf("Iris (Chromium) %s is out. Install the new %s over this one.", v, CEF_BUNDLE), "Download", release_page, life_ms = 10000)
	}), msg)
}

@(test)
test_release_pick :: proc(t: ^testing.T) {
	list := `[
		{"tag_name": "cef-v2.5.0", "draft": true, "html_url": "https://x/draft"},
		{"tag_name": "cef-v2.6.0", "prerelease": true, "html_url": "https://x/pre"},
		{"tag_name": "v2.4.1", "draft": false, "html_url": "https://x/v2.4.1"},
		{"tag_name": "cef-v2.4.10", "draft": false, "html_url": "https://x/cef-v2.4.10",
		 "assets": [{"name": "SHA256SUMS", "browser_download_url": "https://x/sums"},
		            {"name": "Iris-Cef-x86_64.flatpak", "browser_download_url": "https://x/cef.flatpak"}]},
		{"tag_name": "cef-v2.4.9", "draft": false, "html_url": "https://x/cef-v2.4.9"}
	]`
	v, link, ok := release_pick(transmute([]u8)list)
	testing.expect(t, ok)
	testing.expect_value(t, v, "2.4.10")
	testing.expect_value(t, link, "https://x/cef.flatpak")
	_, _, ok = release_pick(transmute([]u8)string(`[{"tag_name": "v2.4.1"}]`))
	testing.expect(t, !ok)
	// a pre-release only is no update
	_, _, ok = release_pick(transmute([]u8)string(`[{"tag_name": "cef-v9.0.0", "prerelease": true}]`))
	testing.expect(t, !ok)
}
