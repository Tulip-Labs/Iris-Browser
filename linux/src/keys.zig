//! The keyboard: the usual browser keys, before the page sees them.
const core = @import("core.zig");
const search = @import("search.zig");
const engine = @import("engine.zig");
const Browser = @import("browser.zig").Browser;
const c = core.c;

pub fn attach(b: *Browser) void {
    const k = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(k, c.GTK_PHASE_CAPTURE);
    _ = core.onKey(k, b, handle);
    c.gtk_widget_add_controller(b.window, k);
}

pub fn handle(b: *Browser, key: u32, _: u32, state: u32) bool {
    const ctrl = state & c.GDK_CONTROL_MASK != 0;
    const shift = state & c.GDK_SHIFT_MASK != 0;
    const alt = state & c.GDK_ALT_MASK != 0;
    const lower = c.gdk_keyval_to_lower(key);
    if (ctrl and !alt) {
        switch (lower) {
            c.GDK_KEY_t => if (shift) b.reopenClosed() else {
                _ = b.newTab(.{});
            },
            c.GDK_KEY_n => if (shift) {
                _ = b.newTab(.{ .container = engine.Container.private_id });
            } else {
                _ = b.app.newWindow(false);
            },
            c.GDK_KEY_w => b.closeCurrent(),
            c.GDK_KEY_q => b.app.quit(),
            c.GDK_KEY_l, c.GDK_KEY_k => b.focusAddress(),
            c.GDK_KEY_r => if (b.current) |t| {
                if (shift) {
                    if (t.web) |w| c.webkit_web_view_reload_bypass_cache(w);
                } else t.reload();
            },
            c.GDK_KEY_f => b.openFind(),
            c.GDK_KEY_j => b.showDownloads(),
            c.GDK_KEY_y => if (shift) b.showDownloads() else return false,
            c.GDK_KEY_plus, c.GDK_KEY_equal, c.GDK_KEY_KP_Add => b.zoom(1),
            c.GDK_KEY_minus, c.GDK_KEY_KP_Subtract => b.zoom(-1),
            c.GDK_KEY_0, c.GDK_KEY_KP_0 => b.zoom(0),
            c.GDK_KEY_Tab => b.cycle(if (shift) -1 else 1),
            c.GDK_KEY_ISO_Left_Tab => b.cycle(-1),
            c.GDK_KEY_Page_Down => b.cycle(1),
            c.GDK_KEY_Page_Up => b.cycle(-1),
            c.GDK_KEY_1...c.GDK_KEY_9 => b.selectIndex(lower - c.GDK_KEY_1),
            else => return false,
        }
        return true;
    }
    if (alt and !ctrl) {
        switch (key) {
            c.GDK_KEY_Left => if (b.current) |t| t.back(),
            c.GDK_KEY_Right => if (b.current) |t| t.forward(),
            c.GDK_KEY_Home => b.go(search.home),
            else => return false,
        }
        return true;
    }
    switch (key) {
        c.GDK_KEY_F5 => if (b.current) |t| t.reload(),
        c.GDK_KEY_F6 => b.focusAddress(),
        c.GDK_KEY_F11 => b.toggleWindowFullscreen(),
        c.GDK_KEY_Escape => if (b.menu != null) b.closeMenu() else if (b.fullscreen) b.toggleWindowFullscreen() else return false,
        else => return false,
    }
    return true;
}
