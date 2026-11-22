//! Where Iris keeps things (~/.local/share/iris and ~/.cache/iris; inside
//! the Flatpak, the app's own ~/.var/app/io.github.tulip_labs.Iris/...): its
//! settings, the tabs to open again, and the pages you have been to. The
//! files are JSON, the same as Iris 2.1 wrote, so nothing is lost moving on.
const std = @import("std");
const core = @import("core.zig");
const c = core.c;
const search = @import("search.zig");

pub const Paths = struct {
    var data_dir: ?[]u8 = null;
    var cache_dir: ?[]u8 = null;

    pub fn data() []const u8 {
        if (data_dir == null) data_dir = made(core.str(c.g_get_user_data_dir()));
        return data_dir.?;
    }

    pub fn cache() []const u8 {
        if (cache_dir == null) cache_dir = made(core.str(c.g_get_user_cache_dir()));
        return cache_dir.?;
    }

    fn made(base: []const u8) []u8 {
        const d = core.fmtZ("{s}/iris", .{base});
        _ = c.g_mkdir_with_parents(d.ptr, 0o755);
        return d[0..d.len];
    }

    pub fn downloads() []const u8 {
        const d = c.g_get_user_special_dir(c.G_USER_DIRECTORY_DOWNLOAD);
        return if (d != null) core.str(d) else core.fmt("{s}/Downloads", .{core.str(c.g_get_home_dir())});
    }
};

/// a file's bytes (Iris's heap), or null
pub fn readFile(path: []const u8) ?[]u8 {
    const p = core.z(path);
    defer core.gpa.free(p);
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(p.ptr, &contents, &len, null) == 0) return null;
    defer c.g_free(contents);
    return core.dupe(contents[0..len]);
}

/// written beside and moved over, so a crash never leaves half a file
pub fn writeFile(path: []const u8, bytes: []const u8) void {
    const p = core.z(path);
    defer core.gpa.free(p);
    _ = c.g_file_set_contents(p.ptr, bytes.ptr, @intCast(bytes.len), null);
}

pub fn dataPath(name: []const u8) []u8 {
    return core.fmt("{s}/{s}", .{ Paths.data(), name });
}

/// one value in a JSON file; the parsed value lives as long as Iris
pub fn loadJSON(comptime T: type, name: []const u8) ?T {
    const path = dataPath(name);
    defer core.gpa.free(path);
    const bytes = readFile(path) orelse return null;
    defer core.gpa.free(bytes);
    const parsed = std.json.parseFromSlice(T, core.gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    // the arena stays: its strings are the settings' own
    return parsed.value;
}

pub fn saveJSON(name: []const u8, v: anytype) void {
    const out = std.json.Stringify.valueAlloc(core.gpa, v, .{}) catch return;
    defer core.gpa.free(out);
    const path = dataPath(name);
    defer core.gpa.free(path);
    writeFile(path, out);
}

pub const ShieldLevel = @import("rules.zig").Level;

pub const SavedTab = struct {
    url: []const u8,
    title: []const u8 = "",
    container: ?[]const u8 = null,
};

pub const Settings = struct {
    shields: bool = true,
    /// sites where the shield is off
    shieldsOff: []const []const u8 = &.{},
    /// the pages open when Iris last closed, to open again
    session: []const SavedTab = &.{},
    lastUpdateCheck: f64 = 0,
    skippedVersion: ?[]const u8 = null,
    /// YouTube sends H.264 instead of VP9 or AV1 (much lighter)
    lightVideo: bool = true,
    /// the graphics chip decodes video (VA-API); off by default
    hardwareVideo: bool = false,
    /// how hard Shields block
    shieldLevel: ShieldLevel = .aggressive,
};

pub const SettingsStore = struct {
    pub var value: Settings = .{};
    var loaded = false;

    pub fn get() *Settings {
        if (!loaded) {
            loaded = true;
            value = loadJSON(Settings, "settings.json") orelse .{};
        }
        return &value;
    }

    pub fn save() void {
        saveJSON("settings.json", get().*);
    }

    pub fn shieldsOffFor(site: []const u8) bool {
        for (get().shieldsOff) |s| if (std.mem.eql(u8, s, site)) return true;
        return false;
    }

    /// turns the shield off for a site, or back on
    pub fn toggleSite(site: []const u8) void {
        const s = get();
        var list: std.ArrayList([]const u8) = .empty;
        var found = false;
        for (s.shieldsOff) |x| {
            if (std.mem.eql(u8, x, site)) found = true else list.append(core.gpa, x) catch {};
        }
        if (!found) list.append(core.gpa, core.dupe(site)) catch {};
        s.shieldsOff = list.items;
        save();
    }
};

// ---------------------------------------------------------------- history

/// The pages you have been to, for the address bar's suggestions. Private
/// tabs leave nothing here.
pub const Visit = struct {
    url: []const u8,
    title: []const u8 = "",
    visits: u32 = 1,
    last: f64 = 0,
};

pub const History = struct {
    pub var list: std.ArrayList(Visit) = .empty;
    var loaded = false;
    var dirty = false;

    fn ensure() void {
        if (loaded) return;
        loaded = true;
        if (loadJSON([]Visit, "history.json")) |v| list.appendSlice(core.gpa, v) catch {};
    }

    fn now() f64 {
        return @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000;
    }

    fn score(v: Visit, t: f64) f64 {
        const days = @max(0, t - v.last) / 86400;
        return @as(f64, @floatFromInt(v.visits)) / (1 + days / 7);
    }

    pub fn record(url: []const u8, named: []const u8) void {
        ensure();
        if (!std.mem.startsWith(u8, url, "http") or search.aiQuery(url) != null) return;
        const t = now();
        for (list.items) |*v| if (std.mem.eql(u8, v.url, url)) {
            v.visits += 1;
            v.last = t;
            if (named.len > 0) v.title = core.dupe(named);
            later();
            return;
        };
        list.append(core.gpa, .{ .url = core.dupe(url), .title = core.dupe(named), .visits = 1, .last = t }) catch {};
        if (list.items.len > 3000) {
            std.sort.pdq(Visit, list.items, t, struct {
                fn f(tt: f64, a: Visit, b: Visit) bool {
                    return score(a, tt) > score(b, tt);
                }
            }.f);
            list.shrinkRetainingCapacity(2500);
        }
        later();
    }

    pub fn title(url: []const u8, t: []const u8) void {
        ensure();
        if (t.len == 0) return;
        for (list.items) |*v| if (std.mem.eql(u8, v.url, url)) {
            v.title = core.dupe(t);
            later();
            return;
        };
    }

    var flushing: u8 = 0;

    fn later() void {
        if (dirty) return;
        dirty = true;
        _ = core.after(2000, &flushing, flushCB);
    }

    fn flushCB(_: *u8) void {
        flush();
    }

    pub fn flush() void {
        if (!dirty) return;
        dirty = false;
        saveJSON("history.json", list.items);
    }

    /// up to n pages matching typed text, best first
    pub fn suggest(q0: []const u8, n: usize, out: *std.ArrayList(Visit)) void {
        ensure();
        const q = std.ascii.allocLowerString(core.gpa, std.mem.trim(u8, q0, " ")) catch return;
        defer core.gpa.free(q);
        if (q.len == 0) return;
        const t = now();
        const Scored = struct { v: Visit, s: f64 };
        var hits: std.ArrayList(Scored) = .empty;
        defer hits.deinit(core.gpa);
        for (list.items) |v| {
            const host = std.ascii.allocLowerString(core.gpa, search.display(v.url)) catch continue;
            defer core.gpa.free(host);
            const u = std.ascii.allocLowerString(core.gpa, v.url) catch continue;
            defer core.gpa.free(u);
            const ti = std.ascii.allocLowerString(core.gpa, v.title) catch continue;
            defer core.gpa.free(ti);
            var s: f64 = 0;
            if (std.mem.startsWith(u8, host, q)) s = 4 else if (std.mem.indexOf(u8, u, q) != null) s = 2 else if (std.mem.indexOf(u8, ti, q) != null) s = 1.5;
            if (s > 0) hits.append(core.gpa, .{ .v = v, .s = s * (1 + score(v, t)) }) catch {};
        }
        std.sort.pdq(Scored, hits.items, {}, struct {
            fn f(_: void, a: Scored, b: Scored) bool {
                return a.s > b.s;
            }
        }.f);
        for (hits.items[0..@min(n, hits.items.len)]) |h| out.append(core.gpa, h.v) catch {};
    }
};
