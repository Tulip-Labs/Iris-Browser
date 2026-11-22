//! New versions: Iris asks GitHub once a day and tells you when there is
//! one. It never installs anything itself; the Flatpak updates the way every
//! Flatpak does (your software centre, or flatpak update).
const std = @import("std");
const core = @import("core.zig");
const store = @import("store.zig");
const Browser = @import("browser.zig").Browser;
const version = @import("app.zig").version;
const c = core.c;

const api = "https://api.github.com/repos/Tulip-Labs/Iris-Browser/releases/latest";
var session: ?*c.SoupSession = null;

/// a is newer than b ("2.0.1" > "2.0.0")
pub fn newer(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return false;
        const nx = std.fmt.parseInt(u32, x orelse "0", 10) catch 0;
        const ny = std.fmt.parseInt(u32, y orelse "0", 10) catch 0;
        if (nx != ny) return nx > ny;
    }
}

const Check = struct { b: *Browser, page: []u8 = &.{} };

/// the quiet daily check
pub fn check(b: *Browser) void {
    const now: f64 = @floatFromInt(std.time.timestamp());
    const s = store.SettingsStore.get();
    if (now - s.lastUpdateCheck < 86400) return;
    s.lastUpdateCheck = now;
    store.SettingsStore.save();
    if (session == null) session = c.soup_session_new();
    const msg = c.soup_message_new("GET", api) orelse return;
    defer core.unref(msg);
    const h = c.soup_message_get_request_headers(msg);
    c.soup_message_headers_append(h, "Accept", "application/vnd.github+json");
    c.soup_message_headers_append(h, "User-Agent", "Iris/" ++ version);
    const k = core.gpa.create(Check) catch return;
    k.* = .{ .b = b };
    c.soup_session_send_and_read_async(session, msg, c.G_PRIORITY_DEFAULT, null, answered, k);
}

const Release = struct { tag_name: []const u8 = "", html_url: []const u8 = "" };

fn answered(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
    const k: *Check = core.cast(*Check, d);
    const bytes = c.soup_session_send_and_read_finish(@ptrCast(o), res, null) orelse return core.gpa.destroy(k);
    defer c.g_bytes_unref(bytes);
    var n: usize = 0;
    const p = c.g_bytes_get_data(bytes, &n) orelse return core.gpa.destroy(k);
    const data = @as([*]const u8, @ptrCast(p))[0..n];
    const parsed = std.json.parseFromSlice(Release, core.gpa, data, .{ .ignore_unknown_fields = true }) catch return core.gpa.destroy(k);
    defer parsed.deinit();
    const tag = parsed.value.tag_name;
    const v = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    if (v.len == 0 or !newer(v, version)) return core.gpa.destroy(k);
    k.page = core.dupe(if (parsed.value.html_url.len > 0) parsed.value.html_url else "https://github.com/Tulip-Labs/Iris-Browser/releases");
    const text = core.fmt("Iris {s} is out. Your software centre or flatpak update installs it.", .{v});
    defer core.gpa.free(text);
    k.b.toastAction(text, "What's new", k, whatsNew);
}

fn whatsNew(k: *Check) void {
    _ = k.b.newTab(.{ .url = k.page });
}

test newer {
    try std.testing.expect(newer("2.0.1", "2.0.0"));
    try std.testing.expect(newer("2.10", "2.9.9"));
    try std.testing.expect(!newer("2.2.0", "2.2"));
    try std.testing.expect(!newer("1.9", "2.0"));
}
