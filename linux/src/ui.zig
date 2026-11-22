//! Plain GTK pieces the browser is built from. They draw no backgrounds of
//! their own: the Stage puts glass under them.
const std = @import("std");
const core = @import("core.zig");
const c = core.c;
const Widget = core.Widget;
const RGBA = core.RGBA;

pub fn cls(w: anytype, names: []const [*:0]const u8) void {
    for (names) |n| c.gtk_widget_add_css_class(@ptrCast(w), n);
}

pub fn setCls(w: anytype, name: [*:0]const u8, on: bool) void {
    if (on) c.gtk_widget_add_css_class(@ptrCast(w), name) else c.gtk_widget_remove_css_class(@ptrCast(w), name);
}

pub fn box(vertical: bool, spacing: c_int) Widget {
    return c.gtk_box_new(if (vertical) c.GTK_ORIENTATION_VERTICAL else c.GTK_ORIENTATION_HORIZONTAL, spacing).?;
}

pub fn append(b: Widget, child: Widget) void {
    c.gtk_box_append(@ptrCast(b), child);
}

pub fn label(words: []const u8, classes: []const [*:0]const u8) Widget {
    const t = core.z(words);
    defer core.gpa.free(t);
    const l = c.gtk_label_new(t.ptr).?;
    cls(l, classes);
    return l;
}

pub fn setLabel(l: Widget, words: []const u8) void {
    const t = core.z(words);
    defer core.gpa.free(t);
    c.gtk_label_set_text(@ptrCast(l), t.ptr);
}

pub fn ellipsize(l: Widget, chars: c_int) void {
    c.gtk_label_set_ellipsize(@ptrCast(l), c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_width_chars(@ptrCast(l), chars);
    c.gtk_label_set_xalign(@ptrCast(l), 0);
}

pub fn icon(name: [*:0]const u8, size: c_int) Widget {
    const i = c.gtk_image_new_from_icon_name(name).?;
    c.gtk_image_set_pixel_size(@ptrCast(i), size);
    return i;
}

/// a round icon button; f runs on click
pub fn button(iconName: [*:0]const u8, tip: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) Widget {
    const b = c.gtk_button_new_from_icon_name(iconName).?;
    cls(b, &.{ "iris-flat", "iris-icon" });
    c.gtk_widget_set_size_request(b, 34, 34);
    c.gtk_widget_set_tooltip_text(b, tip);
    c.gtk_widget_set_focus_on_click(b, 0);
    _ = core.on(b, "clicked", ctx, f);
    return b;
}

/// a button with a label (notices)
pub fn textButton(words: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) Widget {
    const t = core.z(words);
    defer core.gpa.free(t);
    const b = c.gtk_button_new_with_label(t.ptr).?;
    cls(b, &.{ "iris-flat", "iris-text-button" });
    c.gtk_widget_set_focus_on_click(b, 0);
    _ = core.on(b, "clicked", ctx, f);
    return b;
}

pub const RowLead = union(enum) { none, icon: [*:0]const u8, dot: RGBA, widget: Widget };

/// a row of a menu: something at the start, text, and the keys that do the
/// same; f runs on click
pub fn row(lead: RowLead, words: []const u8, keys: ?[]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) Widget {
    const b = c.gtk_button_new().?;
    cls(b, &.{ "iris-flat", "iris-row" });
    c.gtk_widget_set_focus_on_click(b, 0);
    const h = box(false, 10);
    switch (lead) {
        .none => {},
        .icon => |n| append(h, icon(n, 16)),
        .dot => |col| append(h, dot(col, 16)),
        .widget => |w| append(h, w),
    }
    const l = label(words, &.{});
    c.gtk_label_set_xalign(@ptrCast(l), 0);
    c.gtk_label_set_ellipsize(@ptrCast(l), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_hexpand(l, 1);
    append(h, l);
    if (keys) |k| append(h, label(k, &.{ "iris-dim", "iris-keys" }));
    c.gtk_button_set_child(@ptrCast(b), h);
    _ = core.on(b, "clicked", ctx, f);
    return b;
}

pub fn separator() Widget {
    const s = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?;
    cls(s, &.{"iris-sep"});
    return s;
}

fn drawDot(_: [*c]c.GtkDrawingArea, cr: ?*c.cairo_t, w: c_int, h: c_int, d: ?*anyopaque) callconv(.c) void {
    const col: *RGBA = core.cast(*RGBA, d);
    const r = @as(f64, @floatFromInt(@min(w, h))) / 2 - 2.5;
    c.cairo_arc(cr, @as(f64, @floatFromInt(w)) / 2, @as(f64, @floatFromInt(h)) / 2, r, 0, 2 * std.math.pi);
    c.cairo_set_source_rgba(cr, col.r, col.g, col.b, col.a);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.7);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

fn freeDot(d: ?*anyopaque) callconv(.c) void {
    core.gpa.destroy(core.cast(*RGBA, d));
}

/// a small coloured dot (a container's colour)
pub fn dot(col: RGBA, size: c_int) Widget {
    const d = c.gtk_drawing_area_new().?;
    c.gtk_widget_set_size_request(d, size, size);
    c.gtk_widget_set_valign(d, c.GTK_ALIGN_CENTER);
    const k = core.gpa.create(RGBA) catch @panic("oom");
    k.* = col;
    c.gtk_drawing_area_set_draw_func(@ptrCast(d), drawDot, k, freeDot);
    return d;
}

pub fn natural(w: Widget, forWidth: c_int) [2]f64 {
    var mw: c_int = 0;
    var nw: c_int = 0;
    var mh: c_int = 0;
    var nh: c_int = 0;
    c.gtk_widget_measure(w, c.GTK_ORIENTATION_HORIZONTAL, -1, &mw, &nw, null, null);
    c.gtk_widget_measure(w, c.GTK_ORIENTATION_VERTICAL, if (forWidth > 0) forWidth else nw, &mh, &nh, null, null);
    return .{ @floatFromInt(nw), @floatFromInt(nh) };
}

pub fn text(t: Widget) []const u8 {
    return core.str(c.gtk_editable_get_text(@ptrCast(t)));
}

pub fn setText(t: Widget, s: []const u8) void {
    const z = core.z(s);
    defer core.gpa.free(z);
    c.gtk_editable_set_text(@ptrCast(t), z.ptr);
}

/// Iris's style sheet (light: the dawn's violet ink)
pub fn installCSS() void {
    const p = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(p, css);
    c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), @ptrCast(p), 600);
}

pub const palette = [_][]const u8{ "#0a84ff", "#ff9f0a", "#30d158", "#ff375f", "#bf5af2", "#64d2ff", "#ffd60a", "#ac8e68" };

const css =
    \\window.iris, window.iris.background { background: none; box-shadow: none; }
    \\window.iris.csd { border-radius: 14px; }
    \\iris-stage { color: #241c40; }
    \\.iris-flat, .iris-flat:hover, .iris-flat:active, .iris-flat:checked, .iris-flat:focus {
    \\  background: none; box-shadow: none; border: none; outline: none; text-shadow: none; -gtk-icon-shadow: none; }
    \\.iris-flat { min-height: 0; min-width: 0; padding: 0; }
    \\.iris-icon { min-width: 34px; min-height: 34px; border-radius: 999px; color: #241c40; }
    \\.iris-icon:disabled { color: alpha(#241c40, .32); }
    \\.iris-icon.small { min-width: 22px; min-height: 22px; }
    \\.iris-tab { padding: 0 6px 0 10px; }
    \\.iris-tab label { font-weight: 500; font-size: 13px; }
    \\.iris-tab.selected label { font-weight: 600; }
    \\.iris-tab.iris-sandboxed { border-radius: 16px; box-shadow: inset 0 0 0 1.5px alpha(#ff9f0a, .85); }
    \\.iris-tab.iris-sandboxed > image:first-child { color: #e8890a; }
    \\.iris-address { padding: 0 12px; }
    \\.iris-address text { font-size: 14.5px; background: none; caret-color: #6a4cf5; }
    \\.iris-address text selection { background: alpha(#6a4cf5, .24); color: inherit; }
    \\.iris-address text placeholder { color: alpha(#241c40, .45); }
    \\.iris-chip { font-size: 12px; font-weight: 600; padding: 1px 9px 1px 7px; border-radius: 999px; color: white; }
    \\.iris-row { padding: 7px 12px; border-radius: 10px; min-height: 22px; }
    \\.iris-row.selected { background: alpha(#6a4cf5, .14); }
    \\.iris-choice { padding: 3px 10px; border-radius: 999px; font-weight: 600; color: #241c40; }
    \\.iris-choice.selected { background: alpha(#6a4cf5, .18); box-shadow: inset 0 0 0 1px alpha(#6a4cf5, .45); }
    \\.iris-text-button { padding: 4px 12px; border-radius: 999px; font-weight: 600; color: #5a3fd8; }
    \\.iris-menu { padding: 6px; }
    \\.iris-dim { color: alpha(#241c40, .58); }
    \\.iris-badge { min-width: 16px; padding: 0 5px; border-radius: 999px; background: #6a4cf5; color: white; font-size: 10.5px; font-weight: 700; }
    \\.iris-keys { font-size: 12px; }
    \\.iris-title { font-weight: 700; font-size: 15px; }
    \\.iris-sep { margin: 4px 10px; background: alpha(#241c40, .10); min-height: 1px; }
    \\progressbar.iris trough { min-height: 4px; border-radius: 2px; background: alpha(#241c40, .08); }
    \\progressbar.iris progress { min-height: 4px; border-radius: 2px; background: #6a4cf5; }
    \\.iris-find text { font-size: 14px; min-width: 180px; background: none; }
    \\.iris-toast label { font-weight: 500; }
    \\iris-page { background: white; }
    \\windowcontrols button { min-width: 26px; min-height: 26px; padding: 0; margin: 0 2px;
    \\  background: alpha(white, .55); border-radius: 999px; box-shadow: inset 0 0 0 1px alpha(white, .8); }
    \\windowcontrols button:hover { background: alpha(white, .85); }
    \\.iris-c0 { color: #0a84ff; } .iris-c1 { color: #ff9f0a; } .iris-c2 { color: #30d158; } .iris-c3 { color: #ff375f; }
    \\.iris-c4 { color: #bf5af2; } .iris-c5 { color: #64d2ff; } .iris-c6 { color: #ffd60a; } .iris-c7 { color: #ac8e68; }
    \\.iris-cp { color: #5e5ce6; }
;
