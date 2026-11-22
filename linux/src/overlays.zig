//! The glass that floats over everything: suggestions, menus, find, the
//! shields, the downloads, and what pages ask for. WebKitGTK drew a page's
//! own pop-ups (a <select>'s list, alert(), file fields); with WPE, Iris
//! draws them, in glass.
const std = @import("std");
const core = @import("core.zig");
const G = @import("glass.zig");
const ui = @import("ui.zig");
const search = @import("search.zig");
const store = @import("store.zig");
const engine = @import("engine.zig");
const shields = @import("shields.zig");
const rules = @import("rules.zig");
const stagez = @import("stage.zig");
const browser = @import("browser.zig");
const Browser = browser.Browser;
const Act = browser.Act;
const Tab = @import("tab.zig").Tab;
const c = core.c;
const Rect = core.Rect;
const Widget = core.Widget;
const Item = stagez.Item;

const row_glass = G.Glass{ .radius = 10, .level = 0.45, .bend = 3, .rim = 8, .dispersion = false };

fn heading(text: []const u8) Widget {
    const h = ui.label(text, &.{ "iris-dim", "iris-keys" });
    c.gtk_label_set_xalign(@ptrCast(h), 0);
    c.gtk_widget_set_margin_start(h, 12);
    c.gtk_widget_set_margin_top(h, 4);
    c.gtk_widget_set_margin_bottom(h, 2);
    return h;
}

fn note(text: []const u8) Widget {
    const n = ui.label(text, &.{ "iris-dim", "iris-keys" });
    c.gtk_label_set_wrap(@ptrCast(n), 1);
    c.gtk_label_set_xalign(@ptrCast(n), 0);
    c.gtk_widget_set_margin_start(n, 12);
    c.gtk_widget_set_margin_end(n, 12);
    c.gtk_widget_set_margin_top(n, 4);
    c.gtk_widget_set_margin_bottom(n, 6);
    return n;
}

/// a menu row that does f with an Act (the browser, a tab, a string)
fn actRow(b: *Browser, lead: ui.RowLead, text: []const u8, keys: ?[]const u8, t: ?*Tab, s: []const u8, comptime f: fn (*Act) void) Widget {
    const a = Act.make(b, t, s);
    return a.own(ui.row(lead, text, keys, a, f));
}

fn containerLead(k: engine.Container) ui.RowLead {
    return .{ .widget = k.iconWidget(16) };
}

// ---------------------------------------------------------------- suggestions

/// what the address bar suggests while you type
pub const Suggestions = struct {
    b: *Browser,
    box: Widget,
    item: *Item,
    urls: std.ArrayList([]u8) = .empty,
    rows: std.ArrayList(Widget) = .empty,
    selected: usize = 0,
    moved: bool = false,

    pub fn create(b: *Browser) *Suggestions {
        const s = core.gpa.create(Suggestions) catch @panic("oom");
        const box = ui.box(true, 2);
        const wrap = ui.box(true, 0);
        ui.cls(wrap, &.{"iris-menu"});
        ui.append(wrap, box);
        const it = b.stage.add(wrap, .overlay, .{ .radius = 18, .level = 0.72, .panel = true, .bend = 9, .rim = 18, .blur = 3, .shadow = 1 }, false);
        it.alpha.value = 0;
        it.scale.value = 0.97;
        b.stage.show(it, true, true);
        s.* = .{ .b = b, .box = box, .item = it };
        return s;
    }

    pub fn update(s: *Suggestions, text: []const u8) void {
        for (s.rows.items) |r| c.gtk_box_remove(@ptrCast(s.box), r);
        s.item.parts.clearRetainingCapacity();
        s.rows.clearRetainingCapacity();
        for (s.urls.items) |u| core.gpa.free(u);
        s.urls.clearRetainingCapacity();
        s.selected = 0;
        s.moved = false;
        const t = std.mem.trim(u8, text, " ");
        const first = search.resolve(t);
        defer core.gpa.free(first);
        if (search.isURLLike(t)) s.add("go-jump-symbolic", first, null, first) else s.add("system-search-symbolic", t, "Ask Google AI Mode", first);
        var hist: std.ArrayList(store.Visit) = .empty;
        defer hist.deinit(core.gpa);
        store.History.suggest(t, 6, &hist);
        outer: for (hist.items) |v| {
            for (s.urls.items) |u| if (std.mem.eql(u8, u, v.url)) continue :outer;
            const shown = if (v.title.len > 0) core.dupe(v.title) else search.display(v.url);
            defer core.gpa.free(shown);
            s.add("document-open-recent-symbolic", shown, v.url, v.url);
        }
        s.mark();
        s.place();
    }

    fn add(s: *Suggestions, icon: [*:0]const u8, title: []const u8, sub: ?[]const u8, url: []const u8) void {
        const row = c.gtk_button_new().?;
        ui.cls(row, &.{ "iris-flat", "iris-row" });
        c.gtk_widget_set_focus_on_click(row, 0);
        const h = ui.box(false, 10);
        ui.append(h, ui.icon(icon, 16));
        const t = ui.label(title, &.{});
        ui.ellipsize(t, 10);
        ui.append(h, t);
        if (sub) |x| {
            const l = ui.label(x, &.{"iris-dim"});
            ui.ellipsize(l, 6);
            c.gtk_widget_set_hexpand(l, 1);
            c.gtk_label_set_xalign(@ptrCast(l), 1);
            ui.append(h, l);
        }
        c.gtk_button_set_child(@ptrCast(row), h);
        const a = Act.make(s.b, null, url);
        _ = core.on(row, "clicked", a, goCB);
        _ = a.own(row);
        ui.append(s.box, row);
        s.rows.append(core.gpa, row) catch {};
        s.urls.append(core.gpa, core.dupe(url)) catch {};
        s.b.stage.part(s.item, row, row_glass, true);
    }

    fn goCB(a: *Act) void {
        a.b.go(a.s);
    }

    fn mark(s: *Suggestions) void {
        for (s.rows.items, 0..) |r, i| ui.setCls(r, "selected", i == s.selected);
    }

    pub fn move(s: *Suggestions, d: i32) void {
        const n: i32 = @intCast(s.rows.items.len);
        if (n == 0) return;
        s.selected = @intCast(@mod(@as(i32, @intCast(s.selected)) + d + n, n));
        s.moved = true;
        s.mark();
        s.b.stage.kick();
    }

    /// the row Enter opens: the one chosen with the arrows
    pub fn chosen(s: *Suggestions) ?[]const u8 {
        return if (s.moved and s.selected < s.urls.items.len) s.urls.items[s.selected] else null;
    }

    pub fn place(s: *Suggestions) void {
        const a = s.b.addressFrame();
        const w = @max(a.w, 420);
        const h = ui.natural(s.item.w, @intFromFloat(w))[1];
        s.b.stage.place(s.item, .{ .x = a.x, .y = a.maxY() + 8, .w = w, .h = h }, false);
    }

    pub fn close(s: *Suggestions) void {
        s.b.stage.remove(s.item, true, null);
        for (s.urls.items) |u| core.gpa.free(u);
        s.urls.deinit(core.gpa);
        s.rows.deinit(core.gpa);
        core.gpa.destroy(s);
    }
};

// ---------------------------------------------------------------- find

/// find in page (Ctrl+F)
pub const FindBar = struct {
    b: *Browser,
    item: *Item,
    text: Widget,
    count: Widget,
    tab: *Tab,
    fc: *c.WebKitFindController,

    pub fn create(b: *Browser) ?*FindBar {
        const t = b.current orelse return null;
        const wv = t.web orelse return null;
        const f = core.gpa.create(FindBar) catch return null;
        const h = ui.box(false, 6);
        ui.cls(h, &.{"iris-find"});
        c.gtk_widget_set_margin_start(h, 14);
        c.gtk_widget_set_margin_end(h, 6);
        ui.append(h, ui.icon("edit-find-symbolic", 16));
        const text = c.gtk_text_new().?;
        c.gtk_text_set_placeholder_text(@ptrCast(text), "Find in page");
        c.gtk_widget_set_valign(text, c.GTK_ALIGN_CENTER);
        ui.append(h, text);
        const count = ui.label("", &.{"iris-dim"});
        ui.append(h, count);
        const fc = c.webkit_web_view_get_find_controller(wv).?;
        f.* = .{ .b = b, .item = undefined, .text = text, .count = count, .tab = t, .fc = fc };
        const up = ui.button("go-up-symbolic", "Previous (Shift+Enter)", f, previous);
        const down = ui.button("go-down-symbolic", "Next (Enter)", f, next);
        ui.append(h, up);
        ui.append(h, down);
        f.item = b.stage.add(h, .overlay, .{ .radius = 19, .level = 0.5, .bend = 7, .rim = 14, .shadow = 1 }, false);
        const x = ui.button("window-close-symbolic", "Close (Esc)", f, close);
        ui.append(h, x);
        for ([_]Widget{ up, down, x }) |btn| b.stage.part(f.item, btn, .{ .radius = 17, .level = 0.35, .bend = 3, .rim = 8, .dispersion = false }, true);
        _ = core.on(text, "changed", f, changed);
        _ = core.on(text, "activate", f, next);
        _ = core.on1(fc, "counted-matches", f, counted);
        _ = core.on(fc, "failed-to-find-text", f, failed);
        const k = c.gtk_event_controller_key_new();
        _ = core.onKey(k, f, key);
        c.gtk_widget_add_controller(text, k);
        f.item.alpha.value = 0;
        f.item.scale.value = 0.95;
        b.stage.show(f.item, true, true);
        f.place();
        _ = c.gtk_widget_grab_focus(text);
        return f;
    }

    fn previous(f: *FindBar) void {
        c.webkit_find_controller_search_previous(f.fc);
    }
    fn next(f: *FindBar) void {
        c.webkit_find_controller_search_next(f.fc);
    }

    fn changed(f: *FindBar) void {
        const q = ui.text(f.text);
        if (q.len == 0) {
            c.webkit_find_controller_search_finish(f.fc);
            ui.setLabel(f.count, "");
            return;
        }
        const qz = core.z(q);
        defer core.gpa.free(qz);
        const opts = c.WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE | c.WEBKIT_FIND_OPTIONS_WRAP_AROUND;
        c.webkit_find_controller_search(f.fc, qz.ptr, opts, 1000);
        c.webkit_find_controller_count_matches(f.fc, qz.ptr, opts, 1000);
    }

    fn counted(f: *FindBar, n: ?*anyopaque) void {
        const k: usize = @intFromPtr(n);
        const s = if (k == 1) core.dupe("1 match") else core.fmt("{d} matches", .{k});
        defer core.gpa.free(s);
        ui.setLabel(f.count, s);
        f.place();
    }

    fn failed(f: *FindBar) void {
        ui.setLabel(f.count, "No matches");
        f.place();
    }

    fn key(f: *FindBar, k: u32, _: u32, state: u32) bool {
        if (k == c.GDK_KEY_Escape) {
            f.close();
            return true;
        }
        if (k == c.GDK_KEY_Return and state & c.GDK_SHIFT_MASK != 0) {
            f.previous();
            return true;
        }
        return false;
    }

    pub fn place(f: *FindBar) void {
        const n = ui.natural(f.item.w, -1);
        const cd = f.b.card;
        f.b.stage.place(f.item, .{ .x = cd.maxX() - n[0] - 14, .y = cd.y + 14, .w = n[0], .h = @max(n[1], 38) }, false);
    }

    pub fn close(f: *FindBar) void {
        c.webkit_find_controller_search_finish(f.fc);
        f.b.stage.remove(f.item, true, null);
        if (f.b.find == f) f.b.find = null;
        f.b.focusPage();
        core.gpa.destroy(f);
    }
};

// ---------------------------------------------------------------- downloads

/// the downloads, with what each is doing
pub const DownloadsPanel = struct {
    b: *Browser,
    box: Widget,
    rows: std.AutoHashMapUnmanaged(*engine.Download, [2]Widget) = .empty,

    pub fn create(b: *Browser) *DownloadsPanel {
        const p = core.gpa.create(DownloadsPanel) catch @panic("oom");
        p.* = .{ .b = b, .box = ui.box(true, 4) };
        p.build();
        return p;
    }

    fn build(p: *DownloadsPanel) void {
        const head = ui.box(false, 8);
        c.gtk_widget_set_margin_start(head, 10);
        c.gtk_widget_set_margin_end(head, 4);
        c.gtk_widget_set_margin_top(head, 4);
        c.gtk_widget_set_margin_bottom(head, 2);
        const title = ui.label("Downloads", &.{"iris-title"});
        c.gtk_widget_set_hexpand(title, 1);
        c.gtk_label_set_xalign(@ptrCast(title), 0);
        ui.append(head, title);
        ui.append(head, ui.textButton("Folder", p, folder));
        var any = false;
        for (engine.Downloads.list.items) |d| any = any or d.done or d.failed;
        if (any) ui.append(head, ui.textButton("Clear", p, clear));
        ui.append(p.box, head);
        if (engine.Downloads.list.items.len == 0) {
            const e = ui.label("Nothing downloaded yet", &.{"iris-dim"});
            c.gtk_widget_set_margin_top(e, 18);
            c.gtk_widget_set_margin_bottom(e, 22);
            ui.append(p.box, e);
            return;
        }
        for (engine.Downloads.list.items[0..@min(12, engine.Downloads.list.items.len)]) |d| ui.append(p.box, p.row(d));
    }

    fn folder(p: *DownloadsPanel) void {
        const z = core.z(store.Paths.downloads());
        defer core.gpa.free(z);
        const f = c.g_file_new_for_path(z.ptr);
        defer core.unref(f);
        const l = c.gtk_file_launcher_new(f);
        defer core.unref(l);
        c.gtk_file_launcher_launch(l, p.b.win(), null, null, null);
    }

    fn clear(p: *DownloadsPanel) void {
        engine.Downloads.clearFinished();
        p.b.closeMenu();
        p.b.showDownloads();
    }

    const DlAct = struct { p: *DownloadsPanel, d: *engine.Download };

    fn row(p: *DownloadsPanel, d: *engine.Download) Widget {
        const r = c.gtk_button_new().?;
        ui.cls(r, &.{ "iris-flat", "iris-row" });
        const v = ui.box(true, 4);
        const top = ui.box(false, 8);
        ui.append(top, ui.icon(if (d.failed) "dialog-warning-symbolic" else "folder-download-symbolic", 16));
        const name = ui.label(if (d.name.get().len == 0) "Starting\u{2026}" else d.name.get(), &.{});
        ui.ellipsize(name, 12);
        c.gtk_widget_set_hexpand(name, 1);
        ui.append(top, name);
        const a = core.gpa.create(DlAct) catch return r;
        a.* = .{ .p = p, .d = d };
        if (!d.done and !d.failed) {
            const x = ui.button("process-stop-symbolic", "Cancel", a, cancel);
            ui.cls(x, &.{"small"});
            c.gtk_widget_set_size_request(x, 24, 24);
            ui.append(top, x);
        } else if (d.done) {
            const f = ui.button("folder-open-symbolic", "Show in folder", a, showIn);
            ui.cls(f, &.{"small"});
            c.gtk_widget_set_size_request(f, 24, 24);
            ui.append(top, f);
        }
        ui.append(v, top);
        const st = d.status();
        defer core.gpa.free(st);
        const status = ui.label(st, &.{ "iris-dim", "iris-keys" });
        c.gtk_label_set_xalign(@ptrCast(status), 0);
        const bar = c.gtk_progress_bar_new().?;
        ui.cls(bar, &.{"iris"});
        c.gtk_progress_bar_set_fraction(@ptrCast(bar), d.progress);
        c.gtk_widget_set_visible(bar, @intFromBool(!(d.done or d.failed)));
        ui.append(v, bar);
        ui.append(v, status);
        c.gtk_button_set_child(@ptrCast(r), v);
        _ = core.on(r, "clicked", a, openIt);
        p.rows.put(core.gpa, d, .{ status, bar }) catch {};
        return r;
    }

    fn cancel(a: *DlAct) void {
        a.d.cancel();
    }
    fn showIn(a: *DlAct) void {
        engine.Downloads.showInFolder(a.d, a.p.b.win());
    }
    fn openIt(a: *DlAct) void {
        if (a.d.done) engine.Downloads.open(a.d, a.p.b.win());
    }

    pub fn update(p: *DownloadsPanel, d0: ?*engine.Download) void {
        const d = d0 orelse return p.rebuild();
        const r = p.rows.get(d) orelse return p.rebuild();
        if (d.done or d.failed) return p.rebuild();
        const st = d.status();
        defer core.gpa.free(st);
        ui.setLabel(r[0], st);
        c.gtk_progress_bar_set_fraction(@ptrCast(r[1]), d.progress);
    }

    fn rebuild(p: *DownloadsPanel) void {
        const b = p.b;
        b.closeMenu();
        b.showDownloads();
    }
};

// ---------------------------------------------------------------- containers

/// the containers: a new tab in one, this page in another, or a new one
pub fn showContainerMenu(b: *Browser, anchor: Rect, newTabOnly: bool) void {
    engine.Containers.ensure();
    const m = ui.box(true, 0);
    ui.append(m, heading("New tab in"));
    ui.append(m, actRow(b, .{ .icon = "web-browser-symbolic" }, "No Container", null, null, "", newPlain));
    for (engine.Containers.list.items) |k| ui.append(m, actRow(b, containerLead(k), k.name, null, null, k.id, newIn));
    ui.append(m, actRow(b, containerLead(engine.Containers.get(engine.Container.private_id).?), "Private", null, null, engine.Container.private_id, newIn));
    if (!newTabOnly) if (b.current) |t| if (t.url.get().len > 0) {
        ui.append(m, ui.separator());
        ui.append(m, heading("Open this page in"));
        if (t.container != null) ui.append(m, actRow(b, .{ .icon = "web-browser-symbolic" }, "No Container", null, t, "", pageIn));
        for (engine.Containers.list.items) |k| {
            if (t.container != null and std.mem.eql(u8, t.container.?, k.id)) continue;
            ui.append(m, actRow(b, containerLead(k), k.name, null, t, k.id, pageIn));
        }
    };
    ui.append(m, ui.separator());
    ui.append(m, actRow(b, .{ .icon = "list-add-symbolic" }, "New Container\u{2026}", null, null, "", askNew));
    if (engine.Containers.list.items.len > 0) ui.append(m, actRow(b, .{ .icon = "user-trash-symbolic" }, "Remove a Container\u{2026}", null, null, "", askRemove));
    b.openMenu(m, anchor, 260, !newTabOnly);
}

fn newPlain(a: *Act) void {
    a.b.closeMenu();
    _ = a.b.newTab(.{});
}

fn newIn(a: *Act) void {
    a.b.closeMenu();
    _ = a.b.newTab(.{ .container = a.s });
}

fn pageIn(a: *Act) void {
    const t = a.t.?;
    a.b.closeMenu();
    _ = a.b.newTab(.{ .url = t.url.get(), .container = if (a.s.len == 0) null else a.s, .after = t });
}

const NewContainer = struct { b: *Browser, entry: Widget, chosen: []const u8 = "star", buttons: std.ArrayList(Widget) = .empty };
const IconPick = struct { nc: *NewContainer, name: []const u8, button: Widget };

fn askNew(a: *Act) void {
    const b = a.b;
    b.closeMenu();
    const d = c.adw_alert_dialog_new("New Container", "A container keeps its own cookies, sign-ins and site data, apart from every other.").?;
    const ad: *c.AdwAlertDialog = @ptrCast(d);
    const v = ui.box(true, 12);
    const entry = c.gtk_entry_new().?;
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Name");
    c.gtk_entry_set_activates_default(@ptrCast(entry), 1);
    ui.append(v, entry);
    const nc = core.gpa.create(NewContainer) catch return;
    nc.* = .{ .b = b, .entry = entry };
    // its icon
    const grid = c.gtk_flow_box_new().?;
    c.gtk_flow_box_set_selection_mode(@ptrCast(grid), c.GTK_SELECTION_NONE);
    c.gtk_flow_box_set_max_children_per_line(@ptrCast(grid), 6);
    c.gtk_flow_box_set_min_children_per_line(@ptrCast(grid), 6);
    c.gtk_flow_box_set_homogeneous(@ptrCast(grid), 1);
    for (engine.Container.icons) |name| {
        const iname = core.fmtZ("iris-{s}-symbolic", .{name});
        defer core.gpa.free(iname);
        const btn = c.gtk_button_new_from_icon_name(iname.ptr).?;
        ui.cls(btn, &.{ "flat", "iris-icon-choice" });
        if (std.mem.eql(u8, name, nc.chosen)) ui.cls(btn, &.{"selected"});
        const pick = core.gpa.create(IconPick) catch continue;
        pick.* = .{ .nc = nc, .name = name, .button = btn };
        _ = core.on(btn, "clicked", pick, picked);
        nc.buttons.append(core.gpa, btn) catch {};
        c.gtk_flow_box_append(@ptrCast(grid), btn);
    }
    ui.append(v, grid);
    c.adw_alert_dialog_set_extra_child(ad, v);
    c.adw_alert_dialog_add_response(ad, "cancel", "Cancel");
    c.adw_alert_dialog_add_response(ad, "add", "Add");
    c.adw_alert_dialog_set_response_appearance(ad, "add", c.ADW_RESPONSE_SUGGESTED);
    c.adw_alert_dialog_set_default_response(ad, "add");
    c.adw_alert_dialog_set_close_response(ad, "cancel");
    _ = core.on1(d, "response", nc, newResponse);
    c.adw_dialog_present(@ptrCast(d), b.window);
    _ = c.gtk_widget_grab_focus(entry);
}

fn picked(p: *IconPick) void {
    p.nc.chosen = p.name;
    for (p.nc.buttons.items) |o| c.gtk_widget_remove_css_class(o, "selected");
    c.gtk_widget_add_css_class(p.button, "selected");
}

fn newResponse(nc: *NewContainer, r: ?*anyopaque) void {
    if (!std.mem.eql(u8, core.str(core.cast(?[*:0]const u8, r)), "add")) return;
    const name = std.mem.trim(u8, ui.text(nc.entry), " ");
    if (name.len == 0) return;
    const k = engine.Containers.add(name, nc.chosen);
    _ = nc.b.newTab(.{ .container = k.id });
}

fn askRemove(a: *Act) void {
    const b = a.b;
    b.closeMenu();
    const d = c.adw_alert_dialog_new("Remove a Container", "Its tabs close, and its cookies, sign-ins and site data are deleted.").?;
    const ad: *c.AdwAlertDialog = @ptrCast(d);
    c.adw_alert_dialog_add_response(ad, "cancel", "Cancel");
    for (engine.Containers.list.items) |k| {
        const id = core.z(k.id);
        defer core.gpa.free(id);
        const name = core.z(k.name);
        defer core.gpa.free(name);
        c.adw_alert_dialog_add_response(ad, id.ptr, name.ptr);
        c.adw_alert_dialog_set_response_appearance(ad, id.ptr, c.ADW_RESPONSE_DESTRUCTIVE);
    }
    c.adw_alert_dialog_set_close_response(ad, "cancel");
    _ = core.on1(d, "response", b, removeResponse);
    c.adw_dialog_present(@ptrCast(d), b.window);
}

fn removeResponse(b: *Browser, r: ?*anyopaque) void {
    const id = core.str(core.cast(?[*:0]const u8, r));
    if (id.len == 0 or std.mem.eql(u8, id, "cancel")) return;
    b.app.removeContainer(id);
}

// ---------------------------------------------------------------- shields

/// the shield for this site, and for everywhere
pub fn showShields(b: *Browser) void {
    const m = ui.box(true, 2);
    const host = if (b.current) |t| search.host(t.url.get()) else null;
    defer if (host) |h| core.gpa.free(h);
    const site: ?[]const u8 = if (host) |h| search.site(h) else null;
    const title = ui.label("Iris Shields", &.{"iris-title"});
    c.gtk_label_set_xalign(@ptrCast(title), 0);
    c.gtk_widget_set_margin_start(title, 12);
    c.gtk_widget_set_margin_top(title, 6);
    ui.append(m, title);
    ui.append(m, note("Ads and trackers are stopped inside the engine, before a request leaves the computer, as in Brave. Cookies never go to other sites."));
    const s = store.SettingsStore.get();
    if (site) |st| if (s.shields) {
        const on = shields.onFor(st);
        const text = core.fmt("{s} for {s}", .{ if (on) "On" else "Off", st });
        defer core.gpa.free(text);
        ui.append(m, actRow(b, .{ .icon = if (on) "security-high-symbolic" else "security-low-symbolic" }, text, if (on) "Turn off" else "Turn on", null, st, toggleSite));
    };
    ui.append(m, actRow(b, .{ .icon = if (s.shields) "security-high-symbolic" else "security-low-symbolic" }, if (s.shields) "On everywhere" else "Off everywhere", if (s.shields) "Turn off" else "Turn on", null, "", toggleAll));
    if (s.shields) {
        ui.append(m, ui.separator());
        for ([_]rules.Level{ .moderate, .aggressive, .ultra }) |l| {
            const r = actRow(b, if (l == s.shieldLevel) .{ .icon = "object-select-symbolic" } else .none, l.title(), l.hint(), null, @tagName(l), setLevel);
            if (l == s.shieldLevel) ui.cls(r, &.{"selected"});
            ui.append(m, r);
        }
        ui.append(m, note(switch (s.shieldLevel) {
            .moderate => "Ads and trackers from other sites (EasyList, EasyPrivacy). A site's own requests always load.",
            .aggressive => "Also a site's own ads and trackers, uBlock Origin's filters, and the empty boxes ads leave.",
            .ultra => "Also cookie notices, newsletter and sign-up pop-ups and other annoyances. uBlock's fixes for broken sites stay on.",
        }));
        if (!shields.Shields.shared().ready()) ui.append(m, note("Getting the block list ready (the first start takes a moment)\u{2026}"));
    }
    b.openMenu(m, b.stage.bounds(b.shieldButton) orelse b.addressFrame(), 320, true);
}

fn toggleSite(a: *Act) void {
    store.SettingsStore.toggleSite(a.s);
    a.b.closeMenu();
    if (a.b.current) |t| {
        t.reload();
        a.b.tabChanged(t);
    }
}

fn toggleAll(a: *Act) void {
    const s = store.SettingsStore.get();
    s.shields = !s.shields;
    store.SettingsStore.save();
    a.b.closeMenu();
    a.b.app.shieldsChanged();
}

fn setLevel(a: *Act) void {
    a.b.closeMenu();
    const l = std.meta.stringToEnum(rules.Level, a.s) orelse return;
    const s = store.SettingsStore.get();
    if (l == s.shieldLevel) return;
    s.shieldLevel = l;
    store.SettingsStore.save();
    shields.Shields.shared().levelChanged();
    const msg = core.fmt("Shields: {s}. Pages pick it up as they load.", .{l.title()});
    defer core.gpa.free(msg);
    a.b.toast(msg);
}

// ---------------------------------------------------------------- a tab's menu

/// what a tab's pill offers on a right click
pub fn tabMenu(b: *Browser, t: *Tab) void {
    const m = ui.box(true, 0);
    ui.append(m, actRow(b, .{ .icon = "view-refresh-symbolic" }, "Reload", null, t, "", reloadTab));
    ui.append(m, actRow(b, .{ .icon = "edit-copy-symbolic" }, "Duplicate", null, t, "", duplicate));
    ui.append(m, ui.separator());
    if (t.url.get().len > 0) for (engine.Containers.list.items) |k| {
        if (t.container != null and std.mem.eql(u8, t.container.?, k.id)) continue;
        const text = core.fmt("Open in {s}", .{k.name});
        defer core.gpa.free(text);
        ui.append(m, actRow(b, containerLead(k), text, null, t, k.id, pageIn));
    };
    ui.append(m, ui.separator());
    ui.append(m, actRow(b, .{ .icon = "window-close-symbolic" }, "Close Other Tabs", null, t, "", closeOthers));
    ui.append(m, actRow(b, .{ .icon = "window-close-symbolic" }, "Close Tab", "Ctrl+W", t, "", closeTab));
    b.openMenu(m, t.pillItem.frame.rect(), 240, false);
}

fn reloadTab(a: *Act) void {
    a.b.closeMenu();
    a.t.?.reload();
}
fn duplicate(a: *Act) void {
    a.b.closeMenu();
    const t = a.t.?;
    _ = a.b.newTab(.{ .url = t.url.get(), .container = t.container, .after = t });
}
fn closeOthers(a: *Act) void {
    a.b.closeMenu();
    var i: usize = 0;
    while (i < a.b.tabs.items.len) {
        const o = a.b.tabs.items[i];
        if (o != a.t.?) a.b.close(o) else i += 1;
    }
}
fn closeTab(a: *Act) void {
    a.b.closeMenu();
    a.b.close(a.t.?);
}

// ---------------------------------------------------------------- right click in a page

/// where a point of a page is, in the stage
fn pagePoint(b: *Browser, t: *Tab, x: f64, y: f64) [2]f64 {
    const p = t.page orelse return .{ b.card.midX(), b.card.midY() };
    var in = G.gpoint(x, y);
    var out = std.mem.zeroes(c.graphene_point_t);
    if (c.gtk_widget_compute_point(p.widget, b.stage.widget, &in, &out) == 0) return .{ b.card.midX(), b.card.midY() };
    return .{ out.x, out.y };
}

/// Iris's own menu on a right click in a page
pub fn contextMenu(b: *Browser, t: *Tab, menu: *c.WebKitContextMenu, hit: *c.WebKitHitTestResult) void {
    var px: c_int = 0;
    var py: c_int = 0;
    _ = c.webkit_context_menu_get_position(menu, &px, &py);
    const at = pagePoint(b, t, @floatFromInt(px), @floatFromInt(py));
    const link: ?[]const u8 = if (c.webkit_hit_test_result_context_is_link(hit) != 0) core.str(c.webkit_hit_test_result_get_link_uri(hit)) else null;
    const image: ?[]const u8 = if (c.webkit_hit_test_result_context_is_image(hit) != 0) core.str(c.webkit_hit_test_result_get_image_uri(hit)) else null;
    const media: ?[]const u8 = if (c.webkit_hit_test_result_context_is_media(hit) != 0) core.str(c.webkit_hit_test_result_get_media_uri(hit)) else null;
    const editable = c.webkit_hit_test_result_context_is_editable(hit) != 0;
    const selection = c.webkit_hit_test_result_context_is_selection(hit) != 0;
    const m = ui.box(true, 0);
    if (link) |l| if (!std.mem.startsWith(u8, l, "javascript:")) {
        ui.append(m, actRow(b, .{ .icon = "tab-new-symbolic" }, "Open Link in New Tab", null, t, l, openBackground));
        for (engine.Containers.list.items) |k| {
            if (t.container != null and std.mem.eql(u8, t.container.?, k.id)) continue;
            const text = core.fmt("Open Link in {s}", .{k.name});
            defer core.gpa.free(text);
            const both = core.fmt("{s}\n{s}", .{ k.id, l });
            defer core.gpa.free(both);
            ui.append(m, actRow(b, containerLead(k), text, null, t, both, openLinkIn));
        }
        ui.append(m, actRow(b, .{ .icon = "edit-copy-symbolic" }, "Copy Link", null, t, l, copyText));
        ui.append(m, actRow(b, .{ .icon = "folder-download-symbolic" }, "Download Link", null, t, l, save));
    };
    if (image) |img| {
        if (c.gtk_widget_get_first_child(m) != null) ui.append(m, ui.separator());
        ui.append(m, actRow(b, .{ .icon = "image-x-generic-symbolic" }, "Open Image in New Tab", null, t, img, openBackground));
        ui.append(m, actRow(b, .{ .icon = "edit-copy-symbolic" }, "Copy Image Address", null, t, img, copyText));
        ui.append(m, actRow(b, .{ .icon = "folder-download-symbolic" }, "Save Image", null, t, img, save));
    }
    if (media) |md| if (image == null) {
        if (c.gtk_widget_get_first_child(m) != null) ui.append(m, ui.separator());
        ui.append(m, actRow(b, .{ .icon = "edit-copy-symbolic" }, "Copy Video Address", null, t, md, copyText));
        ui.append(m, actRow(b, .{ .icon = "folder-download-symbolic" }, "Save Video", null, t, md, save));
    };
    if (editable) {
        if (c.gtk_widget_get_first_child(m) != null) ui.append(m, ui.separator());
        ui.append(m, actRow(b, .{ .icon = "edit-cut-symbolic" }, "Cut", "Ctrl+X", t, c.WEBKIT_EDITING_COMMAND_CUT, editCmd));
        ui.append(m, actRow(b, .{ .icon = "edit-copy-symbolic" }, "Copy", "Ctrl+C", t, c.WEBKIT_EDITING_COMMAND_COPY, editCmd));
        ui.append(m, actRow(b, .{ .icon = "edit-paste-symbolic" }, "Paste", "Ctrl+V", t, c.WEBKIT_EDITING_COMMAND_PASTE, editCmd));
        ui.append(m, actRow(b, .{ .icon = "edit-select-all-symbolic" }, "Select All", "Ctrl+A", t, c.WEBKIT_EDITING_COMMAND_SELECT_ALL, editCmd));
    } else if (selection) {
        if (c.gtk_widget_get_first_child(m) != null) ui.append(m, ui.separator());
        ui.append(m, actRow(b, .{ .icon = "edit-copy-symbolic" }, "Copy", "Ctrl+C", t, c.WEBKIT_EDITING_COMMAND_COPY, editCmd));
        ui.append(m, actRow(b, .{ .icon = "system-search-symbolic" }, "Ask Google AI Mode", null, t, "", askAI));
    }
    if (link == null and image == null and media == null and !editable and !selection) {
        ui.append(m, actRow(b, .{ .icon = "go-previous-symbolic" }, "Back", "Alt+\u{2190}", t, "", goBack));
        ui.append(m, actRow(b, .{ .icon = "go-next-symbolic" }, "Forward", "Alt+\u{2192}", t, "", goForward));
        ui.append(m, actRow(b, .{ .icon = "view-refresh-symbolic" }, "Reload", "Ctrl+R", t, "", reloadTab));
        ui.append(m, actRow(b, .{ .icon = "edit-select-all-symbolic" }, "Select All", "Ctrl+A", t, c.WEBKIT_EDITING_COMMAND_SELECT_ALL, editCmd));
    }
    b.openMenu(m, .{ .x = at[0], .y = at[1] - 8 }, 250, false);
}

fn openBackground(a: *Act) void {
    a.b.closeMenu();
    a.b.openInBackground(a.s, a.t.?);
}

fn openLinkIn(a: *Act) void {
    a.b.closeMenu();
    const nl = std.mem.indexOfScalar(u8, a.s, '\n') orelse return;
    _ = a.b.newTab(.{ .url = a.s[nl + 1 ..], .container = a.s[0..nl], .after = a.t });
}

fn copyText(a: *Act) void {
    a.b.closeMenu();
    const z = core.z(a.s);
    defer core.gpa.free(z);
    c.gdk_clipboard_set_text(c.gtk_widget_get_clipboard(a.b.window), z.ptr);
}

fn save(a: *Act) void {
    a.b.closeMenu();
    const w = a.t.?.web orelse return;
    const z = core.z(a.s);
    defer core.gpa.free(z);
    if (c.webkit_web_view_download_uri(w, z.ptr)) |d| core.unref(d);
}

fn editCmd(a: *Act) void {
    a.b.closeMenu();
    const w = a.t.?.web orelse return;
    const z = core.z(a.s);
    defer core.gpa.free(z);
    c.webkit_web_view_execute_editing_command(w, z.ptr);
}

fn goBack(a: *Act) void {
    a.b.closeMenu();
    a.t.?.back();
}
fn goForward(a: *Act) void {
    a.b.closeMenu();
    a.t.?.forward();
}

fn askAI(a: *Act) void {
    a.b.closeMenu();
    const job = Act.make(a.b, a.t, "");
    a.t.?.run("window.getSelection().toString()", job, struct {
        fn done(ctx: *anyopaque, s: ?[]const u8) void {
            const j: *Act = core.cast(*Act, ctx);
            defer {
                core.gpa.free(j.s);
                core.gpa.destroy(j);
            }
            const text = s orelse return;
            if (text.len == 0) return;
            const u = search.aiURL(text);
            defer core.gpa.free(u);
            _ = j.b.newTab(.{ .url = u, .container = j.t.?.container, .after = j.t });
        }
    }.done);
}

// ---------------------------------------------------------------- a page's own pop-ups

const OptAct = struct { menu: *c.WebKitOptionMenu, index: c.guint, b: *Browser };

/// the <select> list showing, if one is
var openOption: ?*c.WebKitOptionMenu = null;

/// the menu went away: a <select> hears it closed (after a choice too)
pub fn menuClosed() void {
    const m = openOption orelse return;
    openOption = null;
    c.webkit_option_menu_close(m);
    core.unref(m);
}

/// a <select>'s list, as a glass menu where the page put it
pub fn optionMenu(b: *Browser, t: *Tab, menu: *c.WebKitOptionMenu, rect: ?*c.WebKitRectangle) void {
    _ = c.g_object_ref(menu);
    const m = ui.box(true, 0);
    const n = c.webkit_option_menu_get_n_items(menu);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const item = c.webkit_option_menu_get_item(menu, i);
        const label = core.str(c.webkit_option_menu_item_get_label(item));
        if (c.webkit_option_menu_item_is_group_label(item) != 0) {
            ui.append(m, heading(label));
            continue;
        }
        const o = core.gpa.create(OptAct) catch continue;
        o.* = .{ .menu = menu, .index = i, .b = b };
        const r = ui.row(if (c.webkit_option_menu_item_is_selected(item) != 0) .{ .icon = "object-select-symbolic" } else .none, label, null, o, optionChosen);
        c.gtk_widget_set_sensitive(r, c.webkit_option_menu_item_is_enabled(item));
        ui.append(m, r);
    }
    var at = Rect{ .x = b.card.midX(), .y = b.card.midY() };
    if (rect) |r| {
        const p = pagePoint(b, t, @floatFromInt(r.x), @floatFromInt(r.y));
        at = .{ .x = p[0], .y = p[1], .w = @floatFromInt(r.width), .h = @floatFromInt(r.height) };
    }
    b.openMenu(m, at, @max(at.w, 200), false);
    openOption = menu;
    // the page can close it too (it navigated, the field went away)
    _ = core.on(menu, "close", b, optionClosed);
}

fn optionChosen(o: *OptAct) void {
    c.webkit_option_menu_activate_item(o.menu, o.index);
    o.b.closeMenu();
}

fn optionClosed(b: *Browser) void {
    if (openOption != null) b.closeMenu();
}

const DialogAct = struct { d: *c.WebKitScriptDialog, entry: ?Widget = null };

/// alert(), confirm() and prompt(), as Adwaita's dialogs
pub fn scriptDialog(b: *Browser, t: *Tab, d: *c.WebKitScriptDialog) void {
    const kind = c.webkit_script_dialog_get_dialog_type(d);
    const host = search.display(t.url.get());
    defer core.gpa.free(host);
    const title = core.fmtZ("{s} says", .{if (host.len > 0) host else "This page"});
    defer core.gpa.free(title);
    const dlg = c.adw_alert_dialog_new(title.ptr, c.webkit_script_dialog_get_message(d)).?;
    const ad: *c.AdwAlertDialog = @ptrCast(dlg);
    const act = core.gpa.create(DialogAct) catch return;
    act.* = .{ .d = c.webkit_script_dialog_ref(d).? };
    switch (kind) {
        c.WEBKIT_SCRIPT_DIALOG_ALERT => c.adw_alert_dialog_add_response(ad, "ok", "OK"),
        c.WEBKIT_SCRIPT_DIALOG_PROMPT => {
            const e = c.gtk_entry_new().?;
            ui.setText(e, core.str(c.webkit_script_dialog_prompt_get_default_text(d)));
            c.gtk_entry_set_activates_default(@ptrCast(e), 1);
            c.adw_alert_dialog_set_extra_child(ad, e);
            act.entry = e;
            c.adw_alert_dialog_add_response(ad, "cancel", "Cancel");
            c.adw_alert_dialog_add_response(ad, "ok", "OK");
        },
        c.WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM => {
            c.adw_alert_dialog_add_response(ad, "cancel", "Stay");
            c.adw_alert_dialog_add_response(ad, "ok", "Leave");
        },
        else => {
            c.adw_alert_dialog_add_response(ad, "cancel", "Cancel");
            c.adw_alert_dialog_add_response(ad, "ok", "OK");
        },
    }
    c.adw_alert_dialog_set_default_response(ad, "ok");
    c.adw_alert_dialog_set_close_response(ad, if (kind == c.WEBKIT_SCRIPT_DIALOG_ALERT) "ok" else "cancel");
    _ = core.on1(dlg, "response", act, dialogResponse);
    c.adw_dialog_present(@ptrCast(dlg), b.window);
}

fn dialogResponse(a: *DialogAct, r: ?*anyopaque) void {
    const ok = std.mem.eql(u8, core.str(core.cast(?[*:0]const u8, r)), "ok");
    const kind = c.webkit_script_dialog_get_dialog_type(a.d);
    if (kind == c.WEBKIT_SCRIPT_DIALOG_CONFIRM or kind == c.WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM) c.webkit_script_dialog_confirm_set_confirmed(a.d, @intFromBool(ok));
    if (kind == c.WEBKIT_SCRIPT_DIALOG_PROMPT and ok) if (a.entry) |e| {
        const z = core.z(ui.text(e));
        defer core.gpa.free(z);
        c.webkit_script_dialog_prompt_set_text(a.d, z.ptr);
    };
    c.webkit_script_dialog_close(a.d);
    c.webkit_script_dialog_unref(a.d);
    core.gpa.destroy(a);
}

/// a page's file field: the desktop's file chooser (the portal in Flatpak)
pub fn fileChooser(b: *Browser, t: *Tab, r: *c.WebKitFileChooserRequest) void {
    if (t.sandboxed) {
        // the sandbox reads no files of yours
        c.webkit_file_chooser_request_cancel(r);
        return b.toast("Files can't be uploaded to sites in the sandbox");
    }
    _ = c.g_object_ref(r);
    const fd = c.gtk_file_dialog_new();
    if (c.webkit_file_chooser_request_get_select_multiple(r) != 0) {
        c.gtk_file_dialog_open_multiple(fd, b.win(), null, filesChosen, r);
    } else c.gtk_file_dialog_open(fd, b.win(), null, fileChosen, r);
}

fn fileChosen(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
    const r: *c.WebKitFileChooserRequest = core.cast(*c.WebKitFileChooserRequest, d);
    defer core.unref(r);
    defer core.unref(o);
    const f = c.gtk_file_dialog_open_finish(@ptrCast(o), res, null) orelse return c.webkit_file_chooser_request_cancel(r);
    defer core.unref(f);
    const path = c.g_file_get_path(f) orelse return c.webkit_file_chooser_request_cancel(r);
    defer c.g_free(path);
    var list = [_]?[*:0]const u8{ path, null };
    c.webkit_file_chooser_request_select_files(r, @ptrCast(&list));
}

fn filesChosen(o: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
    const r: *c.WebKitFileChooserRequest = core.cast(*c.WebKitFileChooserRequest, d);
    defer core.unref(r);
    defer core.unref(o);
    const files = c.gtk_file_dialog_open_multiple_finish(@ptrCast(o), res, null) orelse return c.webkit_file_chooser_request_cancel(r);
    defer core.unref(files);
    const n = c.g_list_model_get_n_items(files);
    var paths: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (paths.items) |p| if (p) |x| c.g_free(@constCast(@ptrCast(x)));
        paths.deinit(core.gpa);
    }
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const f = c.g_list_model_get_item(files, i) orelse continue;
        defer core.unref(f);
        if (c.g_file_get_path(@ptrCast(f))) |p| paths.append(core.gpa, p) catch {};
    }
    paths.append(core.gpa, null) catch {};
    c.webkit_file_chooser_request_select_files(r, @ptrCast(paths.items.ptr));
}

// ---------------------------------------------------------------- permissions

const PermAct = struct { req: *c.WebKitPermissionRequest, answered: bool = false, b: *Browser };

pub fn permission(b: *Browser, t: *Tab, req: *c.WebKitPermissionRequest) void {
    // nothing of your computer for a site in the sandbox
    if (t.sandboxed) return c.webkit_permission_request_deny(req);
    const name = core.typeName(req);
    const what: []const u8 = if (std.mem.eql(u8, name, "WebKitUserMediaPermissionRequest"))
        "use your camera or microphone"
    else if (std.mem.eql(u8, name, "WebKitGeolocationPermissionRequest"))
        "know your location"
    else if (std.mem.eql(u8, name, "WebKitNotificationPermissionRequest"))
        "show notifications"
    else if (std.mem.eql(u8, name, "WebKitClipboardPermissionRequest"))
        "read your clipboard"
    else if (std.mem.eql(u8, name, "WebKitPointerLockPermissionRequest"))
        return c.webkit_permission_request_allow(req)
    else
        "use a feature of your computer";
    const p = core.gpa.create(PermAct) catch return c.webkit_permission_request_deny(req);
    p.* = .{ .req = core.ref(req), .b = b };
    const site = search.display(t.url.get());
    defer core.gpa.free(site);
    const msg = core.fmt("{s} wants to {s}", .{ if (site.len > 0) site else "This page", what });
    defer core.gpa.free(msg);
    b.toastAction(msg, "Allow", p, allow);
    _ = core.after(6100, p, expire);
}

fn allow(p: *PermAct) void {
    if (p.answered) return;
    p.answered = true;
    c.webkit_permission_request_allow(p.req);
}

/// not answered in time: no
fn expire(p: *PermAct) void {
    if (!p.answered) c.webkit_permission_request_deny(p.req);
    core.unref(p.req);
    core.gpa.destroy(p);
}
