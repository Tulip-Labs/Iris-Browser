// New versions: Iris asks GitHub once a day and says when there is one. It
// never installs anything itself; the Flatpak updates the way every Flatpak
// does (your software centre, or flatpak update).
//
// And `iris --shield-rules LEVEL DIR OUT`: the content rules a level makes
// from the lists in DIR, for checks.
package iris

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

RELEASES_API :: "https://api.github.com/repos/Tulip-Labs/Iris-Browser/releases/latest"

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
	msg := soup_message_new("GET", RELEASES_API)
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
		Release :: struct {
			tag_name: string,
			html_url: string,
		}
		r: Release
		if json.unmarshal(([^]u8)(p)[:n], &r, allocator = context.temp_allocator) != nil do return
		v := strings.trim_prefix(r.tag_name, "v")
		if len(v) == 0 || !version_newer(v, VERSION) do return
		delete(release_page)
		release_page = strings.clone(len(r.html_url) > 0 ? r.html_url : "https://github.com/Tulip-Labs/Iris-Browser/releases")
		chrome_toast(fmt.tprintf("Iris %s is out. Your software centre or flatpak update installs it.", v), "What's new", release_page, life_ms = 10000)
	}), msg)
}

/// iris --shield-rules LEVEL DIR OUT
shield_rules_cli :: proc(level_name, dir, out: string) -> int {
	l: Level
	switch level_name {
	case "moderate": l = .moderate
	case "aggressive": l = .aggressive
	case "ultra": l = .ultra
	case:
		fmt.eprintln("iris: the level is moderate, aggressive or ultra")
		return 2
	}
	start := time.now()
	c := Converter{level = l}
	lists := 0
	for li in level_lists(l) {
		text, err := os.read_entire_file_from_path(fmt.tprintf("%s/%s.txt", dir, list_id(li)), context.allocator)
		if err != nil do continue
		converter_add_list(&c, string(text), list_generic_ok(li))
		lists += 1
	}
	// as Iris itself does: its own domains until the lists come, and at ultra
	if lists == 0 || l == .ultra do converter_add_domains(&c, shield_domains())
	blocks, hides, exceptions := len(c.blocks), len(c.hides), len(c.exceptions)
	parts := converter_finish(&c, 120_000)
	for p, i in parts {
		if os.write_entire_file_from_string(fmt.tprintf("%s/%s-%d.json", out, level_name, i), p) != nil {
			fmt.eprintln("iris: cannot write to", out)
			return 1
		}
	}
	fmt.printf("%s: %d blocks, %d hiding rules, %d exceptions, %d parts, %.1f s\n", level_name, blocks, hides, exceptions, len(parts), time.duration_seconds(time.since(start)))
	return 0
}
