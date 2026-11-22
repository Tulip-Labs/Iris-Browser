//! One Iris window: tabs, their pages and the glass chrome around them.
const std = @import("std");
const core = @import("core.zig");
const G = @import("glass.zig");
const ui = @import("ui.zig");
const search = @import("search.zig");
const store = @import("store.zig");
const engine = @import("engine.zig");
const shields = @import("shields.zig");
const stagez = @import("stage.zig");
const overlays = @import("overlays.zig");
const keys = @import("keys.zig");
const App = @import("app.zig").App;
const Tab = @import("tab.zig").Tab;
const c = core.c;
const Rect = core.Rect;
const RGBA = core.RGBA;
const Spring = core.Spring;
const Widget = core.Widget;
const Item = stagez.Item;

/// a small piece of work a button or row does later, with what it needs;
/// it lives as long as the widget it belongs to
pub const Act = struct {
    b: *Browser,
    t: ?*Tab = null,
    s: []u8 = &.{},
    p: ?*anyopaque = null,

    pub fn make(b: *Browser, t: ?*Tab, s: []const u8) *Act {
        const a = core.gpa.create(Act) catch @panic("oom");
        a.* = .{ .b = b, .t = t, .s = core.dupe(s) };
        return a;
    }

    fn free(d: ?*anyopaque) callconv(.c) void {
        const a: *Act = core.cast(*Act, d);
        core.gpa.free(a.s);
        core.gpa.destroy(a);
    }

    /// ties the act's life to a widget
    pub fn own(a: *Act, w: Widget) Widget {
        c.g_object_set_data_full(core.obj(w), "iris-act", a, free);
        return w;
    }
};

/// The liquid edge of a sliding glass pill: the side it travels towards
/// leads and the other follows, so the pill stretches in flight.
const LiquidSpan = struct {
    lo: Spring = Spring.init(0, 520, 0.18),
    hi: Spring = Spring.init(0, 520, 0.18),
    fresh: bool = true,

    fn go(s: *LiquidSpan, a: f64, b: f64, animate: bool) void {
        if (s.fresh or !animate) {
            s.lo.snap(a);
            s.hi.snap(b);
            s.fresh = false;
            return;
        }
        const right = a > s.lo.target;
        s.lo.stiffness = if (right) 260 else 620;
        s.hi.stiffness = if (right) 620 else 260;
        s.lo.damping = 2 * 0.82 * @sqrt(s.lo.stiffness);
        s.hi.damping = 2 * 0.82 * @sqrt(s.hi.stiffness);
        s.lo.target = a;
        s.hi.target = b;
    }

    fn step(s: *LiquidSpan, dt: f64) bool {
        const m = s.lo.step(dt);
        return s.hi.step(dt) or m;
    }
};

pub const Browser = struct {
    app: *App,
    window: Widget,
    stage: *stagez.Stage,
    tabs: std.ArrayList(*Tab) = .empty,
    current: ?*Tab = null,
    /// closed tabs, to open again (Ctrl+Shift+T)
    closed: std.ArrayList(Closed) = .empty,
    fullscreen: bool = false,
    blur: bool = false,
    blurRegion: [5]c_int = .{ 0, 0, 0, 0, 0 },

    handle: *Item = undefined,
    indicator: *Item = undefined,
    indicatorSpan: LiquidSpan = .{},
    indicatorTicking: bool = false,
    plus: *Item = undefined,
    controls: *Item = undefined,
    nav: *Item = undefined,
    back: Widget = undefined,
    forward: Widget = undefined,
    reload: Widget = undefined,
    address: *Item = undefined,
    addressText: Widget = undefined,
    chip: Widget = undefined,
    chipLabel: Widget = undefined,
    chipIcon: Widget = undefined,
    actions: *Item = undefined,
    shieldButton: Widget = undefined,
    downloadsButton: Widget = undefined,
    containerButton: Widget = undefined,
    downloadsBadge: Widget = undefined,
    unseenDownloads: usize = 0,
    counted: std.AutoHashMapUnmanaged(*engine.Download, void) = .empty,
    /// a tab already open on Google AI Mode, waiting for the next new tab
    spare: ?*Tab = null,
    editing: bool = false,
    progressShown: Spring = Spring.init(0, 200, 0),
    progressValue: Spring = Spring.init(0, 160, 0),
    progressTicking: bool = false,

    card: Rect = .{},
    radius: f64 = 14,

    // overlays
    menu: ?*Item = null,
    suggestions: ?*overlays.Suggestions = null,
    find: ?*overlays.FindBar = null,
    downloadsPanel: ?*overlays.DownloadsPanel = null,
    toastItem: ?*Item = null,
    toastTimer: c.guint = 0,
    status: *Item = undefined,
    statusLabel: Widget = undefined,

    // the page's colour reaching up under the chrome
    reachTex: ?*c.GdkTexture = null,
    reachRect: Rect = .{},
    reachAt: i64 = 0,
    reachTimer: c.guint = 0,
    reachFor: ?*Tab = null,

    pub const Closed = struct { url: []u8, container: ?[]u8 };

    pub fn create(app: *App) *Browser {
        const b = core.gpa.create(Browser) catch @panic("oom");
        const window = c.adw_application_window_new(@ptrCast(app.gtk)).?;
        b.* = .{ .app = app, .window = window, .stage = stagez.Stage.create() };
        c.gtk_window_set_title(b.win(), "Iris");
        c.gtk_window_set_default_size(b.win(), 1280, 820);
        c.gtk_widget_add_css_class(window, "iris");
        c.adw_application_window_set_content(@ptrCast(window), b.stage.widget);
        c.gtk_window_set_icon_name(b.win(), "io.github.tulip_labs.Iris");

        b.stage.background = .{ .ctx = b, .f = drawBackCB };
        b.stage.afterPages = .{ .ctx = b, .f = drawReachCB };
        b.stage.layout = .{ .ctx = b, .f = layoutCB };
        b.stage.chromeLive = .{ .ctx = b, .f = chromeLiveCB };
        b.buildChrome();
        // Google's names are looked up before the first question
        engine.Engine.warm(engine.Containers.session(null), &engine.Engine.google_hosts);
        b.buildStatus();
        keys.attach(b);

        // a click anywhere else closes a menu
        const click = c.gtk_gesture_click_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(click), c.GTK_PHASE_CAPTURE);
        _ = core.onPress(click, "pressed", b, pressedCB);
        c.gtk_widget_add_controller(window, @ptrCast(click));
        _ = core.on(window, "realize", b, realized);
        _ = core.onBool0(window, "close-request", b, closeRequest);
        _ = core.on1(window, "notify::is-active", b, activeChanged);
        engine.Downloads.changed.append(core.gpa, .{ .ctx = b, .f = downloadChangedCB }) catch {};
        b.stage.relayout();
        return b;
    }

    pub fn win(b: *Browser) *c.GtkWindow {
        return @ptrCast(b.window);
    }

    pub fn present(b: *Browser) void {
        c.gtk_window_present(b.win());
    }

    fn realized(b: *Browser) void {
        b.blur = c.iris_blur_available(b.window) != 0;
        if (c.gtk_native_get_surface(@ptrCast(b.window))) |surface| _ = core.on1(surface, "notify::state", b, stateChanged);
        b.stage.relayout();
        b.layout(b.stage.width, b.stage.height);
    }

    fn stateChanged(b: *Browser, _: ?*anyopaque) void {
        b.stage.relayout();
        b.layout(b.stage.width, b.stage.height);
    }

    fn closeRequest(b: *Browser) bool {
        b.saveSession();
        if (b.spare) |s| s.destroy();
        b.spare = null;
        b.app.closed(b);
        return false;
    }

    /// the window's active state reaches every page (focus rings, carets)
    fn activeChanged(b: *Browser, _: ?*anyopaque) void {
        const on = c.gtk_window_is_active(b.win()) != 0;
        for (b.tabs.items) |t| if (t.page) |p| p.setActive(on);
    }

    fn pressedCB(b: *Browser, _: i32, x: f64, y: f64) void {
        if (b.menu) |m| if (!m.frame.rect().contains(x, y)) b.closeMenu();
    }

    fn chromeLiveCB(ctx: *anyopaque) bool {
        const b: *Browser = core.cast(*Browser, ctx);
        return b.editing or b.suggestions != null;
    }

    // ---------------------------------------------------------------- chrome

    fn buildChrome(b: *Browser) void {
        const st = b.stage;
        // the empty parts of the top move the window
        b.handle = st.add(c.gtk_window_handle_new().?, .back, null, false);

        // the selected tab's glass, sliding from tab to tab
        const ind = ui.box(false, 0);
        c.gtk_widget_set_can_target(ind, 0);
        b.indicator = st.add(ind, .chrome, .{ .radius = 16, .level = 0.70, .bend = 6, .rim = 12, .shadow = 0.7 }, false);
        b.indicator.animateFrames = false;

        const p = ui.button("list-add-symbolic", "New tab (Ctrl+T)", b, newTabCB);
        b.plus = st.add(p, .chrome, .{ .radius = 16, .level = 0.24, .bend = 5, .rim = 10 }, true);
        const pc = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(pc), 3);
        _ = core.onPress(pc, "pressed", b, plusMenu);
        c.gtk_widget_add_controller(p, @ptrCast(pc));

        b.controls = st.add(c.gtk_window_controls_new(c.GTK_PACK_END).?, .chrome, null, false);

        // back, forward, reload: one capsule
        const navBox = ui.box(false, 2);
        c.gtk_widget_set_margin_start(navBox, 4);
        c.gtk_widget_set_margin_end(navBox, 4);
        b.back = ui.button("go-previous-symbolic", "Back (Alt+\u{2190})", b, backCB);
        b.forward = ui.button("go-next-symbolic", "Forward (Alt+\u{2192})", b, forwardCB);
        b.reload = ui.button("view-refresh-symbolic", "Reload (Ctrl+R)", b, reloadCB);
        for ([_]Widget{ b.back, b.forward, b.reload }) |w| {
            c.gtk_widget_set_valign(w, c.GTK_ALIGN_CENTER);
            ui.append(navBox, w);
        }
        b.nav = st.add(navBox, .chrome, .{ .radius = 19, .level = 0.20 }, false);
        for ([_]Widget{ b.back, b.forward, b.reload }) |w| st.part(b.nav, w, .{ .radius = 17, .level = 0.30, .bend = 3, .rim = 8, .dispersion = false }, true);

        // the address
        const ab = ui.box(false, 8);
        ui.cls(ab, &.{"iris-address"});
        b.chip = ui.box(false, 5);
        ui.cls(b.chip, &.{"iris-chip"});
        b.chipIcon = ui.icon("iris-star-symbolic", 13);
        b.chipLabel = ui.label("", &.{});
        ui.append(b.chip, b.chipIcon);
        ui.append(b.chip, b.chipLabel);
        c.gtk_widget_set_valign(b.chip, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_visible(b.chip, 0);
        const t = c.gtk_text_new().?;
        b.addressText = t;
        c.gtk_widget_set_hexpand(t, 1);
        c.gtk_widget_set_valign(t, c.GTK_ALIGN_CENTER);
        c.gtk_text_set_placeholder_text(@ptrCast(t), "Search or enter address");
        c.gtk_editable_set_alignment(@ptrCast(t), 0.5);
        ui.append(ab, b.chip);
        ui.append(ab, t);
        b.address = st.add(ab, .chrome, .{ .radius = 19, .level = 0.30, .bend = 7, .rim = 14 }, true);
        st.part(b.address, b.chip, .{ .radius = 10, .tint = RGBA.hex("#6a4cf5", 0.9), .bend = 2, .rim = 5, .dispersion = false, .rimLight = 0.6 }, false);
        b.address.front = .{ .ctx = b, .f = drawProgressCB };
        b.wireAddress(t);

        // shields, containers, and downloads while there are any (no menu:
        // find and zoom are Ctrl+F and Ctrl+plus, minus and 0)
        const actBox = ui.box(false, 2);
        c.gtk_widget_set_margin_start(actBox, 4);
        c.gtk_widget_set_margin_end(actBox, 4);
        b.shieldButton = ui.button("security-high-symbolic", "Shields", b, shieldsCB);
        b.downloadsButton = ui.button("folder-download-symbolic", "Downloads (Ctrl+Shift+Y)", b, downloadsCB);
        const dl = ui.box(false, 3);
        ui.append(dl, ui.icon("folder-download-symbolic", 16));
        b.downloadsBadge = ui.label("", &.{"iris-badge"});
        c.gtk_widget_set_visible(b.downloadsBadge, 0);
        ui.append(dl, b.downloadsBadge);
        c.gtk_button_set_child(@ptrCast(b.downloadsButton), dl);
        c.gtk_widget_set_visible(b.downloadsButton, 0);
        b.containerButton = ui.button("view-grid-symbolic", "Containers", b, containersCB);
        for ([_]Widget{ b.shieldButton, b.containerButton, b.downloadsButton }) |w| {
            c.gtk_widget_set_valign(w, c.GTK_ALIGN_CENTER);
            ui.append(actBox, w);
        }
        b.actions = st.add(actBox, .chrome, .{ .radius = 19, .level = 0.20 }, false);
        for ([_]Widget{ b.shieldButton, b.containerButton, b.downloadsButton }) |w| st.part(b.actions, w, .{ .radius = 17, .level = 0.30, .bend = 3, .rim = 8, .dispersion = false }, true);
    }

    fn newTabCB(b: *Browser) void {
        _ = b.newTab(.{});
    }
    fn plusMenu(b: *Browser, _: i32, _: f64, _: f64) void {
        overlays.showContainerMenu(b, b.plus.frame.rect(), true);
    }
    fn backCB(b: *Browser) void {
        if (b.current) |t| t.back();
    }
    fn forwardCB(b: *Browser) void {
        if (b.current) |t| t.forward();
    }
    fn reloadCB(b: *Browser) void {
        const t = b.current orelse return;
        if (t.loading) t.stop() else t.reload();
    }
    fn shieldsCB(b: *Browser) void {
        overlays.showShields(b);
    }
    fn downloadsCB(b: *Browser) void {
        b.showDownloads();
    }
    fn containersCB(b: *Browser) void {
        overlays.showContainerMenu(b, b.stage.bounds(b.containerButton) orelse b.actions.frame.rect(), false);
    }

    fn wireAddress(b: *Browser, t: Widget) void {
        const focus = c.gtk_event_controller_focus_new();
        _ = core.on(focus, "enter", b, beginEditing);
        _ = core.on(focus, "leave", b, endEditing);
        c.gtk_widget_add_controller(t, focus);
        _ = core.on(t, "activate", b, activated);
        _ = core.on(t, "changed", b, changed);
        const k = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(k, c.GTK_PHASE_CAPTURE);
        _ = core.onKey(k, b, addressKey);
        c.gtk_widget_add_controller(t, k);
    }

    fn activated(b: *Browser) void {
        if (b.suggestions) |s| if (s.chosen()) |u| return b.go(u);
        const u = search.resolve(ui.text(b.addressText));
        defer core.gpa.free(u);
        b.go(u);
    }

    fn changed(b: *Browser) void {
        if (!b.editing or c.gtk_widget_has_focus(b.addressText) == 0) return;
        b.typed(ui.text(b.addressText));
    }

    fn addressKey(b: *Browser, key: u32, _: u32, _: u32) bool {
        switch (key) {
            c.GDK_KEY_Escape => {
                if (b.suggestions != null) b.closeSuggestions() else b.focusPage();
                return true;
            },
            c.GDK_KEY_Down => {
                if (b.suggestions) |s| s.move(1);
                return b.suggestions != null;
            },
            c.GDK_KEY_Up => {
                if (b.suggestions) |s| s.move(-1);
                return b.suggestions != null;
            },
            else => return false,
        }
    }

    fn beginEditing(b: *Browser) void {
        b.editing = true;
        c.gtk_editable_set_alignment(@ptrCast(b.addressText), 0);
        const e = search.editable(if (b.current) |t| t.url.get() else "");
        defer core.gpa.free(e);
        ui.setText(b.addressText, e);
        if (b.address.glass) |*g| g.tint = RGBA.white.alpha(0.62);
        b.address.scale.value = 0.985;
        b.address.scale.target = 1;
        b.stage.relayout();
        b.layout(b.stage.width, b.stage.height);
        core.idle(b, selectAll);
        b.stage.kick();
    }

    fn selectAll(b: *Browser) void {
        c.gtk_editable_select_region(@ptrCast(b.addressText), 0, -1);
    }

    fn endEditing(b: *Browser) void {
        b.editing = false;
        b.closeSuggestions();
        c.gtk_editable_set_alignment(@ptrCast(b.addressText), 0.5);
        if (b.address.glass) |*g| g.tint = RGBA.white.alpha(0.30);
        b.showAddress();
        b.layout(b.stage.width, b.stage.height);
        b.stage.kick();
    }

    pub fn focusAddress(b: *Browser) void {
        if (b.fullscreen) return;
        _ = c.gtk_widget_grab_focus(b.addressText);
    }

    pub fn focusPage(b: *Browser) void {
        if (b.current) |t| if (t.page) |p| {
            _ = c.gtk_widget_grab_focus(p.widget);
        };
    }

    fn showAddress(b: *Browser) void {
        if (b.editing) return;
        const d = search.display(if (b.current) |t| t.url.get() else "");
        defer core.gpa.free(d);
        ui.setText(b.addressText, d);
    }

    fn typed(b: *Browser, text: []const u8) void {
        if (std.mem.trim(u8, text, " ").len == 0) return b.closeSuggestions();
        if (b.suggestions == null) b.suggestions = overlays.Suggestions.create(b);
        b.suggestions.?.update(text);
    }

    pub fn closeSuggestions(b: *Browser) void {
        if (b.suggestions) |s| s.close();
        b.suggestions = null;
    }

    pub fn addressFrame(b: *Browser) Rect {
        return b.address.frame.target();
    }

    // ---------------------------------------------------------------- drawing

    fn windowRadius(b: *Browser) f64 {
        const s = c.gtk_native_get_surface(@ptrCast(b.window)) orelse return 14;
        const st = c.gdk_toplevel_get_state(@ptrCast(s));
        const square = c.GDK_TOPLEVEL_STATE_MAXIMIZED | c.GDK_TOPLEVEL_STATE_FULLSCREEN | c.GDK_TOPLEVEL_STATE_TILED;
        return if (st & square != 0) 0 else 14;
    }

    fn drawBackCB(ctx: *anyopaque, s: G.Snap, r: Rect) void {
        const b: *Browser = core.cast(*Browser, ctx);
        b.drawBack(s, r.w, r.h);
    }

    /// Iris's dawn: lilac above, rose and peach, her sky below
    fn drawBack(b: *Browser, s: G.Snap, w: f64, h: f64) void {
        const r = Rect{ .w = w, .h = h };
        var rr = G.rrect(r, b.radius);
        c.gtk_snapshot_push_rounded_clip(s, &rr);
        // translucent where the compositor blurs what is behind; nearly solid
        // where it cannot
        G.color(s, .{ .r = 0.95, .g = 0.94, .b = 0.99, .a = if (b.blur) 0.58 else 0.97 }, r);
        const m = @max(w, h);
        G.radial(s, r, .{ w * 0.06, -60 }, m * 0.75, 2, .{ .{ 0, .{ .r = 0.68, .g = 0.74, .b = 1, .a = 0.30 } }, .{ 1, .{ .r = 0.68, .g = 0.74, .b = 1, .a = 0 } } });
        G.radial(s, r, .{ w * 0.88, -40 }, m * 0.7, 2, .{ .{ 0, .{ .r = 1, .g = 0.62, .b = 0.84, .a = 0.26 } }, .{ 1, .{ .r = 1, .g = 0.5, .b = 0.8, .a = 0 } } });
        G.radial(s, r, .{ w * 0.5, h * 0.55 }, m * 0.55, 2, .{ .{ 0, .{ .r = 1, .g = 0.92, .b = 0.84, .a = 0.22 } }, .{ 1, .{ .r = 1, .g = 0.9, .b = 0.85, .a = 0 } } });
        G.radial(s, r, .{ w * 0.1, h + 40 }, m * 0.6, 2, .{ .{ 0, .{ .r = 0.45, .g = 0.76, .b = 1, .a = 0.24 } }, .{ 1, .{ .r = 0.3, .g = 0.75, .b = 1, .a = 0 } } });
        G.linear(s, .{ .w = w, .h = b.card.y }, .{ 0, 0 }, .{ 0, b.card.y }, 2, .{ .{ 0, RGBA.white.alpha(0.45) }, .{ 1, RGBA.white.alpha(0) } });
        c.gtk_snapshot_pop(s);
        // the window's own rim of light
        if (b.radius > 0) {
            const p = G.pushRimStroke(s, r, b.radius, 1);
            G.linear(s, r, .{ 0, 0 }, .{ 0, h }, 3, .{ .{ 0, RGBA.white.alpha(0.9) }, .{ 0.2, RGBA.white.alpha(0.35) }, .{ 1, RGBA.white.alpha(0.2) } });
            G.popRimStroke(s, p);
        }
    }

    pub fn invalidateReach(b: *Browser) void {
        b.reachAt = 0;
        b.stage.dirtyChrome();
    }

    fn drawReachCB(ctx: *anyopaque, s: G.Snap, _: Rect) void {
        const b: *Browser = core.cast(*Browser, ctx);
        b.drawReach(s);
    }

    /// the page's colour reaches up under the chrome (as Apple's toolbars
    /// take on the colour of the page under them), for the glass to bend;
    /// made at most once a second and kept as a texture
    fn drawReach(b: *Browser, s: G.Snap) void {
        if (b.fullscreen) return;
        const t = b.current orelse return;
        const page = t.item orelse return;
        if (page.alpha.value <= 0.01) return;
        const now = std.time.milliTimestamp();
        const fresh = now - b.reachAt < 1000 and b.reachFor == t;
        if (!fresh or b.reachTex == null) {
            if (b.stage.nodeOf(page)) |node| {
                defer c.gsk_render_node_unref(node);
                const top = b.card.y;
                if (c.gtk_snapshot_new()) |sub| {
                    var clip = G.grect(.{ .w = b.stage.width, .h = top });
                    c.gtk_snapshot_push_clip(sub, &clip);
                    c.gtk_snapshot_push_blur(sub, 26);
                    // the page's first rows, stretched up to the window's top
                    c.gtk_snapshot_scale(sub, 1, @floatCast(top / 3));
                    var up = G.gpoint(0, -top);
                    c.gtk_snapshot_translate(sub, &up);
                    c.gtk_snapshot_append_node(sub, node);
                    c.gtk_snapshot_pop(sub);
                    c.gtk_snapshot_pop(sub);
                    if (c.gtk_snapshot_free_to_node(sub)) |n| {
                        defer c.gsk_render_node_unref(n);
                        if (b.stage.renderTexture(n, .{ .w = b.stage.width, .h = top })) |tr| {
                            core.unref(b.reachTex);
                            b.reachTex = tr[0];
                            b.reachRect = tr[1];
                            b.reachAt = now;
                            b.reachFor = t;
                            b.stage.dirtyChrome();
                        }
                    }
                }
            }
        } else if (b.reachTimer == 0) {
            // the page changed meanwhile: look again in a second
            b.reachTimer = core.after(1000, b, reachAgain);
        }
        const tex = b.reachTex orelse return;
        c.gtk_snapshot_push_opacity(s, 0.42 * page.alpha.value);
        var g = G.grect(b.reachRect);
        c.gtk_snapshot_append_texture(s, tex, &g);
        c.gtk_snapshot_pop(s);
    }

    fn reachAgain(b: *Browser) void {
        b.reachTimer = 0;
        c.gtk_widget_queue_draw(b.stage.widget);
    }

    fn drawProgressCB(ctx: *anyopaque, s: G.Snap, r: Rect) void {
        const b: *Browser = core.cast(*Browser, ctx);
        const a = b.progressShown.value;
        if (a <= 0.01) return;
        const w = (r.w - 28) * @min(1, @max(0, b.progressValue.value));
        G.rounded(s, .{ .r = 0.42, .g = 0.30, .b = 0.96, .a = 0.9 * a }, .{ .x = r.x + 14, .y = r.maxY() - 3.5, .w = w, .h = 2.5 }, 1.25);
    }

    pub fn progressChanged(b: *Browser, t: *Tab) void {
        if (t != b.current) return;
        b.progressValue.target = t.progress;
        b.progressShown.target = if (t.loading) 1 else 0;
        if (b.progressTicking) return;
        b.progressTicking = true;
        _ = core.every(16, b, progressStep);
    }

    fn progressStep(b: *Browser) bool {
        const dt = 1.0 / 60.0;
        const m1 = b.progressValue.step(dt);
        const m2 = b.progressShown.step(dt);
        if (b.progressShown.target == 0 and b.progressShown.value < 0.02) b.progressValue.snap(0);
        b.stage.dirtyChrome();
        b.progressTicking = m1 or m2;
        return b.progressTicking;
    }

    // ---------------------------------------------------------------- layout

    fn layoutCB(ctx: *anyopaque, w: f64, h: f64) void {
        const b: *Browser = core.cast(*Browser, ctx);
        b.layout(w, h);
    }

    pub fn layout(b: *Browser, W: f64, H: f64) void {
        const st = b.stage;
        b.radius = b.windowRadius();
        const pad = 8.0;
        const showChrome = !b.fullscreen;
        const tabY = 6.0;
        const tabH = 32.0;
        const toolY = 44.0;
        const toolH = 38.0;
        b.card = if (showChrome) .{ .x = pad, .y = toolY + toolH + 8, .w = W - 2 * pad, .h = H - (toolY + toolH + 8) - pad } else .{ .w = W, .h = H };

        st.chromeHeight = if (showChrome) b.card.y else 0;
        st.place(b.handle, .{ .w = W, .h = b.card.y }, false);
        const cn = ui.natural(b.controls.w, -1);
        st.place(b.controls, .{ .x = W - pad - cn[0], .y = tabY + (tabH - cn[1]) / 2, .w = cn[0], .h = cn[1] }, false);

        // the tabs
        const x0 = pad;
        const x1 = W - pad - cn[0] - 10 - tabH - 6;
        const n: f64 = @floatFromInt(@max(1, b.tabs.items.len));
        const tw = @min(232, @max(44, (x1 - x0 - 4 * (n - 1)) / n));
        for (b.tabs.items, 0..) |t, i| {
            const fi: f64 = @floatFromInt(i);
            st.place(t.pillItem, .{ .x = x0 + fi * (tw + 4), .y = tabY, .w = tw, .h = tabH }, true);
            c.gtk_widget_set_visible(t.close, @intFromBool(t == b.current or tw > 110));
        }
        const plusX = @min(x1 + 6, x0 + n * (tw + 4));
        st.place(b.plus, .{ .x = plusX, .y = tabY, .w = tabH, .h = tabH }, true);
        if (b.current) |cur| for (b.tabs.items, 0..) |t, i| if (t == cur) {
            const fi: f64 = @floatFromInt(i);
            const x = x0 + fi * (tw + 4);
            b.indicatorSpan.go(x, x + tw, st.animations);
            st.kick();
            b.tickIndicator();
        };

        // the toolbar
        const nw = ui.natural(b.nav.w, -1)[0];
        const aw = ui.natural(b.actions.w, -1)[0];
        st.place(b.nav, .{ .x = pad, .y = toolY, .w = nw, .h = toolH }, false);
        st.place(b.actions, .{ .x = W - pad - aw, .y = toolY, .w = aw, .h = toolH }, false);
        const ax = pad + nw + 8;
        const aW = W - pad - aw - 8 - ax;
        // the address bar draws in a little until you type in it
        const inset = if (b.editing) 0 else @min(aW * 0.08, 60);
        st.place(b.address, .{ .x = ax + inset, .y = toolY, .w = aW - 2 * inset, .h = toolH }, true);

        for (b.tabs.items) |t| if (t.item) |p| st.place(p, b.card, false);
        for ([_]*Item{ b.handle, b.indicator, b.plus, b.controls, b.nav, b.address, b.actions }) |it| if (it.shown != showChrome) st.show(it, showChrome, true);
        for (b.tabs.items) |t| if (t.pillItem.shown != showChrome) st.show(t.pillItem, showChrome, true);
        const pr: f64 = if (showChrome) 12 else 0;
        for (b.tabs.items) |t| if (t.item) |p| {
            p.clip = pr;
        };
        b.placeOverlays();
        b.updateBlur(W, H);
    }

    fn tickIndicator(b: *Browser) void {
        b.applyIndicator();
        if (b.indicatorTicking) return;
        b.indicatorTicking = true;
        _ = core.every(8, b, indicatorStep);
    }

    fn applyIndicator(b: *Browser) void {
        const lo = b.indicatorSpan.lo.value;
        const hi = b.indicatorSpan.hi.value;
        // in flight the pill thins a little, like a drop
        const speed = @abs(b.indicatorSpan.lo.velocity) + @abs(b.indicatorSpan.hi.velocity);
        const squeeze = @min(3, speed / 900);
        b.indicator.frame.go(.{ .x = lo, .y = 6 + squeeze, .w = @max(10, hi - lo), .h = 32 - 2 * squeeze }, false);
        c.gtk_widget_queue_allocate(b.stage.widget);
    }

    fn indicatorStep(b: *Browser) bool {
        const moving = b.indicatorSpan.step(0.008);
        b.applyIndicator();
        b.indicatorTicking = moving;
        return moving;
    }

    fn updateBlur(b: *Browser, w: f64, h: f64) void {
        if (!b.blur) return;
        var sx: f64 = 0;
        var sy: f64 = 0;
        c.gtk_native_get_surface_transform(@ptrCast(b.window), &sx, &sy);
        const r = [5]c_int{ @intFromFloat(sx), @intFromFloat(sy), @intFromFloat(w), @intFromFloat(h), @intFromFloat(b.radius) };
        if (!std.mem.eql(c_int, &r, &b.blurRegion)) {
            b.blurRegion = r;
            c.iris_blur_set(b.window, r[0], r[1], r[2], r[3], r[4]);
        }
    }

    // ---------------------------------------------------------------- tabs

    pub const NewTab = struct {
        url: ?[]const u8 = null,
        container: ?[]const u8 = null,
        after: ?*Tab = null,
        select: bool = true,
        related: ?*c.WebKitWebView = null,
        lazy: bool = false,
    };

    pub fn newTab(b: *Browser, o: NewTab) *Tab {
        // a plain new tab is Google AI Mode: the spare one, already loaded
        const plain = (o.url == null or o.url.?.len == 0) and o.related == null;
        const fromSpare = plain and o.container == null and b.spare != null;
        const t = if (fromSpare) b.spare.? else Tab.create(b, o.container);
        if (fromSpare) b.spare = null;
        const it = b.stage.add(t.pill, .chrome, .{ .radius = 16, .level = 0.22, .bend = 4, .rim = 9, .dispersion = false }, true);
        it.glassFollowsHover = true;
        it.alpha.value = 0;
        it.scale.value = 0.86;
        t.pillItem = it;
        b.stage.show(it, !b.fullscreen, true);
        b.wirePill(t);
        var at: usize = b.tabs.items.len;
        if (o.after) |a| for (b.tabs.items, 0..) |x, i| if (x == a) {
            at = i + 1;
        };
        b.tabs.insert(core.gpa, at, t) catch {};
        // the tab opens where it will sit
        if (at > 0) {
            const prev = b.tabs.items[at - 1].pillItem.frame.target();
            it.frame.go(.{ .x = prev.maxX() + 4, .y = prev.y, .w = prev.w, .h = prev.h }, false);
        }
        if (o.related) |r| {
            _ = t.ensureWeb(r);
        } else if (o.url) |u| {
            if (u.len > 0) {
                if (o.lazy) {
                    t.pending = core.dupe(u);
                    const d = search.display(u);
                    defer core.gpa.free(d);
                    t.title.set(d);
                    ui.setLabel(t.pillLabel, d);
                } else t.load(u);
            } else if (!fromSpare) t.load(search.home);
        } else if (!fromSpare) t.load(search.home);
        if (o.select or b.current == null) b.select(t) else b.layout(b.stage.width, b.stage.height);
        if (b.spare == null) _ = core.after(1500, b, prepareSpare);
        return t;
    }

    /// the next new tab, loaded in the background a moment after this one
    fn prepareSpare(b: *Browser) void {
        if (b.spare != null or b.tabs.items.len == 0) return;
        const s = Tab.create(b, null);
        b.spare = s;
        s.load(search.home);
    }

    fn wirePill(b: *Browser, t: *Tab) void {
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        const a = Act.make(b, t, "");
        a.p = click;
        _ = core.onPress(click, "pressed", a, pillPressed);
        c.gtk_widget_add_controller(t.pill, @ptrCast(click));
        _ = a.own(t.pill);
    }

    /// middle closes, right opens the tab's menu, left selects
    fn pillPressed(a: *Act, _: i32, _: f64, _: f64) void {
        const t = a.t.?;
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(@alignCast(a.p)));
        if (btn == 2) a.b.close(t) else if (btn == 3) overlays.tabMenu(a.b, t) else a.b.select(t);
    }

    /// a tab's page joins the stage (the first time it opens something)
    pub fn attachPage(b: *Browser, t: *Tab) void {
        const p = t.page orelse return;
        if (t.item != null) return;
        const it = b.stage.add(p.widget, .page, null, false);
        it.clip = if (b.fullscreen) 0 else 12;
        it.animateFrames = false;
        b.stage.place(it, b.card, false);
        t.item = it;
        if (t == b.current) {
            it.alpha.value = 0;
            it.scale.value = 0.99;
            b.stage.show(it, true, true);
        } else b.stage.show(it, false, false);
        p.setActive(c.gtk_window_is_active(b.win()) != 0);
    }

    /// a tab's page leaves the stage (it is about to be made again)
    pub fn detachPage(b: *Browser, t: *Tab) void {
        if (t.item) |it| b.stage.remove(it, false, null);
        t.item = null;
    }

    pub fn select(b: *Browser, t: *Tab) void {
        const old = b.current;
        if (old == t) return b.layout(b.stage.width, b.stage.height);
        b.current = t;
        if (t.pending) |p| {
            t.pending = null;
            t.load(p);
            core.gpa.free(p);
        }
        if (old) |o| if (o.item) |op| b.stage.show(op, false, true);
        if (t.item) |np| {
            b.stage.raise(np);
            b.stage.show(np, true, true);
        } else {
            // a tab with nothing in it opens Google AI Mode
            t.load(search.home);
        }
        if (old) |o| c.gtk_widget_remove_css_class(o.pill, "selected");
        c.gtk_widget_add_css_class(t.pill, "selected");
        b.invalidateReach();
        if (engine.Containers.get(t.container)) |k| {
            if (b.indicator.glass) |*g| {
                g.level = null;
                g.tint = RGBA.hex(k.color, 0.30);
            }
        } else if (b.indicator.glass) |*g| g.level = 0.70;
        b.closeMenu();
        if (b.find) |f| f.close();
        b.tabChanged(t);
        b.progressChanged(t);
        b.layout(b.stage.width, b.stage.height);
        if (!b.editing) b.focusPage();
    }

    pub fn close(b: *Browser, t: *Tab) void {
        var idx: ?usize = null;
        for (b.tabs.items, 0..) |x, i| if (x == t) {
            idx = i;
        };
        const i = idx orelse return;
        if (t.url.get().len > 0 and !t.isPrivate()) b.closed.append(core.gpa, .{ .url = core.dupe(t.url.get()), .container = if (t.container) |k| core.dupe(k) else null }) catch {};
        _ = b.tabs.orderedRemove(i);
        if (t == b.current) {
            b.current = null;
            // the last tab: Iris stays, with a fresh one
            if (b.tabs.items.len == 0) _ = b.newTab(.{}) else b.select(b.tabs.items[@min(i, b.tabs.items.len - 1)]);
        }
        b.stage.remove(t.pillItem, true, null);
        if (t.item) |it| b.stage.remove(it, true, null);
        t.item = null;
        t.destroy();
        if (t.isPrivate()) {
            var anyPrivate = false;
            for (b.tabs.items) |x| anyPrivate = anyPrivate or x.isPrivate();
            if (!anyPrivate and !b.app.anyPrivate(b)) engine.Containers.endPrivate();
        }
        b.layout(b.stage.width, b.stage.height);
    }

    pub fn closeCurrent(b: *Browser) void {
        if (b.current) |t| b.close(t);
    }

    pub fn reopenClosed(b: *Browser) void {
        const last = b.closed.pop() orelse return;
        _ = b.newTab(.{ .url = last.url, .container = last.container });
    }

    pub fn cycle(b: *Browser, d: i32) void {
        const cur = b.current orelse return;
        const n: i32 = @intCast(b.tabs.items.len);
        if (n < 2) return;
        for (b.tabs.items, 0..) |t, i| if (t == cur) {
            const j: usize = @intCast(@mod(@as(i32, @intCast(i)) + d + n, n));
            return b.select(b.tabs.items[j]);
        };
    }

    pub fn selectIndex(b: *Browser, i: usize) void {
        if (i == 8) {
            if (b.tabs.items.len > 0) b.select(b.tabs.items[b.tabs.items.len - 1]);
            return;
        }
        if (i < b.tabs.items.len) b.select(b.tabs.items[i]);
    }

    pub fn go(b: *Browser, url: []const u8) void {
        if (url.len == 0) return;
        b.closeSuggestions();
        const t = b.current orelse b.newTab(.{});
        t.load(url);
        b.focusPage();
    }

    pub fn tabChanged(b: *Browser, t: *Tab) void {
        const shown = if (t.title.get().len > 0) core.dupe(t.title.get()) else if (t.url.get().len == 0) core.dupe("New Tab") else search.display(t.url.get());
        defer core.gpa.free(shown);
        ui.setLabel(t.pillLabel, shown);
        const z = core.z(shown);
        defer core.gpa.free(z);
        c.gtk_widget_set_tooltip_text(t.pill, z.ptr);
        b.stage.dirtyChrome();
        if (t != b.current) return;
        c.gtk_widget_set_sensitive(b.back, @intFromBool(t.canBack));
        c.gtk_widget_set_sensitive(b.forward, @intFromBool(t.canForward));
        c.gtk_button_set_icon_name(@ptrCast(b.reload), if (t.loading) "process-stop-symbolic" else "view-refresh-symbolic");
        if (engine.Containers.get(t.container)) |k| {
            ui.setLabel(b.chipLabel, k.name);
            c.gtk_image_set_from_icon_name(@ptrCast(b.chipIcon), k.iconName().ptr);
            c.gtk_widget_set_visible(b.chip, 1);
            if (b.address.parts.items.len > 0) b.address.parts.items[0].glass.tint = RGBA.hex(k.color, 0.92);
        } else c.gtk_widget_set_visible(b.chip, 0);
        const h = search.host(t.url.get());
        defer if (h) |x| core.gpa.free(x);
        c.gtk_button_set_icon_name(@ptrCast(b.shieldButton), if (shields.onFor(h)) "security-high-symbolic" else "security-low-symbolic");
        b.showAddress();
        const title = if (t.title.get().len == 0) core.fmtZ("Iris", .{}) else core.fmtZ("{s} \u{2013} Iris", .{t.title.get()});
        defer core.gpa.free(title);
        c.gtk_window_set_title(b.win(), title.ptr);
        b.stage.dirtyChrome();
    }

    // ---------------------------------------------------------------- pop-ups and new windows

    /// a page asks for a new window: links open as tabs; pop-ups from
    /// scripts only when you clicked, to the same site or a sign-in, and
    /// never to an ad server. True when handled.
    pub fn newWindow(b: *Browser, t: *Tab, d: *c.WebKitPolicyDecision) bool {
        const nav = c.webkit_navigation_policy_decision_get_navigation_action(@ptrCast(d));
        const req = c.webkit_navigation_action_get_request(nav) orelse return false;
        const u = core.str(c.webkit_uri_request_get_uri(req));
        const host = search.host(u) orelse core.dupe("");
        defer core.gpa.free(host);
        const pageHost = search.host(t.url.get());
        defer if (pageHost) |x| core.gpa.free(x);
        const on = shields.onFor(pageHost);
        if (on and shields.hostBlocked(host)) {
            c.webkit_policy_decision_ignore(d);
            return true;
        }
        if (c.webkit_navigation_action_get_navigation_type(nav) == c.WEBKIT_NAVIGATION_TYPE_LINK_CLICKED) {
            c.webkit_policy_decision_ignore(d);
            const background = c.webkit_navigation_action_get_mouse_button(nav) == 2;
            _ = b.newTab(.{ .url = u, .container = t.container, .after = t, .select = !background });
            return true;
        }
        // the sandbox opens no windows of its own
        if (t.sandboxed) {
            c.webkit_policy_decision_ignore(d);
            return true;
        }
        const gesture = c.webkit_navigation_action_is_user_gesture(nav) != 0;
        const pageSite = if (pageHost) |ph| search.site(ph) else "";
        if (gesture and (std.mem.eql(u8, search.site(host), pageSite) or search.isSignIn(host) or std.mem.eql(u8, u, "about:blank"))) {
            return false; // WebKit goes on and asks for the view ("create")
        }
        c.webkit_policy_decision_ignore(d);
        if (on) {
            b.toastAction("Pop-up blocked", "Open", Act.make(b, t, u), openBlocked);
        } else _ = b.newTab(.{ .url = u, .container = t.container, .after = t });
        return true;
    }

    fn openBlocked(a: *Act) void {
        _ = a.b.newTab(.{ .url = a.s, .container = if (a.t) |t| t.container else null, .after = a.t });
    }

    pub fn popup(b: *Browser, t: *Tab, _: ?*c.WebKitNavigationAction) ?*c.WebKitWebView {
        const parent = t.web orelse return null;
        const p = b.newTab(.{ .container = t.container, .after = t, .select = false, .related = parent });
        return p.web;
    }

    pub fn openInBackground(b: *Browser, u: []const u8, t: *Tab) void {
        _ = b.newTab(.{ .url = u, .container = t.container, .after = t, .select = false });
    }

    // ---------------------------------------------------------------- full screen

    pub fn pageFullscreen(b: *Browser, on: bool) void {
        b.fullscreen = on;
        if (on) c.gtk_window_fullscreen(b.win()) else c.gtk_window_unfullscreen(b.win());
        b.closeMenu();
        b.layout(b.stage.width, b.stage.height);
        b.stage.relayout();
    }

    pub fn toggleWindowFullscreen(b: *Browser) void {
        if (c.gtk_window_is_fullscreen(b.win()) != 0) {
            b.fullscreen = false;
            c.gtk_window_unfullscreen(b.win());
        } else c.gtk_window_fullscreen(b.win());
        b.layout(b.stage.width, b.stage.height);
    }

    // ---------------------------------------------------------------- session

    pub fn saveSession(b: *Browser) void {
        if (b.app.isLast(b)) b.app.saveSession();
        store.History.flush();
    }

    pub fn restore(b: *Browser, saved: []const store.SavedTab) void {
        for (saved, 0..) |s, i| {
            const k: ?[]const u8 = if (engine.Containers.get(s.container) == null) null else s.container;
            const t = b.newTab(.{ .url = s.url, .container = k, .select = i == 0, .lazy = i != 0 });
            if (i != 0 and s.title.len > 0) {
                t.title.set(s.title);
                ui.setLabel(t.pillLabel, s.title);
            }
        }
    }

    // ---------------------------------------------------------------- overlays

    pub fn closeMenu(b: *Browser) void {
        overlays.menuClosed();
        if (b.menu) |m| {
            b.stage.remove(m, true, null);
            b.menu = null;
            b.downloadsPanel = null;
        }
    }

    pub fn placeOverlays(b: *Browser) void {
        if (b.suggestions) |s| s.place();
        if (b.find) |f| f.place();
        if (b.toastItem) |t| {
            const n = ui.natural(t.w, -1);
            b.stage.place(t, .{ .x = b.card.midX() - n[0] / 2, .y = b.card.maxY() - n[1] - 18, .w = n[0], .h = n[1] }, false);
        }
        b.placeStatus();
    }

    /// a menu of glass, under r (or at a point)
    pub fn openMenu(b: *Browser, content: Widget, r: Rect, width: ?f64, alignRight: bool) void {
        b.closeMenu();
        const wrap = ui.box(true, 0);
        ui.cls(wrap, &.{"iris-menu"});
        // a long menu scrolls inside the window
        const nat = ui.natural(content, if (width) |w| @intFromFloat(w) else -1)[1];
        const room = @max(160, b.stage.height - r.maxY() - 24);
        if (nat > room) {
            const sc = c.gtk_scrolled_window_new().?;
            c.gtk_scrolled_window_set_policy(@ptrCast(sc), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
            c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(sc), 1);
            c.gtk_scrolled_window_set_max_content_height(@ptrCast(sc), @intFromFloat(room - 12));
            c.gtk_scrolled_window_set_child(@ptrCast(sc), content);
            ui.append(wrap, sc);
        } else ui.append(wrap, content);
        const it = b.stage.add(wrap, .overlay, .{ .radius = 18, .level = 0.70, .panel = true, .bend = 9, .rim = 18, .lens = 0.02, .blur = 3, .shadow = 1 }, false);
        var n = ui.natural(wrap, -1);
        if (width) |w| n = .{ w, ui.natural(wrap, @intFromFloat(w))[1] };
        var x = if (alignRight) r.maxX() - n[0] else r.x;
        var y = r.maxY() + 8;
        x = @min(@max(8, x), b.stage.width - n[0] - 8);
        if (y + n[1] > b.stage.height - 8) y = @max(8, r.y - n[1] - 8);
        it.frame.go(.{ .x = x, .y = y, .w = n[0], .h = @min(n[1], b.stage.height - 16) }, false);
        it.alpha.value = 0;
        it.scale.value = 0.92;
        b.stage.show(it, true, true);
        // each row lights up as glass under the pointer
        b.glassRows(it, content);
        b.menu = it;
    }

    pub fn glassRows(b: *Browser, it: *Item, w: Widget) void {
        var ch = c.gtk_widget_get_first_child(w);
        while (ch) |child| : (ch = c.gtk_widget_get_next_sibling(child)) {
            if (c.gtk_widget_has_css_class(child, "iris-row") != 0) {
                b.stage.part(it, child, .{ .radius = 10, .level = 0.45, .bend = 3, .rim = 8, .dispersion = false }, true);
            } else b.glassRows(it, child);
        }
    }

    pub fn toast(b: *Browser, text: []const u8) void {
        b.showToast(text, null);
    }

    /// a notice with one action; ctx is an Act or anything with a method f
    pub fn toastAction(b: *Browser, text: []const u8, name: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
        const T = @TypeOf(ctx);
        const Wrap = struct {
            b: *Browser,
            ctx: T,
            fn run(w: *@This()) void {
                f(w.ctx);
                w.b.hideToast();
            }
        };
        const w = core.gpa.create(Wrap) catch return;
        w.* = .{ .b = b, .ctx = ctx };
        b.showToast(text, ui.textButton(name, w, Wrap.run));
    }

    fn showToast(b: *Browser, text: []const u8, action: ?Widget) void {
        if (b.toastItem) |t| b.stage.remove(t, true, null);
        if (b.toastTimer != 0) _ = c.g_source_remove(b.toastTimer);
        b.toastTimer = 0;
        const bx = ui.box(false, 10);
        ui.cls(bx, &.{"iris-toast"});
        c.gtk_widget_set_margin_start(bx, 16);
        c.gtk_widget_set_margin_end(bx, 8);
        c.gtk_widget_set_margin_top(bx, 6);
        c.gtk_widget_set_margin_bottom(bx, 6);
        ui.append(bx, ui.label(text, &.{}));
        if (action) |a| ui.append(bx, a);
        const x = ui.button("window-close-symbolic", "Dismiss", b, hideToast);
        ui.cls(x, &.{"small"});
        c.gtk_widget_set_size_request(x, 24, 24);
        ui.append(bx, x);
        const it = b.stage.add(bx, .overlay, .{ .radius = 22, .level = 0.5, .bend = 8, .rim = 16, .shadow = 1 }, false);
        const n = ui.natural(bx, -1);
        it.frame.go(.{ .x = b.card.midX() - n[0] / 2, .y = b.card.maxY() - n[1] - 18, .w = n[0], .h = n[1] }, false);
        it.alpha.value = 0;
        it.scale.value = 0.9;
        b.stage.show(it, true, true);
        b.toastItem = it;
        b.toastTimer = core.after(6000, b, toastTimeout);
    }

    fn toastTimeout(b: *Browser) void {
        b.toastTimer = 0;
        b.hideToast();
    }

    pub fn hideToast(b: *Browser) void {
        if (b.toastItem) |t| b.stage.remove(t, true, null);
        b.toastItem = null;
    }

    fn buildStatus(b: *Browser) void {
        b.statusLabel = ui.label("", &.{"iris-dim"});
        ui.ellipsize(b.statusLabel, 10);
        c.gtk_label_set_max_width_chars(@ptrCast(b.statusLabel), 70);
        c.gtk_widget_set_margin_start(b.statusLabel, 12);
        c.gtk_widget_set_margin_end(b.statusLabel, 12);
        c.gtk_widget_set_margin_top(b.statusLabel, 5);
        c.gtk_widget_set_margin_bottom(b.statusLabel, 5);
        c.gtk_widget_set_can_target(b.statusLabel, 0);
        b.status = b.stage.add(b.statusLabel, .overlay, .{ .radius = 14, .level = 0.55, .bend = 5, .rim = 10, .dispersion = false }, false);
        b.stage.show(b.status, false, false);
    }

    fn placeStatus(b: *Browser) void {
        const n = ui.natural(b.statusLabel, -1);
        b.stage.place(b.status, .{ .x = b.card.x + 10, .y = b.card.maxY() - n[1] - 10, .w = @min(n[0], b.card.w * 0.6), .h = n[1] }, false);
    }

    pub fn hoverLink(b: *Browser, t: *Tab, link: ?[]const u8) void {
        if (t != b.current) return;
        if (link) |l| if (!std.mem.startsWith(u8, l, "javascript:")) {
            // the link's site is looked up while the pointer rests on it
            if (t.web) |w| if (c.webkit_web_view_get_network_session(w)) |s| {
                const target = search.unwrapRedirect(l);
                defer if (target) |x| core.gpa.free(x);
                if (search.host(target orelse l)) |h| {
                    defer core.gpa.free(h);
                    engine.Engine.warm(s, &.{h});
                }
            };
            ui.setLabel(b.statusLabel, l);
            b.placeStatus();
            b.stage.show(b.status, true, true);
            return;
        };
        if (b.status.shown) b.stage.show(b.status, false, true);
    }

    // ---------------------------------------------------------------- downloads

    /// the downloads button: there while a file comes in, then with the
    /// number finished until you open the downloads
    fn updateDownloadsButton(b: *Browser) void {
        const show = engine.Downloads.active() > 0 or b.unseenDownloads > 0;
        const was = c.gtk_widget_get_visible(b.downloadsButton) != 0;
        c.gtk_widget_set_visible(b.downloadsButton, @intFromBool(show));
        const n = if (b.unseenDownloads > 99) core.dupe("99+") else core.fmt("{d}", .{b.unseenDownloads});
        defer core.gpa.free(n);
        ui.setLabel(b.downloadsBadge, n);
        c.gtk_widget_set_visible(b.downloadsBadge, @intFromBool(b.unseenDownloads > 0));
        if (was != show) b.layout(b.stage.width, b.stage.height);
        b.stage.dirtyChrome();
    }

    fn downloadChangedCB(ctx: *anyopaque, d: ?*engine.Download) void {
        const b: *Browser = core.cast(*Browser, ctx);
        if (d) |dl| if (dl.done and !dl.failed) {
            const g = b.counted.getOrPut(core.gpa, dl) catch return;
            if (!g.found_existing) b.unseenDownloads += 1;
        };
        b.updateDownloadsButton();
        if (b.downloadsPanel) |p| p.update(d);
    }

    pub fn showDownloads(b: *Browser) void {
        b.unseenDownloads = 0;
        b.updateDownloadsButton();
        const panel = overlays.DownloadsPanel.create(b);
        b.openMenu(panel.box, b.stage.bounds(b.downloadsButton) orelse b.actions.frame.rect(), 380, true);
        b.downloadsPanel = panel;
    }

    // ---------------------------------------------------------------- what pages ask

    pub fn permission(b: *Browser, t: *Tab, req: *c.WebKitPermissionRequest) void {
        overlays.permission(b, t, req);
    }

    pub fn contextMenu(b: *Browser, t: *Tab, menu: *c.WebKitContextMenu, hit: *c.WebKitHitTestResult) void {
        overlays.contextMenu(b, t, menu, hit);
    }

    pub fn optionMenu(b: *Browser, t: *Tab, menu: *c.WebKitOptionMenu, rect: ?*c.WebKitRectangle) void {
        overlays.optionMenu(b, t, menu, rect);
    }

    pub fn scriptDialog(b: *Browser, t: *Tab, d: *c.WebKitScriptDialog) void {
        overlays.scriptDialog(b, t, d);
    }

    pub fn fileChooser(b: *Browser, t: *Tab, r: *c.WebKitFileChooserRequest) void {
        overlays.fileChooser(b, t, r);
    }

    pub fn zoom(b: *Browser, d: i32) void {
        const t = b.current orelse return;
        const steps = [_]f64{ 0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3 };
        if (d == 0) return t.setZoom(1);
        var i: i32 = 4;
        for (steps, 0..) |s, k| if (s >= t.zoom - 0.001) {
            i = @intCast(k);
            break;
        };
        const j: usize = @intCast(@max(0, @min(@as(i32, steps.len - 1), i + d)));
        t.setZoom(steps[j]);
    }

    pub fn openFind(b: *Browser) void {
        if (b.find) |f| {
            _ = c.gtk_widget_grab_focus(f.text);
            return;
        }
        b.find = overlays.FindBar.create(b);
    }

    pub fn closeTabs(b: *Browser, container: []const u8) void {
        var i: usize = 0;
        while (i < b.tabs.items.len) {
            const t = b.tabs.items[i];
            if (t.container != null and std.mem.eql(u8, t.container.?, container)) b.close(t) else i += 1;
        }
    }
};
