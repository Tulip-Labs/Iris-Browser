//! Small bridges from Zig to GLib's C world (signals, idles, timeouts,
//! strings) and the geometry and springs every moving piece of Iris uses.
const std = @import("std");
pub const c = @import("c");

/// one allocator for Iris: GLib's own heap, so memory from either side
/// can be freed by the other's rules when needed
pub const gpa = std.heap.c_allocator;

pub const Widget = *c.GtkWidget;

/// a pointer as the type a C function wants (GObject casts are unchecked
/// in C too)
pub inline fn cast(comptime T: type, p: anytype) T {
    return @ptrCast(@alignCast(p));
}

pub inline fn obj(p: anytype) *c.GObject {
    return @ptrCast(@alignCast(p));
}

// ---------------------------------------------------------------- signals

fn connectRaw(instance: anytype, name: [*:0]const u8, cb: anytype, data: ?*anyopaque, late: bool) c_ulong {
    return c.g_signal_connect_data(@ptrCast(instance), name, @ptrCast(cb), data, null, if (late) c.G_CONNECT_AFTER else 0);
}

/// signal(instance) -> void
pub fn on(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, d: ?*anyopaque) callconv(.c) void {
            f(cast(T, d));
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance) -> void, after the default handler
pub fn onAfter(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, d: ?*anyopaque) callconv(.c) void {
            f(cast(T, d));
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), true);
}

/// signal(instance, a) -> void
pub fn on1(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), ?*anyopaque) void) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, a: ?*anyopaque, d: ?*anyopaque) callconv(.c) void {
            f(cast(T, d), a);
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance, a, b) -> void
pub fn on2(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), ?*anyopaque, ?*anyopaque) void) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque, d: ?*anyopaque) callconv(.c) void {
            f(cast(T, d), a, b);
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance) -> gboolean
pub fn onBool0(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) bool) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, d: ?*anyopaque) callconv(.c) c.gboolean {
            return @intFromBool(f(cast(T, d)));
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance, a) -> gboolean
pub fn onBool1(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), ?*anyopaque) bool) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, a: ?*anyopaque, d: ?*anyopaque) callconv(.c) c.gboolean {
            return @intFromBool(f(cast(T, d), a));
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance, a, b) -> gboolean
pub fn onBool2(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), ?*anyopaque, ?*anyopaque) bool) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque, d: ?*anyopaque) callconv(.c) c.gboolean {
            return @intFromBool(f(cast(T, d), a, b));
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance, a, uint) -> gboolean (policy decisions)
pub fn onBoolPtrUInt(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), ?*anyopaque, u32) bool) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, a: ?*anyopaque, b: c_uint, d: ?*anyopaque) callconv(.c) c.gboolean {
            return @intFromBool(f(cast(T, d), a, @intCast(b)));
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// key-pressed(controller, keyval, keycode, state) -> gboolean
pub fn onKey(instance: anytype, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32, u32, u32) bool) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, key: c_uint, code: c_uint, state: c_uint, d: ?*anyopaque) callconv(.c) c.gboolean {
            return @intFromBool(f(cast(T, d), @intCast(key), @intCast(code), @intCast(state)));
        }
    };
    return connectRaw(instance, "key-pressed", &S.cb, @ptrCast(ctx), false);
}

/// key-released(controller, keyval, keycode, state)
pub fn onKeyUp(instance: anytype, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32, u32, u32) void) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, key: c_uint, code: c_uint, state: c_uint, d: ?*anyopaque) callconv(.c) void {
            f(cast(T, d), @intCast(key), @intCast(code), @intCast(state));
        }
    };
    return connectRaw(instance, "key-released", &S.cb, @ptrCast(ctx), false);
}

/// signal(instance, double, double) (motion, enter)
pub fn onXY(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), f64, f64) void) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, x: f64, y: f64, d: ?*anyopaque) callconv(.c) void {
            f(cast(T, d), x, y);
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance, double, double) -> gboolean (scroll)
pub fn onXYBool(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), f64, f64) bool) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, x: f64, y: f64, d: ?*anyopaque) callconv(.c) c.gboolean {
            return @intFromBool(f(cast(T, d), x, y));
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// signal(instance, int n, double, double) (pressed, released)
pub fn onPress(instance: anytype, name: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), i32, f64, f64) void) c_ulong {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(_: ?*anyopaque, n: c_int, x: f64, y: f64, d: ?*anyopaque) callconv(.c) void {
            f(cast(T, d), @intCast(n), x, y);
        }
    };
    return connectRaw(instance, name, &S.cb, @ptrCast(ctx), false);
}

/// a callback when GLib's main loop is next idle
pub fn idle(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(d: ?*anyopaque) callconv(.c) c.gboolean {
            f(cast(T, d));
            return 0;
        }
    };
    _ = c.g_idle_add_full(c.G_PRIORITY_DEFAULT_IDLE, &S.cb, @ptrCast(ctx), null);
}

/// a callback after ms milliseconds; returns the source id
pub fn after(ms: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) u32 {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(d: ?*anyopaque) callconv(.c) c.gboolean {
            f(cast(T, d));
            return 0;
        }
    };
    return c.g_timeout_add_full(c.G_PRIORITY_DEFAULT, ms, &S.cb, @ptrCast(ctx), null);
}

/// a callback every ms milliseconds while it returns true
pub fn every(ms: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx)) bool) u32 {
    const T = @TypeOf(ctx);
    const S = struct {
        fn cb(d: ?*anyopaque) callconv(.c) c.gboolean {
            return @intFromBool(f(cast(T, d)));
        }
    };
    return c.g_timeout_add_full(c.G_PRIORITY_DEFAULT, ms, &S.cb, @ptrCast(ctx), null);
}

// ---------------------------------------------------------------- strings

/// a C string as a slice (empty for null)
pub fn str(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "";
}

/// a zero-terminated copy (Iris's heap); free with gpa.free
pub fn z(s: []const u8) [:0]u8 {
    return gpa.dupeZ(u8, s) catch @panic("out of memory");
}

/// a string copy (Iris's heap)
pub fn dupe(s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @panic("out of memory");
}

/// formatted text (Iris's heap)
pub fn fmt(comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(gpa, f, args) catch @panic("out of memory");
}

/// formatted, zero-terminated text (Iris's heap)
pub fn fmtZ(comptime f: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, f, args, 0) catch @panic("out of memory");
}

/// a string GLib allocated, copied to Iris's heap and freed
pub fn takeStr(p: ?[*:0]u8) ?[]u8 {
    const s = p orelse return null;
    defer c.g_free(s);
    return dupe(std.mem.span(s));
}

/// a string that owns its bytes and can change (labels, addresses)
pub const Text = struct {
    buf: []u8 = &.{},

    pub fn get(t: Text) []const u8 {
        return t.buf;
    }

    pub fn set(t: *Text, s: []const u8) void {
        if (std.mem.eql(u8, t.buf, s)) return;
        const n = dupe(s);
        gpa.free(t.buf);
        t.buf = n;
    }

    pub fn deinit(t: *Text) void {
        gpa.free(t.buf);
        t.buf = &.{};
    }
};

// ---------------------------------------------------------------- GObject

pub fn unref(p: ?*anyopaque) void {
    if (p) |o| c.g_object_unref(o);
}

pub fn ref(p: anytype) @TypeOf(p) {
    _ = c.g_object_ref(@ptrCast(p));
    return p;
}

/// a value attached to a GObject (as Swift's Unmanaged did)
pub fn setData(o: anytype, key: [*:0]const u8, v: ?*anyopaque) void {
    c.g_object_set_data(obj(o), key, v);
}

pub fn getData(comptime T: type, o: anytype, key: [*:0]const u8) ?T {
    const d = c.g_object_get_data(obj(o), key) orelse return null;
    return cast(T, d);
}

/// g_object_get for one boolean property
pub fn getBool(o: anytype, name: [*:0]const u8) bool {
    var v: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_BOOLEAN);
    c.g_object_get_property(obj(o), name, &v);
    const b = c.g_value_get_boolean(&v) != 0;
    c.g_value_unset(&v);
    return b;
}

/// the GType of a GObject instance
pub fn typeOf(o: anytype) c.GType {
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(o));
    return inst.g_class.*.g_type;
}

pub fn typeName(o: anytype) []const u8 {
    return str(c.g_type_name(typeOf(o)));
}

pub fn isA(o: anytype, t: c.GType) bool {
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(o)), t) != 0;
}

// ---------------------------------------------------------------- geometry

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn maxX(r: Rect) f64 {
        return r.x + r.w;
    }
    pub fn maxY(r: Rect) f64 {
        return r.y + r.h;
    }
    pub fn midX(r: Rect) f64 {
        return r.x + r.w / 2;
    }
    pub fn midY(r: Rect) f64 {
        return r.y + r.h / 2;
    }
    pub fn inset(r: Rect, d: f64) Rect {
        return .{ .x = r.x + d, .y = r.y + d, .w = @max(0, r.w - 2 * d), .h = @max(0, r.h - 2 * d) };
    }
    pub fn contains(r: Rect, px: f64, py: f64) bool {
        return px >= r.x and px < r.maxX() and py >= r.y and py < r.maxY();
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

pub const RGBA = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1,

    pub const white = RGBA{ .r = 1, .g = 1, .b = 1 };
    pub const black = RGBA{ .r = 0, .g = 0, .b = 0 };

    pub fn hex(s: []const u8, a: f64) RGBA {
        const t = std.mem.trimLeft(u8, s, "#");
        const v = std.fmt.parseInt(u32, t, 16) catch 0;
        return .{ .r = @as(f64, @floatFromInt((v >> 16) & 255)) / 255, .g = @as(f64, @floatFromInt((v >> 8) & 255)) / 255, .b = @as(f64, @floatFromInt(v & 255)) / 255, .a = a };
    }

    pub fn alpha(c0: RGBA, x: f64) RGBA {
        return .{ .r = c0.r, .g = c0.g, .b = c0.b, .a = c0.a * x };
    }

    pub fn gdk(c0: RGBA) c.GdkRGBA {
        return .{ .red = @floatCast(c0.r), .green = @floatCast(c0.g), .blue = @floatCast(c0.b), .alpha = @floatCast(c0.a) };
    }
};

/// A value that springs to where the interface wants it: positions, sizes,
/// fades, hovers and presses all move this way. Critically damped by
/// default; `bounce` lets a little overshoot through (the liquid feel).
pub const Spring = struct {
    value: f64,
    target: f64,
    velocity: f64 = 0,
    stiffness: f64,
    damping: f64,

    pub fn init(v: f64, stiffness: f64, bounce: f64) Spring {
        return .{ .value = v, .target = v, .stiffness = stiffness, .damping = 2 * (1 - bounce) * @sqrt(stiffness) };
    }

    pub fn settled(s: Spring) bool {
        return @abs(s.velocity) < 0.02 and @abs(s.target - s.value) < 0.02;
    }

    pub fn snap(s: *Spring, v: f64) void {
        s.value = v;
        s.target = v;
        s.velocity = 0;
    }

    /// moves dt seconds on; true while still moving
    pub fn step(s: *Spring, dt: f64) bool {
        if (s.settled()) {
            s.value = s.target;
            s.velocity = 0;
            return false;
        }
        // a few small steps keep a stiff spring stable at 60 Hz and below
        const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(dt / (1.0 / 240.0)))));
        const h = dt / @as(f64, @floatFromInt(n));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = s.stiffness * (s.target - s.value) - s.damping * s.velocity;
            s.velocity += a * h;
            s.value += s.velocity * h;
        }
        return true;
    }
};

/// four springs for a moving, resizing rectangle
pub const SpringRect = struct {
    x: Spring,
    y: Spring,
    w: Spring,
    h: Spring,
    fresh: bool = true,

    pub fn init(stiffness: f64, bounce: f64) SpringRect {
        return .{ .x = Spring.init(0, stiffness, bounce), .y = Spring.init(0, stiffness, bounce), .w = Spring.init(0, stiffness, bounce), .h = Spring.init(0, stiffness, bounce) };
    }

    pub fn rect(s: SpringRect) Rect {
        return .{ .x = s.x.value, .y = s.y.value, .w = @max(0, s.w.value), .h = @max(0, s.h.value) };
    }

    pub fn target(s: SpringRect) Rect {
        return .{ .x = s.x.target, .y = s.y.target, .w = s.w.target, .h = s.h.target };
    }

    pub fn settled(s: SpringRect) bool {
        return s.x.settled() and s.y.settled() and s.w.settled() and s.h.settled();
    }

    pub fn go(s: *SpringRect, r: Rect, animate: bool) void {
        if (s.fresh or !animate) {
            s.x.snap(r.x);
            s.y.snap(r.y);
            s.w.snap(r.w);
            s.h.snap(r.h);
            s.fresh = false;
            return;
        }
        s.x.target = r.x;
        s.y.target = r.y;
        s.w.target = r.w;
        s.h.target = r.h;
    }

    pub fn step(s: *SpringRect, dt: f64) bool {
        var m = s.x.step(dt);
        m = s.y.step(dt) or m;
        m = s.w.step(dt) or m;
        m = s.h.step(dt) or m;
        return m;
    }
};

test "a spring settles at its target" {
    var s = Spring.init(0, 380, 0);
    s.target = 10;
    var i: usize = 0;
    while (s.step(1.0 / 60.0) and i < 600) : (i += 1) {}
    try std.testing.expect(s.settled());
    try std.testing.expectApproxEqAbs(@as(f64, 10), s.value, 0.03);
}

test "colours from hex" {
    const c0 = RGBA.hex("#0a84ff", 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 / 255.0), c0.r, 1e-9);
    try std.testing.expectEqual(@as(f64, 0.5), c0.a);
}
