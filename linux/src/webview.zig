//! Pages without WebKitGTK: WPE WebKit draws each page into buffers, and
//! Iris shows them itself.
//!
//! Iris is its own WPEPlatform "platform" (WPE WebKit 2.54+): a WPEDisplay,
//! WPEView and WPEToplevel made here as GObject subclasses. WebKit's web
//! process renders a frame into a DMA-BUF and hands it to IrisView's
//! render_buffer; Iris wraps that buffer, as it is, in a GdkDmabufTexture
//! (GTK 4.14+) and draws it in the stage. GSK samples it straight from the
//! GPU: no copy, and the Liquid Glass render nodes bend the live page as
//! they bend everything else. A buffer is given back to WebKit when GTK lets
//! go of its texture.
//!
//! Input goes the other way: the page widget's GTK event controllers become
//! WPEEvents (pointer, buttons with press counts, smooth and wheel scrolling,
//! keys with their XKB keycodes, focus), and the system clipboard is mirrored
//! into WPE's.
const std = @import("std");
const core = @import("core.zig");
const G = @import("glass.zig");
const c = core.c;
const Widget = core.Widget;

// ---------------------------------------------------------------- types

var display_type: c.GType = 0;
var view_type: c.GType = 0;
var toplevel_type: c.GType = 0;
var clipboard_type: c.GType = 0;
var page_type: c.GType = 0;

fn register(parent: c.GType, name: [*:0]const u8, class_init: c.GClassInitFunc) c.GType {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(parent, &q);
    var info = std.mem.zeroes(c.GTypeInfo);
    info.class_size = @intCast(q.class_size);
    info.instance_size = @intCast(q.instance_size);
    info.class_init = class_init;
    return c.g_type_register_static(parent, name, &info, 0);
}

// ---------------------------------------------------------------- display

/// The one display: GTK's. EGL and the GPU (DRM render node) are found the
/// way WPE's headless platform finds them; buffer formats are the ones GTK
/// can import as DMA-BUF textures, so every frame WebKit makes, GTK can show.
const Display = struct {
    var shared: ?*c.WPEDisplay = null;
    var headless: ?*c.WPEDisplay = null;
    var keymap: ?*c.WPEKeymap = null;

    fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const dc: *c.WPEDisplayClass = @ptrCast(@alignCast(klass));
        dc.connect = connect;
        dc.create_view = createView;
        dc.create_toplevel = createToplevel;
        dc.get_egl_display = eglDisplay;
        dc.get_drm_device = drmDevice;
        dc.get_keymap = getKeymap;
        dc.get_clipboard = getClipboard;
        dc.get_preferred_buffer_formats = formats;
    }

    fn connect(_: ?*c.WPEDisplay, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
        const h = c.wpe_display_headless_new() orelse return 0;
        if (c.wpe_display_connect(h, err) == 0) {
            core.unref(h);
            return 0;
        }
        headless = h;
        return 1;
    }

    fn createView(d: ?*c.WPEDisplay) callconv(.c) ?*c.WPEView {
        return @ptrCast(@alignCast(c.g_object_new(view_type, "display", d, @as(?*anyopaque, null))));
    }

    fn createToplevel(d: ?*c.WPEDisplay, max: c.guint) callconv(.c) ?*c.WPEToplevel {
        return @ptrCast(@alignCast(c.g_object_new(toplevel_type, "display", d, "max-views", max, @as(?*anyopaque, null))));
    }

    fn eglDisplay(_: ?*c.WPEDisplay, err: [*c][*c]c.GError) callconv(.c) c.gpointer {
        return c.wpe_display_get_egl_display(headless, err);
    }

    fn drmDevice(_: ?*c.WPEDisplay) callconv(.c) ?*c.WPEDRMDevice {
        return c.wpe_display_get_drm_device(headless);
    }

    fn getKeymap(_: ?*c.WPEDisplay) callconv(.c) ?*c.WPEKeymap {
        if (keymap == null) keymap = c.wpe_keymap_xkb_new();
        return keymap;
    }

    fn getClipboard(d: ?*c.WPEDisplay) callconv(.c) ?*c.WPEClipboard {
        return Clipboard.create(d);
    }

    /// what GTK can import: every DMA-BUF format and modifier of its display
    fn formats(_: ?*c.WPEDisplay) callconv(.c) ?*c.WPEBufferFormats {
        const gdk = c.gdk_display_get_default() orelse return null;
        const fmts = c.gdk_display_get_dmabuf_formats(gdk) orelse return null;
        const n = c.gdk_dmabuf_formats_get_n_formats(fmts);
        if (n == 0) return null;
        const dev = c.wpe_display_get_drm_device(headless);
        const b = c.wpe_buffer_formats_builder_new(dev);
        c.wpe_buffer_formats_builder_append_group(b, dev, c.WPE_BUFFER_FORMAT_USAGE_RENDERING);
        var i: c.gsize = 0;
        while (i < n) : (i += 1) {
            var fourcc: u32 = 0;
            var modifier: u64 = 0;
            c.gdk_dmabuf_formats_get_format(fmts, i, &fourcc, &modifier);
            c.wpe_buffer_formats_builder_append_format(b, fourcc, modifier);
        }
        const out = c.wpe_buffer_formats_builder_end(b);
        c.wpe_buffer_formats_builder_unref(b);
        return out;
    }

    fn get() *c.WPEDisplay {
        if (shared) |d| return d;
        if (display_type == 0) {
            display_type = register(c.wpe_display_get_type(), "IrisDisplay", classInit);
            view_type = register(c.wpe_view_get_type(), "IrisView", View.classInit);
            toplevel_type = register(c.wpe_toplevel_get_type(), "IrisToplevel", Toplevel.classInit);
            clipboard_type = register(c.wpe_clipboard_get_type(), "IrisClipboard", Clipboard.classInit);
        }
        const d: *c.WPEDisplay = @ptrCast(@alignCast(c.g_object_new(display_type, @as(?[*:0]const u8, null))));
        var err: ?*c.GError = null;
        if (c.wpe_display_connect(d, &err) == 0) {
            if (err) |e| {
                std.log.err("WPE display: {s}", .{core.str(e.message)});
                c.g_error_free(e);
            }
        }
        // WebKit picks this display for views made without one
        c.wpe_display_set_primary(d);
        shared = d;
        return d;
    }
};

/// the display every page uses (made on first use)
pub fn display() *c.WPEDisplay {
    return Display.get();
}

// ---------------------------------------------------------------- view

/// Where WebKit's frames arrive. Each one becomes the page's texture.
const View = struct {
    fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const vc: *c.WPEViewClass = @ptrCast(@alignCast(klass));
        vc.render_buffer = renderBuffer;
        vc.set_cursor_from_name = cursor;
    }

    fn renderBuffer(v: ?*c.WPEView, buffer: ?*c.WPEBuffer, damage: [*c]const c.WPERectangle, n: c.guint, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
        _ = damage;
        _ = n;
        const view = v orelse return 0;
        const buf = buffer orelse return 0;
        const page = core.getData(*Page, view, "iris-page") orelse {
            // no page (yet, or any more): the frame goes straight back
            c.wpe_view_buffer_rendered(view, buf);
            c.wpe_view_buffer_released(view, buf);
            return 1;
        };
        return @intFromBool(page.frame(buf, err));
    }

    fn cursor(v: ?*c.WPEView, name: [*c]const u8) callconv(.c) void {
        const page = core.getData(*Page, v, "iris-page") orelse return;
        c.gtk_widget_set_cursor_from_name(page.widget, name);
    }
};

// ---------------------------------------------------------------- toplevel

/// A page's window, as WebKit sees it: its size is the page's, and its
/// full screen is Iris's own (the page's video asks, the browser answers).
const Toplevel = struct {
    fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const tc: *c.WPEToplevelClass = @ptrCast(@alignCast(klass));
        tc.resize = resize;
        tc.set_fullscreen = fullscreen;
    }

    fn resize(t: ?*c.WPEToplevel, w: c_int, h: c_int) callconv(.c) c.gboolean {
        c.wpe_toplevel_resized(t, w, h);
        return 1;
    }

    fn fullscreen(t: ?*c.WPEToplevel, on: c.gboolean) callconv(.c) c.gboolean {
        const page = core.getData(*Page, t, "iris-page") orelse return 0;
        if (page.onFullscreen) |h| h.f(h.ctx, on != 0);
        var state = c.wpe_toplevel_get_state(t);
        if (on != 0) state |= c.WPE_TOPLEVEL_STATE_FULLSCREEN else state &= ~@as(c.WPEToplevelState, c.WPE_TOPLEVEL_STATE_FULLSCREEN);
        c.wpe_toplevel_state_changed(t, state);
        return 1;
    }
};

// ---------------------------------------------------------------- clipboard

/// WPE's clipboard, kept in step with the desktop's: a page's copy goes to
/// GTK's clipboard, and what the desktop copies comes back for pasting.
const Clipboard = struct {
    var mirroring = false;
    var instance: ?*c.WPEClipboard = null;

    fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const cc: *c.WPEClipboardClass = @ptrCast(@alignCast(klass));
        cc.changed = changed;
    }

    fn create(d: ?*c.WPEDisplay) *c.WPEClipboard {
        const cb: *c.WPEClipboard = @ptrCast(@alignCast(c.g_object_new(clipboard_type, "display", d, @as(?*anyopaque, null))));
        instance = cb;
        if (c.gdk_display_get_default()) |gd| {
            const sys = c.gdk_display_get_clipboard(gd);
            _ = core.on(sys, "changed", cb, systemChanged);
            systemChanged(cb);
        }
        return cb;
    }

    /// a page copied: the desktop gets its text
    fn changed(_: ?*c.WPEClipboard, _: [*c]c.GPtrArray, is_local: c.gboolean, content: ?*c.WPEClipboardContent) callconv(.c) void {
        if (mirroring or is_local == 0) return;
        const ct = content orelse return;
        const text = c.wpe_clipboard_content_get_text(ct) orelse return;
        const gd = c.gdk_display_get_default() orelse return;
        c.gdk_clipboard_set_text(c.gdk_display_get_clipboard(gd), text);
    }

    /// the desktop copied: pages can paste it
    fn systemChanged(cb: *c.WPEClipboard) void {
        const gd = c.gdk_display_get_default() orelse return;
        const sys = c.gdk_display_get_clipboard(gd);
        if (c.gdk_clipboard_is_local(sys) != 0) return;
        c.gdk_clipboard_read_text_async(sys, null, readDone, cb);
    }

    fn readDone(src: ?*c.GObject, res: ?*c.GAsyncResult, d: ?*anyopaque) callconv(.c) void {
        const cb: *c.WPEClipboard = core.cast(*c.WPEClipboard, d);
        const text = c.gdk_clipboard_read_text_finish(@ptrCast(src), res, null) orelse return;
        defer c.g_free(text);
        const content = c.wpe_clipboard_content_new();
        defer c.wpe_clipboard_content_unref(content);
        c.wpe_clipboard_content_set_text(content, text);
        mirroring = true;
        c.wpe_clipboard_set_content(cb, content);
        mirroring = false;
    }
};

// ---------------------------------------------------------------- the page widget

pub const BoolHook = struct { ctx: *anyopaque, f: *const fn (*anyopaque, bool) void };

/// One page on screen: a GTK widget (IrisPage) showing a WebKitWebView's
/// frames and feeding it input.
pub const Page = struct {
    widget: Widget,
    web: *c.WebKitWebView,
    view: *c.WPEView,
    toplevel: ?*c.WPEToplevel = null,
    /// the frame on screen
    tex: ?*c.GdkTexture = null,
    /// buffers shown but not yet reported as rendered (on the next frame)
    pending: std.ArrayList(*c.WPEBuffer) = .empty,
    frameTick: c.guint = 0,
    pointer: [2]f64 = .{ 0, 0 },
    buttons: c.WPEModifiers = 0,
    onFullscreen: ?BoolHook = null,
    /// keys Iris itself handles first (shortcuts); true when taken
    keyFilter: ?KeyHook = null,

    pub const KeyHook = struct { ctx: *anyopaque, f: *const fn (*anyopaque, u32, u32) bool };

    /// a page for a web view made with Iris's display
    pub fn create(web: *c.WebKitWebView) *Page {
        if (page_type == 0) page_type = register(c.gtk_widget_get_type(), "IrisPage", pageClassInit);
        const p = core.gpa.create(Page) catch @panic("oom");
        const w: Widget = @ptrCast(@alignCast(c.g_object_new(page_type, @as(?[*:0]const u8, null))));
        _ = c.g_object_ref_sink(w);
        const view = c.webkit_web_view_get_wpe_view(web).?;
        p.* = .{ .widget = w, .web = web, .view = view };
        core.setData(w, "iris-page", p);
        core.setData(view, "iris-page", p);
        p.toplevel = c.wpe_view_get_toplevel(view);
        if (p.toplevel) |t| core.setData(t, "iris-page", p);
        c.gtk_widget_set_focusable(w, 1);
        c.gtk_widget_set_cursor_from_name(w, "default");
        p.wireInput();
        return p;
    }

    pub fn destroy(p: *Page) void {
        core.setData(p.view, "iris-page", null);
        if (p.toplevel) |t| core.setData(t, "iris-page", null);
        core.setData(p.widget, "iris-page", null);
        p.flushRendered();
        if (p.frameTick != 0) c.gtk_widget_remove_tick_callback(p.widget, p.frameTick);
        core.unref(p.tex);
        p.tex = null;
        p.pending.deinit(core.gpa);
        core.unref(p.widget);
        core.gpa.destroy(p);
    }

    fn of(w: anytype) ?*Page {
        return core.getData(*Page, w, "iris-page");
    }

    // ---- frames

    const Held = struct { view: *c.WPEView, buffer: *c.WPEBuffer };

    /// GTK let go of a frame's texture: WebKit may draw into it again
    fn release(d: ?*anyopaque) callconv(.c) void {
        const h: *Held = core.cast(*Held, d);
        c.wpe_view_buffer_released(h.view, h.buffer);
        core.unref(h.buffer);
        core.unref(h.view);
        core.gpa.destroy(h);
    }

    fn frame(p: *Page, buf: *c.WPEBuffer, err: [*c][*c]c.GError) bool {
        const w = c.wpe_buffer_get_width(buf);
        const h = c.wpe_buffer_get_height(buf);
        var tex: ?*c.GdkTexture = null;
        if (core.isA(buf, c.wpe_buffer_dma_buf_get_type())) {
            // the GPU's buffer, as it is: a DMA-BUF texture (no copy)
            const db: *c.WPEBufferDMABuf = @ptrCast(@alignCast(buf));
            const b = c.gdk_dmabuf_texture_builder_new();
            defer core.unref(b);
            c.gdk_dmabuf_texture_builder_set_display(b, c.gtk_widget_get_display(p.widget));
            c.gdk_dmabuf_texture_builder_set_width(b, @intCast(w));
            c.gdk_dmabuf_texture_builder_set_height(b, @intCast(h));
            c.gdk_dmabuf_texture_builder_set_fourcc(b, c.wpe_buffer_dma_buf_get_format(db));
            c.gdk_dmabuf_texture_builder_set_modifier(b, c.wpe_buffer_dma_buf_get_modifier(db));
            c.gdk_dmabuf_texture_builder_set_premultiplied(b, 1);
            const planes = c.wpe_buffer_dma_buf_get_n_planes(db);
            c.gdk_dmabuf_texture_builder_set_n_planes(b, planes);
            var i: c.guint = 0;
            while (i < planes) : (i += 1) {
                c.gdk_dmabuf_texture_builder_set_fd(b, i, c.wpe_buffer_dma_buf_get_fd(db, i));
                c.gdk_dmabuf_texture_builder_set_offset(b, i, c.wpe_buffer_dma_buf_get_offset(db, i));
                c.gdk_dmabuf_texture_builder_set_stride(b, i, c.wpe_buffer_dma_buf_get_stride(db, i));
            }
            // the previous frame: GTK redraws only what changed
            if (p.tex) |old| c.gdk_dmabuf_texture_builder_set_update_texture(b, old);
            const held = core.gpa.create(Held) catch return false;
            held.* = .{ .view = core.ref(p.view), .buffer = core.ref(buf) };
            tex = c.gdk_dmabuf_texture_builder_build(b, release, held, err);
            if (tex == null) {
                // GTK could not take it: hand it straight back
                release(held);
                return false;
            }
        } else if (core.isA(buf, c.wpe_buffer_shm_get_type())) {
            // software rendering: the pixels are copied once, and the buffer
            // goes back at once
            const sb: *c.WPEBufferSHM = @ptrCast(@alignCast(buf));
            const data = c.wpe_buffer_shm_get_data(sb) orelse return false;
            var size: c.gsize = 0;
            const bytes = c.g_bytes_get_data(data, &size);
            const copy = c.g_bytes_new(bytes, size);
            defer c.g_bytes_unref(copy);
            tex = c.gdk_memory_texture_new(w, h, c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, copy, c.wpe_buffer_shm_get_stride(sb));
            c.wpe_view_buffer_released(p.view, buf);
        } else return false;

        core.unref(p.tex);
        p.tex = tex;
        p.pending.append(core.gpa, core.ref(buf)) catch {};
        c.gtk_widget_queue_draw(p.widget);
        // WebKit makes its next frame once this one is on screen
        if (p.frameTick == 0) p.frameTick = c.gtk_widget_add_tick_callback(p.widget, onFrame, p, null);
        return true;
    }

    fn onFrame(_: [*c]c.GtkWidget, _: ?*c.GdkFrameClock, d: ?*anyopaque) callconv(.c) c.gboolean {
        const p: *Page = core.cast(*Page, d);
        p.frameTick = 0;
        p.flushRendered();
        return 0;
    }

    fn flushRendered(p: *Page) void {
        for (p.pending.items) |b| {
            c.wpe_view_buffer_rendered(p.view, b);
            core.unref(b);
        }
        p.pending.clearRetainingCapacity();
    }

    fn snapshot(p: *Page, s: G.Snap) void {
        const t = p.tex orelse return;
        const w: f64 = @floatFromInt(c.gtk_widget_get_width(p.widget));
        const h: f64 = @floatFromInt(c.gtk_widget_get_height(p.widget));
        var r = G.grect(.{ .w = w, .h = h });
        c.gtk_snapshot_append_scaled_texture(s, t, c.GSK_SCALING_FILTER_LINEAR, &r);
    }

    fn allocate(p: *Page, w: c_int, h: c_int) void {
        if (w <= 0 or h <= 0) return;
        if (p.toplevel) |t| {
            const scale = c.gtk_widget_get_scale_factor(p.widget);
            const native = c.gtk_widget_get_native(p.widget);
            const fs: f64 = if (native) |n| (if (c.gtk_native_get_surface(n)) |sf| c.gdk_surface_get_scale(sf) else @floatFromInt(scale)) else @floatFromInt(scale);
            if (c.wpe_toplevel_get_scale(t) != fs) c.wpe_toplevel_scale_changed(t, fs);
            c.wpe_toplevel_resized(t, w, h);
        }
        c.wpe_view_resized(p.view, w, h);
    }

    /// the page is shown or hidden (a background tab keeps running, unseen)
    pub fn setVisible(p: *Page, on: bool) void {
        c.wpe_view_set_visible(p.view, @intFromBool(on));
    }

    /// the window became active or not
    pub fn setActive(p: *Page, on: bool) void {
        const t = p.toplevel orelse return;
        var state = c.wpe_toplevel_get_state(t);
        if (on) state |= c.WPE_TOPLEVEL_STATE_ACTIVE else state &= ~@as(c.WPEToplevelState, c.WPE_TOPLEVEL_STATE_ACTIVE);
        c.wpe_toplevel_state_changed(t, state);
    }

    // ---- input

    fn wireInput(p: *Page) void {
        trackEvents(p.widget);
        const motion = c.gtk_event_controller_motion_new();
        _ = core.onXY(motion, "motion", p, moved);
        _ = core.onXY(motion, "enter", p, entered);
        _ = core.on(motion, "leave", p, left);
        c.gtk_widget_add_controller(p.widget, motion);

        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = core.onPress(click, "pressed", p, pressed);
        _ = core.onPress(click, "released", p, released);
        c.gtk_widget_add_controller(p.widget, @ptrCast(click));

        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = core.onXYBool(scroll, "scroll", p, scrolled);
        _ = core.on(scroll, "scroll-end", p, scrollEnded);
        c.gtk_widget_add_controller(p.widget, scroll);

        const keys = c.gtk_event_controller_key_new();
        _ = core.onKey(keys, p, keyDown);
        _ = core.onKeyUp(keys, p, keyUp);
        c.gtk_widget_add_controller(p.widget, keys);

        const focus = c.gtk_event_controller_focus_new();
        _ = core.on(focus, "enter", p, focusIn);
        _ = core.on(focus, "leave", p, focusOut);
        c.gtk_widget_add_controller(p.widget, focus);

        _ = core.on(p.widget, "map", p, mapped);
        _ = core.on(p.widget, "unmap", p, unmapped);
    }

    fn mods(state: c.GdkModifierType) c.WPEModifiers {
        var m: c.WPEModifiers = 0;
        if (state & c.GDK_CONTROL_MASK != 0) m |= c.WPE_MODIFIER_KEYBOARD_CONTROL;
        if (state & c.GDK_SHIFT_MASK != 0) m |= c.WPE_MODIFIER_KEYBOARD_SHIFT;
        if (state & c.GDK_ALT_MASK != 0) m |= c.WPE_MODIFIER_KEYBOARD_ALT;
        if (state & (c.GDK_META_MASK | c.GDK_SUPER_MASK) != 0) m |= c.WPE_MODIFIER_KEYBOARD_META;
        if (state & c.GDK_LOCK_MASK != 0) m |= c.WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
        if (state & c.GDK_BUTTON1_MASK != 0) m |= c.WPE_MODIFIER_POINTER_BUTTON1;
        if (state & c.GDK_BUTTON2_MASK != 0) m |= c.WPE_MODIFIER_POINTER_BUTTON2;
        if (state & c.GDK_BUTTON3_MASK != 0) m |= c.WPE_MODIFIER_POINTER_BUTTON3;
        return m;
    }

    /// the modifiers and time of the event GTK is delivering now
    fn now(p: *Page) struct { u32, c.WPEModifiers, c.WPEInputSource } {
        _ = p;
        var t: u32 = 0;
        var m: c.WPEModifiers = 0;
        var src: c.WPEInputSource = c.WPE_INPUT_SOURCE_MOUSE;
        if (current_event) |e| {
            t = c.gdk_event_get_time(e);
            m = mods(c.gdk_event_get_modifier_state(e));
            if (c.gdk_event_get_device(e)) |dev| src = switch (c.gdk_device_get_source(dev)) {
                c.GDK_SOURCE_TOUCHPAD => c.WPE_INPUT_SOURCE_TOUCHPAD,
                c.GDK_SOURCE_TOUCHSCREEN => c.WPE_INPUT_SOURCE_TOUCHSCREEN,
                c.GDK_SOURCE_PEN => c.WPE_INPUT_SOURCE_PEN,
                c.GDK_SOURCE_TRACKPOINT => c.WPE_INPUT_SOURCE_TRACKPOINT,
                c.GDK_SOURCE_KEYBOARD => c.WPE_INPUT_SOURCE_KEYBOARD,
                else => c.WPE_INPUT_SOURCE_MOUSE,
            };
        }
        return .{ t, m, src };
    }

    /// the GdkEvent being handled (set by a capture-phase controller first)
    var current_event: ?*c.GdkEvent = null;

    fn send(p: *Page, e: ?*c.WPEEvent) void {
        const ev = e orelse return;
        _ = c.wpe_view_event(p.view, ev);
        c.wpe_event_unref(ev);
    }

    fn moved(p: *Page, x: f64, y: f64) void {
        const n = p.now();
        const dx = x - p.pointer[0];
        const dy = y - p.pointer[1];
        p.pointer = .{ x, y };
        p.send(c.wpe_event_pointer_move_new(c.WPE_EVENT_POINTER_MOVE, p.view, n[2], n[0], n[1] | p.buttons, x, y, dx, dy));
    }

    fn entered(p: *Page, x: f64, y: f64) void {
        const n = p.now();
        p.pointer = .{ x, y };
        p.send(c.wpe_event_pointer_move_new(c.WPE_EVENT_POINTER_ENTER, p.view, n[2], n[0], n[1], x, y, 0, 0));
    }

    fn left(p: *Page) void {
        const n = p.now();
        p.send(c.wpe_event_pointer_move_new(c.WPE_EVENT_POINTER_LEAVE, p.view, n[2], n[0], n[1], p.pointer[0], p.pointer[1], 0, 0));
    }

    fn buttonMask(b: c.guint) c.WPEModifiers {
        return switch (b) {
            1 => c.WPE_MODIFIER_POINTER_BUTTON1,
            2 => c.WPE_MODIFIER_POINTER_BUTTON2,
            3 => c.WPE_MODIFIER_POINTER_BUTTON3,
            4 => c.WPE_MODIFIER_POINTER_BUTTON4,
            5 => c.WPE_MODIFIER_POINTER_BUTTON5,
            else => 0,
        };
    }

    fn pressed(p: *Page, _: i32, x: f64, y: f64) void {
        // a click gives the page the keyboard
        if (c.gtk_widget_has_focus(p.widget) == 0) _ = c.gtk_widget_grab_focus(p.widget);
        const n = p.now();
        const b = gtkButton();
        p.buttons |= buttonMask(b);
        const count = c.wpe_view_compute_press_count(p.view, x, y, b, n[0]);
        p.send(c.wpe_event_pointer_button_new(c.WPE_EVENT_POINTER_DOWN, p.view, n[2], n[0], n[1] | p.buttons, b, x, y, count));
    }

    fn released(p: *Page, _: i32, x: f64, y: f64) void {
        const n = p.now();
        const b = gtkButton();
        p.buttons &= ~buttonMask(b);
        p.send(c.wpe_event_pointer_button_new(c.WPE_EVENT_POINTER_UP, p.view, n[2], n[0], n[1] | p.buttons, b, x, y, 0));
    }

    fn gtkButton() c.guint {
        const e = current_event orelse return 1;
        const b = c.gdk_button_event_get_button(e);
        return if (b == 0) 1 else b;
    }

    fn scrolled(p: *Page, dx: f64, dy: f64) bool {
        const n = p.now();
        // wheels click in steps, touchpads glide in pixels; WebKit's deltas
        // point the other way from GTK's (as on WPE's own Wayland platform)
        var precise = false;
        if (current_event) |e| precise = c.gdk_scroll_event_get_unit(e) == c.GDK_SCROLL_UNIT_SURFACE;
        p.send(c.wpe_event_scroll_new(p.view, n[2], n[0], n[1], -dx, -dy, @intFromBool(precise), 0, p.pointer[0], p.pointer[1]));
        return true;
    }

    fn scrollEnded(p: *Page) void {
        const n = p.now();
        p.send(c.wpe_event_scroll_new(p.view, n[2], n[0], n[1], 0, 0, 1, 1, p.pointer[0], p.pointer[1]));
    }

    fn keyDown(p: *Page, keyval: u32, keycode: u32, state: u32) bool {
        if (p.keyFilter) |k| if (k.f(k.ctx, keyval, state)) return true;
        const n = p.now();
        p.send(c.wpe_event_keyboard_new(c.WPE_EVENT_KEYBOARD_KEY_DOWN, p.view, c.WPE_INPUT_SOURCE_KEYBOARD, n[0], mods(state), keycode, keyval));
        return true;
    }

    fn keyUp(p: *Page, keyval: u32, keycode: u32, state: u32) void {
        const n = p.now();
        p.send(c.wpe_event_keyboard_new(c.WPE_EVENT_KEYBOARD_KEY_UP, p.view, c.WPE_INPUT_SOURCE_KEYBOARD, n[0], mods(state), keycode, keyval));
    }

    fn focusIn(p: *Page) void {
        c.wpe_view_focus_in(p.view);
    }

    fn focusOut(p: *Page) void {
        c.wpe_view_focus_out(p.view);
    }

    fn mapped(p: *Page) void {
        c.wpe_view_map(p.view);
        c.wpe_view_set_visible(p.view, 1);
    }

    fn unmapped(p: *Page) void {
        c.wpe_view_set_visible(p.view, 0);
    }

    // ---- the GType's virtual functions

    fn pageClassInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const wc: *c.GtkWidgetClass = @ptrCast(@alignCast(klass));
        wc.snapshot = snapCB;
        wc.size_allocate = allocCB;
        wc.measure = measureCB;
        c.gtk_widget_class_set_css_name(wc, "iris-page");
    }

    fn snapCB(w: [*c]c.GtkWidget, s: ?*c.GtkSnapshot) callconv(.c) void {
        const p = of(w) orelse return;
        if (s) |sn| p.snapshot(sn);
    }

    fn allocCB(w: [*c]c.GtkWidget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        const p = of(w) orelse return;
        p.allocate(width, height);
    }

    fn measureCB(_: [*c]c.GtkWidget, _: c.GtkOrientation, _: c_int, minimum: [*c]c_int, natural: [*c]c_int, minB: [*c]c_int, natB: [*c]c_int) callconv(.c) void {
        if (minimum != null) minimum.* = 0;
        if (natural != null) natural.* = 0;
        if (minB != null) minB.* = -1;
        if (natB != null) natB.* = -1;
    }
};

/// every input controller sets the event it delivers before Iris reads it
pub fn trackEvents(w: Widget) void {
    // a capture-phase controller on the page records GTK's current event
    // for the controllers that follow (they run in the same dispatch)
    const legacy = c.gtk_event_controller_legacy_new();
    c.gtk_event_controller_set_propagation_phase(legacy, c.GTK_PHASE_CAPTURE);
    _ = core.onBool1(legacy, "event", legacy, struct {
        fn f(_: ?*c.GtkEventController, e: ?*anyopaque) bool {
            Page.current_event = core.cast(?*c.GdkEvent, e);
            return false;
        }
    }.f);
    c.gtk_widget_add_controller(w, legacy);
}
