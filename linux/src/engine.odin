// The engine around the pages: one web context for every tab (one pool of
// web processes and caches, with memory limits), the sandbox's own context,
// the containers (a network session each), the scripts pages get, and the
// downloads.
package iris

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

// ---------------------------------------------------------------- the engine

@(private="file") the_pressure: ^WebKitMemoryPressureSettings
@(private="file") the_context: ^WebKitWebContext
@(private="file") sandbox_context_: ^WebKitWebContext

memory_mb :: proc() -> u64 {
	info: linux.Sys_Info
	if linux.sysinfo(&info) != .NONE do return 8192
	return u64(info.totalram) * u64(max(1, info.mem_unit)) / (1 << 20)
}

/// each web process gives memory back early, and never takes more than
/// a sixth of the computer's
pressure :: proc() -> ^WebKitMemoryPressureSettings {
	if the_pressure != nil do return the_pressure
	p := webkit_memory_pressure_settings_new()
	webkit_memory_pressure_settings_set_memory_limit(p, u32(min(2048, max(512, memory_mb() / 6))))
	webkit_memory_pressure_settings_set_conservative_threshold(p, 0.33)
	webkit_memory_pressure_settings_set_strict_threshold(p, 0.5)
	webkit_memory_pressure_settings_set_poll_interval(p, 5)
	the_pressure = p
	return p
}

web_context :: proc() -> ^WebKitWebContext {
	if the_context != nil do return the_context
	webkit_network_session_set_memory_pressure_settings(pressure())
	ctx := cast(^WebKitWebContext)gnew(webkit_web_context_get_type(), {name = "memory-pressure-settings", value = rawptr(pressure()), type = webkit_memory_pressure_settings_get_type(), boxed = true})
	webkit_web_context_set_cache_model(ctx, WEBKIT_CACHE_MODEL_WEB_BROWSER)
	the_context = ctx
	return ctx
}

LIGHT_VIDEO :: `(() => {
  const heavy = /vp0?9|vp8|av01/i;
  for (const MS of [window.MediaSource, window.ManagedMediaSource]) {
    if (MS && MS.isTypeSupported) {
      const ok = MS.isTypeSupported.bind(MS);
      MS.isTypeSupported = t => heavy.test(t) ? false : ok(t);
    }
  }
  const can = HTMLMediaElement.prototype.canPlayType;
  HTMLMediaElement.prototype.canPlayType = function (t) { return heavy.test(t) ? '' : can.call(this, t); };
})();`

/// Google AI Mode in Iris's glass (the same file as Iris for Android's)
AI_GLASS :: #load("aimode.js", string)
/// YouTube with no ads and nothing for it to notice (the same file as Iris
/// for Android's)
YOUTUBE :: #load("youtube.js", string)

/// a page left unable to scroll by a cookie notice the shield hid (the
/// notice set overflow: hidden on the page, and only its own button undoes
/// it): scrolling comes back when the page is taller than the window and
/// nothing fixed sits over its middle. Web apps that scroll inside
/// themselves are exactly the window's height, and stay as they are.
SCROLL_UNLOCK :: `(() => {
  const fix = () => {
    const x = innerWidth / 2, y = innerHeight / 2;
    for (let n = document.elementFromPoint(x, y); n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
      const p = getComputedStyle(n).position;
      if (p === 'fixed' || p === 'sticky') return;
    }
    for (const e of [document.documentElement, document.body]) {
      if (!e || getComputedStyle(e).overflowY !== 'hidden') continue;
      if (document.documentElement.scrollHeight < innerHeight + 80) continue;
      e.style.setProperty('overflow', 'auto', 'important');
    }
  };
  const later = () => { setTimeout(fix, 1500); setTimeout(fix, 5000); };
  if (document.readyState === 'complete') later(); else addEventListener('load', later, { once: true });
})();`

@(private="file") add_script :: proc(ucm: ^WebKitUserContentManager, source: string, all_frames: bool, hosts: []cstring) {
	list: [8]cstring
	for h, i in hosts[:min(len(hosts), 7)] do list[i] = h
	s := webkit_user_script_new(cstr(source), all_frames ? 0 : WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, 0, &list[0], nil)
	if s == nil do return
	webkit_user_content_manager_add_script(ucm, s)
	webkit_user_script_unref(s)
}

add_page_scripts :: proc(ucm: ^WebKitUserContentManager) {
	google := [?]cstring{"https://www.google.com/*", "https://google.com/*"}
	add_script(ucm, AI_GLASS, false, google[:])
	yt := [?]cstring{"https://*.youtube.com/*", "https://youtube.com/*", "https://*.youtube-nocookie.com/*"}
	add_script(ucm, YOUTUBE, true, yt[:])
	if settings().lightVideo do add_script(ucm, LIGHT_VIDEO, true, yt[:])
	// every other site's top page (Google's and YouTube's lock nothing)
	not_here := [?]cstring{"https://www.google.com/*", "https://*.youtube.com/*", "https://mail.google.com/*", "https://docs.google.com/*", nil}
	if s := webkit_user_script_new(SCROLL_UNLOCK, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END, nil, &not_here[0]); s != nil {
		webkit_user_content_manager_add_script(ucm, s)
		webkit_user_script_unref(s)
	}
}

/// what Google search, AI Mode and YouTube load first: looked up (and the
/// first few connected) before you need them. Only these: nothing else is
/// looked up or loaded ahead.
GOOGLE_HOSTS :: [?]string{
	"www.google.com", "www.gstatic.com", "ssl.gstatic.com", "fonts.gstatic.com", "apis.google.com",
	"encrypted-tbn0.gstatic.com", "lh3.googleusercontent.com", "play.google.com",
	"www.youtube.com", "m.youtube.com", "i.ytimg.com", "yt3.ggpht.com", "redirector.googlevideo.com",
}
/// the hosts worth a whole connection (TCP and TLS) ahead: the page and its
/// first scripts and images
GOOGLE_PRECONNECT :: `(() => {
  for (const h of ['https://www.google.com', 'https://www.gstatic.com', 'https://www.youtube.com', 'https://i.ytimg.com']) {
    const l = document.createElement('link');
    l.rel = 'preconnect';
    l.href = h;
    (document.head || document.documentElement).appendChild(l);
    l.remove();
  }
})();`

/// names looked up before they are needed (a link under the pointer, Google)
warm_dns :: proc(session: ^WebKitNetworkSession, hosts: ..string) {
	for h in hosts do if len(h) > 0 do webkit_network_session_prefetch_dns(session, cstr(h))
}

/// Google and YouTube made ready (their names looked up; from the page you
/// are on, which WebKit lets ask for connections, their first connections
/// opened): when Iris starts, when the address bar takes the keyboard and
/// when you type in it. At most every 20 seconds: WebKit keeps both a while.
warm_for_search :: proc() {
	@(static) last: f64
	now := now_s()
	if now - last < 20 do return
	last = now
	hosts := GOOGLE_HOSTS
	t := b.current
	if t == nil || t.web == nil || t.sandboxed {
		warm_dns(container_session(t != nil && !t.sandboxed ? t.container : ""), ..hosts[:])
		return
	}
	warm_dns(webkit_web_view_get_network_session(t.web), ..hosts[:])
	// <link rel=preconnect> in a world of Iris's own (WebKit has no call for
	// it): a page you opened yourself over HTTPS, never a private tab
	if !tab_is_private(t) && strings.has_prefix(t.url, "https://") {
		webkit_web_view_evaluate_javascript(t.web, GOOGLE_PRECONNECT, -1, "iris", nil, nil, nil, nil)
	}
}

/// video decoding on the graphics chip stays off: some drivers broke the
/// picture into blocks
video_environment :: proc() {
	off := "vah264dec:NONE,vah265dec:NONE,vavp8dec:NONE,vavp9dec:NONE,vaav1dec:NONE,vampeg2dec:NONE,vaapih264dec:NONE,vaapih265dec:NONE,vaapivp8dec:NONE,vaapivp9dec:NONE,vaapiav1dec:NONE,nvh264dec:NONE,nvh265dec:NONE,nvvp9dec:NONE,nvav1dec:NONE,v4l2slh264dec:NONE,v4l2slh265dec:NONE,v4l2slvp9dec:NONE,v4l2slav1dec:NONE"
	have := env("GST_PLUGIN_FEATURE_RANK")
	all := len(have) > 0 ? strings.concatenate({have, ",", off}, context.temp_allocator) : off
	g_setenv("GST_PLUGIN_FEATURE_RANK", cstr(all), 1)
}

// ---------------------------------------------------------------- the sandbox

/// sites Iris does not trust: a web context of their own (their own web
/// processes, in WebKit's process sandbox)
sandbox_context :: proc() -> ^WebKitWebContext {
	if sandbox_context_ != nil do return sandbox_context_
	ctx := cast(^WebKitWebContext)gnew(webkit_web_context_get_type(), {name = "memory-pressure-settings", value = rawptr(pressure()), type = webkit_memory_pressure_settings_get_type(), boxed = true})
	webkit_web_context_set_cache_model(ctx, 0) // document viewer
	sandbox_context_ = ctx
	return ctx
}

/// a world in memory for one sandboxed tab: none of your cookies, storage
/// or sign-ins, gone when the tab closes
sandbox_session :: proc() -> ^WebKitNetworkSession {
	s := webkit_network_session_new_ephemeral()
	webkit_cookie_manager_set_accept_policy(webkit_network_session_get_cookie_manager(s), WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY)
	webkit_network_session_set_itp_enabled(s, 1)
	return s
}

sandbox_settings :: proc() -> ^WebKitSettings {
	s := webkit_settings_new()
	webkit_settings_set_enable_developer_extras(s, 0)
	webkit_settings_set_javascript_can_open_windows_automatically(s, 0)
	webkit_settings_set_javascript_can_access_clipboard(s, 0)
	webkit_settings_set_enable_webgl(s, 0)
	webkit_settings_set_enable_webrtc(s, 0)
	webkit_settings_set_enable_media_stream(s, 0)
	webkit_settings_set_enable_encrypted_media(s, 0)
	webkit_settings_set_allow_file_access_from_file_urls(s, 0)
	webkit_settings_set_allow_universal_access_from_file_urls(s, 0)
	webkit_settings_set_enable_smooth_scrolling(s, 1)
	return s
}

normal_settings :: proc() -> ^WebKitSettings {
	s := webkit_settings_new()
	webkit_settings_set_enable_developer_extras(s, 1)
	webkit_settings_set_javascript_can_open_windows_automatically(s, 0)
	webkit_settings_set_enable_smooth_scrolling(s, 1)
	webkit_settings_set_media_playback_requires_user_gesture(s, 0)
	webkit_settings_set_enable_webrtc(s, 1)
	webkit_settings_set_enable_media_stream(s, 1)
	webkit_settings_set_enable_encrypted_media(s, 1)
	webkit_settings_set_enable_media(s, 1)
	webkit_settings_set_enable_mediasource(s, 1)
	webkit_settings_set_enable_media_capabilities(s, 1)
	return s
}

// ---------------------------------------------------------------- containers

Container :: struct {
	id:    string,
	name:  string,
	color: string,
	icon:  string,
}

PRIVATE_ID :: "private"
CONTAINER_ICONS :: [?]string{"person", "briefcase", "cart", "bank", "home", "heart", "game", "book", "plane", "code", "music", "star"}
PALETTE :: [?]string{"#0a84ff", "#ff9f0a", "#30d158", "#ff375f", "#8e8e93", "#64d2ff", "#ffd60a", "#ac8e68"}

containers: [dynamic]Container
@(private="file") containers_loaded: bool
@(private="file") sessions: map[string]^WebKitNetworkSession
/// every new network session (downloads listen to it)
session_made: proc(s: ^WebKitNetworkSession)

new_id :: proc() -> string {
	b: [16]u8
	linux.getrandom(b[:], {})
	// 32 hex digits ("%x" on the array wrote "[1f, a, ...]")
	sb := strings.builder_make()
	for x in b do fmt.sbprintf(&sb, "%02x", x)
	return strings.to_string(sb)
}

containers_ensure :: proc() {
	if containers_loaded do return
	containers_loaded = true
	if l, ok := load_json([dynamic]Container, "containers.json"); ok {
		containers = l
		return
	}
	p := PALETTE
	append(&containers,
		Container{new_id(), "Personal", p[0], "person"},
		Container{new_id(), "Work", p[1], "briefcase"},
		Container{new_id(), "Shopping", p[3], "cart"},
		Container{new_id(), "Banking", p[2], "bank"},
	)
	containers_save()
}

@(private="file") containers_save :: proc() {
	save_json("containers.json", containers[:])
}

container_get :: proc(id: string) -> (Container, bool) {
	containers_ensure()
	if id == "" do return {}, false
	if id == PRIVATE_ID do return {PRIVATE_ID, "Private", "#636366", "private"}, true
	for k in containers do if k.id == id do return k, true
	return {}, false
}

/// a container's id as Iris makes them (hex; before 2.2.4 the bytes were
/// written as a list, "[1f, a, ...]"): anything else in containers.json
/// never names a folder
valid_container_id :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 128 do return false
	for c in transmute([]u8)id {
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c == '[' || c == ']' || c == ',' || c == ' '
		if !ok do return false
	}
	return true
}

/// the network session of a container ("" for none): cookies and storage
/// of its own, on disk (private: in memory only)
container_session :: proc(id: string) -> ^WebKitNetworkSession {
	if s, ok := sessions[id]; ok do return s
	s: ^WebKitNetworkSession
	if id == PRIVATE_ID || (id != "" && !valid_container_id(id)) {
		s = webkit_network_session_new_ephemeral()
	} else {
		sub := id == "" ? "default" : strings.concatenate({"containers/", id}, context.temp_allocator)
		data := join({data_dir(), "web", sub}, context.temp_allocator)
		cache := join({cache_dir(), "web", sub}, context.temp_allocator)
		make_dirs(data)
		s = webkit_network_session_new(cstr(data), cstr(cache))
		webkit_cookie_manager_set_persistent_storage(webkit_network_session_get_cookie_manager(s), cstr(join({data, "cookies.sqlite"}, context.temp_allocator)), 1)
	}
	webkit_cookie_manager_set_accept_policy(webkit_network_session_get_cookie_manager(s), WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY)
	webkit_network_session_set_itp_enabled(s, 1)
	webkit_website_data_manager_set_favicons_enabled(webkit_network_session_get_website_data_manager(s), 1)
	sessions[strings.clone(id)] = s
	if session_made != nil do session_made(s)
	return s
}

/// the last private tab closed: its world goes
end_private :: proc() {
	if s, ok := sessions[PRIVATE_ID]; ok {
		delete_key(&sessions, PRIVATE_ID)
		unref(s)
	}
}

container_add :: proc(name, icon: string) -> Container {
	containers_ensure()
	p := PALETTE
	color := p[len(containers) % len(p)]
	outer: for c in p {
		for k in containers do if k.color == c do continue outer
		color = c
		break
	}
	k := Container{new_id(), strings.clone(name), color, strings.clone(icon)}
	append(&containers, k)
	containers_save()
	return k
}

/// a container and everything its sites kept, gone
container_remove :: proc(id: string) {
	for i := 0; i < len(containers); {
		if containers[i].id == id { ordered_remove(&containers, i) } else { i += 1 }
	}
	containers_save()
	if s, ok := sessions[id]; ok {
		delete_key(&sessions, id)
		webkit_website_data_manager_clear(webkit_network_session_get_website_data_manager(s), WEBKIT_WEBSITE_DATA_ALL, 0, nil, nil, nil)
		unref(s)
	}
	if !valid_container_id(id) do return
	for base in ([?]string{data_dir(), cache_dir()}) do os.remove_all(join({base, "web", "containers", id}, context.temp_allocator))
}

// ---------------------------------------------------------------- downloads

Download :: struct {
	dl:        ^WebKitDownload,
	id:        int,
	name:      string,
	path:      string,
	progress:  f64,
	received:  u64,
	done:      bool,
	failed:    bool,
	cancelled: bool,
}

downloads: [dynamic]^Download
/// a download started, moved on or ended
downloads_changed: proc(d: ^Download)
@(private="file") next_download := 1

download_status :: proc(d: ^Download) -> string {
	if d.failed do return d.cancelled ? "Cancelled" : "Failed"
	if d.done do return format_size(d.received)
	if d.progress > 0.001 {
		return fmt.tprintf("%s of %s", format_size(d.received), format_size(u64(f64(d.received) / d.progress)))
	}
	return format_size(d.received)
}

format_size :: proc(b: u64) -> string {
	switch {
	case b < 1000: return fmt.tprintf("%d bytes", b)
	case b < 1000_000: return fmt.tprintf("%.1f kB", f64(b) / 1e3)
	case b < 1000_000_000: return fmt.tprintf("%.1f MB", f64(b) / 1e6)
	}
	return fmt.tprintf("%.1f GB", f64(b) / 1e9)
}

downloads_active :: proc() -> int {
	n := 0
	for d in downloads do if !d.done && !d.failed do n += 1
	return n
}

downloads_listen :: proc(s: ^WebKitNetworkSession) {
	on(s, "download-started", rawptr(proc "c" (s: rawptr, dl: ^WebKitDownload, data: rawptr) {
		context = main_context
		download_started(dl)
	}), nil)
}

@(private="file") taken :: proc(p: string) -> bool {
	if os.exists(p) do return true
	for d in downloads do if d.path == p && !d.failed do return true
	return false
}

/// the name a site suggests, made safe for the Downloads folder: no folders,
/// no control characters, not hidden, and short enough for the file system
/// (255 bytes), its extension kept
download_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in name {
		switch {
		case r == '/' || r == '\\': strings.write_byte(&b, '_')
		case r < 0x20 || r == 0x7f || r == 0xfffd: strings.write_byte(&b, '_')
		case: strings.write_rune(&b, r)
		}
	}
	clean := strings.trim(strings.to_string(b), " .")
	if clean == "" do return strings.clone("download", allocator)
	MAX :: 200 // room left for " (99)"
	if len(clean) > MAX {
		ext := filepath.ext(clean)
		if len(ext) > 16 do ext = ""
		keep := MAX - len(ext)
		// never cut a character in half
		for keep > 0 && (clean[keep] & 0xc0) == 0x80 do keep -= 1
		clean = strings.concatenate({clean[:keep], ext}, context.temp_allocator)
	}
	return strings.clone(clean, allocator)
}

/// a free name in the Downloads folder ("a.pdf", "a (2).pdf", ...)
unique_download :: proc(name: string) -> string {
	dir := downloads_dir()
	make_dirs(dir)
	base := download_name(name)
	ext := filepath.ext(base)
	stem := base[:len(base) - len(ext)]
	p := join({dir, base})
	for n := 2; taken(p); n += 1 {
		delete(p)
		p = join({dir, fmt.tprintf("%s (%d)%s", stem, n, ext)})
	}
	return p
}

@(private="file") download_started :: proc(dl: ^WebKitDownload) {
	d := new(Download)
	d^ = {dl = cast(^WebKitDownload)g_object_ref(dl), id = next_download}
	next_download += 1
	inject_at(&downloads, 0, d)
	on(dl, "decide-destination", rawptr(proc "c" (dl: ^WebKitDownload, name: cstring, d: ^Download) -> gboolean {
		context = main_context
		suggested := string(name)
		p := unique_download(len(suggested) > 0 ? suggested : "download")
		d.path = p
		d.name = filepath.base(p)
		webkit_download_set_destination(d.dl, cstr(p))
		changed(d)
		return 1
	}), d)
	on(dl, "notify::estimated-progress", rawptr(proc "c" (dl: ^WebKitDownload, spec: rawptr, d: ^Download) {
		context = main_context
		d.progress = webkit_download_get_estimated_progress(d.dl)
		d.received = webkit_download_get_received_data_length(d.dl)
		changed(d)
	}), d)
	on(dl, "failed", rawptr(proc "c" (dl: ^WebKitDownload, err: ^GError, d: ^Download) {
		context = main_context
		d.failed = true
		changed(d)
	}), d)
	on(dl, "finished", rawptr(proc "c" (dl: ^WebKitDownload, d: ^Download) {
		context = main_context
		if !d.failed {
			d.done = true
			d.progress = 1
		}
		changed(d)
	}), d)
	changed(d)
}

@(private="file") changed :: proc(d: ^Download) {
	if downloads_changed != nil do downloads_changed(d)
}

download_cancel :: proc(d: ^Download) {
	d.cancelled = true
	webkit_download_cancel(d.dl)
}

downloads_clear_finished :: proc() {
	for i := 0; i < len(downloads); {
		d := downloads[i]
		if d.done || d.failed {
			ordered_remove(&downloads, i)
			unref(d.dl)
			free(d)
		} else {
			i += 1
		}
	}
}

/// opens a finished download with its app (xdg-open; the portal in Flatpak)
download_open :: proc(d: ^Download) {
	spawn({"xdg-open", d.path})
}

/// shows a download in the file manager
download_show :: proc(d: ^Download) {
	bus := g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)
	if bus == nil {
		spawn({"xdg-open", filepath.dir(d.path)})
		return
	}
	uri := g_variant_new_string(cstr(file_uri(d.path, context.temp_allocator)))
	t := g_variant_type_new("s")
	arr := g_variant_new_array(t, &uri, 1)
	g_variant_type_free(t)
	args := [2]^GVariant{arr, g_variant_new_string("")}
	g_dbus_connection_call(bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems", g_variant_new_tuple(&args[0], 2), nil, 0, -1, nil, nil, nil)
}

/// starts a program on its own (GLib reaps it)
spawn :: proc(argv: []string) {
	a := make([]cstring, len(argv) + 1, context.temp_allocator)
	for s, i in argv do a[i] = cstr(s)
	err: ^GError
	g_spawn_async(nil, &a[0], nil, 1 << 2, nil, nil, nil, &err) // SEARCH_PATH
	if err != nil do g_error_free(err)
}

@(private="file") _t :: time.Duration

// ---------------------------------------------------------------- tests

@(test) test_download_names :: proc(t: ^testing.T) {
	testing.expect_value(t, download_name("report.pdf"), "report.pdf")
	testing.expect_value(t, download_name("../../.bashrc"), "_.._.bashrc")
	testing.expect_value(t, download_name(".hidden"), "hidden")
	testing.expect_value(t, download_name("a\nb\x00c.txt"), "a_b_c.txt")
	testing.expect_value(t, download_name("dir\\file.zip"), "dir_file.zip")
	testing.expect_value(t, download_name(""), "download")
	testing.expect_value(t, download_name(" .. "), "download")
	long := strings.repeat("ñ", 150, context.temp_allocator) // 300 bytes
	n := download_name(strings.concatenate({long, ".tar.gz"}, context.temp_allocator))
	testing.expect(t, len(n) <= 200)
	testing.expect(t, strings.has_suffix(n, ".gz"))
	testing.expect(t, utf8.valid_string(n))
}

@(test) test_container_ids :: proc(t: ^testing.T) {
	id := new_id()
	defer delete(id)
	testing.expect_value(t, len(id), 32)
	testing.expect(t, valid_container_id(id))
	testing.expect(t, valid_container_id("[1, 2, 3, fa, 5, 6, 7, 8, 9, a, b, c, d, e, f, 10]"))
	testing.expect(t, !valid_container_id("../../.."))
	testing.expect(t, !valid_container_id("a/b"))
	testing.expect(t, !valid_container_id(""))
}
