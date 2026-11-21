import CAdwaita
import Foundation

/// The new-tab page: slow drifting colour for the glass to bend, a capsule
/// that takes you to the address bar, and the sites you go to most.
final class NewTabPage {
    unowned let b: Browser
    let box = UI.box(true, 22)
    let item: Item
    private let tiles = UI.box(false, 14)
    private var phase = Double.random(in: 0..<100)
    private var timer: UInt32 = 0
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
        b.stage.part(item, s, Glass(radius: 26, tint: RGBA.white.alpha(0.30), bend: 10, rim: 20, lens: 0.03), onlyActive: false)
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
            b.stage.part(item, t, Glass(radius: 20, tint: RGBA.white.alpha(0.24), bend: 7, rim: 14), onlyActive: false)
        }
        gtk_widget_set_visible(tiles, gtk_widget_get_first_child(tiles) == nil ? 0 : 1)
        animate()
    }

    private func animate() {
        guard timer == 0, b.stage.animations else { return }
        // a slow drift, 20 frames a second, and only while the window is
        // the one in use (no work behind other windows)
        timer = every(ms: 50) { [weak self] in
            guard let self else { return false }
            if !self.item.shown && self.item.alpha.value < 0.01 { self.timer = 0; return false }
            if gtk_window_is_active(self.b.win) == 0 { return true }
            self.phase += 0.05
            gtk_widget_queue_draw(self.b.stage.widget)
            return true
        }
    }

    /// colour that drifts like light through water
    private func paint(_ s: Snap, _ r: Rect) {
        if item.shown { animate() }
        Draw.linear(s, r, from: (r.x, r.y), to: (r.maxX, r.maxY), [(0, RGBA(hex: "#4b2fb8")), (0.55, RGBA(hex: "#2f56d9")), (1, RGBA(hex: "#1aa3d9"))])
        let p = phase
        let blobs: [(Double, Double, Double, String, Double)] = [
            (0.25 + 0.18 * sin(p * 0.23), 0.30 + 0.16 * cos(p * 0.19), 0.55, "#ff6ec7", 0.70),
            (0.75 + 0.15 * cos(p * 0.17), 0.25 + 0.20 * sin(p * 0.21), 0.50, "#3ee6ff", 0.60),
            (0.60 + 0.20 * sin(p * 0.13 + 2), 0.80 + 0.12 * cos(p * 0.16), 0.60, "#ffb86b", 0.55),
            (0.20 + 0.14 * cos(p * 0.11 + 1), 0.85 + 0.10 * sin(p * 0.14), 0.45, "#8f6bff", 0.80),
        ]
        let size = max(r.w, r.h)
        for (bx, by, br, c, a) in blobs {
            Draw.radial(s, r, center: (r.x + r.w * bx, r.y + r.h * by), radius: size * br,
                        [(0, RGBA(hex: c, a)), (1, RGBA(hex: c, 0))])
        }
    }
}
