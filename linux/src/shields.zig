//! Iris Shields, as in Brave: ads and trackers are stopped inside WPE WebKit
//! before a request leaves the computer. The filter lists uBlock Origin uses
//! become content rules for the chosen level (rules.zig), compiled once by
//! WebKit's content-filter store and kept; Iris's own ~100,000 domains (a
//! native Zig array, made at build time) cover the first start until the
//! lists have come, and answer the pop-up check at once.
const std = @import("std");
const core = @import("core.zig");
const rules = @import("rules.zig");
const store = @import("store.zig");
const search = @import("search.zig");
const domains = @import("domains");
const c = core.c;

pub const version_agent = "Iris/2.2.0";

/// whether a host (or a domain it belongs to) is one of Iris's ad and
/// tracker domains (binary search in the built-in sorted array)
pub fn hostBlocked(h: []const u8) bool {
    return rules.listed(&domains.list, h);
}

/// whether Shields guard pages of this host
pub fn onFor(host: ?[]const u8) bool {
    const s = store.SettingsStore.get();
    if (!s.shields) return false;
    const h = host orelse return true;
    return !store.SettingsStore.shieldsOffFor(search.site(h));
}

pub fn level() rules.Level {
    return store.SettingsStore.get().shieldLevel;
}

pub const Shields = struct {
    filters: std.ArrayList(*c.WebKitUserContentFilter) = .empty,
    waiting: std.ArrayList(*c.WebKitUserContentManager) = .empty,
    filterStore: *c.WebKitUserContentFilterStore,
    dir: []u8,
    building: ?rules.Level = null,
    fetchTried: [3]bool = .{ false, false, false },
    session: ?*c.SoupSession = null,
    /// a new set of rules is in place: pages already open take it
    installed: ?Hook = null,

    pub const Hook = struct { ctx: *anyopaque, f: *const fn (*anyopaque) void };

    var instance: ?*Shields = null;

    pub fn shared() *Shields {
        if (instance) |s| return s;
        const s = core.gpa.create(Shields) catch @panic("oom");
        const dir = core.fmt("{s}/shields", .{store.Paths.cache()});
        const lists = core.fmtZ("{s}/lists", .{dir});
        defer core.gpa.free(lists);
        _ = c.g_mkdir_with_parents(lists.ptr, 0o755);
        const dz = core.z(dir);
        defer core.gpa.free(dz);
        s.* = .{ .filterStore = c.webkit_user_content_filter_store_new(dz.ptr).?, .dir = dir };
        instance = s;
        return s;
    }

    fn idsPath(s: *Shields, l: rules.Level) []u8 {
        return core.fmt("{s}/{s}.ids", .{ s.dir, @tagName(l) });
    }

    fn listPath(s: *Shields, l: rules.List) []u8 {
        return core.fmt("{s}/lists/{s}.txt", .{ s.dir, l.id() });
    }

    /// the compiled rules of the level, kept from before; else they are made
    pub fn start(s: *Shields) void {
        s.load(level());
        // the lists are fetched again every four days
        _ = core.after(8000, s, refreshLists);
    }

    pub fn levelChanged(s: *Shields) void {
        s.load(level());
    }

    // ---- loading what was compiled before

    const Load = struct {
        s: *Shields,
        l: rules.Level,
        got: []?*c.WebKitUserContentFilter,
        left: usize,
        failed: bool = false,
    };

    const LoadOne = struct { job: *Load, i: usize };

    fn load(s: *Shields, l: rules.Level) void {
        // a hand-made rule list, for checks (IRIS_SHIELDS_JSON=file)
        if (std.posix.getenv("IRIS_SHIELDS_JSON")) |p| {
            if (store.readFile(p)) |j| {
                s.compile(&.{j}, l);
                return;
            }
        }
        const path = s.idsPath(l);
        defer core.gpa.free(path);
        const text = store.readFile(path) orelse return s.build(l);
        var ids: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |id| ids.append(core.gpa, id) catch {};
        if (ids.items.len == 0) return s.build(l);
        const job = core.gpa.create(Load) catch return;
        job.* = .{ .s = s, .l = l, .got = core.gpa.alloc(?*c.WebKitUserContentFilter, ids.items.len) catch return, .left = ids.items.len };
        @memset(job.got, null);
        for (ids.items, 0..) |id, i| {
            const one = core.gpa.create(LoadOne) catch continue;
            one.* = .{ .job = job, .i = i };
            const idz = core.z(id);
            defer core.gpa.free(idz);
            c.webkit_user_content_filter_store_load(s.filterStore, idz.ptr, null, loaded, one);
        }
    }

    fn loaded(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
        const one: *LoadOne = core.cast(*LoadOne, d);
        defer core.gpa.destroy(one);
        const job = one.job;
        var err: ?*c.GError = null;
        const f = c.webkit_user_content_filter_store_load_finish(@ptrCast(o), res, &err);
        if (err) |e| c.g_error_free(e);
        job.got[one.i] = f;
        if (f == null) job.failed = true;
        job.left -= 1;
        if (job.left > 0) return;
        defer {
            core.gpa.free(job.got);
            core.gpa.destroy(job);
        }
        if (job.failed) {
            for (job.got) |g| if (g) |x| c.webkit_user_content_filter_unref(x);
            job.s.build(job.l);
        } else job.s.install(job.got, job.l);
    }

    // ---- building from the lists (on a thread of its own)

    const Build = struct {
        s: *Shields,
        l: rules.Level,
        paths: [][]u8,
        arena: std.heap.ArenaAllocator,
        parts: []const []const u8 = &.{},
    };

    fn build(s: *Shields, l: rules.Level) void {
        if (s.building != null) return;
        var missing: std.ArrayList(rules.List) = .empty;
        for (l.lists()) |li| {
            const p = s.listPath(li);
            defer core.gpa.free(p);
            const pz = core.z(p);
            defer core.gpa.free(pz);
            if (c.g_file_test(pz.ptr, c.G_FILE_TEST_EXISTS) == 0) missing.append(core.gpa, li) catch {};
        }
        if (missing.items.len > 0 and !s.fetchTried[@intFromEnum(l)]) {
            s.fetchTried[@intFromEnum(l)] = true;
            s.fetch(missing.items, .{ .s = s, .l = l });
            return;
        }
        s.building = l;
        const job = core.gpa.create(Build) catch return;
        var paths: std.ArrayList([]u8) = .empty;
        for (l.lists()) |li| paths.append(core.gpa, s.listPath(li)) catch {};
        job.* = .{ .s = s, .l = l, .paths = paths.items, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
        const th = std.Thread.spawn(.{}, convert, .{job}) catch {
            s.building = null;
            return;
        };
        th.detach();
    }

    fn convert(job: *Build) void {
        var conv = rules.Converter.init(job.arena.allocator(), job.l);
        var any = false;
        for (job.paths) |p| {
            const t = store.readFile(p) orelse continue;
            defer core.gpa.free(t);
            conv.addList(t);
            any = true;
        }
        // Iris's own domain list, until the lists have come
        if (!any) conv.addDomains(&domains.list);
        var max: usize = 120_000;
        if (std.posix.getenv("IRIS_SHIELDS_PART")) |v| max = std.fmt.parseInt(usize, v, 10) catch max;
        job.parts = conv.finish(max);
        core.idle(job, converted);
    }

    fn converted(job: *Build) void {
        job.s.building = null;
        job.s.compile(job.parts, job.l);
        for (job.paths) |p| core.gpa.free(p);
        core.gpa.free(job.paths);
        job.arena.deinit();
        core.gpa.destroy(job);
    }

    // ---- compiling (WebKit's content-filter store)

    const Compile = struct {
        s: *Shields,
        l: rules.Level,
        ids: [][:0]u8,
        got: []?*c.WebKitUserContentFilter,
        left: usize,
    };

    const CompileOne = struct { job: *Compile, i: usize };

    fn compile(s: *Shields, parts: []const []const u8, l: rules.Level) void {
        if (parts.len == 0) return;
        const job = core.gpa.create(Compile) catch return;
        const stamp = std.time.timestamp();
        job.* = .{ .s = s, .l = l, .ids = core.gpa.alloc([:0]u8, parts.len) catch return, .got = core.gpa.alloc(?*c.WebKitUserContentFilter, parts.len) catch return, .left = parts.len };
        @memset(job.got, null);
        s.building = l;
        for (parts, 0..) |json, i| {
            job.ids[i] = core.fmtZ("iris-{s}-{d}-{d}", .{ @tagName(l), stamp, i });
            const bytes = c.g_bytes_new(json.ptr, json.len);
            const one = core.gpa.create(CompileOne) catch continue;
            one.* = .{ .job = job, .i = i };
            c.webkit_user_content_filter_store_save(s.filterStore, job.ids[i].ptr, bytes, null, saved, one);
            c.g_bytes_unref(bytes);
        }
    }

    fn saved(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
        const one: *CompileOne = core.cast(*CompileOne, d);
        defer core.gpa.destroy(one);
        const job = one.job;
        var err: ?*c.GError = null;
        const f = c.webkit_user_content_filter_store_save_finish(@ptrCast(o), res, &err);
        if (err) |e| {
            std.log.warn("the shield's rules did not compile: {s}", .{core.str(e.message)});
            c.g_error_free(e);
        }
        job.got[one.i] = f;
        job.left -= 1;
        if (job.left > 0) return;
        const s = job.s;
        s.building = null;
        defer {
            for (job.ids) |id| core.gpa.free(id);
            core.gpa.free(job.ids);
            core.gpa.free(job.got);
            core.gpa.destroy(job);
        }
        for (job.got) |g| if (g == null) {
            for (job.got) |x| if (x) |y| c.webkit_user_content_filter_unref(y);
            return;
        };
        // the ids of the rules kept, for next time; the old ones go
        const path = s.idsPath(job.l);
        defer core.gpa.free(path);
        if (store.readFile(path)) |old| {
            defer core.gpa.free(old);
            var it = std.mem.tokenizeScalar(u8, old, '\n');
            while (it.next()) |id| {
                var still = false;
                for (job.ids) |n| if (std.mem.eql(u8, n, id)) {
                    still = true;
                };
                if (!still) {
                    const idz = core.z(id);
                    defer core.gpa.free(idz);
                    c.webkit_user_content_filter_store_remove(s.filterStore, idz.ptr, null, null, null);
                }
            }
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(core.gpa);
        for (job.ids, 0..) |id, i| {
            if (i > 0) out.append(core.gpa, '\n') catch {};
            out.appendSlice(core.gpa, id) catch {};
        }
        store.writeFile(path, out.items);
        s.install(job.got, job.l);
    }

    fn install(s: *Shields, made: []?*c.WebKitUserContentFilter, l: rules.Level) void {
        if (l != level()) {
            for (made) |m| if (m) |x| c.webkit_user_content_filter_unref(x);
            return;
        }
        for (s.filters.items) |f| c.webkit_user_content_filter_unref(f);
        s.filters.clearRetainingCapacity();
        for (made) |m| if (m) |x| s.filters.append(core.gpa, x) catch {};
        for (s.waiting.items) |ucm| for (s.filters.items) |f| c.webkit_user_content_manager_add_filter(ucm, f);
        s.waiting.clearRetainingCapacity();
        if (s.installed) |h| h.f(h.ctx);
    }

    pub fn ready(s: *Shields) bool {
        return s.filters.items.len > 0;
    }

    // ---- the lists

    const Then = struct { s: *Shields, l: ?rules.Level, rebuildAll: bool = false };

    /// fetches the level's lists that are missing or older than four days,
    /// then makes the rules again
    fn refreshLists(s: *Shields) void {
        var old: std.ArrayList(rules.List) = .empty;
        const now: i128 = std.time.nanoTimestamp();
        for (level().lists()) |li| {
            const p = s.listPath(li);
            defer core.gpa.free(p);
            const st = std.fs.cwd().statFile(p) catch {
                old.append(core.gpa, li) catch {};
                continue;
            };
            if (now - st.mtime > 4 * 86400 * std.time.ns_per_s) old.append(core.gpa, li) catch {};
        }
        if (old.items.len == 0) return;
        s.fetch(old.items, .{ .s = s, .l = level(), .rebuildAll = true });
    }

    const Fetch = struct {
        then: Then,
        left: usize,
    };

    const Get = struct {
        fetch: *Fetch,
        list: rules.List,
        mirror: usize = 0,
        msg: ?*c.SoupMessage = null,
    };

    fn fetch(s: *Shields, lists: []const rules.List, then: Then) void {
        if (s.session == null) s.session = c.soup_session_new();
        const f = core.gpa.create(Fetch) catch return;
        f.* = .{ .then = then, .left = lists.len };
        for (lists) |li| {
            const g = core.gpa.create(Get) catch continue;
            g.* = .{ .fetch = f, .list = li };
            s.get(g);
        }
    }

    /// the first mirror that answers 200
    fn get(s: *Shields, g: *Get) void {
        if (g.mirror >= rules.List.mirrors.len) return s.gotList(g, null);
        const url = core.fmtZ("{s}{s}", .{ rules.List.mirrors[g.mirror], g.list.path() });
        defer core.gpa.free(url);
        const msg = c.soup_message_new("GET", url.ptr) orelse {
            g.mirror += 1;
            return s.get(g);
        };
        c.soup_message_headers_append(c.soup_message_get_request_headers(msg), "User-Agent", version_agent);
        g.msg = msg;
        c.soup_session_send_and_read_async(s.session, msg, c.G_PRIORITY_LOW, null, answered, g);
    }

    fn answered(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
        const g: *Get = core.cast(*Get, d);
        const s = instance.?;
        var err: ?*c.GError = null;
        const bytes = c.soup_session_send_and_read_finish(@ptrCast(o), res, &err);
        if (err) |e| c.g_error_free(e);
        const status = c.soup_message_get_status(g.msg);
        core.unref(g.msg);
        g.msg = null;
        if (bytes) |b| {
            defer c.g_bytes_unref(b);
            var n: c.gsize = 0;
            const p: [*]const u8 = @ptrCast(c.g_bytes_get_data(b, &n) orelse return s.next(g));
            if (status == 200) return s.gotList(g, p[0..n]);
        }
        s.next(g);
    }

    fn next(s: *Shields, g: *Get) void {
        g.mirror += 1;
        s.get(g);
    }

    fn gotList(s: *Shields, g: *Get, data: ?[]const u8) void {
        const f = g.fetch;
        if (data) |text| {
            // a filter list, whole (never an error page)
            if (text.len > 1000 and (text[0] == '!' or text[0] == '[')) {
                const p = s.listPath(g.list);
                defer core.gpa.free(p);
                store.writeFile(p, text);
            }
        }
        core.gpa.destroy(g);
        f.left -= 1;
        if (f.left > 0) return;
        const then = f.then;
        core.gpa.destroy(f);
        if (then.rebuildAll) {
            // every level's kept rules are made again from the new lists
            for ([_]rules.Level{ .moderate, .aggressive, .ultra }) |l| if (l != level()) {
                const p = s.idsPath(l);
                defer core.gpa.free(p);
                std.fs.cwd().deleteFile(p) catch {};
            };
        }
        if (then.l) |l| s.build(l);
    }

    // ---- pages

    /// puts the rules on a page's content manager, or takes them off, for
    /// the site it is about to open
    pub fn apply(s: *Shields, ucm: *c.WebKitUserContentManager, host: ?[]const u8) void {
        c.webkit_user_content_manager_remove_all_filters(ucm);
        s.forget(ucm);
        if (!onFor(host)) return;
        if (s.filters.items.len == 0) {
            s.waiting.append(core.gpa, ucm) catch {};
        } else for (s.filters.items) |f| c.webkit_user_content_manager_add_filter(ucm, f);
    }

    pub fn forget(s: *Shields, ucm: *c.WebKitUserContentManager) void {
        var i: usize = 0;
        while (i < s.waiting.items.len) {
            if (s.waiting.items[i] == ucm) _ = s.waiting.swapRemove(i) else i += 1;
        }
    }
};

test "the built-in domains answer at once" {
    try std.testing.expect(domains.list.len > 50_000);
    try std.testing.expect(!hostBlocked("example.com"));
}
