//! The Stage is Iris's window content: one GTK widget (a GObject subclass
//! made here, in Zig) that lays out every piece of the browser and draws them
//! in layers, so the glass of each layer can bend what lies behind it:
//!
//!   back     the window's own tint (and the desktop, blurred by the compositor)
//!   page     the pages (WPE WebKit's buffers, as textures)
//!   chrome   tabs, address and buttons: glass over the back and the pages
//!   overlay  menus, suggestions, downloads, find, notices: glass over all
//!
//! Every piece moves on springs: frames, fades, presses and hovers.
const std = @import("std");
const core = @import("core.zig");
const G = @import("glass.zig");
const c = core.c;
const Rect = core.Rect;
const Spring = core.Spring;
const SpringRect = core.SpringRect;
const Widget = core.Widget;

pub const Layer = enum(u8) { back = 0, page, chrome, overlay };

/// a drawing hook: what to draw under or over an item
pub const DrawHook = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque, G.Snap, Rect) void,
};

/// a sub-widget drawn on its own glass (a button inside a group)
pub const Part = struct {
    w: Widget,
    glass: G.Glass,
    hover: Spring = Spring.init(0, 420, 0),
    press: Spring = Spring.init(0, 900, 0),
    /// glass shows only when hovered or pressed (plain buttons)
    onlyActive: bool,
};

pub const Item = struct {
    w: Widget,
    layer: Layer,
    frame: SpringRect = SpringRect.init(420, 0.12),
    glass: ?G.Glass = null,
    parts: std.ArrayList(Part) = .empty,
    alpha: Spring = Spring.init(1, 260, 0),
    scale: Spring = Spring.init(1, 520, 0.28),
    hover: Spring = Spring.init(0, 420, 0),
    press: Spring = Spring.init(0, 900, 0),
    /// a page's rounded clip
    clip: ?f64 = null,
    /// shown at all (an item fading out stays until its alpha reaches 0)
    shown: bool = true,
    dying: bool = false,
    onGone: ?DrawlessHook = null,
    behind: ?DrawHook = null,
    front: ?DrawHook = null,
    /// the glass shows only while hovered (tabs that are not selected)
    glassFollowsHover: bool = false,
    /// reads the widget's hover and press for its glass
    reactive: bool = false,
    animateFrames: bool = true,

    fn moving(it: *Item, dt: f64) bool {
        var m = if (it.animateFrames) it.frame.step(dt) else false;
        m = it.alpha.step(dt) or m;
        m = it.scale.step(dt) or m;
        m = it.hover.step(dt) or m;
        m = it.press.step(dt) or m;
        for (it.parts.items) |*p| {
            m = p.hover.step(dt) or m;
            m = p.press.step(dt) or m;
        }
        return m;
    }
};

/// a callback with no drawing (after an item is gone)
pub const DrawlessHook = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque) void,
};

// ------------------------------------------------------------ the GType

var parent_dispose: ?*const fn ([*c]c.GObject) callconv(.c) void = null;
var stage_type: c.GType = 0;

fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    const parent: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    parent_dispose = parent.dispose;
    oc.dispose = dispose;
    const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
    wc.snapshot = snapshotCB;
    wc.size_allocate = allocateCB;
    wc.measure = measureCB;
    c.gtk_widget_class_set_css_name(wc, "iris-stage");
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    if (Stage.of(o)) |st| st.releaseChildren();
    if (parent_dispose) |f| f(o);
}

fn snapshotCB(w: [*c]c.GtkWidget, s: ?*c.GtkSnapshot) callconv(.c) void {
    if (Stage.of(w)) |st| if (s) |sn| st.snapshot(sn);
}

fn allocateCB(w: [*c]c.GtkWidget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    if (Stage.of(w)) |st| st.allocate(@floatFromInt(width), @floatFromInt(height));
}

fn measureCB(_: [*c]c.GtkWidget, orientation: c.GtkOrientation, _: c_int, minimum: [*c]c_int, natural: [*c]c_int, minB: [*c]c_int, natB: [*c]c_int) callconv(.c) void {
    const horiz = orientation == c.GTK_ORIENTATION_HORIZONTAL;
    if (minimum != null) minimum.* = if (horiz) 420 else 300;
    if (natural != null) natural.* = if (horiz) 1280 else 820;
    if (minB != null) minB.* = -1;
    if (natB != null) natB.* = -1;
}

fn stageType() c.GType {
    if (stage_type == 0) {
        var q: c.GTypeQuery = undefined;
        c.g_type_query(c.gtk_widget_get_type(), &q);
        var info = std.mem.zeroes(c.GTypeInfo);
        info.class_size = @intCast(q.class_size);
        info.instance_size = @intCast(q.instance_size);
        info.class_init = classInit;
        stage_type = c.g_type_register_static(c.gtk_widget_get_type(), "IrisStage", &info, 0);
    }
    return stage_type;
}

// ------------------------------------------------------------ the stage

pub const Stage = struct {
    widget: Widget,
    items: std.ArrayList(*Item) = .empty,
    width: f64 = 0,
    height: f64 = 0,
    /// the browser places every item for a size
    layout: ?LayoutHook = null,
    /// the back layer
    background: ?DrawHook = null,
    /// drawn into the scene after the pages (the page's colour reaching up)
    afterPages: ?DrawHook = null,
    pointer: ?[2]f64 = null,
    /// the height of the chrome, kept as one picture while nothing in it changes
    chromeHeight: f64 = 0,
    /// the chrome is drawn live (no picture) while this says so (typing)
    chromeLive: ?LiveHook = null,
    chromeDirty: bool = true,
    chromeTex: ?*c.GdkTexture = null,
    chromeTexRect: Rect = .{},
    chromeTexKey: [3]f64 = .{ 0, 0, 0 },
    inChrome: bool = false,
    animations: bool = true,
    ticking: bool = false,
    lastFrame: i64 = 0,
    laidOut: bool = false,

    pub const LayoutHook = struct { ctx: *anyopaque, f: *const fn (*anyopaque, f64, f64) void };
    pub const LiveHook = struct { ctx: *anyopaque, f: *const fn (*anyopaque) bool };

    pub fn of(p: anytype) ?*Stage {
        return core.getData(*Stage, p, "iris-stage");
    }

    pub fn create() *Stage {
        const st = core.gpa.create(Stage) catch @panic("oom");
        const w: Widget = @ptrCast(@alignCast(c.g_object_new(stageType(), null)));
        st.* = .{ .widget = w };
        core.setData(w, "iris-stage", st);
        c.gtk_widget_set_focusable(w, 0);
        c.gtk_widget_set_overflow(w, c.GTK_OVERFLOW_HIDDEN);
        // the pointer, for the light it casts on glass
        const motion = c.gtk_event_controller_motion_new();
        c.gtk_event_controller_set_propagation_phase(motion, c.GTK_PHASE_CAPTURE);
        _ = core.onXY(motion, "motion", st, motionCB);
        _ = core.on(motion, "leave", st, leaveCB);
        c.gtk_widget_add_controller(w, motion);
        st.animations = core.getBool(c.gtk_settings_get_default(), "gtk-enable-animations");
        return st;
    }

    fn motionCB(st: *Stage, x: f64, y: f64) void {
        st.pointer = .{ x, y };
        if (y < st.chromeHeight + 8 or st.inChrome) {
            st.inChrome = y < st.chromeHeight + 8;
            st.dirtyChrome();
        }
        for (st.items.items) |it| {
            var lit = it.reactive and it.hover.value > 0.01;
            for (it.parts.items) |p| lit = lit or p.hover.value > 0.01;
            if (lit) {
                c.gtk_widget_queue_draw(st.widget);
                break;
            }
        }
    }

    fn leaveCB(st: *Stage) void {
        st.pointer = null;
        st.inChrome = false;
        st.dirtyChrome();
        st.kick();
    }

    fn releaseChildren(st: *Stage) void {
        for (st.items.items) |it| c.gtk_widget_unparent(it.w);
        st.items.clearRetainingCapacity();
    }

    pub fn add(st: *Stage, w: Widget, layer: Layer, glass: ?G.Glass, reactive: bool) *Item {
        const it = core.gpa.create(Item) catch @panic("oom");
        it.* = .{ .w = w, .layer = layer, .glass = glass, .reactive = reactive };
        st.items.append(core.gpa, it) catch @panic("oom");
        c.gtk_widget_set_parent(w, st.widget);
        if (reactive) st.watch(w);
        st.restack();
        return it;
    }

    pub fn part(st: *Stage, it: *Item, w: Widget, g: G.Glass, onlyActive: bool) void {
        it.parts.append(core.gpa, .{ .w = w, .glass = g, .onlyActive = onlyActive }) catch @panic("oom");
        st.watch(w);
    }

    pub fn removeParts(it: *Item, w: Widget) void {
        var i: usize = 0;
        while (i < it.parts.items.len) {
            if (it.parts.items[i].w == w) _ = it.parts.orderedRemove(i) else i += 1;
        }
    }

    fn watch(st: *Stage, w: Widget) void {
        _ = core.on1(w, "state-flags-changed", st, stateCB);
    }

    fn stateCB(st: *Stage, _: ?*anyopaque) void {
        st.kick();
    }

    /// fades an item out (and lets it go); then runs once it is gone
    pub fn remove(st: *Stage, it: *Item, animated: bool, then: ?DrawlessHook) void {
        if (!animated or !st.animations) {
            st.drop(it);
            if (then) |h| h.f(h.ctx);
            return;
        }
        it.dying = true;
        it.onGone = then;
        it.alpha.target = 0;
        it.scale.target = 0.96;
        st.kick();
    }

    fn drop(st: *Stage, it: *Item) void {
        for (st.items.items, 0..) |x, i| if (x == it) {
            _ = st.items.orderedRemove(i);
            c.gtk_widget_unparent(it.w);
            it.parts.deinit(core.gpa);
            core.gpa.destroy(it);
            return;
        };
    }

    fn lessThan(_: void, a: *Item, b: *Item) bool {
        return @intFromEnum(a.layer) < @intFromEnum(b.layer);
    }

    /// the order GTK picks and draws children in: layer by layer
    pub fn restack(st: *Stage) void {
        std.sort.insertion(*Item, st.items.items, {}, lessThan);
        for (st.items.items) |it| c.gtk_widget_insert_before(it.w, st.widget, null);
    }

    pub fn raise(st: *Stage, it: *Item) void {
        for (st.items.items, 0..) |x, i| if (x == it) {
            _ = st.items.orderedRemove(i);
            st.items.append(core.gpa, it) catch {};
            st.restack();
            return;
        };
    }

    /// shows or hides an item, fading
    pub fn show(st: *Stage, it: *Item, on: bool, animated: bool) void {
        it.shown = on;
        if (on) c.gtk_widget_set_child_visible(it.w, 1);
        if (animated and st.animations) {
            it.alpha.target = if (on) 1 else 0;
            if (on and it.alpha.value < 0.01) it.scale.value = if (it.layer == .overlay) 0.94 else 0.985;
            it.scale.target = 1;
        } else {
            it.alpha.snap(if (on) 1 else 0);
            it.scale.snap(1);
            if (!on) c.gtk_widget_set_child_visible(it.w, 0);
        }
        st.kick();
        c.gtk_widget_queue_allocate(st.widget);
    }

    pub fn place(st: *Stage, it: *Item, r: Rect, animate: bool) void {
        it.frame.go(r, animate and st.animations and st.laidOut);
        if (!it.frame.settled()) st.kick();
    }

    pub fn relayout(st: *Stage) void {
        c.gtk_widget_queue_allocate(st.widget);
    }

    /// something in the chrome changed: its picture is made again
    pub fn dirtyChrome(st: *Stage) void {
        st.chromeDirty = true;
        c.gtk_widget_queue_draw(st.widget);
    }

    /// renders a node to a texture on the GPU, aligned to the screen's
    /// pixels (at fractional scales too)
    pub fn renderTexture(st: *Stage, node: G.Node, r: Rect) ?struct { *c.GdkTexture, Rect } {
        const native = c.gtk_widget_get_native(st.widget) orelse return null;
        const renderer = c.gtk_native_get_renderer(native) orelse return null;
        const surface = c.gtk_native_get_surface(native) orelse return null;
        const s = c.gdk_surface_get_scale(surface);
        var sx: f64 = 0;
        var sy: f64 = 0;
        c.gtk_native_get_surface_transform(native, &sx, &sy);
        var o = std.mem.zeroes(c.graphene_point_t);
        var at = std.mem.zeroes(c.graphene_point_t);
        _ = c.gtk_widget_compute_point(st.widget, @ptrCast(@alignCast(native)), &o, &at);
        const dx = (@as(f64, at.x) + sx + r.x) * s;
        const dy = (@as(f64, at.y) + sy + r.y) * s;
        const fx = dx - @floor(dx);
        const fy = dy - @floor(dy);
        const sub = c.gtk_snapshot_new() orelse return null;
        var t = G.gpoint(fx, fy);
        c.gtk_snapshot_translate(sub, &t);
        c.gtk_snapshot_scale(sub, @floatCast(s), @floatCast(s));
        var back = G.gpoint(-r.x, -r.y);
        c.gtk_snapshot_translate(sub, &back);
        c.gtk_snapshot_append_node(sub, node);
        const scaled = c.gtk_snapshot_free_to_node(sub) orelse return null;
        defer c.gsk_render_node_unref(scaled);
        const pw = @ceil(r.w * s + fx);
        const ph = @ceil(r.h * s + fy);
        var vp = G.grect(.{ .w = pw, .h = ph });
        const tex = c.gsk_renderer_render_texture(renderer, scaled, &vp) orelse return null;
        return .{ tex, .{ .x = r.x - fx / s, .y = r.y - fy / s, .w = pw / s, .h = ph / s } };
    }

    pub fn kick(st: *Stage) void {
        st.chromeDirty = true;
        c.gtk_widget_queue_draw(st.widget);
        if (st.ticking) return;
        st.ticking = true;
        st.lastFrame = 0;
        _ = c.gtk_widget_add_tick_callback(st.widget, tickCB, st, null);
    }

    fn tickCB(_: [*c]c.GtkWidget, clock: ?*c.GdkFrameClock, d: ?*anyopaque) callconv(.c) c.gboolean {
        const st: *Stage = core.cast(*Stage, d);
        return @intFromBool(st.tick(c.gdk_frame_clock_get_frame_time(clock)));
    }

    fn tick(st: *Stage, now: i64) bool {
        const dt: f64 = if (st.lastFrame == 0) 1.0 / 60.0 else @min(1.0 / 20.0, @as(f64, @floatFromInt(now - st.lastFrame)) / 1_000_000.0);
        st.lastFrame = now;
        var moving = false;
        var framesMoved = false;
        for (st.items.items) |it| {
            st.readState(it);
            const before = it.frame.rect();
            if (it.moving(if (st.animations) dt else 10)) moving = true;
            if (!it.frame.rect().eql(before)) framesMoved = true;
        }
        // what has faded out goes
        var i: usize = 0;
        while (i < st.items.items.len) {
            const it = st.items.items[i];
            if (it.dying and it.alpha.value < 0.01) {
                const then = it.onGone;
                st.drop(it);
                if (then) |h| h.f(h.ctx);
                continue;
            }
            if (!it.shown and !it.dying and it.alpha.value < 0.01 and it.alpha.target == 0) c.gtk_widget_set_child_visible(it.w, 0);
            i += 1;
        }
        if (framesMoved) c.gtk_widget_queue_allocate(st.widget);
        c.gtk_widget_queue_draw(st.widget);
        if (!moving) st.ticking = false;
        return moving;
    }

    fn flags(w: Widget) struct { hover: bool, press: bool } {
        const f = c.gtk_widget_get_state_flags(w);
        return .{ .hover = f & c.GTK_STATE_FLAG_PRELIGHT != 0, .press = f & c.GTK_STATE_FLAG_ACTIVE != 0 };
    }

    fn readState(_: *Stage, it: *Item) void {
        if (it.reactive) {
            const f = flags(it.w);
            it.hover.target = if (f.hover) 1 else 0;
            it.press.target = if (f.press) 1 else 0;
        }
        for (it.parts.items) |*p| {
            const f = flags(p.w);
            p.hover.target = if (f.hover) 1 else 0;
            p.press.target = if (f.press) 1 else 0;
        }
    }

    fn allocate(st: *Stage, w: f64, h: f64) void {
        const resized = w != st.width or h != st.height;
        st.width = w;
        st.height = h;
        if (resized or !st.laidOut) {
            if (st.layout) |l| l.f(l.ctx, w, h);
            st.chromeDirty = true;
        }
        st.laidOut = true;
        for (st.items.items) |it| {
            if (c.gtk_widget_get_child_visible(it.w) == 0) continue;
            const r = it.frame.rect();
            var p = G.gpoint(r.x, r.y);
            const t = c.gsk_transform_translate(null, &p);
            c.gtk_widget_allocate(it.w, @intFromFloat(@max(0, @round(r.w))), @intFromFloat(@max(0, @round(r.h))), -1, t);
        }
    }

    /// where a widget inside the stage is, in the stage's units
    pub fn bounds(st: *Stage, w: Widget) ?Rect {
        var o = std.mem.zeroes(c.graphene_point_t);
        var out = std.mem.zeroes(c.graphene_point_t);
        if (c.gtk_widget_get_mapped(w) == 0 or c.gtk_widget_compute_point(w, st.widget, &o, &out) == 0) return null;
        return .{ .x = out.x, .y = out.y, .w = @floatFromInt(c.gtk_widget_get_width(w)), .h = @floatFromInt(c.gtk_widget_get_height(w)) };
    }

    /// a page's picture as a node (for the colour reaching up from it)
    pub fn nodeOf(st: *Stage, it: *Item) ?G.Node {
        if (c.gtk_widget_get_child_visible(it.w) == 0) return null;
        const sub = c.gtk_snapshot_new() orelse return null;
        c.gtk_widget_snapshot_child(st.widget, it.w, sub);
        return c.gtk_snapshot_free_to_node(sub);
    }

    fn snapshot(st: *Stage, s: G.Snap) void {
        const sub = c.gtk_snapshot_new().?;
        if (st.background) |b| b.f(b.ctx, sub, .{ .w = st.width, .h = st.height });
        for (st.items.items) |it| if (@intFromEnum(it.layer) <= @intFromEnum(Layer.page)) st.draw(sub, it, null);
        if (st.afterPages) |a| a.f(a.ctx, sub, .{ .w = st.width, .h = st.height });
        const scene = c.gtk_snapshot_free_to_node(sub);
        if (scene) |sc| c.gtk_snapshot_append_node(s, sc);

        // the chrome: drawn live while it moves or you type in it, otherwise
        // kept as one picture made again only when something in it changes
        var chrome: ?G.Node = null;
        const key = [3]f64{ st.width, st.height, st.chromeHeight };
        const live = st.ticking or (if (st.chromeLive) |l| l.f(l.ctx) else false) or st.chromeHeight <= 0;
        if (!live and !st.chromeDirty and st.chromeTex != null and std.mem.eql(f64, &key, &st.chromeTexKey)) {
            var g = G.grect(st.chromeTexRect);
            chrome = c.gsk_texture_node_new(st.chromeTex, &g);
        } else {
            const sub2 = c.gtk_snapshot_new().?;
            for (st.items.items) |it| if (it.layer == .chrome) st.draw(sub2, it, scene);
            chrome = c.gtk_snapshot_free_to_node(sub2);
            if (chrome) |ch| {
                if (!live) {
                    if (st.renderTexture(ch, .{ .w = st.width, .h = st.chromeHeight })) |tr| {
                        core.unref(st.chromeTex);
                        st.chromeTex = tr[0];
                        st.chromeTexRect = tr[1];
                        st.chromeTexKey = key;
                        st.chromeDirty = false;
                        c.gsk_render_node_unref(ch);
                        var g = G.grect(tr[1]);
                        chrome = c.gsk_texture_node_new(tr[0], &g);
                    }
                } else st.chromeDirty = true;
            }
        }
        if (chrome) |ch| c.gtk_snapshot_append_node(s, ch);

        var anyOverlay = false;
        for (st.items.items) |it| if (it.layer == .overlay and c.gtk_widget_get_child_visible(it.w) != 0) {
            anyOverlay = true;
        };
        if (anyOverlay) {
            var nodes: [2]?*c.GskRenderNode = undefined;
            var n: c_uint = 0;
            if (scene) |sc| {
                nodes[n] = sc;
                n += 1;
            }
            if (chrome) |ch| {
                nodes[n] = ch;
                n += 1;
            }
            const all = c.gsk_container_node_new(@ptrCast(&nodes), n);
            for (st.items.items) |it| if (it.layer == .overlay) st.draw(s, it, all);
            if (all) |a| c.gsk_render_node_unref(a);
        }
        if (scene) |sc| c.gsk_render_node_unref(sc);
        if (chrome) |ch| c.gsk_render_node_unref(ch);
    }

    fn draw(st: *Stage, s: G.Snap, it: *Item, scene: ?G.Node) void {
        if (c.gtk_widget_get_child_visible(it.w) == 0 or it.alpha.value <= 0.003) return;
        const r = it.frame.rect();
        c.gtk_snapshot_save(s);
        const a = @min(1, @max(0, it.alpha.value));
        if (a < 0.999) c.gtk_snapshot_push_opacity(s, a);
        const k = it.scale.value * (1 - 0.03 * it.press.value);
        if (@abs(k - 1) > 0.0005) {
            var ctr = G.gpoint(r.midX(), r.midY());
            c.gtk_snapshot_translate(s, &ctr);
            c.gtk_snapshot_scale(s, @floatCast(k), @floatCast(k));
            var b = G.gpoint(-r.midX(), -r.midY());
            c.gtk_snapshot_translate(s, &b);
        }
        if (it.clip) |cl| {
            var rr = G.rrect(r, cl);
            c.gtk_snapshot_push_rounded_clip(s, &rr);
        }
        if (it.behind) |h| h.f(h.ctx, s, r);
        if (it.glass) |g0| {
            var g = g0;
            if (it.glassFollowsHover) g.amount *= @max(it.hover.value, it.press.value);
            G.glass(s, scene, r, g, .{ .pointer = st.pointer, .hover = it.hover.value, .press = it.press.value });
        }
        for (it.parts.items) |p| {
            const on = @max(p.hover.value, p.press.value);
            if (p.onlyActive and on < 0.004) continue;
            const b = st.bounds(p.w) orelse continue;
            var g = p.glass;
            if (p.onlyActive) g.amount *= on;
            G.glass(s, scene, b, g, .{ .pointer = st.pointer, .hover = p.hover.value, .press = p.press.value });
        }
        c.gtk_widget_snapshot_child(st.widget, it.w, s);
        if (it.front) |h| h.f(h.ctx, s, r);
        if (it.clip != null) c.gtk_snapshot_pop(s);
        if (a < 0.999) c.gtk_snapshot_pop(s);
        c.gtk_snapshot_restore(s);
    }
};
