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
import "core:time"

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
}

GOOGLE_HOSTS :: [?]string{"www.google.com", "www.gstatic.com", "ssl.gstatic.com", "fonts.gstatic.com", "encrypted-tbn0.gstatic.com", "lh3.googleusercontent.com"}

/// names looked up before they are needed (a link under the pointer, Google)
warm_dns :: proc(session: ^WebKitNetworkSession, hosts: ..string) {
	for h in hosts do if len(h) > 0 do webkit_network_session_prefetch_dns(session, cstr(h))
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
PALETTE :: [?]string{"#0a84ff", "#ff9f0a", "#30d158", "#ff375f", "#bf5af2", "#64d2ff", "#ffd60a", "#ac8e68"}

containers: [dynamic]Container
@(private="file") containers_loaded: bool
@(private="file") sessions: map[string]^WebKitNetworkSession
/// every new network session (downloads listen to it)
session_made: proc(s: ^WebKitNetworkSession)

@(private="file") new_id :: proc() -> string {
	b: [16]u8
	linux.getrandom(b[:], {})
	return fmt.aprintf("%x", b)
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
	if id == PRIVATE_ID do return {PRIVATE_ID, "Private", "#5e5ce6", "private"}, true
	for k in containers do if k.id == id do return k, true
	return {}, false
}

/// the network session of a container ("" for none): cookies and storage
/// of its own, on disk (private: in memory only)
container_session :: proc(id: string) -> ^WebKitNetworkSession {
	if s, ok := sessions[id]; ok do return s
	s: ^WebKitNetworkSession
	if id == PRIVATE_ID {
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

/// a free name in the Downloads folder ("a.pdf", "a (2).pdf", ...)
unique_download :: proc(name: string) -> string {
	dir := downloads_dir()
	make_dirs(dir)
	clean, _ := strings.replace_all(name, "/", "_", context.temp_allocator)
	base := (clean == "" || clean == "." || clean == "..") ? "download" : clean
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
	uri := g_variant_new_string(cstr(strings.concatenate({"file://", d.path}, context.temp_allocator)))
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
