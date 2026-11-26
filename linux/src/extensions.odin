// Mozilla Add-ons (addons.mozilla.org, .xpi) for the CEF engine, the only
// extension store Iris supports (no Chrome Web Store, no .crx).
//
// This file is the installer and the notices:
//  - an add-on page of Mozilla's gets "Add to Iris": the latest .xpi comes
//    from AMO's public API, checked against the SHA-256 the API gives, and
//    the Rust core (core/src/xpi.rs) unpacks it Zip-Slip safe and reads its
//    manifest.json (Manifest V2 or V3) into the registry
//  - a Chrome Web Store page gets Iris's notice, with a button to the same
//    extension's search on Mozilla's site
//
// What is not here yet: running the add-ons (background pages, content
// scripts, the browser.* bridge). Until it is, this stays behind
// IRIS_EXTENSIONS=1, so nobody is told an add-on works that does not.
package iris

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"


extensions_enabled :: proc() -> bool {
	return env("IRIS_EXTENSIONS") == "1"
}

ext_dir :: proc() -> string {
	return join({data_dir(), "extensions"}, context.temp_allocator)
}

/// what the registry keeps of an installed add-on (the core's summary,
/// the parts Iris reads again)
Ext :: struct {
	id:               string,
	dir:              string,
	name:             string,
	version:          string,
	manifest_version: int,
	enabled:          bool,
}

@(private="file") registry_path :: proc() -> string {
	return join({data_dir(), "extensions.json"}, context.temp_allocator)
}

extensions_list :: proc(allocator := context.temp_allocator) -> []Ext {
	data, ok := read_file(registry_path(), context.temp_allocator)
	if !ok do return nil
	list: [dynamic]Ext
	list.allocator = allocator
	if json.unmarshal(data, &list, allocator = allocator) != nil do return nil
	return list[:]
}

@(private="file") registry_save :: proc(list: []Ext) -> bool {
	data, err := json.marshal(list, {pretty = true}, context.temp_allocator)
	if err != nil do return false
	return write_file(registry_path(), data)
}

/// an add-on into the registry (a newer version of the same id replaces it)
@(private="file") registry_add :: proc(e: Ext) -> bool {
	old := extensions_list(context.temp_allocator)
	out := make([dynamic]Ext, context.temp_allocator)
	for x in old do if x.id != e.id do append(&out, x)
	append(&out, e)
	return registry_save(out[:])
}

/// removes an add-on: its files and its registry entry
extension_remove :: proc(id: string) -> bool {
	old := extensions_list(context.temp_allocator)
	out := make([dynamic]Ext, context.temp_allocator)
	dir := ""
	for x in old do if x.id == id { dir = x.dir } else { append(&out, x) }
	if len(dir) == 0 do return false
	iris_xpi_uninstall(strings.clone_to_cstring(ext_dir(), context.temp_allocator), strings.clone_to_cstring(dir, context.temp_allocator))
	return registry_save(out[:])
}

// ---------------------------------------------------------------- what a page is

/// the tabs a notice was shown for, with the address: once per page
@(private="file") last_notice: map[int]string

/// a page committed in a tab: a Chrome Web Store page gets the notice, a
/// Mozilla add-on page the install button
extensions_page_seen :: proc(t: ^Tab, u: string) {
	if !extensions_enabled() || !strings.has_prefix(u, "https://") do return
	if last_notice[t.id] == u do return
	// cheap first: only these hosts ever need the core
	h, _ := host_of(u, context.temp_allocator)
	if h != "addons.mozilla.org" && h != "chromewebstore.google.com" && h != "chrome.google.com" do return
	c := classify_fields(core_url_classify(u))
	switch c.kind {
	case "amo":
		set_notice(t.id, u)
		chrome_toast("Add this add-on to Iris?", "Add to Iris", fmt.tprintf("iris-install:%s", c.slug), life_ms = 12000)
	case "cws":
		set_notice(t.id, u)
		chrome_toast("Iris champions open web freedom and supports Mozilla Add-ons (.xpi) instead of proprietary Chrome Web Store extensions.", "Open Mozilla Add-ons", c.search, life_ms = 20000)
	}
}

@(private="file") set_notice :: proc(id: int, u: string) {
	if old, ok := last_notice[id]; ok do delete(old)
	last_notice[id] = strings.clone(u)
}

Classified :: struct {
	kind:   string,
	slug:   string,
	api:    string,
	name:   string,
	search: string,
}

classify_fields :: proc(j: string) -> (c: Classified) {
	if len(j) == 0 do return
	json.unmarshal(transmute([]u8)j, &c, allocator = context.temp_allocator)
	return
}

/// the toast's button: "iris-install:<slug>" installs from Mozilla
extensions_toast_action :: proc(url: string) -> bool {
	slug, ok := strings.substring_from(url, len("iris-install:"))
	if !strings.has_prefix(url, "iris-install:") || !ok do return false
	if !amo_slug_ok(slug) do return true
	extension_install_amo(slug)
	return true
}

@(private="file") amo_slug_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 100 || s[0] == '.' || strings.contains(s, "..") do return false
	for c in transmute([]u8)s do if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '-' && c != '_' && c != '.' && c != '~' do return false
	return true
}

// ---------------------------------------------------------------- the install

Amo_File :: struct {
	url:  string,
	hash: string,
}

Amo_Version :: struct {
	file: Amo_File,
}

Amo_Addon :: struct {
	guid:            string,
	slug:            string,
	current_version: Amo_Version,
}

@(private="file") MAX_XPI :: 64 << 20

@(private="file") Get :: struct {
	then:  proc(data: []u8, d: rawptr),
	fail:  proc(d: rawptr),
	data:  rawptr,
	msg:   ^SoupMessage,
	limit: uint,
}

@(private="file") ext_session: ^SoupSession

/// GET an address; `then` gets the body, `fail` is called otherwise (both on the main thread)
@(private="file") http_get :: proc(url: string, limit: uint, then: proc(data: []u8, d: rawptr), fail: proc(d: rawptr), d: rawptr) {
	if ext_session == nil do ext_session = soup_session_new()
	msg := soup_message_new("GET", strings.clone_to_cstring(url, context.temp_allocator))
	if msg == nil {
		fail(d)
		return
	}
	soup_message_headers_append(soup_message_get_request_headers(msg), "User-Agent", USER_AGENT)
	g := new(Get)
	g^ = {then, fail, d, msg, limit}
	soup_session_send_and_read_async(ext_session, msg, 300, nil, rawptr(proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
		context = main_context
		g := cast(^Get)d
		defer {
			unref(g.msg)
			free(g)
		}
		err: ^GError
		b := soup_session_send_and_read_finish(cast(^SoupSession)o, res, &err)
		if err != nil do g_error_free(err)
		if b == nil || soup_message_get_status(g.msg) != 200 {
			if b != nil do g_bytes_unref(b)
			g.fail(g.data)
			return
		}
		defer g_bytes_unref(b)
		n: uint
		p := g_bytes_get_data(b, &n)
		if p == nil || n > g.limit {
			g.fail(g.data)
			return
		}
		g.then(([^]u8)(p)[:n], g.data)
	}), g)
}

@(private="file") Install :: struct {
	slug: string,
	hash: string,
}

@(private="file") install_failed :: proc(d: rawptr) {
	i := cast(^Install)d
	browser_toast("Iris could not get this add-on from Mozilla")
	delete(i.slug)
	delete(i.hash)
	free(i)
}

/// the latest .xpi of an add-on of addons.mozilla.org, by its slug
extension_install_amo :: proc(slug: string) {
	i := new(Install)
	i.slug = strings.clone(slug)
	browser_toast("Adding the add-on from Mozilla...")
	http_get(fmt.tprintf("https://addons.mozilla.org/api/v5/addons/addon/%s/", slug), 4 << 20, proc(data: []u8, d: rawptr) {
		i := cast(^Install)d
		a: Amo_Addon
		if json.unmarshal(data, &a, allocator = context.temp_allocator) != nil {
			install_failed(d)
			return
		}
		f := a.current_version.file
		// only Mozilla's own hosts, over https, and only with the checksum
		// the API gave (it is what the download is checked against)
		if !(strings.has_prefix(f.url, "https://addons.mozilla.org/") || strings.has_prefix(f.url, "https://addons.cdn.mozilla.net/")) || !strings.has_prefix(f.hash, "sha256:") {
			install_failed(d)
			return
		}
		i.hash = strings.clone(f.hash)
		http_get(f.url, MAX_XPI, proc(data: []u8, d: rawptr) {
			i := cast(^Install)d
			defer {
				delete(i.slug)
				delete(i.hash)
				free(i)
			}
			summary, code := core_xpi_install(data, ext_dir(), i.hash)
			if code != 0 {
				browser_toast(ext_error_text(code))
				return
			}
			e: Ext
			if json.unmarshal(transmute([]u8)summary, &e, allocator = context.temp_allocator) != nil || !registry_add({e.id, e.dir, e.name, e.version, e.manifest_version, true}) {
				browser_toast("Iris could not keep the add-on's details")
				return
			}
			log.infof("add-on %s %s installed", e.id, e.version)
			browser_toast(fmt.tprintf("%s %s is added", len(e.name) > 0 ? e.name : e.id, e.version))
		}, install_failed, d)
	}, install_failed, i)
}

ext_error_text :: proc(code: i32) -> string {
	switch code {
	case -1: return "The add-on's checksum is not Mozilla's: nothing was added"
	case -2: return "That file is not an add-on"
	case -3: return "The add-on is too big"
	case -4: return "The add-on has paths outside its folder: nothing was added"
	case -5, -6: return "The add-on's manifest.json is missing or broken"
	}
	return "Iris could not save the add-on"
}

@(test) test_amo_slug :: proc(t: ^testing.T) {
	testing.expect(t, amo_slug_ok("ublock-origin"))
	testing.expect(t, amo_slug_ok("a_b.c~d"))
	testing.expect(t, !amo_slug_ok(""))
	testing.expect(t, !amo_slug_ok("../x"))
	testing.expect(t, !amo_slug_ok("a/b"))
	testing.expect(t, !amo_slug_ok(".hidden"))
	testing.expect(t, !amo_slug_ok("a b"))
}


@(test) test_xpi_install_and_registry :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/iris-ext-test-%d", os.get_pid())
	defer os.remove_all(dir)
	os.set_env("XDG_DATA_HOME", dir)
	defer os.unset_env("XDG_DATA_HOME")
	// (data_dir is read once: this test only needs ext_dir's own arguments)
	dest := fmt.tprintf("%s/ext", dir)
	xpi := #load("testdata/test.xpi")
	summary, code := core_xpi_install(xpi, dest, "")
	testing.expect_value(t, code, 0)
	e: Ext
	testing.expect(t, json.unmarshal(transmute([]u8)summary, &e, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, e.id, "test@iris.example")
	testing.expect_value(t, e.name, "Test Add-on")
	testing.expect_value(t, e.manifest_version, 3)
	testing.expect(t, os.exists(fmt.tprintf("%s/test@iris.example/c.js", dest)))
	// a wrong checksum is refused, a non-add-on too
	_, code = core_xpi_install(xpi, dest, "sha256:0000000000000000000000000000000000000000000000000000000000000000")
	testing.expect_value(t, code, -1)
	_, code = core_xpi_install(transmute([]u8)string("not a zip"), dest, "")
	testing.expect_value(t, code, -2)
	// the page classifier, through the core
	c := classify_fields(core_url_classify("https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/"))
	testing.expect_value(t, c.kind, "amo")
	testing.expect_value(t, c.slug, "ublock-origin")
	c = classify_fields(core_url_classify("https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh"))
	testing.expect_value(t, c.kind, "cws")
	testing.expect(t, strings.contains(c.search, "addons.mozilla.org") && strings.contains(c.search, "dark%20reader"))
}

