//! Liquid Glass, drawn with GTK's own render nodes (no shaders of Iris's,
//! so it runs the same on GTK's GL and Vulkan renderers, at any scale).
//!
//! Not frosted glass: what lies behind stays sharp. Glass bends it:
//! - the middle magnifies a little, like a lens;
//! - towards the rim the picture is pulled in from beyond the edge, in three
//!   steps that grow towards the edge, and the outermost step splits red and
//!   blue a little (dispersion);
//! - a rim of light runs round it, brightest where the light comes from
//!   (top left) and again opposite, plus a soft inner highlight;
//! - the pointer lights the glass where it is, and a press presses it in.
//!
//! The pages are WPE WebKit's own buffers (DMA-BUF textures inside GSK), so
//! the glass bends the live page with no copy.
const std = @import("std");
const core = @import("core.zig");
const c = core.c;
const Rect = core.Rect;
const RGBA = core.RGBA;

pub const Snap = *c.GtkSnapshot;
pub const Node = *c.GskRenderNode;

/// Iris's look: light, the colours of a dawn sky (Dark and Auto were
/// choices before 2.1.1)
pub const Look = struct {
    /// the ink of words and glyphs: a deep violet, the dawn's shadow
    pub const ink = RGBA{ .r = 0.14, .g = 0.11, .b = 0.25 };

    /// a glass tint by how much of the material shows (0.2 for bars, 0.7
    /// for panels)
    pub fn tint(level: f64, panel: bool) RGBA {
        return if (panel) .{ .r = 0.98, .g = 0.98, .b = 1, .a = level } else RGBA.white.alpha(level);
    }

    pub const rim: f64 = 1;
};

pub const Glass = struct {
    radius: f64,
    /// how much of the material shows (0 none, 1 all): hovers fade it in
    amount: f64 = 1,
    tint: RGBA = RGBA.white.alpha(0.16),
    /// when set, the tint comes from the look at this level
    level: ?f64 = null,
    /// a panel's tint (menus, notes): more solid, for reading
    panel: bool = false,
    /// refraction at the rim, in pixels pulled in from beyond the edge
    bend: f64 = 7,
    /// width of the bending rim
    rim: f64 = 14,
    /// lens magnification of the middle
    lens: f64 = 0.025,
    /// a touch of softening, for legibility (not frost)
    blur: f64 = 0,
    dispersion: bool = true,
    shadow: f64 = 0,
    rimLight: f64 = 1,
};

pub fn grect(r: Rect) c.graphene_rect_t {
    return .{ .origin = .{ .x = @floatCast(r.x), .y = @floatCast(r.y) }, .size = .{ .width = @floatCast(r.w), .height = @floatCast(r.h) } };
}

pub fn gpoint(x: f64, y: f64) c.graphene_point_t {
    return .{ .x = @floatCast(x), .y = @floatCast(y) };
}

pub fn rrect(r: Rect, radius: f64) c.GskRoundedRect {
    var rr: c.GskRoundedRect = undefined;
    var g = grect(r);
    _ = c.gsk_rounded_rect_init_from_rect(&rr, &g, @floatCast(@min(radius, @min(r.w, r.h) / 2)));
    return rr;
}

pub const Stop = struct { f64, RGBA };

pub fn color(s: Snap, col: RGBA, r: Rect) void {
    var k = col.gdk();
    var g = grect(r);
    c.gtk_snapshot_append_color(s, &k, &g);
}

pub fn rounded(s: Snap, col: RGBA, r: Rect, radius: f64) void {
    var rr = rrect(r, radius);
    c.gtk_snapshot_push_rounded_clip(s, &rr);
    color(s, col, r);
    c.gtk_snapshot_pop(s);
}

fn stops(comptime n: usize, st: [n]Stop) [n]c.GskColorStop {
    var out: [n]c.GskColorStop = undefined;
    for (st, 0..) |p, i| out[i] = .{ .offset = @floatCast(p[0]), .color = p[1].gdk() };
    return out;
}

pub fn linear(s: Snap, r: Rect, from: [2]f64, to: [2]f64, comptime n: usize, st: [n]Stop) void {
    var g = grect(r);
    var a = gpoint(from[0], from[1]);
    var b = gpoint(to[0], to[1]);
    const cs = stops(n, st);
    c.gtk_snapshot_append_linear_gradient(s, &g, &a, &b, &cs, n);
}

pub fn radial(s: Snap, r: Rect, center: [2]f64, radius: f64, comptime n: usize, st: [n]Stop) void {
    var g = grect(r);
    var ctr = gpoint(center[0], center[1]);
    const cs = stops(n, st);
    c.gtk_snapshot_append_radial_gradient(s, &g, &ctr, @floatCast(radius), @floatCast(radius), 0, 1, &cs, n);
}

pub const Shadow = struct { dx: f64 = 0, dy: f64 = 0, spread: f64 = 0, blur: f64 };

pub fn inset(s: Snap, r: Rect, radius: f64, col: RGBA, sh: Shadow) void {
    var rr = rrect(r, radius);
    var k = col.gdk();
    c.gtk_snapshot_append_inset_shadow(s, &rr, &k, @floatCast(sh.dx), @floatCast(sh.dy), @floatCast(sh.spread), @floatCast(sh.blur));
}

pub fn outset(s: Snap, r: Rect, radius: f64, col: RGBA, sh: Shadow) void {
    var rr = rrect(r, radius);
    var k = col.gdk();
    c.gtk_snapshot_append_outset_shadow(s, &rr, &k, @floatCast(sh.dx), @floatCast(sh.dy), @floatCast(sh.spread), @floatCast(sh.blur));
}

/// a stroke along a rounded rectangle; what follows until popStroke is its paint
pub fn pushRimStroke(s: Snap, r: Rect, radius: f64, width: f64) ?*c.GskPath {
    const b = c.gsk_path_builder_new() orelse return null;
    var rr = rrect(r.inset(width / 2), @max(0, radius - width / 2));
    c.gsk_path_builder_add_rounded_rect(b, &rr);
    const path = c.gsk_path_builder_free_to_path(b);
    const stroke = c.gsk_stroke_new(@floatCast(width));
    c.gtk_snapshot_push_stroke(s, path, stroke);
    c.gsk_stroke_free(stroke);
    return path;
}

pub fn popRimStroke(s: Snap, path: ?*c.GskPath) void {
    if (path) |p| {
        c.gtk_snapshot_pop(s);
        c.gsk_path_unref(p);
    }
}

/// draws `scene` scaled about the middle of r so its edges move by d
/// pixels inwards (d > 0: content from beyond the edge comes in)
pub fn bent(s: Snap, scene: Node, r: Rect, d: f64, lens: f64, blur: f64) void {
    const sx = @max(0.2, 1 - 2 * d / @max(r.w, 1)) * (1 + lens);
    const sy = @max(0.2, 1 - 2 * d / @max(r.h, 1)) * (1 + lens);
    c.gtk_snapshot_save(s);
    var ctr = gpoint(r.midX(), r.midY());
    c.gtk_snapshot_translate(s, &ctr);
    c.gtk_snapshot_scale(s, @floatCast(sx), @floatCast(sy));
    var back = gpoint(-r.midX(), -r.midY());
    c.gtk_snapshot_translate(s, &back);
    // only the part of the scene this glass can show
    var need = grect(r.inset(-(@abs(d) + blur * 3 + 4)));
    c.gtk_snapshot_push_clip(s, &need);
    if (blur > 0) c.gtk_snapshot_push_blur(s, blur);
    c.gtk_snapshot_append_node(s, scene);
    if (blur > 0) c.gtk_snapshot_pop(s);
    c.gtk_snapshot_pop(s);
    c.gtk_snapshot_restore(s);
}

/// keeps one colour channel of what follows (dispersion); pop after
fn pushChannel(s: Snap, i: usize) void {
    var m: c.graphene_matrix_t = undefined;
    var f = [_]f32{0} ** 16;
    f[15] = 1;
    f[i * 5] = 1;
    _ = c.graphene_matrix_init_from_float(&m, &f);
    var off: c.graphene_vec4_t = undefined;
    _ = c.graphene_vec4_init(&off, 0, 0, 0, 0);
    c.gtk_snapshot_push_color_matrix(s, &m, &off);
}

pub const Light = struct {
    pointer: ?[2]f64 = null,
    hover: f64 = 0,
    press: f64 = 0,
};

/// Liquid Glass over `scene` (what lies behind, as one node) in r.
pub fn glass(s: Snap, scene: ?Node, r: Rect, g0: Glass, light: Light) void {
    if (g0.amount <= 0.004 or r.w <= 1 or r.h <= 1) return;
    var g = g0;
    if (g.level) |l| g.tint = Look.tint(l, g.panel);
    g.rimLight *= Look.rim;
    const fade = g.amount < 0.999;
    if (fade) c.gtk_snapshot_push_opacity(s, g.amount);
    const rad = @min(g.radius, @min(r.w, r.h) / 2);
    if (g.shadow > 0) outset(s, r, rad, RGBA.black.alpha(0.10 * g.shadow), .{ .dy = 2, .blur = 12 });
    var rr = rrect(r, rad);
    c.gtk_snapshot_push_rounded_clip(s, &rr);
    if (scene) |sc| {
        const bend = g.bend * (1 + 0.35 * light.press);
        // the body: a gentle lens
        bent(s, sc, r, 0, g.lens + 0.012 * light.press, g.blur);
        // the rim: three steps, each nearer the edge and bending more
        const steps = [_][2]f64{ .{ 0.4, 1.0 }, .{ 0.72, 0.62 }, .{ 1.0, 0.34 } };
        for (steps, 0..) |st, i| {
            const k = st[0];
            const w = @max(2, g.rim * st[1]);
            c.gtk_snapshot_push_mask(s, c.GSK_MASK_MODE_ALPHA);
            inset(s, r, rad, RGBA.white, .{ .spread = w * 0.35, .blur = w });
            c.gtk_snapshot_pop(s);
            if (g.dispersion and i == steps.len - 1) {
                // red bends a little less and blue a little more
                c.gtk_snapshot_push_blend(s, c.GSK_BLEND_MODE_SCREEN);
                pushChannel(s, 0);
                bent(s, sc, r, bend * k * 0.86, 0, g.blur);
                c.gtk_snapshot_pop(s);
                c.gtk_snapshot_pop(s);
                c.gtk_snapshot_push_blend(s, c.GSK_BLEND_MODE_SCREEN);
                pushChannel(s, 1);
                bent(s, sc, r, bend * k, 0, g.blur);
                c.gtk_snapshot_pop(s);
                c.gtk_snapshot_pop(s);
                pushChannel(s, 2);
                bent(s, sc, r, bend * k * 1.14, 0, g.blur);
                c.gtk_snapshot_pop(s);
                c.gtk_snapshot_pop(s);
                c.gtk_snapshot_pop(s);
            } else {
                bent(s, sc, r, bend * k, 0, g.blur);
            }
            c.gtk_snapshot_pop(s);
        }
    }
    // the glass itself: a faint tint, lighter when hovered or pressed
    color(s, g.tint.alpha(1 + 0.6 * light.hover + 0.9 * light.press), r);
    // light from above: a bright line just inside the top, a soft shade
    // inside the bottom
    inset(s, r, rad, RGBA.white.alpha(0.55 * g.rimLight), .{ .dy = 1.2, .blur = 1.6 });
    inset(s, r, rad, RGBA.white.alpha(0.22 * g.rimLight), .{ .blur = @min(r.h, r.w) * 0.35 });
    inset(s, r, rad, RGBA.black.alpha(0.05 * g.rimLight), .{ .dy = -1.2, .blur = 3 });
    // the pointer lights the glass where it is
    if (light.pointer) |p| {
        if (light.hover > 0.01) {
            const reach = @max(r.h, @min(r.w, 160)) * 0.9;
            radial(s, r, p, reach, 2, .{ .{ 0, RGBA.white.alpha(0.30 * light.hover) }, .{ 1, RGBA.white.alpha(0) } });
        }
    }
    c.gtk_snapshot_pop(s);
    // the rim of light
    if (g.rimLight > 0) {
        const p1 = pushRimStroke(s, r, rad, 1);
        linear(s, r, .{ r.x, r.y }, .{ r.maxX(), r.maxY() }, 4, .{
            .{ 0, RGBA.white.alpha(0.95 * g.rimLight) },
            .{ 0.35, RGBA.white.alpha(0.18 * g.rimLight) },
            .{ 0.62, RGBA.white.alpha(0.10 * g.rimLight) },
            .{ 1, RGBA.white.alpha(0.70 * g.rimLight) },
        });
        popRimStroke(s, p1);
        // and a hair of shade outside it, so glass reads on white pages
        const p2 = pushRimStroke(s, r.inset(-0.5), rad + 0.5, 0.6);
        color(s, RGBA.black.alpha(0.10 * g.rimLight), r.inset(-1));
        popRimStroke(s, p2);
    }
    if (fade) c.gtk_snapshot_pop(s);
}
