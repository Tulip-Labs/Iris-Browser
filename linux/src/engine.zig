//! What every page shares: WPE WebKit's web context (one pool of web
//! processes for normal tabs), the containers' network sessions (each a
//! world of cookies and storage of its own), the sandbox for sites Iris does
//! not trust (a web context and a throwaway session of its own), downloads,
//! and the scripts Iris adds to pages.
const std = @import("std");
const core = @import("core.zig");
const store = @import("store.zig");
const ui = @import("ui.zig");
const c = core.c;

// ---------------------------------------------------------------- engine

pub const Engine = struct {
    var pressure_: ?*c.WebKitMemoryPressureSettings = null;
    var context_: ?*c.WebKitWebContext = null;

    /// the computer's memory, in MB
    pub fn memoryMB() u64 {
        const pages = std.c.sysconf(85); // _SC_PHYS_PAGES
        const size = std.c.sysconf(30); // _SC_PAGESIZE
        return if (pages > 0 and size > 0) @as(u64, @intCast(pages)) * @as(u64, @intCast(size)) / (1 << 20) else 8192;
    }

    /// a sixth of the memory for one web process, between 512 MB and 2 GB,
    /// so a heavy page gives memory back early instead of growing (every tab
    /// stays awake: nothing is put to sleep)
    pub fn pressure() *c.WebKitMemoryPressureSettings {
        if (pressure_) |p| return p;
        const p = c.webkit_memory_pressure_settings_new().?;
        c.webkit_memory_pressure_settings_set_memory_limit(p, @intCast(@min(2048, @max(512, memoryMB() / 6))));
        c.webkit_memory_pressure_settings_set_conservative_threshold(p, 0.33);
        c.webkit_memory_pressure_settings_set_strict_threshold(p, 0.5);
        c.webkit_memory_pressure_settings_set_poll_interval(p, 5);
        pressure_ = p;
        return p;
    }

    pub fn context() *c.WebKitWebContext {
        if (context_) |x| return x;
        // the network process too (one for all sessions)
        c.webkit_network_session_set_memory_pressure_settings(pressure());
        const ctx: *c.WebKitWebContext = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_context_get_type(), "memory-pressure-settings", pressure(), @as(?*anyopaque, null))));
        c.webkit_web_context_set_cache_model(ctx, if (memoryMB() <= 8192) c.WEBKIT_CACHE_MODEL_DOCUMENT_BROWSER else c.WEBKIT_CACHE_MODEL_WEB_BROWSER);
        context_ = ctx;
        return ctx;
    }

    /// YouTube asks which video formats play; told VP9 and AV1 do not, it
    /// sends H.264, a fraction of the processor time
    const light_video =
        \\(() => {
        \\  const heavy = /vp0?9|vp8|av01/i;
        \\  for (const MS of [window.MediaSource, window.ManagedMediaSource]) {
        \\    if (MS && MS.isTypeSupported) {
        \\      const ok = MS.isTypeSupported.bind(MS);
        \\      MS.isTypeSupported = t => heavy.test(t) ? false : ok(t);
        \\    }
        \\  }
        \\  const can = HTMLMediaElement.prototype.canPlayType;
        \\  HTMLMediaElement.prototype.canPlayType = function (t) { return heavy.test(t) ? '' : can.call(this, t); };
        \\})();
    ;

    /// Iris's Liquid Glass for Google AI Mode (the same script as Android's)
    pub const ai_glass = @embedFile("aimode.js");

    fn addScript(ucm: *c.WebKitUserContentManager, source: [*:0]const u8, frames: c.WebKitUserContentInjectedFrames, hosts: []const [*:0]const u8) void {
        var list: [8]?[*:0]const u8 = .{null} ** 8;
        for (hosts, 0..) |h, i| list[i] = h;
        const script = c.webkit_user_script_new(source, frames, c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, @ptrCast(&list), null) orelse return;
        c.webkit_user_content_manager_add_script(ucm, script);
        c.webkit_user_script_unref(script);
    }

    pub fn addScripts(ucm: *c.WebKitUserContentManager) void {
        addScript(ucm, ai_glass, c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, &.{ "https://www.google.com/*", "https://google.com/*" });
        if (store.SettingsStore.get().lightVideo)
            addScript(ucm, light_video, c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, &.{ "https://*.youtube.com/*", "https://youtube.com/*", "https://*.youtube-nocookie.com/*" });
    }

    /// names looked up before they are needed
    pub fn warm(session: *c.WebKitNetworkSession, hosts: []const []const u8) void {
        for (hosts) |h| {
            if (h.len == 0) continue;
            const z = core.z(h);
            defer core.gpa.free(z);
            c.webkit_network_session_prefetch_dns(session, z.ptr);
        }
    }

    pub const google_hosts = [_][]const u8{ "www.google.com", "www.gstatic.com", "ssl.gstatic.com", "fonts.gstatic.com", "encrypted-tbn0.gstatic.com", "lh3.googleusercontent.com" };

    /// hardware video decoding off unless chosen: GStreamer's decoders on
    /// the graphics chip are ranked out (before GStreamer starts)
    pub fn videoEnvironment() void {
        if (store.SettingsStore.get().hardwareVideo) return;
        const off = "vah264dec:NONE,vah265dec:NONE,vavp8dec:NONE,vavp9dec:NONE,vaav1dec:NONE,vampeg2dec:NONE,vaapih264dec:NONE,vaapih265dec:NONE,vaapivp8dec:NONE,vaapivp9dec:NONE,vaapiav1dec:NONE,nvh264dec:NONE,nvh265dec:NONE,nvvp9dec:NONE,nvav1dec:NONE,v4l2slh264dec:NONE,v4l2slh265dec:NONE,v4l2slvp9dec:NONE,v4l2slav1dec:NONE";
        const have = c.g_getenv("GST_PLUGIN_FEATURE_RANK");
        if (have != null and core.str(have).len > 0) {
            const all = core.fmtZ("{s},{s}", .{ core.str(have), off });
            defer core.gpa.free(all);
            _ = c.g_setenv("GST_PLUGIN_FEATURE_RANK", all.ptr, 1);
        } else _ = c.g_setenv("GST_PLUGIN_FEATURE_RANK", off, 1);
    }
};

// ---------------------------------------------------------------- sandbox

/// The sandbox, for sites Iris does not trust (search.untrusted, or a
/// certificate that fails). Nothing is asked: such a site simply opens here.
/// - Its own web context: web processes of its own, never shared with your
///   other tabs, each in WebKit's bubblewrap sandbox (and Flatpak's).
/// - Its own network session per tab, in memory only: no cookie, storage,
///   cache or sign-in of yours, and nothing it sets survives the tab.
/// - Less to attack: no WebGL, WebRTC, camera, microphone, location,
///   notifications, clipboard, pop-ups or downloads.
pub const Sandbox = struct {
    var context_: ?*c.WebKitWebContext = null;

    pub fn context() *c.WebKitWebContext {
        if (context_) |x| return x;
        const ctx: *c.WebKitWebContext = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_context_get_type(), "memory-pressure-settings", Engine.pressure(), @as(?*anyopaque, null))));
        c.webkit_web_context_set_cache_model(ctx, c.WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER);
        context_ = ctx;
        return ctx;
    }

    /// a fresh world for one sandboxed tab, gone with it
    pub fn session() *c.WebKitNetworkSession {
        const s = c.webkit_network_session_new_ephemeral().?;
        const cookies = c.webkit_network_session_get_cookie_manager(s);
        c.webkit_cookie_manager_set_accept_policy(cookies, c.WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY);
        c.webkit_network_session_set_itp_enabled(s, 1);
        return s;
    }

    pub fn settings() *c.WebKitSettings {
        const s = c.webkit_settings_new().?;
        c.webkit_settings_set_enable_developer_extras(s, 0);
        c.webkit_settings_set_javascript_can_open_windows_automatically(s, 0);
        c.webkit_settings_set_javascript_can_access_clipboard(s, 0);
        c.webkit_settings_set_enable_webgl(s, 0);
        c.webkit_settings_set_enable_webrtc(s, 0);
        c.webkit_settings_set_enable_media_stream(s, 0);
        c.webkit_settings_set_enable_encrypted_media(s, 0);
        c.webkit_settings_set_allow_file_access_from_file_urls(s, 0);
        c.webkit_settings_set_allow_universal_access_from_file_urls(s, 0);
        c.webkit_settings_set_enable_smooth_scrolling(s, 1);
        return s;
    }
};

/// a normal tab's settings: calls and meetings (WebRTC, camera, microphone,
/// screen sharing through the desktop's portals), media, developer tools
pub fn normalSettings() *c.WebKitSettings {
    const s = c.webkit_settings_new().?;
    c.webkit_settings_set_enable_developer_extras(s, 1);
    c.webkit_settings_set_javascript_can_open_windows_automatically(s, 0);
    c.webkit_settings_set_enable_smooth_scrolling(s, 1);
    c.webkit_settings_set_media_playback_requires_user_gesture(s, 0);
    c.webkit_settings_set_enable_webrtc(s, 1);
    c.webkit_settings_set_enable_media_stream(s, 1);
    c.webkit_settings_set_enable_encrypted_media(s, 1);
    c.webkit_settings_set_enable_media(s, 1);
    c.webkit_settings_set_enable_mediasource(s, 1);
    c.webkit_settings_set_enable_media_capabilities(s, 1);
    return s;
}

// ---------------------------------------------------------------- containers

/// A container is a world of its own: its own cookies, storage, cache,
/// sign-ins and site data, in a network session of its own on disk. Private
/// tabs share one session that lives in memory only.
pub const Container = struct {
    id: []const u8,
    name: []const u8,
    color: []const u8,
    /// one of icons (a container from an older Iris has none)
    icon: ?[]const u8 = null,

    pub const private_id = "private";
    pub const icons = [_][]const u8{ "person", "briefcase", "cart", "bank", "home", "heart", "game", "book", "plane", "code", "music", "star" };

    pub fn iconName(k: Container) [:0]const u8 {
        if (std.mem.eql(u8, k.id, private_id)) return "view-conceal-symbolic";
        if (k.icon) |i| for (icons) |n| if (std.mem.eql(u8, n, i)) return core.fmtZ("iris-{s}-symbolic", .{i});
        const n = std.ascii.allocLowerString(core.gpa, k.name) catch return "iris-star-symbolic";
        defer core.gpa.free(n);
        const has = struct {
            fn f(h: []const u8, s: []const u8) bool {
                return std.mem.indexOf(u8, h, s) != null;
            }
        }.f;
        const guess: []const u8 = if (has(n, "work")) "briefcase" else if (has(n, "shop")) "cart" else if (has(n, "bank") or has(n, "money")) "bank" else if (has(n, "person") or has(n, "me")) "person" else if (has(n, "home") or has(n, "family")) "home" else "star";
        return core.fmtZ("iris-{s}-symbolic", .{guess});
    }

    /// the CSS class that gives an icon the container's colour
    pub fn colorClass(k: Container) [*:0]const u8 {
        if (std.mem.eql(u8, k.id, private_id)) return "iris-cp";
        const names = [_][*:0]const u8{ "iris-c0", "iris-c1", "iris-c2", "iris-c3", "iris-c4", "iris-c5", "iris-c6", "iris-c7" };
        for (ui.palette, 0..) |p, i| if (std.mem.eql(u8, p, k.color)) return names[i];
        return names[0];
    }

    pub fn iconWidget(k: Container, size: c_int) core.Widget {
        const name = k.iconName();
        const i = ui.icon(name.ptr, size);
        ui.cls(i, &.{k.colorClass()});
        return i;
    }
};

pub const Containers = struct {
    pub var list: std.ArrayList(Container) = .empty;
    var loaded = false;
    var sessions: std.StringHashMapUnmanaged(*c.WebKitNetworkSession) = .empty;
    /// runs for each new session (downloads listen to it)
    pub var sessionMade: ?*const fn (*c.WebKitNetworkSession) void = null;

    fn uuid() []const u8 {
        const u = c.g_uuid_string_random();
        defer c.g_free(u);
        return core.dupe(core.str(u));
    }

    pub fn ensure() void {
        if (loaded) return;
        loaded = true;
        if (store.loadJSON([]Container, "containers.json")) |l| {
            list.appendSlice(core.gpa, l) catch {};
        } else {
            list.appendSlice(core.gpa, &.{
                .{ .id = uuid(), .name = "Personal", .color = ui.palette[0], .icon = "person" },
                .{ .id = uuid(), .name = "Work", .color = ui.palette[1], .icon = "briefcase" },
                .{ .id = uuid(), .name = "Shopping", .color = ui.palette[3], .icon = "cart" },
                .{ .id = uuid(), .name = "Banking", .color = ui.palette[2], .icon = "bank" },
            }) catch {};
            save();
        }
    }

    fn save() void {
        store.saveJSON("containers.json", list.items);
    }

    pub fn get(id: ?[]const u8) ?Container {
        ensure();
        const i = id orelse return null;
        if (std.mem.eql(u8, i, Container.private_id)) return .{ .id = Container.private_id, .name = "Private", .color = "#5e5ce6" };
        for (list.items) |k| if (std.mem.eql(u8, k.id, i)) return k;
        return null;
    }

    /// the session of a container (null: the default world)
    pub fn session(id: ?[]const u8) *c.WebKitNetworkSession {
        const key = id orelse "";
        if (sessions.get(key)) |s| return s;
        var s: *c.WebKitNetworkSession = undefined;
        if (id != null and std.mem.eql(u8, id.?, Container.private_id)) {
            s = c.webkit_network_session_new_ephemeral().?;
        } else {
            const sub = if (id) |i| core.fmt("containers/{s}", .{i}) else core.dupe("default");
            defer core.gpa.free(sub);
            const data = core.fmtZ("{s}/web/{s}", .{ store.Paths.data(), sub });
            const cache = core.fmtZ("{s}/web/{s}", .{ store.Paths.cache(), sub });
            defer core.gpa.free(cache);
            _ = c.g_mkdir_with_parents(data.ptr, 0o755);
            s = c.webkit_network_session_new(data.ptr, cache.ptr).?;
            const cookies = c.webkit_network_session_get_cookie_manager(s);
            const db = core.fmtZ("{s}/cookies.sqlite", .{data});
            defer core.gpa.free(db);
            c.webkit_cookie_manager_set_persistent_storage(cookies, db.ptr, c.WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
            core.gpa.free(data);
        }
        const cookies = c.webkit_network_session_get_cookie_manager(s);
        // no cookies for sites other than the one you are on
        c.webkit_cookie_manager_set_accept_policy(cookies, c.WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY);
        c.webkit_network_session_set_itp_enabled(s, 1);
        c.webkit_website_data_manager_set_favicons_enabled(c.webkit_network_session_get_website_data_manager(s), 1);
        sessions.put(core.gpa, core.dupe(key), s) catch {};
        if (sessionMade) |f| f(s);
        return s;
    }

    /// the private session ends with the last private tab
    pub fn endPrivate() void {
        if (sessions.fetchRemove(Container.private_id)) |kv| core.unref(kv.value);
    }

    pub fn add(name: []const u8, icon: ?[]const u8) Container {
        ensure();
        var color: []const u8 = ui.palette[list.items.len % ui.palette.len];
        outer: for (ui.palette) |p| {
            for (list.items) |k| if (std.mem.eql(u8, k.color, p)) continue :outer;
            color = p;
            break;
        }
        const k = Container{ .id = uuid(), .name = core.dupe(name), .color = color, .icon = if (icon) |i| core.dupe(i) else null };
        list.append(core.gpa, k) catch {};
        save();
        return k;
    }

    pub fn rename(id: []const u8, name: []const u8) void {
        for (list.items) |*k| if (std.mem.eql(u8, k.id, id)) {
            k.name = core.dupe(name);
        };
        save();
    }

    /// removes a container and everything its sites kept
    pub fn remove(id: []const u8) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i].id, id)) _ = list.orderedRemove(i) else i += 1;
        }
        save();
        if (sessions.fetchRemove(id)) |kv| {
            c.webkit_website_data_manager_clear(c.webkit_network_session_get_website_data_manager(kv.value), c.WEBKIT_WEBSITE_DATA_ALL, 0, null, null, null);
            core.unref(kv.value);
        }
        for ([_][]const u8{ store.Paths.data(), store.Paths.cache() }) |base| {
            const p = core.fmt("{s}/web/containers/{s}", .{ base, id });
            defer core.gpa.free(p);
            std.fs.cwd().deleteTree(p) catch {};
        }
    }
};

// ---------------------------------------------------------------- downloads

/// Downloads go to your Downloads folder under the name the site gives
/// (with " (2)" and on when that name is taken).
pub const Download = struct {
    dl: *c.WebKitDownload,
    name: core.Text = .{},
    path: core.Text = .{},
    progress: f64 = 0,
    received: u64 = 0,
    done: bool = false,
    failed: bool = false,
    cancelled: bool = false,
    started: i64,

    pub fn status(d: *Download) []u8 {
        if (d.failed) return core.dupe(if (d.cancelled) "Cancelled" else "Failed");
        if (d.done) return size(d.received);
        const total: f64 = if (d.progress > 0.001) @as(f64, @floatFromInt(d.received)) / d.progress else 0;
        if (total > 0) {
            const a = size(d.received);
            defer core.gpa.free(a);
            const b = size(@intFromFloat(total));
            defer core.gpa.free(b);
            return core.fmt("{s} of {s}", .{ a, b });
        }
        return size(d.received);
    }

    fn size(b: u64) []u8 {
        const s = c.g_format_size(b);
        defer c.g_free(s);
        return core.dupe(core.str(s));
    }

    pub fn cancel(d: *Download) void {
        d.cancelled = true;
        c.webkit_download_cancel(d.dl);
    }
};

pub const Downloads = struct {
    pub var list: std.ArrayList(*Download) = .empty;
    /// runs whenever a download starts, moves or ends
    pub var changed: std.ArrayList(Hook) = .empty;

    pub const Hook = struct { ctx: *anyopaque, f: *const fn (*anyopaque, ?*Download) void };

    pub fn listen(session: *c.WebKitNetworkSession) void {
        _ = core.on1(session, "download-started", &list, startedCB);
    }

    fn startedCB(_: *std.ArrayList(*Download), d: ?*anyopaque) void {
        if (d) |dl| started(core.cast(*c.WebKitDownload, dl));
    }

    fn notify(d: ?*Download) void {
        for (changed.items) |h| h.f(h.ctx, d);
    }

    pub fn active() usize {
        var n: usize = 0;
        for (list.items) |d| if (!d.done and !d.failed) {
            n += 1;
        };
        return n;
    }

    fn taken(p: []const u8) bool {
        const z = core.z(p);
        defer core.gpa.free(z);
        if (c.g_file_test(z.ptr, c.G_FILE_TEST_EXISTS) != 0) return true;
        for (list.items) |d| if (std.mem.eql(u8, d.path.get(), p) and !d.failed) return true;
        return false;
    }

    pub fn unique(name: []const u8) []u8 {
        const dir = store.Paths.downloads();
        const dz = core.z(dir);
        defer core.gpa.free(dz);
        _ = c.g_mkdir_with_parents(dz.ptr, 0o755);
        const clean = core.dupe(name);
        defer core.gpa.free(clean);
        std.mem.replaceScalar(u8, clean, '/', '_');
        const base: []const u8 = if (clean.len == 0 or std.mem.eql(u8, clean, ".") or std.mem.eql(u8, clean, "..")) "download" else clean;
        const ext = std.fs.path.extension(base);
        const stem = base[0 .. base.len - ext.len];
        var p = core.fmt("{s}/{s}", .{ dir, base });
        var n: usize = 2;
        while (taken(p)) : (n += 1) {
            core.gpa.free(p);
            p = core.fmt("{s}/{s} ({d}){s}", .{ dir, stem, n, ext });
        }
        return p;
    }

    fn started(dl: *c.WebKitDownload) void {
        const d = core.gpa.create(Download) catch return;
        d.* = .{ .dl = core.ref(dl), .started = std.time.timestamp() };
        list.insert(core.gpa, 0, d) catch {};
        _ = core.onBool1(dl, "decide-destination", d, decide);
        _ = core.on1(dl, "created-destination", d, created);
        _ = core.on1(dl, "notify::estimated-progress", d, progressed);
        _ = core.on1(dl, "failed", d, failedCB);
        _ = core.on(dl, "finished", d, finished);
        notify(d);
    }

    fn decide(d: *Download, name: ?*anyopaque) bool {
        const suggested = if (name) |n| core.str(core.cast([*:0]const u8, n)) else "download";
        const p = unique(if (suggested.len > 0) suggested else "download");
        defer core.gpa.free(p);
        d.path.set(p);
        d.name.set(std.fs.path.basename(p));
        const z = core.z(p);
        defer core.gpa.free(z);
        c.webkit_download_set_destination(d.dl, z.ptr);
        notify(d);
        return true;
    }

    fn created(d: *Download, dest: ?*anyopaque) void {
        const p = core.str(core.cast([*:0]const u8, dest orelse return));
        d.path.set(p);
        d.name.set(std.fs.path.basename(p));
        notify(d);
    }

    fn progressed(d: *Download, _: ?*anyopaque) void {
        d.progress = c.webkit_download_get_estimated_progress(d.dl);
        d.received = c.webkit_download_get_received_data_length(d.dl);
        notify(d);
    }

    fn failedCB(d: *Download, _: ?*anyopaque) void {
        d.failed = true;
        notify(d);
    }

    fn finished(d: *Download) void {
        if (!d.failed) {
            d.done = true;
            d.progress = 1;
        }
        d.received = c.webkit_download_get_received_data_length(d.dl);
        notify(d);
    }

    pub fn clearFinished() void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].done or list.items[i].failed) _ = list.orderedRemove(i) else i += 1;
        }
        notify(null);
    }

    fn launch(d: *Download, window: ?*c.GtkWindow, folder: bool) void {
        const z = core.z(d.path.get());
        defer core.gpa.free(z);
        const f = c.g_file_new_for_path(z.ptr);
        defer core.unref(f);
        const l = c.gtk_file_launcher_new(f);
        defer core.unref(l);
        if (folder) c.gtk_file_launcher_open_containing_folder(l, window, null, null, null) else c.gtk_file_launcher_launch(l, window, null, null, null);
    }

    /// opens the file with the program meant for it
    pub fn open(d: *Download, window: ?*c.GtkWindow) void {
        launch(d, window, false);
    }

    pub fn showInFolder(d: *Download, window: ?*c.GtkWindow) void {
        launch(d, window, true);
    }
};
