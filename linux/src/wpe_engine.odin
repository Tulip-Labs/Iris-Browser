// The WPE engine around the pages (IRIS_ENGINE=wpe, see engine_api.odin):
// one web context for every tab (one pool of web processes and caches, with
// memory limits), the sandbox's own context, the containers (a network
// session each), the scripts pages get, and the downloads.
package iris

import "core:os"
import "core:path/filepath"
import "core:strings"

// (not indented: the whole file is this engine's)
when !ENGINE_CEF {

@(private="file") the_pressure: ^WebKitMemoryPressureSettings
@(private="file") the_context: ^WebKitWebContext
@(private="file") sandbox_context_: ^WebKitWebContext

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

@(private="file") sessions: map[string]^WebKitNetworkSession
/// every new network session (downloads listen to it)
session_made: proc(s: ^WebKitNetworkSession)

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

engine_forget_container :: proc(id: string) {
	if s, ok := sessions[id]; ok {
		delete_key(&sessions, id)
		webkit_website_data_manager_clear(webkit_network_session_get_website_data_manager(s), WEBKIT_WEBSITE_DATA_ALL, 0, nil, nil, nil)
		unref(s)
	}
	if !valid_container_id(id) do return
	for base in ([?]string{data_dir(), cache_dir()}) do os.remove_all(join({base, "web", "containers", id}, context.temp_allocator))
}

// ---------------------------------------------------------------- the engine's start

/// WPE has no subprocesses of Iris's own binary
engine_subprocess :: proc() -> (code: int, is_sub: bool) { return 0, false }

engine_start :: proc() -> bool {
	video_environment()
	session_made = downloads_listen
	shields.installed = browser_reapply_shields
	shields_start()
	if p := env("IRIS_TEST_CLOSE_TABS"); len(p) > 0 do close_tabs_on_request(strings.clone(p))
	return true
}

/// for the tests (linux.yml): when the file IRIS_TEST_CLOSE_TABS names
/// appears, every tab but the first closes, as Ctrl+W would close them,
/// and the file goes (so the test knows)
@(private="file") close_tabs_on_request :: proc(path: string) {
	after(250, proc(d: rawptr) {
		path := cast(^string)d
		if os.exists(path^) {
			for len(b.tabs) > 1 do browser_close(b.tabs[len(b.tabs) - 1])
			os.remove(path^)
		}
		close_tabs_on_request(path^)
		free(path)
	}, new_clone(path))
}

engine_stop :: proc() {}

engine_shields_level_changed :: proc() { shields_level_changed() }

engine_shields_ready :: proc() -> bool { return shields_ready() }

// ---------------------------------------------------------------- downloads

Download_Engine :: struct {
	dl: ^WebKitDownload,
}

download_release :: proc(d: ^Download) { unref(d.dl) }

downloads_listen :: proc(s: ^WebKitNetworkSession) {
	on(s, "download-started", rawptr(proc "c" (s: rawptr, dl: ^WebKitDownload, data: rawptr) {
		context = main_context
		download_started(dl)
	}), nil)
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
		download_changed(d)
		return 1
	}), d)
	on(dl, "notify::estimated-progress", rawptr(proc "c" (dl: ^WebKitDownload, spec: rawptr, d: ^Download) {
		context = main_context
		d.progress = webkit_download_get_estimated_progress(d.dl)
		d.received = webkit_download_get_received_data_length(d.dl)
		download_changed(d)
	}), d)
	on(dl, "failed", rawptr(proc "c" (dl: ^WebKitDownload, err: ^GError, d: ^Download) {
		context = main_context
		d.failed = true
		download_changed(d)
	}), d)
	on(dl, "finished", rawptr(proc "c" (dl: ^WebKitDownload, d: ^Download) {
		context = main_context
		if !d.failed {
			d.done = true
			d.progress = 1
		}
		download_changed(d)
	}), d)
	download_changed(d)
}

download_cancel :: proc(d: ^Download) {
	d.cancelled = true
	webkit_download_cancel(d.dl)
}

} // when !ENGINE_CEF
