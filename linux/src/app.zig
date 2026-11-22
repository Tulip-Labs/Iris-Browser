//! The application: its windows, the session, and what they share.
const std = @import("std");
const core = @import("core.zig");
const ui = @import("ui.zig");
const search = @import("search.zig");
const store = @import("store.zig");
const engine = @import("engine.zig");
const shields = @import("shields.zig");
const updates = @import("updates.zig");
const Browser = @import("browser.zig").Browser;
const c = core.c;

pub const version = "2.2.0";
pub const id = "io.github.tulip_labs.Iris";

pub const App = struct {
    gtk: *c.AdwApplication,
    browsers: std.ArrayList(*Browser) = .empty,
    started: bool = false,

    pub fn create() *App {
        const a = core.gpa.create(App) catch @panic("oom");
        a.* = .{ .gtk = c.adw_application_new(id, c.G_APPLICATION_HANDLES_OPEN).? };
        _ = core.on(a.gtk, "startup", a, startup);
        _ = core.on(a.gtk, "activate", a, activateCB);
        _ = c.g_signal_connect_data(core.obj(a.gtk), "open", @ptrCast(&openCB), a, null, 0);
        return a;
    }

    pub fn run(a: *App) u8 {
        const args = std.process.argsAlloc(core.gpa) catch return 1;
        defer std.process.argsFree(core.gpa, args);
        var argv: std.ArrayList(?[*:0]u8) = .empty;
        defer argv.deinit(core.gpa);
        for (args) |x| argv.append(core.gpa, x.ptr) catch {};
        argv.append(core.gpa, null) catch {};
        const r = c.g_application_run(@ptrCast(a.gtk), @intCast(args.len), @ptrCast(argv.items.ptr));
        return @intCast(@max(0, @min(255, r)));
    }

    fn startup(a: *App) void {
        c.g_set_prgname("iris");
        c.g_set_application_name("Iris");
        // light, always
        c.adw_style_manager_set_color_scheme(c.adw_style_manager_get_default(), c.ADW_COLOR_SCHEME_FORCE_LIGHT);
        ui.installCSS();
        if (iconsDir()) |dir| {
            defer core.gpa.free(dir);
            c.gtk_icon_theme_add_search_path(c.gtk_icon_theme_get_for_display(c.gdk_display_get_default()), dir.ptr);
        }
        engine.Containers.sessionMade = engine.Downloads.listen;
        const s = shields.Shields.shared();
        s.installed = .{ .ctx = a, .f = reapplyCB };
        s.start();
    }

    /// share/iris/icons beside the program, or resources/icons in the tree
    fn iconsDir() ?[:0]u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe = std.fs.selfExeDirPath(&buf) catch return null;
        for ([_][]const u8{ "../share/iris/icons", "../../resources/icons" }) |rel| {
            const p = std.fs.path.joinZ(core.gpa, &.{ exe, rel }) catch continue;
            if (std.fs.accessAbsolute(p, .{})) |_| return p else |_| core.gpa.free(p);
        }
        return null;
    }

    fn activateCB(a: *App) void {
        a.activate(&.{});
    }

    fn openCB(_: ?*c.GApplication, files: [*]?*c.GFile, n: c_int, _: ?[*:0]const u8, a: *App) callconv(.c) void {
        var urls: std.ArrayList([]const u8) = .empty;
        defer {
            for (urls.items) |u| core.gpa.free(u);
            urls.deinit(core.gpa);
        }
        for (files[0..@intCast(n)]) |f| {
            const u = core.takeStr(c.g_file_get_uri(f)) orelse continue;
            urls.append(core.gpa, u) catch {};
        }
        a.activate(urls.items);
    }

    fn activate(a: *App, urls: []const []const u8) void {
        if (a.started and a.browsers.items.len > 0) {
            const b = a.browsers.items[a.browsers.items.len - 1];
            for (urls) |u| _ = b.newTab(.{ .url = u });
            b.present();
            return;
        }
        a.started = true;
        const b = a.newWindow(true);
        const saved = store.SettingsStore.get().session;
        if (saved.len > 0) b.restore(saved);
        for (urls) |u| _ = b.newTab(.{ .url = u });
        if (b.tabs.items.len == 0) _ = b.newTab(.{});
        updates.check(b);
    }

    pub fn newWindow(a: *App, empty: bool) *Browser {
        const b = Browser.create(a);
        a.browsers.append(core.gpa, b) catch {};
        if (!empty) _ = b.newTab(.{});
        b.present();
        return b;
    }

    pub fn closed(a: *App, b: *Browser) void {
        for (a.browsers.items, 0..) |x, i| if (x == b) {
            _ = a.browsers.orderedRemove(i);
            return;
        };
    }

    pub fn isLast(a: *App, _: *Browser) bool {
        return a.browsers.items.len <= 1;
    }

    pub fn anyPrivate(a: *App, except: *Browser) bool {
        for (a.browsers.items) |b| {
            if (b == except) continue;
            for (b.tabs.items) |t| if (t.isPrivate()) return true;
        }
        return false;
    }

    /// every window's tabs open again next time
    pub fn saveSession(a: *App) void {
        var saved: std.ArrayList(store.SavedTab) = .empty;
        for (a.browsers.items) |b| for (b.tabs.items) |t| {
            if (t.isPrivate() or t.sandboxed) continue;
            const u = t.pending orelse t.url.get();
            if (u.len == 0 or search.isAIMode(u)) continue;
            saved.append(core.gpa, .{ .url = core.dupe(u), .title = core.dupe(t.title.get()), .container = if (t.container) |k| core.dupe(k) else null }) catch {};
        };
        store.SettingsStore.get().session = saved.items;
        store.SettingsStore.save();
        store.History.flush();
    }

    pub fn quit(a: *App) void {
        a.saveSession();
        c.g_application_quit(@ptrCast(a.gtk));
    }

    pub fn removeContainer(a: *App, k: []const u8) void {
        const kid = core.dupe(k);
        defer core.gpa.free(kid);
        for (a.browsers.items) |b| b.closeTabs(kid);
        engine.Containers.remove(kid);
    }

    fn reapplyCB(ctx: *anyopaque) void {
        core.cast(*App, ctx).reapplyShields();
    }

    /// new rules (a level, fresh lists): every page takes them, as it is
    pub fn reapplyShields(a: *App) void {
        for (a.browsers.items) |b| for (b.tabs.items) |t| a.applyTo(t);
    }

    fn applyTo(_: *App, t: anytype) void {
        const ucm = t.ucm orelse return;
        const h = search.host(t.url.get());
        defer if (h) |x| core.gpa.free(x);
        shields.Shields.shared().apply(ucm, h);
    }

    pub fn shieldsChanged(a: *App) void {
        for (a.browsers.items) |b| {
            for (b.tabs.items) |t| a.applyTo(t);
            if (b.current) |t| {
                t.reload();
                b.tabChanged(t);
            }
        }
    }
};
