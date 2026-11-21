import CAdwaita
import Foundation

/// The new-tab page: Iris, goddess of the rainbow (Ember's wallpaper, light
/// by day and dark by night) for the glass to bend, a capsule that takes
/// you to the address bar, and the sites you go to most.
final class NewTabPage {
    unowned let b: Browser
    let box = UI.box(true, 22)
    let item: Item
    private let tiles = UI.box(false, 14)
    private var tex: OpaquePointer?
    private var texRect = Rect()
    private var texKey = ""
    private var search: GtkW!

    init(_ b: Browser) {
        self.b = b
        gtk_widget_set_halign(box, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
        gtk_widget_set_focusable(box, 1)
        let title = UI.label("Iris", "iris-ntp-title")
        UI.append(box, title)
        let s = gtk_button_new()!
        UI.cls(s, "iris-flat")
        let sh = UI.box(false, 10)
        gtk_widget_set_margin_start(sh, 20); gtk_widget_set_margin_end(sh, 20)
        gtk_widget_set_margin_top(sh, 12); gtk_widget_set_margin_bottom(sh, 12)
        UI.append(sh, UI.icon("system-search-symbolic", 18))
        let l = UI.label("Ask anything, or type an address")
        gtk_widget_set_hexpand(l, 1)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        UI.cls(l, "iris-dim")
        UI.append(sh, l)
        gtk_button_set_child(UnsafeMutablePointer<GtkButton>(OpaquePointer(s)), sh)
        gtk_widget_set_size_request(s, 520, -1)
        on(Ptr(s), "clicked") { [unowned b] in b.focusAddress() }
        search = s
        UI.append(box, s)
        gtk_widget_set_halign(tiles, GTK_ALIGN_CENTER)
        UI.append(box, tiles)
        item = b.stage.add(box, .page)
        item.clip = 12
        item.animateFrames = false
        item.behind = { [unowned self] s, r in self.paint(s, r) }
        b.stage.part(item, s, Glass(radius: 26, level: 0.30, bend: 10, rim: 20, lens: 0.03), onlyActive: false)
        refresh()
    }

    func refresh() {
        var c = gtk_widget_get_first_child(tiles)
        while let w = c {
            c = gtk_widget_get_next_sibling(w)
            item.parts.removeAll { $0.w == w }
            gtk_box_remove(UnsafeMutablePointer<GtkBox>(OpaquePointer(tiles)), w)
        }
        for v in History.shared.top(6) {
            let name = Search.display(v.url)
            let t = gtk_button_new()!
            UI.cls(t, "iris-flat", "iris-tile")
            let vb = UI.box(true, 8)
            let av = adw_avatar_new(40, name, 1)!
            gtk_widget_set_halign(av, GTK_ALIGN_CENTER)
            UI.append(vb, av)
            let l = UI.label(name.split(separator: ".").first.map(String.init)?.capitalized ?? name)
            UI.ellipsize(l, chars: 6)
            gtk_label_set_xalign(OpaquePointer(l), 0.5)
            gtk_label_set_max_width_chars(OpaquePointer(l), 10)
            UI.append(vb, l)
            gtk_button_set_child(UnsafeMutablePointer<GtkButton>(OpaquePointer(t)), vb)
            gtk_widget_set_tooltip_text(t, v.url)
            let url = v.url
            on(Ptr(t), "clicked") { [unowned self] in self.b.go(url) }
            UI.append(tiles, t)
            b.stage.part(item, t, Glass(radius: 20, level: 0.24, bend: 7, rim: 14), onlyActive: false)
        }
        gtk_widget_set_visible(tiles, gtk_widget_get_first_child(tiles) == nil ? 0 : 1)
    }

    func lookChanged() {
        if let t = tex { g_object_unref(Ptr(t)) }
        tex = nil
        texKey = ""
    }

    /// the wallpaper, covering the page, softened a little so the glass
    /// and the words stay first; made once per size and look
    private func paint(_ s: Snap, _ r: Rect) {
        let key = "\(r.w)x\(r.h)/\(Look.dark)"
        if key != texKey || tex == nil {
            if let t = tex { g_object_unref(Ptr(t)) }
            tex = nil
            texKey = key
            if let made = picture(r) { tex = made.0; texRect = made.1 }
        }
        if let tex {
            Stage.drawTexture(s, tex, Rect(x: r.x + texRect.x, y: r.y + texRect.y, w: texRect.w, h: texRect.h))
        } else {
            Draw.color(s, Look.dark ? RGBA(hex: "#141233") : RGBA(hex: "#ece6f4"), r)
        }
    }

    private func picture(_ r: Rect) -> (OpaquePointer, Rect)? {
        guard r.w > 1, r.h > 1, let path = Resources.path("wallpapers/iris-\(Look.dark ? "dark" : "light").jpg") else { return nil }
        let scale = gtk_widget_get_scale_factor(b.stage.widget)
        let pw = Int32(r.w * Double(scale)), ph = Int32(r.h * Double(scale))
        let wide = Double(pw) / Double(max(1, ph)) > 16.0 / 9
        guard let pb = gdk_pixbuf_new_from_file_at_scale(path, wide ? pw : -1, wide ? -1 : ph, 1, nil) else { return nil }
        let src = gdk_texture_new_for_pixbuf(pb)
        g_object_unref(Ptr(pb))
        guard let src, let sub = gtk_snapshot_new() else { return nil }
        let tw = Double(gdk_texture_get_width(src)) / Double(scale), th = Double(gdk_texture_get_height(src)) / Double(scale)
        let k = max(r.w / tw, r.h / th)
        let c = Rect(x: (r.w - tw * k) / 2, y: (r.h - th * k) / 2, w: tw * k, h: th * k)
        var clip = grect(Rect(x: 0, y: 0, w: r.w, h: r.h))
        gtk_snapshot_push_clip(sub, &clip)
        gtk_snapshot_push_blur(sub, 10)
        Stage.drawTexture(sub, OpaquePointer(src), Rect(x: c.x - 30, y: c.y - 30, w: c.w + 60, h: c.h + 60))
        gtk_snapshot_pop(sub)
        // a veil, so the words read on any part of her
        Draw.color(sub, Look.dark ? RGBA(0.02, 0.01, 0.06, 0.22) : RGBA(1, 1, 1, 0.16), Rect(x: 0, y: 0, w: r.w, h: r.h))
        gtk_snapshot_pop(sub)
        g_object_unref(Ptr(src))
        guard let node = gtk_snapshot_free_to_node(sub) else { return nil }
        defer { gsk_render_node_unref(node) }
        return b.stage.renderTexture(node, Rect(x: 0, y: 0, w: r.w, h: r.h))
    }
}
