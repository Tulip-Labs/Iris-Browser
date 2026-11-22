//! One tab: its page (a WPE WebKit web view shown by an IrisPage widget,
//! made when the tab first opens something) and its pill in the tab strip.
//! Every tab stays awake in the background until you close it: WPE runs each
//! page in its own web process, so a busy page never holds up the window.
const std = @import("std");
const core = @import("core.zig");
const ui = @import("ui.zig");
const search = @import("search.zig");
const store = @import("store.zig");
const engine = @import("engine.zig");
const shields = @import("shields.zig");
const webview = @import("webview.zig");
const stage = @import("stage.zig");
const Browser = @import("browser.zig").Browser;
const c = core.c;
const Widget = core.Widget;

pub const Tab = struct {
    browser: *Browser,
    container: ?[]const u8,
    url: core.Text = .{},
    title: core.Text = .{},
    progress: f64 = 0,
    loading: bool = false,
    canBack: bool = false,
    canForward: bool = false,
    zoom: f64 = 1,
    /// an address to open when the tab is first selected (tabs restored
    /// from the last session wait until you go to them)
    pending: ?[]u8 = null,

    web: ?*c.WebKitWebView = null,
    ucm: ?*c.WebKitUserContentManager = null,
    page: ?*webview.Page = null,
    item: ?*stage.Item = null,
    /// in the sandbox: a site Iris does not trust
    sandboxed: bool = false,
    sandboxSession: ?*c.WebKitNetworkSession = null,
    /// hosts whose failing certificate the sandbox let through, once each
    allowedCerts: std.StringHashMapUnmanaged(void) = .empty,

    // the pill
    pill: Widget,
    pillLabel: Widget,
    favicon: Widget,
    close: Widget,
    pillItem: *stage.Item = undefined,

    pub fn create(b: *Browser, container: ?[]const u8) *Tab {
        const t = core.gpa.create(Tab) catch @panic("oom");
        const pill = ui.box(false, 7);
        ui.cls(pill, &.{"iris-tab"});
        const private = if (container) |k| std.mem.eql(u8, k, engine.Container.private_id) else false;
        const fav = ui.icon(if (private) "security-high-symbolic" else "web-browser-symbolic", 16);
        ui.cls(fav, &.{"iris-dim"});
        const lbl = ui.label("New Tab", &.{});
        ui.ellipsize(lbl, 4);
        c.gtk_widget_set_hexpand(lbl, 1);
        t.* = .{ .browser = b, .container = if (container) |k| core.dupe(k) else null, .pill = pill, .pillLabel = lbl, .favicon = fav, .close = undefined };
        const x = ui.button("window-close-symbolic", "Close tab", t, closeClicked);
        ui.cls(x, &.{"small"});
        c.gtk_widget_set_size_request(x, 24, 24);
        t.close = x;
        ui.append(pill, fav);
        if (engine.Containers.get(container)) |k| ui.append(pill, k.iconWidget(14));
        ui.append(pill, lbl);
        ui.append(pill, x);
        c.gtk_widget_set_tooltip_text(pill, "New Tab");
        return t;
    }

    fn closeClicked(t: *Tab) void {
        t.browser.close(t);
    }

    pub fn isPrivate(t: *Tab) bool {
        return if (t.container) |k| std.mem.eql(u8, k, engine.Container.private_id) else false;
    }

    // ---------------------------------------------------------------- the page

    /// the page, made on first use
    pub fn ensureWeb(t: *Tab, related: ?*c.WebKitWebView) *c.WebKitWebView {
        if (t.web) |w| return w;
        const ucm = c.webkit_user_content_manager_new().?;
        t.ucm = ucm;
        engine.Engine.addScripts(ucm);
        const settings = if (t.sandboxed) engine.Sandbox.settings() else engine.normalSettings();
        defer core.unref(settings);
        const display = webview.display();
        var w: *c.WebKitWebView = undefined;
        if (related) |r| {
            // a pop-up the page asked for: same world, and it may talk to the
            // page that opened it
            w = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_view_get_type(), "display", display, "user-content-manager", ucm, "settings", settings, "related-view", r, @as(?*anyopaque, null))));
        } else if (t.sandboxed) {
            // the sandbox: web processes of its own, and a world in memory for this tab alone
            const ss = engine.Sandbox.session();
            t.sandboxSession = ss;
            w = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_view_get_type(), "display", display, "user-content-manager", ucm, "settings", settings, "network-session", ss, "web-context", engine.Sandbox.context(), @as(?*anyopaque, null))));
        } else {
            w = @ptrCast(@alignCast(c.g_object_new(c.webkit_web_view_get_type(), "display", display, "user-content-manager", ucm, "settings", settings, "network-session", engine.Containers.session(t.container), "web-context", engine.Engine.context(), @as(?*anyopaque, null))));
        }
        _ = c.g_object_ref_sink(w);
        t.web = w;
        shields.Shields.shared().apply(ucm, null);
        t.connect(w);
        t.page = webview.Page.create(w);
        t.markSandbox();
        t.browser.attachPage(t);
        return w;
    }

    /// a sandboxed tab looks it: its pill says so
    fn markSandbox(t: *Tab) void {
        ui.setCls(t.pill, "iris-sandboxed", t.sandboxed);
        c.gtk_image_set_from_icon_name(@ptrCast(t.favicon), if (t.sandboxed) "security-low-symbolic" else if (t.isPrivate()) "security-high-symbolic" else "web-browser-symbolic");
    }

    /// the tab's page made again, in or out of the sandbox
    fn remake(t: *Tab, sandboxed: bool) void {
        t.browser.detachPage(t);
        t.destroy();
        t.sandboxed = sandboxed;
        t.allowedCerts.clearRetainingCapacity();
    }

    pub fn load(t: *Tab, u: []const u8) void {
        if (u.len == 0) return;
        // a site Iris does not trust opens in the sandbox, and a trusted one leaves it
        const want = search.untrusted(u);
        if (t.web == null) t.sandboxed = want else if (want != t.sandboxed) t.remake(want);
        const w = t.ensureWeb(null);
        t.url.set(u);
        const h = search.host(u);
        defer if (h) |x| core.gpa.free(x);
        shields.Shields.shared().apply(t.ucm.?, h);
        const z = core.z(u);
        defer core.gpa.free(z);
        c.webkit_web_view_load_uri(w, z.ptr);
        t.browser.tabChanged(t);
    }

    // ---------------------------------------------------------------- signals

    fn connect(t: *Tab, w: *c.WebKitWebView) void {
        _ = core.on1(w, "notify::uri", t, uriChanged);
        _ = core.on1(w, "notify::title", t, titleChanged);
        _ = core.on1(w, "notify::estimated-load-progress", t, progressChanged);
        _ = core.on1(w, "notify::is-loading", t, loadingChanged);
        core.setData(w, "iris-tab", t);
        _ = core.on1(w, "load-changed", t, loadChanged);
        _ = core.onBoolPtrUInt(w, "decide-policy", t, decide);
        _ = c.g_signal_connect_data(w, "create", @ptrCast(&createCB), t, null, 0);
        _ = c.g_signal_connect_data(w, "load-failed-with-tls-errors", @ptrCast(&tlsCB), t, null, 0);
        _ = core.on(w, "ready-to-show", t, readyToShow);
        _ = core.on(w, "close", t, closeAsked);
        _ = core.onBool2(w, "context-menu", t, contextMenu);
        _ = core.on2(w, "mouse-target-changed", t, mouseTarget);
        _ = core.onBool1(w, "permission-request", t, permission);
        _ = core.onBool0(w, "enter-fullscreen", t, enterFullscreen);
        _ = core.onBool0(w, "leave-fullscreen", t, leaveFullscreen);
        _ = core.onBool1(w, "web-process-terminated", t, crashed);
        _ = core.onBool2(w, "show-option-menu", t, optionMenu);
        _ = core.onBool1(w, "script-dialog", t, scriptDialog);
        _ = core.onBool1(w, "run-file-chooser", t, fileChooser);
    }

    fn uriChanged(t: *Tab, _: ?*anyopaque) void {
        const w = t.web orelse return;
        t.url.set(core.str(c.webkit_web_view_get_uri(w)));
        t.browser.tabChanged(t);
    }

    fn titleChanged(t: *Tab, _: ?*anyopaque) void {
        const w = t.web orelse return;
        t.title.set(core.str(c.webkit_web_view_get_title(w)));
        if (!t.isPrivate()) store.History.title(t.url.get(), t.title.get());
        t.browser.tabChanged(t);
    }

    fn progressChanged(t: *Tab, _: ?*anyopaque) void {
        const w = t.web orelse return;
        t.progress = c.webkit_web_view_get_estimated_load_progress(w);
        t.browser.progressChanged(t);
    }

    fn loadingChanged(t: *Tab, _: ?*anyopaque) void {
        const w = t.web orelse return;
        t.loading = c.webkit_web_view_is_loading(w) != 0;
        t.browser.tabChanged(t);
        t.browser.progressChanged(t);
    }

    fn loadChanged(t: *Tab, ev: ?*anyopaque) void {
        const w = t.web orelse return;
        const e: u32 = @truncate(@intFromPtr(ev));
        t.canBack = c.webkit_web_view_can_go_back(w) != 0;
        t.canForward = c.webkit_web_view_can_go_forward(w) != 0;
        if (e == c.WEBKIT_LOAD_COMMITTED and !t.isPrivate()) store.History.record(t.url.get(), t.title.get());
        if (e == c.WEBKIT_LOAD_FINISHED) t.faviconChanged(null);
        t.browser.tabChanged(t);
    }

    /// the site's icon: WPE keeps them in the session's favicon database,
    /// as a list of sizes (premultiplied BGRA); the one nearest 32 px wins
    fn faviconChanged(t: *Tab, _: ?*anyopaque) void {
        const w = t.web orelse return;
        const s = c.webkit_web_view_get_network_session(w) orelse return;
        const db = c.webkit_website_data_manager_get_favicon_database(c.webkit_network_session_get_website_data_manager(s)) orelse return;
        const u = c.webkit_web_view_get_uri(w) orelse return;
        c.webkit_favicon_database_get_page_icons(db, u, null, iconsCB, core.ref(w));
    }

    fn iconsCB(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
        const w: *c.WebKitWebView = core.cast(*c.WebKitWebView, d);
        defer core.unref(w);
        const list = c.webkit_favicon_database_get_page_icons_finish(@ptrCast(o), res, null) orelse return;
        defer c.webkit_image_list_unref(list);
        const t = core.getData(*Tab, w, "iris-tab") orelse return;
        if (t.web != w) return;
        var best: ?*c.WebKitImage = null;
        var gap: c_int = std.math.maxInt(c_int);
        var i: usize = 0;
        while (i < c.webkit_image_list_get_length(list)) : (i += 1) {
            const img = c.webkit_image_list_get(list, i) orelse continue;
            const g: c_int = @intCast(@abs(c.webkit_image_get_width(img) - 32));
            if (g < gap) {
                gap = g;
                best = img;
            }
        }
        const img = best orelse return;
        const bytes = c.webkit_image_as_bytes(img) orelse return;
        defer c.g_bytes_unref(bytes);
        const tex = c.gdk_memory_texture_new(c.webkit_image_get_width(img), c.webkit_image_get_height(img), c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, c.webkit_image_get_stride(img));
        defer core.unref(tex);
        c.gtk_image_set_from_paintable(@ptrCast(t.favicon), @ptrCast(tex));
        c.gtk_widget_remove_css_class(t.favicon, "iris-dim");
        t.browser.stage.dirtyChrome();
    }

    fn createCB(_: ?*c.WebKitWebView, action: ?*c.WebKitNavigationAction, d: ?*anyopaque) callconv(.c) ?*c.WebKitWebView {
        const t: *Tab = core.cast(*Tab, d);
        return t.browser.popup(t, action);
    }

    fn tlsCB(_: ?*c.WebKitWebView, uri: [*c]const u8, cert: ?*c.GTlsCertificate, _: c.GTlsCertificateFlags, d: ?*anyopaque) callconv(.c) c.gboolean {
        const t: *Tab = core.cast(*Tab, d);
        if (uri == null or cert == null) return 0;
        return @intFromBool(t.certificateFailed(core.str(uri), cert.?));
    }

    fn readyToShow(t: *Tab) void {
        t.browser.select(t);
    }

    fn closeAsked(t: *Tab) void {
        t.browser.close(t);
    }

    fn contextMenu(t: *Tab, menu: ?*anyopaque, hit: ?*anyopaque) bool {
        if (menu == null or hit == null) return false;
        t.browser.contextMenu(t, core.cast(*c.WebKitContextMenu, menu), core.cast(*c.WebKitHitTestResult, hit));
        return true;
    }

    fn mouseTarget(t: *Tab, hit: ?*anyopaque, _: ?*anyopaque) void {
        const h = core.cast(*c.WebKitHitTestResult, hit orelse return);
        const link: ?[]const u8 = if (c.webkit_hit_test_result_context_is_link(h) != 0) core.str(c.webkit_hit_test_result_get_link_uri(h)) else null;
        t.browser.hoverLink(t, link);
    }

    fn permission(t: *Tab, req: ?*anyopaque) bool {
        t.browser.permission(t, core.cast(*c.WebKitPermissionRequest, req orelse return false));
        return true;
    }

    fn enterFullscreen(t: *Tab) bool {
        t.browser.pageFullscreen(true);
        return false;
    }

    fn leaveFullscreen(t: *Tab) bool {
        t.browser.pageFullscreen(false);
        return false;
    }

    fn crashed(t: *Tab, _: ?*anyopaque) bool {
        t.browser.toastAction("This page stopped working.", "Reload", t, reloadCB);
        return false;
    }

    fn reloadCB(t: *Tab) void {
        t.reload();
    }

    fn optionMenu(t: *Tab, menu: ?*anyopaque, rect: ?*anyopaque) bool {
        t.browser.optionMenu(t, core.cast(*c.WebKitOptionMenu, menu orelse return false), core.cast(?*c.WebKitRectangle, rect));
        return true;
    }

    fn scriptDialog(t: *Tab, dialog: ?*anyopaque) bool {
        t.browser.scriptDialog(t, core.cast(*c.WebKitScriptDialog, dialog orelse return false));
        return true;
    }

    fn fileChooser(t: *Tab, req: ?*anyopaque) bool {
        t.browser.fileChooser(t, core.cast(*c.WebKitFileChooserRequest, req orelse return false));
        return true;
    }

    // ---------------------------------------------------------------- the sandbox's certificates

    const CertJob = struct { t: *Tab, uri: []u8, host: []u8, cert: *c.GTlsCertificate };

    /// a certificate that fails: the site opens in the sandbox, without asking
    fn certificateFailed(t: *Tab, uri: []const u8, cert: *c.GTlsCertificate) bool {
        const h = search.host(uri) orelse return false;
        if (t.allowedCerts.contains(h)) {
            core.gpa.free(h);
            return false;
        }
        const job = core.gpa.create(CertJob) catch return false;
        job.* = .{ .t = t, .uri = core.dupe(uri), .host = h, .cert = core.ref(cert) };
        // after the signal: the page that failed may be the one let go
        core.idle(job, certRetry);
        return true;
    }

    fn certRetry(job: *CertJob) void {
        const t = job.t;
        defer {
            core.unref(job.cert);
            core.gpa.free(job.uri);
            core.gpa.destroy(job);
        }
        if (!t.sandboxed) t.remake(true);
        const w = t.ensureWeb(null);
        t.allowedCerts.put(core.gpa, job.host, {}) catch {};
        const hz = core.z(job.host);
        defer core.gpa.free(hz);
        if (t.sandboxSession) |s| c.webkit_network_session_allow_tls_certificate_for_host(s, job.cert, hz.ptr);
        t.url.set(job.uri);
        const uz = core.z(job.uri);
        defer core.gpa.free(uz);
        c.webkit_web_view_load_uri(w, uz.ptr);
        const shown = search.display(job.uri);
        defer core.gpa.free(shown);
        const msg = core.fmt("{s} has a certificate that fails: it is open in the sandbox", .{shown});
        defer core.gpa.free(msg);
        t.browser.toast(msg);
        t.browser.tabChanged(t);
    }

    // ---------------------------------------------------------------- what opens

    const Later = struct { t: *Tab, url: []u8 };

    fn loadLater(l: *Later) void {
        l.t.load(l.url);
        core.gpa.free(l.url);
        core.gpa.destroy(l);
    }

    fn later(t: *Tab, u: []u8) void {
        const l = core.gpa.create(Later) catch return;
        l.* = .{ .t = t, .url = u };
        core.idle(l, loadLater);
    }

    fn decide(t: *Tab, decision: ?*anyopaque, kind: u32) bool {
        const d = core.cast(*c.WebKitPolicyDecision, decision orelse return false);
        if (kind == c.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
            const nav = c.webkit_navigation_policy_decision_get_navigation_action(@ptrCast(d));
            const req = c.webkit_navigation_action_get_request(nav) orelse return false;
            const u = core.str(c.webkit_uri_request_get_uri(req));
            if (c.webkit_navigation_action_get_frame_name(nav) != null) return false;
            // a Google result: straight to it, without Google's redirect
            if (search.unwrapRedirect(u)) |target| {
                c.webkit_policy_decision_ignore(d);
                t.later(target);
                return true;
            }
            // into the sandbox, or out of it: the page is made again
            if (std.mem.startsWith(u8, u, "http") and search.untrusted(u) != t.sandboxed) {
                c.webkit_policy_decision_ignore(d);
                t.later(core.dupe(u));
                return true;
            }
            // the main frame is about to open u: the shield for its site
            if (t.ucm) |ucm| {
                const h = search.host(u);
                defer if (h) |x| core.gpa.free(x);
                shields.Shields.shared().apply(ucm, h);
            }
            return false;
        }
        if (kind == c.WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) return t.browser.newWindow(t, d);
        if (kind == c.WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
            const r: *c.WebKitResponsePolicyDecision = @ptrCast(d);
            // what WebKit cannot show is a download
            if (c.webkit_response_policy_decision_is_mime_type_supported(r) == 0 and c.webkit_response_policy_decision_is_main_frame_main_resource(r) != 0) {
                if (t.sandboxed) {
                    // nothing from an untrusted site reaches your files
                    c.webkit_policy_decision_ignore(d);
                    t.browser.toast("Downloads are off for sites in the sandbox");
                    return true;
                }
                c.webkit_policy_decision_download(d);
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- actions

    pub fn back(t: *Tab) void {
        if (t.web) |w| c.webkit_web_view_go_back(w);
    }
    pub fn forward(t: *Tab) void {
        if (t.web) |w| c.webkit_web_view_go_forward(w);
    }
    pub fn reload(t: *Tab) void {
        if (t.web) |w| c.webkit_web_view_reload(w);
    }
    pub fn stop(t: *Tab) void {
        if (t.web) |w| c.webkit_web_view_stop_loading(w);
    }

    pub fn setZoom(t: *Tab, z: f64) void {
        t.zoom = @min(3, @max(0.3, z));
        if (t.web) |w| c.webkit_web_view_set_zoom_level(w, t.zoom);
    }

    pub fn playingAudio(t: *Tab) bool {
        return if (t.web) |w| c.webkit_web_view_is_playing_audio(w) != 0 else false;
    }

    /// a script's answer, as text (the selection, for "Ask Google AI Mode")
    pub fn run(t: *Tab, js: [:0]const u8, ctx: *anyopaque, done: *const fn (*anyopaque, ?[]const u8) void) void {
        const w = t.web orelse return done(ctx, null);
        const Job = struct { ctx: *anyopaque, done: *const fn (*anyopaque, ?[]const u8) void };
        const job = core.gpa.create(Job) catch return;
        job.* = .{ .ctx = ctx, .done = done };
        c.webkit_web_view_evaluate_javascript(w, js.ptr, -1, null, null, null, struct {
            fn cb(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
                const j: *Job = core.cast(*Job, d);
                defer core.gpa.destroy(j);
                var err: ?*c.GError = null;
                const v = c.webkit_web_view_evaluate_javascript_finish(@ptrCast(o), res, &err);
                if (err) |e| c.g_error_free(e);
                if (v) |val| {
                    defer core.unref(val);
                    if (c.jsc_value_is_string(val) != 0) {
                        const s = c.jsc_value_to_string(val);
                        defer c.g_free(s);
                        return j.done(j.ctx, core.str(s));
                    }
                }
                j.done(j.ctx, null);
            }
        }.cb, job);
    }

    pub fn destroy(t: *Tab) void {
        if (t.ucm) |u| shields.Shields.shared().forget(u);
        if (t.page) |p| p.destroy();
        t.page = null;
        if (t.web) |w| {
            // its signals go first: a late "close" from the old page must
            // never close the tab (it may already show a new one)
            _ = c.g_signal_handlers_disconnect_matched(w, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, t);
            c.webkit_web_view_try_close(w);
            core.unref(w);
        }
        t.web = null;
        core.unref(t.ucm);
        t.ucm = null;
        core.unref(t.sandboxSession);
        t.sandboxSession = null;
    }
};
