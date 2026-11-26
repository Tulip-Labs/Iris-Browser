// Brave's adblock-rust in the CEF engine (core/, core_ffi.odin): network
// rules, $redirect surrogates, $removeparam, cosmetic filters and
// scriptlets, from the same lists shields.odin keeps fresh (uBlock Origin's
// and EasyList's) plus scriptlet resources fetched every four days. Built on
// a thread with the matcher (shields.odin), cached in a file that later
// starts only read, swapped in whole; until it is there, the matcher
// (shield_match.odin) answers as before.
package iris

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"
import "core:strings"
import "core:time"


@(private="file") the_engine: ^Adblock

/// the engine in use (any thread; replaced whole, never changed)
cef_adblock :: proc "contextless" () -> ^Adblock {
	return intrinsics.atomic_load(&the_engine)
}

/// a new engine takes over; the old one goes a minute later (a request on
/// the IO thread may still be asking it)
cef_adblock_install :: proc(e: ^Adblock) {
	if e == nil do return
	old := intrinsics.atomic_exchange(&the_engine, e)
	if old != nil do after(60_000, proc(d: rawptr) { iris_adblock_destroy(cast(^Adblock)d) }, old)
}

/// where Brave's scriptlets and redirect resources are (adblock-rust's JSON)
RESOURCES_URL :: "https://raw.githubusercontent.com/brave/adblock-resources/master/dist/resources.json"

adblock_resources_path :: proc() -> string {
	return fmt.tprintf("%s/adblock-resources.json", shields.dir)
}

@(private="file") adblock_cache_path :: proc(l: Level) -> string {
	return fmt.tprintf("%s/adblock-%v.bin", shields.dir, l)
}

/// what an engine is made from: the matcher's key (lists, converter),
/// the resources' file, and the core's version
adblock_key :: proc(base: string, allocator := context.temp_allocator) -> string {
	res := "-"
	if fi, err := os.stat(adblock_resources_path(), context.temp_allocator); err == nil {
		res = fmt.tprintf("%d:%d", fi.size, time.to_unix_nanoseconds(fi.modification_time))
	}
	return fmt.aprintf("%s res:%s core:%s", base, res, iris_core_version(), allocator = allocator)
}

/// an engine from the list files (any thread; the lists are the caller's
/// paths), with the resources when there are some; nil if no list reads
adblock_build :: proc(paths: []string) -> ^Adblock {
	b := iris_adblock_builder_create()
	if b == nil do return nil
	defer iris_adblock_builder_destroy(b)
	any := false
	for p in paths {
		t, ok := read_file(p)
		if !ok do continue
		defer delete(t)
		if len(t) > 0 && iris_adblock_builder_add_list(b, raw_data(t), uint(len(t))) do any = true
	}
	if !any do return nil
	if r, ok := read_file(adblock_resources_path()); ok {
		defer delete(r)
		if !iris_adblock_builder_set_resources(b, raw_data(r), uint(len(r))) {
			log.warn("adblock: the scriptlet resources did not parse; scriptlets are off")
		}
	}
	return iris_adblock_build(b)
}

/// the engine in its cache file, for the next start (key on the first line)
adblock_cache_save :: proc(e: ^Adblock, l: Level, key: string) {
	if e == nil do return
	n: uint
	p := iris_adblock_serialize(e, &n)
	if p == nil do return
	defer iris_bytes_free(p, n)
	data := make([]u8, len(key) + 1 + int(n))
	defer delete(data)
	copy(data, key)
	data[len(key)] = '\n'
	copy(data[len(key) + 1:], ([^]u8)(p)[:n])
	write_file(adblock_cache_path(l), data)
}

/// the cached engine, when it was made from these lists, resources and core
adblock_cache_load :: proc(l: Level, key: string) -> ^Adblock {
	data, ok := read_file(adblock_cache_path(l))
	if !ok do return nil
	defer delete(data)
	nl := -1
	for c, i in data do if c == '\n' { nl = i; break }
	if nl < 0 || string(data[:nl]) != key do return nil
	body := data[nl + 1:]
	if len(body) == 0 do return nil
	return iris_adblock_deserialize(raw_data(body), uint(len(body)))
}

/// the request types as adblock-rust names them
adblock_type_of :: proc "contextless" (rt: i32) -> cstring {
	switch rt {
	case RT_MAIN_FRAME, RT_NAVIGATION_PRELOAD_MAIN_FRAME: return "document"
	case RT_SUB_FRAME, RT_NAVIGATION_PRELOAD_SUB_FRAME: return "subdocument"
	case RT_STYLESHEET: return "stylesheet"
	case RT_SCRIPT, RT_WORKER, RT_SHARED_WORKER, RT_SERVICE_WORKER: return "script"
	case RT_IMAGE, RT_FAVICON: return "image"
	case RT_FONT_RESOURCE: return "font"
	case RT_MEDIA: return "media"
	case RT_OBJECT, RT_PLUGIN_RESOURCE: return "object"
	case RT_XHR: return "xhr"
	case RT_PING, RT_CSP_REPORT: return "ping"
	}
	return "other"
}

// ---------------------------------------------------------------- the resources, every four days

@(private="file") res_session: ^SoupSession

/// the scriptlets and surrogates (resources.json): fetched when older
/// than four days; a new file makes the engine again
adblock_resources_refresh :: proc() {
	if fi, err := os.stat(adblock_resources_path(), context.temp_allocator); err == nil && time.diff(fi.modification_time, time.now()) < 4 * 24 * time.Hour do return
	if res_session == nil do res_session = soup_session_new()
	msg := soup_message_new("GET", RESOURCES_URL)
	if msg == nil do return
	soup_message_headers_append(soup_message_get_request_headers(msg), "User-Agent", USER_AGENT)
	soup_session_send_and_read_async(res_session, msg, 300, nil, rawptr(proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
		context = main_context
		msg := cast(^SoupMessage)d
		defer unref(msg)
		b := soup_session_send_and_read_finish(cast(^SoupSession)o, res, nil)
		if b == nil do return
		defer g_bytes_unref(b)
		n: uint
		p := g_bytes_get_data(b, &n)
		// a real file: a JSON array of resources
		if soup_message_get_status(msg) != 200 || p == nil || n < 1000 || n > 64 << 20 || ([^]u8)(p)[0] != '[' do return
		if write_file(adblock_resources_path(), ([^]u8)(p)[:n]) {
			shields.stale = true
			shields.failed = {}
			shields_settle()
		}
	}), msg)
}


@(test) test_adblock_engine :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/iris-adblock-test-%d", os.get_pid())
	defer os.remove_all(dir)
	list := fmt.tprintf("%s/list.txt", dir)
	write_file(list, transmute([]u8)string("||ads.example.com^\n@@||ads.example.com/ok.js^\n||shop.example^$removeparam=trk\nexample.org##.promo\n"))
	e := adblock_build([]string{list})
	testing.expect(t, e != nil)
	if e == nil do return
	defer iris_adblock_destroy(e)
	a, _ := core_adblock_check(e, "https://ads.example.com/a.js", "https://site.org/", "script")
	testing.expect_value(t, a, u32(CORE_BLOCK))
	a, _ = core_adblock_check(e, "https://ads.example.com/ok.js", "https://site.org/", "script")
	testing.expect_value(t, a, u32(CORE_ALLOW))
	p: string
	a, p = core_adblock_check(e, "https://shop.example/p?id=1&trk=2", "https://shop.example/", "document")
	testing.expect_value(t, a, u32(CORE_REWRITE))
	testing.expect_value(t, p, "https://shop.example/p?id=1")
	css, _, _ := core_adblock_cosmetic(e, "https://example.org/x")
	testing.expect(t, strings.contains(css, ".promo"))
	// the cache file: same key reads, another does not
	shields.dir = dir
	adblock_cache_save(e, .moderate, "k1")
	e2 := adblock_cache_load(.moderate, "k1")
	testing.expect(t, e2 != nil)
	if e2 != nil {
		a, _ = core_adblock_check(e2, "https://ads.example.com/a.js", "https://site.org/", "script")
		testing.expect_value(t, a, u32(CORE_BLOCK))
		iris_adblock_destroy(e2)
	}
	testing.expect(t, adblock_cache_load(.moderate, "k2") == nil)
	testing.expect(t, adblock_build([]string{"/nonexistent/list"}) == nil)
}

