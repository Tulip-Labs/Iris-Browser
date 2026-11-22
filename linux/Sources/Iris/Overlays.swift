import Adwaita
import CAdwaita
import CWebKit
import Foundation

// The glass that floats over everything: suggestions, menus, find, the
// shields and the downloads.

/// what the address bar suggests while you type
final class Suggestions {
    unowned let b: Browser
    let box = UI.box(true, 2)
    let item: Item
    private var urls: [String] = []
    private var rows: [GtkW] = []
    private var selected = 0
    private var moved = false

    init(_ b: Browser) {
        self.b = b
        let wrap = UI.box(true, 0)
        UI.cls(wrap, "iris-menu")
        UI.append(wrap, box)
        item = b.stage.add(wrap, .overlay, glass: Glass(radius: 18, level: 0.72, panel: true, bend: 9, rim: 18, blur: 3, shadow: 1))
        item.alpha.value = 0
        item.scale.value = 0.97
        b.stage.show(item, true)
    }

    func update(_ text: String) {
        for r in rows { gtk_box_remove(UnsafeMutablePointer<GtkBox>(OpaquePointer(box)), r) }
        item.parts.removeAll()
        rows.removeAll()
        urls.removeAll()
        selected = 0
        moved = false
        let t = text.trimmingCharacters(in: .whitespaces)
        if Search.isURLLike(t) {
            add(icon: "go-jump-symbolic", Search.complete(t), nil, url: Search.complete(t))
        } else {
            add(icon: "system-search-symbolic", t, "Ask Google AI Mode", url: Search.resolve(t))
        }
        for v in History.shared.suggest(t, n: 6) where !urls.contains(v.url) {
            add(icon: "document-open-recent-symbolic", v.title.isEmpty ? Search.display(v.url) : v.title, v.url, url: v.url)
        }
        mark()
        place()
    }

    private func add(icon: String, _ title: String, _ sub: String?, url: String) {
        let row = gtk_button_new()!
        UI.cls(row, "iris-flat", "iris-row")
        gtk_widget_set_focus_on_click(row, 0)
        let h = UI.box(false, 10)
        UI.append(h, UI.icon(icon))
        let t = UI.label(title)
        UI.ellipsize(t, chars: 10)
        UI.append(h, t)
        if let sub {
            let s = UI.label(sub, "iris-dim")
            UI.ellipsize(s, chars: 6)
            gtk_widget_set_hexpand(s, 1)
            gtk_label_set_xalign(OpaquePointer(s), 1)
            UI.append(h, s)
        }
        gtk_button_set_child(UnsafeMutablePointer<GtkButton>(OpaquePointer(row)), h)
        on(Ptr(row), "clicked") { [unowned self] in self.b.go(url) }
        UI.append(box, row)
        rows.append(row)
        urls.append(url)
        b.stage.part(item, row, Glass(radius: 10, level: 0.45, bend: 3, rim: 8, dispersion: false))
    }

    private func mark() {
        for (i, r) in rows.enumerated() {
            if i == selected { gtk_widget_add_css_class(r, "selected") } else { gtk_widget_remove_css_class(r, "selected") }
        }
    }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + d + rows.count) % rows.count
        moved = true
        mark()
        b.stage.kick()
    }

    /// the row Enter opens: the one chosen with the arrows
    func chosen() -> String? { moved && selected < urls.count ? urls[selected] : nil }

    func place() {
        let a = b.addressFrame
        let w = max(a.w, 420)
        let h = UI.natural(item.w, forWidth: Int32(w)).1
        b.stage.place(item, Rect(x: a.x, y: a.maxY + 8, w: w, h: h), animate: false)
    }

    func close() { b.stage.remove(item) }
}

/// find in page (Ctrl+F)
final class FindBar {
    unowned let b: Browser
    let item: Item
    let text: GtkW
    let count: GtkW
    let tab: Tab

    init?(_ b: Browser) {
        guard let t = b.current, let wv = t.webView else { return nil }
        self.b = b
        tab = t
        let h = UI.box(false, 6)
        UI.cls(h, "iris-find")
        gtk_widget_set_margin_start(h, 14); gtk_widget_set_margin_end(h, 6)
        UI.append(h, UI.icon("edit-find-symbolic"))
        text = gtk_text_new()!
        gtk_text_set_placeholder_text(UnsafeMutablePointer<GtkText>(OpaquePointer(text)), "Find in page")
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        UI.append(h, text)
        count = UI.label("", "iris-dim")
        UI.append(h, count)
        let fc = webkit_web_view_get_find_controller(wv)
        let up = UI.button("go-up-symbolic", "Previous (Shift+Enter)") { webkit_find_controller_search_previous(fc) }
        let down = UI.button("go-down-symbolic", "Next (Enter)") { webkit_find_controller_search_next(fc) }
        UI.append(h, up)
        UI.append(h, down)
        item = b.stage.add(h, .overlay, glass: Glass(radius: 19, level: 0.5, bend: 7, rim: 14, shadow: 1))
        let x = UI.button("window-close-symbolic", "Close (Esc)") { [weak b] in b?.find?.close() }
        UI.append(h, x)
        for btn in [up, down, x] { b.stage.part(item, btn, Glass(radius: 17, level: 0.35, bend: 3, rim: 8, dispersion: false)) }
        on(Ptr(text), "changed") { [unowned self] in
            let q = UI.text(self.text)
            if q.isEmpty { webkit_find_controller_search_finish(fc); UI.setLabel(self.count, ""); return }
            let opts = WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE.rawValue | WEBKIT_FIND_OPTIONS_WRAP_AROUND.rawValue
            webkit_find_controller_search(fc, q, opts, 1000)
            webkit_find_controller_count_matches(fc, q, opts, 1000)
        }
        on(Ptr(text), "activate") { webkit_find_controller_search_next(fc) }
        onUInt(Ptr(fc), "counted-matches") { [unowned self] n in
            UI.setLabel(self.count, n == 1 ? "1 match" : "\(n) matches")
            self.place()
        }
        on(Ptr(fc), "failed-to-find-text") { [unowned self] in UI.setLabel(self.count, "No matches"); self.place() }
        let keys = gtk_event_controller_key_new()!
        onKey(Ptr(keys)) { [unowned self] key, state in
            if Int32(key) == GDK_KEY_Escape { self.close(); return true }
            if Int32(key) == GDK_KEY_Return && state & GDK_SHIFT_MASK.rawValue != 0 { webkit_find_controller_search_previous(fc); return true }
            return false
        }
        gtk_widget_add_controller(text, keys)
        item.alpha.value = 0
        item.scale.value = 0.95
        b.stage.show(item, true)
        place()
        gtk_widget_grab_focus(text)
    }

    func place() {
        let (w, h) = UI.natural(item.w)
        let c = b.card
        b.stage.place(item, Rect(x: c.maxX - w - 14, y: c.y + 14, w: w, h: max(h, 38)), animate: false)
    }

    func close() {
        if let wv = tab.webView { webkit_find_controller_search_finish(webkit_web_view_get_find_controller(wv)) }
        b.stage.remove(item)
        if b.find === self { b.find = nil }
        b.focusPage()
    }
}

/// the downloads, with what each is doing
final class DownloadsPanel {
    unowned let b: Browser
    let box = UI.box(true, 4)
    private var rows: [ObjectIdentifier: (GtkW, GtkW, GtkW)] = [:] // status, bar, row

    init(_ b: Browser) {
        self.b = b
        build()
    }

    private func build() {
        var c = gtk_widget_get_first_child(box)
        while let w = c {
            c = gtk_widget_get_next_sibling(w)
            gtk_box_remove(UnsafeMutablePointer<GtkBox>(OpaquePointer(box)), w)
        }
        rows.removeAll()
        let head = UI.box(false, 8)
        gtk_widget_set_margin_start(head, 10); gtk_widget_set_margin_end(head, 4)
        gtk_widget_set_margin_top(head, 4); gtk_widget_set_margin_bottom(head, 2)
        let title = UI.label("Downloads", "iris-title")
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_xalign(OpaquePointer(title), 0)
        UI.append(head, title)
        UI.append(head, UI.textButton("Folder") { [unowned self] in
            let f = g_file_new_for_path(Paths.downloads)
            let l = gtk_file_launcher_new(f)
            gtk_file_launcher_launch(l, self.b.win, nil, nil, nil)
            g_object_unref(Ptr(l)); g_object_unref(Ptr(f))
        })
        if Downloads.shared.list.contains(where: { $0.done || $0.failed }) {
            UI.append(head, UI.textButton("Clear") { [unowned self] in Downloads.shared.clearFinished(); self.build(); self.b.closeMenu(); self.b.showDownloads() })
        }
        UI.append(box, head)
        if Downloads.shared.list.isEmpty {
            let e = UI.label("Nothing downloaded yet", "iris-dim")
            gtk_widget_set_margin_top(e, 18); gtk_widget_set_margin_bottom(e, 22)
            UI.append(box, e)
            return
        }
        for d in Downloads.shared.list.prefix(12) { UI.append(box, row(d)) }
    }

    private func row(_ d: Download) -> GtkW {
        let r = gtk_button_new()!
        UI.cls(r, "iris-flat", "iris-row")
        let v = UI.box(true, 4)
        let top = UI.box(false, 8)
        UI.append(top, UI.icon(d.failed ? "dialog-warning-symbolic" : "folder-download-symbolic"))
        let name = UI.label(d.name.isEmpty ? "Starting…" : d.name)
        UI.ellipsize(name, chars: 12)
        gtk_widget_set_hexpand(name, 1)
        UI.append(top, name)
        if !d.done && !d.failed {
            let x = UI.button("process-stop-symbolic", "Cancel") { d.cancel() }
            UI.cls(x, "small"); gtk_widget_set_size_request(x, 24, 24)
            UI.append(top, x)
        } else if d.done {
            let f = UI.button("folder-open-symbolic", "Show in folder") { [unowned self] in Downloads.shared.showInFolder(d, self.b.window) }
            UI.cls(f, "small"); gtk_widget_set_size_request(f, 24, 24)
            UI.append(top, f)
        }
        UI.append(v, top)
        let status = UI.label(d.status, "iris-dim", "iris-keys")
        gtk_label_set_xalign(OpaquePointer(status), 0)
        let bar = gtk_progress_bar_new()!
        UI.cls(bar, "iris")
        gtk_progress_bar_set_fraction(OpaquePointer(bar), d.progress)
        gtk_widget_set_visible(bar, d.done || d.failed ? 0 : 1)
        UI.append(v, bar)
        UI.append(v, status)
        gtk_button_set_child(UnsafeMutablePointer<GtkButton>(OpaquePointer(r)), v)
        on(Ptr(r), "clicked") { [unowned self] in if d.done { Downloads.shared.open(d, self.b.window) } }
        rows[ObjectIdentifier(d)] = (status, bar, r)
        return r
    }

    func update(_ d: Download?) {
        guard let d, let (status, bar, _) = rows[ObjectIdentifier(d)] else {
            b.closeMenu()
            b.showDownloads()
            return
        }
        if d.done || d.failed {
            b.closeMenu()
            b.showDownloads()
            return
        }
        UI.setLabel(status, d.status)
        gtk_progress_bar_set_fraction(OpaquePointer(bar), d.progress)
    }
}

extension Browser {
    // MARK: menus


    func zoom(_ d: Int) {
        guard let t = current else { return }
        let steps = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        if d == 0 { t.setZoom(1); return }
        let i = steps.firstIndex { $0 >= t.zoom - 0.001 } ?? 4
        t.setZoom(steps[max(0, min(steps.count - 1, i + d))])
    }

    func openFind() {
        if let f = find { gtk_widget_grab_focus(f.text); return }
        find = FindBar(self)
    }

    /// the containers: a new tab in one, this page in another, or a new one
    func showContainerMenu(anchor: Rect, newTabOnly: Bool = false) {
        let m = UI.box(true, 0)
        let h = UI.label("New tab in", "iris-dim", "iris-keys")
        gtk_label_set_xalign(OpaquePointer(h), 0)
        gtk_widget_set_margin_start(h, 12); gtk_widget_set_margin_top(h, 4); gtk_widget_set_margin_bottom(h, 2)
        UI.append(m, h)
        UI.append(m, UI.row("web-browser-symbolic", "No Container") { [unowned self] in self.closeMenu(); self.newTab() })
        for c in Containers.shared.list {
            UI.append(m, UI.row(nil, c.name, container: c) { [unowned self] in self.closeMenu(); self.newTab(container: c.id) })
        }
        UI.append(m, UI.row(nil, "Private", container: Containers.shared.get(Container.privateID)) { [unowned self] in self.closeMenu(); self.newTab(container: Container.privateID) })
        if !newTabOnly, let t = current, !t.url.isEmpty {
            UI.append(m, UI.separator())
            let h2 = UI.label("Open this page in", "iris-dim", "iris-keys")
            gtk_label_set_xalign(OpaquePointer(h2), 0)
            gtk_widget_set_margin_start(h2, 12); gtk_widget_set_margin_bottom(h2, 2)
            UI.append(m, h2)
            if t.container != nil {
                UI.append(m, UI.row("web-browser-symbolic", "No Container") { [unowned self] in self.closeMenu(); self.newTab(t.url, after: t) })
            }
            for c in Containers.shared.list where c.id != t.container {
                UI.append(m, UI.row(nil, c.name, container: c) { [unowned self] in self.closeMenu(); self.newTab(t.url, container: c.id, after: t) })
            }
        }
        UI.append(m, UI.separator())
        UI.append(m, UI.row("list-add-symbolic", "New Container…") { [unowned self] in self.closeMenu(); self.askNewContainer() })
        if !Containers.shared.list.isEmpty {
            UI.append(m, UI.row("user-trash-symbolic", "Remove a Container…") { [unowned self] in self.closeMenu(); self.askRemoveContainer() })
        }
        openMenu(m, under: anchor, width: 260, alignRight: !newTabOnly)
    }

    func askNewContainer() {
        let d = adw_alert_dialog_new("New Container", "A container keeps its own cookies, sign-ins and site data, apart from every other.")!
        let a: UnsafeMutablePointer<AdwAlertDialog> = cp(d)!
        let v = UI.box(true, 12)
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(UnsafeMutablePointer<GtkEntry>(OpaquePointer(entry)), "Name")
        gtk_entry_set_activates_default(UnsafeMutablePointer<GtkEntry>(OpaquePointer(entry)), 1)
        UI.append(v, entry)
        // its icon
        var chosen = "star"
        let grid = gtk_flow_box_new()!
        let fb = OpaquePointer(grid)
        gtk_flow_box_set_selection_mode(fb, GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(fb, 6)
        gtk_flow_box_set_min_children_per_line(fb, 6)
        gtk_flow_box_set_homogeneous(fb, 1)
        var buttons: [GtkW] = []
        for name in Container.icons {
            let b = gtk_button_new_from_icon_name("iris-\(name)-symbolic")!
            UI.cls(b, "flat", "iris-icon-choice")
            gtk_widget_set_tooltip_text(b, name.capitalized)
            if name == chosen { UI.cls(b, "selected") }
            on(Ptr(b), "clicked") {
                chosen = name
                for o in buttons { gtk_widget_remove_css_class(o, "selected") }
                gtk_widget_add_css_class(b, "selected")
            }
            buttons.append(b)
            gtk_flow_box_append(fb, b)
        }
        UI.append(v, grid)
        adw_alert_dialog_set_extra_child(a, v)
        adw_alert_dialog_add_response(a, "cancel", "Cancel")
        adw_alert_dialog_add_response(a, "add", "Add")
        adw_alert_dialog_set_response_appearance(a, "add", .suggested)
        adw_alert_dialog_set_default_response(a, "add")
        adw_alert_dialog_set_close_response(a, "cancel")
        on1(Ptr(d), "response") { [unowned self] r in
            guard str(r?.assumingMemoryBound(to: CChar.self)) == "add" else { return }
            let name = UI.text(entry).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let c = Containers.shared.add(name, icon: chosen)
            self.newTab(container: c.id)
        }
        adw_dialog_present(cp(OpaquePointer(d)), window)
        gtk_widget_grab_focus(entry)
    }

    func askRemoveContainer() {
        let d = adw_alert_dialog_new("Remove a Container", "Its tabs close, and its cookies, sign-ins and site data are deleted.")!
        let a: UnsafeMutablePointer<AdwAlertDialog> = cp(d)!
        adw_alert_dialog_add_response(a, "cancel", "Cancel")
        for c in Containers.shared.list {
            adw_alert_dialog_add_response(a, c.id, c.name)
            adw_alert_dialog_set_response_appearance(a, c.id, .destructive)
        }
        adw_alert_dialog_set_close_response(a, "cancel")
        on1(Ptr(d), "response") { [unowned self] r in
            guard let id = str(r?.assumingMemoryBound(to: CChar.self)), id != "cancel" else { return }
            self.app?.removeContainer(id)
        }
        adw_dialog_present(cp(OpaquePointer(d)), window)
    }

    func closeTabs(in container: String) {
        for t in tabs where t.container == container { close(t) }
    }

    /// the shield for this site, and for everywhere
    func showShields() {
        let m = UI.box(true, 2)
        let site = current.flatMap { Search.host($0.url) }.map(Search.site)
        let title = UI.label("Iris Shields", "iris-title")
        gtk_label_set_xalign(OpaquePointer(title), 0)
        gtk_widget_set_margin_start(title, 12); gtk_widget_set_margin_top(title, 6)
        UI.append(m, title)
        let note = UI.label("Ads and trackers are stopped inside the engine, before a request leaves the computer, as in Brave. Cookies never go to other sites.", "iris-dim", "iris-keys")
        gtk_label_set_wrap(OpaquePointer(note), 1)
        gtk_label_set_xalign(OpaquePointer(note), 0)
        gtk_widget_set_margin_start(note, 12); gtk_widget_set_margin_end(note, 12); gtk_widget_set_margin_bottom(note, 6)
        UI.append(m, note)
        if let site, Shields.shared.on {
            let on = Shields.shared.onFor(site)
            UI.append(m, UI.row(on ? "security-high-symbolic" : "security-low-symbolic", on ? "On for \(site)" : "Off for \(site)", keys: on ? "Turn off" : "Turn on") { [unowned self] in
                Shields.shared.toggle(site: site)
                self.closeMenu()
                self.current?.reload()
                if let t = self.current { self.tabChanged(t) }
            })
        }
        let all = Shields.shared.on
        UI.append(m, UI.row(all ? "security-high-symbolic" : "security-low-symbolic", all ? "On everywhere" : "Off everywhere", keys: all ? "Turn off" : "Turn on") { [unowned self] in
            SettingsStore.shared.update { $0.shields.toggle() }
            self.closeMenu()
            self.app?.shieldsChanged()
        })
        if all {
            UI.append(m, UI.separator())
            let level = SettingsStore.shared.value.shieldLevel
            for l in ShieldLevel.allCases {
                let r = UI.row(l == level ? "object-select-symbolic" : nil, l.title, keys: l.hint) { [unowned self] in
                    self.closeMenu()
                    guard l != SettingsStore.shared.value.shieldLevel else { return }
                    SettingsStore.shared.update { $0.shieldLevel = l }
                    Shields.shared.levelChanged()
                    self.toast("Shields: \(l.title). Pages pick it up as they load.")
                }
                if l == level { UI.cls(r, "selected") }
                UI.append(m, r)
            }
            let n = UI.label(level.about, "iris-dim", "iris-keys")
            gtk_label_set_wrap(OpaquePointer(n), 1)
            gtk_label_set_xalign(OpaquePointer(n), 0)
            gtk_widget_set_margin_start(n, 12); gtk_widget_set_margin_end(n, 12); gtk_widget_set_margin_top(n, 4); gtk_widget_set_margin_bottom(n, 6)
            UI.append(m, n)
        }
        if !Shields.shared.ready && Shields.shared.on {
            let w = UI.label("Getting the block list ready (the first start takes a moment)…", "iris-dim", "iris-keys")
            gtk_label_set_wrap(OpaquePointer(w), 1)
            gtk_widget_set_margin_start(w, 12); gtk_widget_set_margin_end(w, 12); gtk_widget_set_margin_bottom(w, 6)
            UI.append(m, w)
        }
        openMenu(m, under: stage.bounds(of: shieldButton) ?? addressFrame, width: 320, alignRight: true)
    }

    /// what a tab's pill offers on a right click
    func tabMenu(_ t: Tab) {
        let m = UI.box(true, 0)
        UI.append(m, UI.row("view-refresh-symbolic", "Reload") { [unowned self] in self.closeMenu(); t.reload() })
        UI.append(m, UI.row("edit-copy-symbolic", "Duplicate") { [unowned self] in
            self.closeMenu(); self.newTab(t.url, container: t.container, after: t)
        })
        UI.append(m, UI.separator())
        for c in Containers.shared.list where c.id != t.container && !t.url.isEmpty {
            UI.append(m, UI.row(nil, "Open in \(c.name)", container: c) { [unowned self] in
                self.closeMenu(); self.newTab(t.url, container: c.id, after: t)
            })
        }
        UI.append(m, UI.separator())
        UI.append(m, UI.row("window-close-symbolic", "Close Other Tabs") { [unowned self] in
            self.closeMenu()
            for o in self.tabs where o !== t { self.close(o) }
        })
        UI.append(m, UI.row("window-close-symbolic", "Close Tab", keys: "Ctrl+W") { [unowned self] in self.closeMenu(); self.close(t) })
        openMenu(m, under: t.pillItem.frame.rect, width: 240)
    }

    /// Iris's own menu on a right click in a page
    func contextMenu(_ t: Tab, _ menu: OpaquePointer, _ hit: OpaquePointer) {
        guard let wv = t.webView else { return }
        var x = 0.0, y = 0.0
        if let ev = webkit_context_menu_get_event(menu) {
            gdk_event_get_position(ev, &x, &y)
            // from the window's surface to the stage
            var sx = 0.0, sy = 0.0
            gtk_native_get_surface_transform(OpaquePointer(window), &sx, &sy)
            var p = gpoint(x - sx, y - sy), out = graphene_point_t()
            if gtk_widget_compute_point(window, stage.widget, &p, &out) != 0 { x = Double(out.x); y = Double(out.y) }
        } else {
            x = card.midX; y = card.midY
        }
        let link = webkit_hit_test_result_context_is_link(hit) != 0 ? str(webkit_hit_test_result_get_link_uri(hit)) : nil
        let image = webkit_hit_test_result_context_is_image(hit) != 0 ? str(webkit_hit_test_result_get_image_uri(hit)) : nil
        let media = webkit_hit_test_result_context_is_media(hit) != 0 ? str(webkit_hit_test_result_get_media_uri(hit)) : nil
        let editable = webkit_hit_test_result_context_is_editable(hit) != 0
        let selection = webkit_hit_test_result_context_is_selection(hit) != 0
        let m = UI.box(true, 0)
        func sep() { if gtk_widget_get_first_child(m) != nil { UI.append(m, UI.separator()) } }
        func copy(_ s: String) { gdk_clipboard_set_text(gtk_widget_get_clipboard(window), s) }
        func save(_ u: String) { if let d = webkit_web_view_download_uri(wv, u) { g_object_unref(Ptr(d)) } }
        if let link, !link.hasPrefix("javascript:") {
            UI.append(m, UI.row("tab-new-symbolic", "Open Link in New Tab") { [unowned self] in self.closeMenu(); self.openInBackground(link, from: t) })
            for c in Containers.shared.list where c.id != t.container {
                UI.append(m, UI.row(nil, "Open Link in \(c.name)", container: c) { [unowned self] in self.closeMenu(); self.newTab(link, container: c.id, after: t) })
            }
            UI.append(m, UI.row("edit-copy-symbolic", "Copy Link") { [unowned self] in self.closeMenu(); copy(link) })
            UI.append(m, UI.row("folder-download-symbolic", "Download Link") { [unowned self] in self.closeMenu(); save(link) })
        }
        if let image {
            sep()
            UI.append(m, UI.row("image-x-generic-symbolic", "Open Image in New Tab") { [unowned self] in self.closeMenu(); self.openInBackground(image, from: t) })
            UI.append(m, UI.row("edit-copy-symbolic", "Copy Image Address") { [unowned self] in self.closeMenu(); copy(image) })
            UI.append(m, UI.row("folder-download-symbolic", "Save Image") { [unowned self] in self.closeMenu(); save(image) })
        }
        if let media, image == nil {
            sep()
            UI.append(m, UI.row("edit-copy-symbolic", "Copy Video Address") { [unowned self] in self.closeMenu(); copy(media) })
            UI.append(m, UI.row("folder-download-symbolic", "Save Video") { [unowned self] in self.closeMenu(); save(media) })
        }
        if editable {
            sep()
            UI.append(m, UI.row("edit-cut-symbolic", "Cut", keys: "Ctrl+X") { [unowned self] in self.closeMenu(); webkit_web_view_execute_editing_command(wv, WEBKIT_EDITING_COMMAND_CUT) })
            UI.append(m, UI.row("edit-copy-symbolic", "Copy", keys: "Ctrl+C") { [unowned self] in self.closeMenu(); webkit_web_view_execute_editing_command(wv, WEBKIT_EDITING_COMMAND_COPY) })
            UI.append(m, UI.row("edit-paste-symbolic", "Paste", keys: "Ctrl+V") { [unowned self] in self.closeMenu(); webkit_web_view_execute_editing_command(wv, WEBKIT_EDITING_COMMAND_PASTE) })
            UI.append(m, UI.row("edit-select-all-symbolic", "Select All", keys: "Ctrl+A") { [unowned self] in self.closeMenu(); webkit_web_view_execute_editing_command(wv, WEBKIT_EDITING_COMMAND_SELECT_ALL) })
        } else if selection {
            sep()
            UI.append(m, UI.row("edit-copy-symbolic", "Copy", keys: "Ctrl+C") { [unowned self] in self.closeMenu(); webkit_web_view_execute_editing_command(wv, WEBKIT_EDITING_COMMAND_COPY) })
            UI.append(m, UI.row("system-search-symbolic", "Ask Google AI Mode") { [unowned self] in
                self.closeMenu()
                t.run("window.getSelection().toString()") { [weak self] s in
                    guard let s, !s.isEmpty else { return }
                    self?.newTab(Search.aiURL(s), container: t.container, after: t)
                }
            })
        }
        if link == nil && image == nil && media == nil && !editable && !selection {
            UI.append(m, UI.row("go-previous-symbolic", "Back", keys: "Alt+←") { [unowned self] in self.closeMenu(); t.back() })
            UI.append(m, UI.row("go-next-symbolic", "Forward", keys: "Alt+→") { [unowned self] in self.closeMenu(); t.forward() })
            UI.append(m, UI.row("view-refresh-symbolic", "Reload", keys: "Ctrl+R") { [unowned self] in self.closeMenu(); t.reload() })
            UI.append(m, UI.row("edit-select-all-symbolic", "Select All", keys: "Ctrl+A") { [unowned self] in self.closeMenu(); webkit_web_view_execute_editing_command(wv, WEBKIT_EDITING_COMMAND_SELECT_ALL) })
        }
        sep()
        UI.append(m, UI.row("applications-engineering-symbolic", "Inspect") { [unowned self] in
            self.closeMenu(); webkit_web_inspector_show(webkit_web_view_get_inspector(wv))
        })
        openMenu(m, under: Rect(x: x, y: y - 8, w: 0, h: 0), width: 250)
    }
}
