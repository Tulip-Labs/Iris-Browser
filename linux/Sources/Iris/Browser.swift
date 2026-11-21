import CAdwaita
import CBlur
import CWebKit
import Foundation

/// One Iris window: tabs, their pages and the glass chrome around them.
final class Browser {
    let window: GtkW
    let stage = Stage()
    private(set) var tabs: [Tab] = []
    private(set) var current: Tab?
    /// closed tabs, to open again (Ctrl+Shift+T)
    private var closed: [(String, String?)] = []
    private(set) var fullscreen = false
    private var blur = false
    private var blurRegion = (0, 0, 0, 0, 0)
    weak var app: IrisApp?

    // the chrome
    private var handle: Item!
    private var indicator: Item!
    private var indicatorSpan = LiquidSpan()
    private var plus: Item!
    private var controls: Item!
    private var nav: Item!
    private var back: GtkW!, forward: GtkW!, reload: GtkW!
    private var address: Item!
    private(set) var addressText: GtkW!
    private var chip: GtkW!
    private var actions: Item!
    var shieldButton: GtkW!, downloadsButton: GtkW!, containerButton: GtkW!, menuButton: GtkW!
    private(set) var ntp: NewTabPage!
    private var editing = false
    private var progressShown = Spring(0, stiffness: 200)
    private var progressValue = Spring(0, stiffness: 160)

    // geometry, worked out by layout
    private(set) var card = Rect()
    private var radius = 14.0

    // overlays
    var menu: Item?
    var suggestions: Suggestions?
    var find: FindBar?
    var toastItem: Item?
    var toastTimer: UInt32 = 0
    var status: Item!
    var statusLabel: GtkW!

    init(app: IrisApp) {
        self.app = app
        window = adw_application_window_new(app.gtk)!
        gtk_window_set_title(win, "Iris")
        gtk_window_set_default_size(win, 1280, 820)
        gtk_widget_add_css_class(window, "iris")
        adw_application_window_set_content(cp(OpaquePointer(window)), stage.widget)
        gtk_window_set_icon_name(win, "io.github.tulip_labs.Iris")

        stage.background = { [unowned self] s, w, h in self.drawBack(s, w, h) }
        stage.afterPages = { [unowned self] s in self.drawReach(s) }
        stage.layout = { [unowned self] w, h in self.layout(w, h) }
        buildChrome()
        ntp = NewTabPage(self)
        buildStatus()

        // a click anywhere else closes a menu
        let click = gtk_gesture_click_new()!
        gtk_event_controller_set_propagation_phase(OpaquePointer(click), GTK_PHASE_CAPTURE)
        onPress(Ptr(click), "pressed") { [unowned self] _, x, y in
            self.pressed(x, y)
            // it only watches: the press goes on to what is under it
            gtk_gesture_set_state(OpaquePointer(click), GTK_EVENT_SEQUENCE_DENIED)
        }
        gtk_widget_add_controller(stage.widget, OpaquePointer(click))

        Keys.attach(self)
        on(Ptr(window), "realize") { [unowned self] in self.realized() }
        onBool0(Ptr(window), "close-request") { [unowned self] in
            self.saveSession()
            self.app?.closed(self)
            return false
        }
        Downloads.shared.changed.append { [weak self] d in self?.downloadChanged(d) }
    }

    var win: UnsafeMutablePointer<GtkWindow> { UnsafeMutablePointer<GtkWindow>(OpaquePointer(window)) }

    func present() { gtk_window_present(win) }

    private func realized() {
        blur = iris_blur_available(window) != 0
        if let surface = gtk_native_get_surface(OpaquePointer(window)) {
            on1(Ptr(surface), "notify::state") { [unowned self] _ in self.stage.relayout(); self.layout(self.stage.width, self.stage.height) }
        }
        stage.relayout()
    }

    // MARK: chrome

    private func buildChrome() {
        // the empty parts of the top move the window
        let h = gtk_window_handle_new()!
        handle = stage.add(h, .back)

        // the selected tab's glass, sliding from tab to tab
        let ind = UI.box()
        gtk_widget_set_can_target(ind, 0)
        indicator = stage.add(ind, .chrome, glass: Glass(radius: 16, tint: RGBA.white.alpha(0.70), bend: 6, rim: 12, dispersion: true, shadow: 0.7))
        indicator.animateFrames = false

        let p = UI.button("list-add-symbolic", "New tab (Ctrl+T)") { [unowned self] in self.newTab() }
        plus = stage.add(p, .chrome, glass: Glass(radius: 16, tint: RGBA.white.alpha(0.24), bend: 5, rim: 10), reactive: true)
        let pc = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(OpaquePointer(pc), 3)
        onPress(Ptr(pc), "pressed") { [unowned self] _, _, _ in self.showContainerMenu(anchor: self.plus.frame.rect, newTabOnly: true) }
        gtk_widget_add_controller(p, OpaquePointer(pc))

        let wc = gtk_window_controls_new(GTK_PACK_END)!
        controls = stage.add(wc, .chrome)

        // back, forward, reload: one capsule
        let navBox = UI.box(false, 2)
        UI.cls(navBox, "iris-group")
        gtk_widget_set_margin_start(navBox, 4); gtk_widget_set_margin_end(navBox, 4)
        back = UI.button("go-previous-symbolic", "Back (Alt+←)") { [unowned self] in self.current?.back() }
        forward = UI.button("go-next-symbolic", "Forward (Alt+→)") { [unowned self] in self.current?.forward() }
        reload = UI.button("view-refresh-symbolic", "Reload (Ctrl+R)") { [unowned self] in
            guard let t = self.current else { return }
            if t.loading { t.stop() } else { t.reload() }
        }
        for b in [back!, forward!, reload!] {
            gtk_widget_set_valign(b, GTK_ALIGN_CENTER)
            UI.append(navBox, b)
        }
        nav = stage.add(navBox, .chrome, glass: Glass(radius: 19, tint: RGBA.white.alpha(0.20)))
        for b in [back!, forward!, reload!] { stage.part(nav, b, Glass(radius: 17, tint: RGBA.white.alpha(0.30), bend: 3, rim: 8, dispersion: false)) }

        // the address
        let ab = UI.box(false, 8)
        UI.cls(ab, "iris-address")
        chip = UI.label("", "iris-chip")
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(chip, 0)
        let t = gtk_text_new()!
        addressText = t
        gtk_widget_set_hexpand(t, 1)
        gtk_widget_set_valign(t, GTK_ALIGN_CENTER)
        gtk_text_set_placeholder_text(UnsafeMutablePointer<GtkText>(OpaquePointer(t)), "Search or enter address")
        gtk_editable_set_alignment(OpaquePointer(t), 0.5)
        UI.append(ab, chip)
        UI.append(ab, t)
        address = stage.add(ab, .chrome, glass: Glass(radius: 19, tint: RGBA.white.alpha(0.30), bend: 7, rim: 14), reactive: true)
        stage.part(address, chip, Glass(radius: 10, tint: RGBA(hex: "#0a84ff", 0.9), bend: 2, rim: 5, dispersion: false, rimLight: 0.6), onlyActive: false)
        address.front = { [unowned self] s, r in self.drawProgress(s, r) }
        wireAddress(t)

        // shields, downloads, containers, menu
        let actBox = UI.box(false, 2)
        gtk_widget_set_margin_start(actBox, 4); gtk_widget_set_margin_end(actBox, 4)
        shieldButton = UI.button("security-high-symbolic", "Shields") { [unowned self] in self.showShields() }
        downloadsButton = UI.button("folder-download-symbolic", "Downloads (Ctrl+Shift+Y)") { [unowned self] in self.showDownloads() }
        containerButton = UI.button("view-grid-symbolic", "Containers") { [unowned self] in
            self.showContainerMenu(anchor: self.stage.bounds(of: self.containerButton) ?? self.actions.frame.rect)
        }
        menuButton = UI.button("open-menu-symbolic", "Menu") { [unowned self] in self.showAppMenu() }
        for b in [shieldButton!, downloadsButton!, containerButton!, menuButton!] {
            gtk_widget_set_valign(b, GTK_ALIGN_CENTER)
            UI.append(actBox, b)
        }
        actions = stage.add(actBox, .chrome, glass: Glass(radius: 19, tint: RGBA.white.alpha(0.20)))
        for b in [shieldButton!, downloadsButton!, containerButton!, menuButton!] {
            stage.part(actions, b, Glass(radius: 17, tint: RGBA.white.alpha(0.30), bend: 3, rim: 8, dispersion: false))
        }
    }

    private func wireAddress(_ t: GtkW) {
        let focus = gtk_event_controller_focus_new()!
        on(Ptr(focus), "enter") { [unowned self] in self.beginEditing() }
        on(Ptr(focus), "leave") { [unowned self] in self.endEditing() }
        gtk_widget_add_controller(t, focus)
        on(Ptr(t), "activate") { [unowned self] in
            let typed = UI.text(t)
            if let s = self.suggestions, let u = s.chosen() { self.go(u) } else { self.go(Search.resolve(typed)) }
        }
        on(Ptr(t), "changed") { [unowned self] in
            guard self.editing, gtk_widget_has_focus(t) != 0 else { return }
            self.typed(UI.text(t))
        }
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        onKey(Ptr(keys)) { [unowned self] key, _ in
            switch Int32(key) {
            case GDK_KEY_Escape:
                if self.suggestions != nil { self.closeSuggestions() } else { self.focusPage() }
                return true
            case GDK_KEY_Down: self.suggestions?.move(1); return self.suggestions != nil
            case GDK_KEY_Up: self.suggestions?.move(-1); return self.suggestions != nil
            default: return false
            }
        }
        gtk_widget_add_controller(t, keys)
    }

    private func beginEditing() {
        editing = true
        gtk_editable_set_alignment(OpaquePointer(addressText), 0)
        UI.setText(addressText, Search.editable(current?.url ?? ""))
        address.glass?.tint = RGBA.white.alpha(0.62)
        address.scale.value = 0.985
        address.scale.target = 1
        stage.relayout()
        layout(stage.width, stage.height)
        idle { [weak self] in
            guard let self else { return }
            gtk_editable_select_region(OpaquePointer(self.addressText), 0, -1)
        }
        stage.kick()
    }

    private func endEditing() {
        editing = false
        closeSuggestions()
        gtk_editable_set_alignment(OpaquePointer(addressText), 0.5)
        address.glass?.tint = RGBA.white.alpha(0.30)
        showAddress()
        layout(stage.width, stage.height)
        stage.kick()
    }

    func focusAddress() {
        if fullscreen { return }
        gtk_widget_grab_focus(addressText)
    }

    func focusPage() {
        if let w = current?.web { gtk_widget_grab_focus(w) } else { gtk_widget_grab_focus(ntp.box) }
    }

    private func showAddress() {
        guard !editing else { return }
        UI.setText(addressText, Search.display(current?.url ?? ""))
    }

    private func typed(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { closeSuggestions(); return }
        if suggestions == nil { suggestions = Suggestions(self) }
        suggestions?.update(text)
    }

    func closeSuggestions() {
        if let s = suggestions { s.close() }
        suggestions = nil
    }

    var addressFrame: Rect { address.frame.target }

    // MARK: the back and the page's colour

    private var windowRadius: Double {
        guard let s = gtk_native_get_surface(OpaquePointer(window)) else { return 14 }
        let st = gdk_toplevel_get_state(s).rawValue
        let square = GDK_TOPLEVEL_STATE_MAXIMIZED.rawValue | GDK_TOPLEVEL_STATE_FULLSCREEN.rawValue | GDK_TOPLEVEL_STATE_TILED.rawValue
        return st & square != 0 ? 0 : 14
    }

    private func drawBack(_ s: Snap, _ w: Double, _ h: Double) {
        let r = Rect(x: 0, y: 0, w: w, h: h)
        var rr = rrect(r, radius)
        gtk_snapshot_push_rounded_clip(s, &rr)
        // translucent where the compositor blurs what is behind; nearly
        // solid where it cannot (sharp windows behind would show through)
        Draw.color(s, RGBA(0.955, 0.955, 0.975, blur ? 0.56 : 0.97), r)
        Draw.radial(s, r, center: (w * 0.15, -40), radius: max(w, h) * 0.7,
                    [(0, RGBA(0.55, 0.45, 1, 0.10)), (1, RGBA(0.55, 0.45, 1, 0))])
        Draw.radial(s, r, center: (w * 0.9, -20), radius: max(w, h) * 0.6,
                    [(0, RGBA(0.30, 0.75, 1, 0.08)), (1, RGBA(0.30, 0.75, 1, 0))])
        Draw.linear(s, Rect(x: 0, y: 0, w: w, h: card.y), from: (0, 0), to: (0, card.y),
                    [(0, RGBA.white.alpha(0.45)), (1, RGBA.white.alpha(0.0))])
        gtk_snapshot_pop(s)
        // the window's own rim of light
        if radius > 0 {
            Draw.rimStroke(s, r, radius, width: 1) {
                Draw.linear(s, r, from: (0, 0), to: (0, h), [(0, RGBA.white.alpha(0.9)), (0.2, RGBA.white.alpha(0.35)), (1, RGBA.white.alpha(0.2))])
            }
        }
    }

    /// the page's colour reaches up under the chrome (as Apple's toolbars
    /// take on the colour of the page under them), for the glass to bend
    private func drawReach(_ s: Snap) {
        guard !fullscreen, let t = current, let page = t.page, page.alpha.value > 0.01,
              let node = stage.node(of: page) else { return }
        let top = card.y
        gtk_snapshot_save(s)
        var clip = grect(Rect(x: 0, y: 0, w: stage.width, h: top))
        gtk_snapshot_push_clip(s, &clip)
        gtk_snapshot_push_opacity(s, 0.42 * page.alpha.value)
        gtk_snapshot_push_blur(s, 26)
        // the page's first rows, stretched up to the window's top
        gtk_snapshot_scale(s, 1, Float(top / 3))
        var up = gpoint(0, -top)
        gtk_snapshot_translate(s, &up)
        gtk_snapshot_append_node(s, node)
        gtk_snapshot_pop(s)
        gtk_snapshot_pop(s)
        gtk_snapshot_pop(s)
        gtk_snapshot_restore(s)
        gsk_render_node_unref(node)
    }

    private func drawProgress(_ s: Snap, _ r: Rect) {
        let a = progressShown.value
        guard a > 0.01 else { return }
        let w = (r.w - 28) * min(1, max(0, progressValue.value))
        let bar = Rect(x: r.x + 14, y: r.maxY - 3.5, w: w, h: 2.5)
        Draw.rounded(s, RGBA(0.04, 0.52, 1, 0.9 * a), bar, 1.25)
    }

    func progressChanged(_ t: Tab) {
        guard t === current else { return }
        progressValue.target = t.progress
        progressShown.target = t.loading ? 1 : 0
        animateProgress()
    }

    private var progressTicking = false
    private func animateProgress() {
        if progressTicking { return }
        progressTicking = true
        var last = Date()
        every(ms: 16) { [weak self] in
            guard let self else { return false }
            let now = Date()
            let dt = now.timeIntervalSince(last)
            last = now
            let a = self.progressValue.step(dt)
            let b = self.progressShown.step(dt)
            if !self.progressShown.settled || self.progressShown.target == 0 && self.progressShown.value < 0.02 {
                if self.progressShown.target == 0 && self.progressShown.value < 0.02 { self.progressValue.snap(0) }
            }
            gtk_widget_queue_draw(self.stage.widget)
            self.progressTicking = a || b
            return self.progressTicking
        }
    }

    // MARK: layout

    private func layout(_ W: Double, _ H: Double) {
        radius = windowRadius
        let pad = 8.0
        let showChrome = !fullscreen
        let tabY = 6.0, tabH = 32.0
        let toolY = 44.0, toolH = 38.0
        card = showChrome ? Rect(x: pad, y: toolY + toolH + 8, w: W - 2 * pad, h: H - (toolY + toolH + 8) - pad) : Rect(x: 0, y: 0, w: W, h: H)

        stage.place(handle, Rect(x: 0, y: 0, w: W, h: card.y), animate: false)
        let (cw, ch) = UI.natural(controls.w)
        stage.place(controls, Rect(x: W - pad - cw, y: tabY + (tabH - ch) / 2, w: cw, h: ch), animate: false)

        // the tabs
        let x0 = pad
        let x1 = W - pad - cw - 10 - tabH - 6
        let n = Double(max(1, tabs.count))
        let tw = min(232, max(44, (x1 - x0 - 4 * (n - 1)) / n))
        for (i, t) in tabs.enumerated() {
            let r = Rect(x: x0 + Double(i) * (tw + 4), y: tabY, w: tw, h: tabH)
            stage.place(t.pillItem, r)
            gtk_widget_set_visible(t.close, (t === current || tw > 110) ? 1 : 0)
        }
        let plusX = min(x1 + 6, x0 + n * (tw + 4))
        stage.place(plus, Rect(x: plusX, y: tabY, w: tabH, h: tabH))
        if let c = current, let i = tabs.firstIndex(where: { $0 === c }) {
            let r = Rect(x: x0 + Double(i) * (tw + 4), y: tabY, w: tw, h: tabH)
            indicatorSpan.go(r.x, r.maxX, animate: stage.animations)
            stage.kick()
            tickIndicator()
        }

        // the toolbar
        let (nw, _) = UI.natural(nav.w)
        let (aw, _) = UI.natural(actions.w)
        stage.place(nav, Rect(x: pad, y: toolY, w: nw, h: toolH), animate: false)
        stage.place(actions, Rect(x: W - pad - aw, y: toolY, w: aw, h: toolH), animate: false)
        let ax = pad + nw + 8
        let aW = W - pad - aw - 8 - ax
        // the address bar draws in a little until you type in it
        let inset = editing ? 0 : min(aW * 0.08, 60)
        stage.place(address, Rect(x: ax + inset, y: toolY, w: aW - 2 * inset, h: toolH))

        for t in tabs { if let p = t.page { stage.place(p, card, animate: false) } }
        stage.place(ntp.item, card, animate: false)
        for it in [handle, indicator, plus, controls, nav, address, actions] {
            if it!.shown != showChrome { stage.show(it!, showChrome) }
        }
        for t in tabs where t.pillItem.shown != showChrome { stage.show(t.pillItem, showChrome) }
        let pr = showChrome ? 12.0 : 0
        for t in tabs { t.page?.clip = pr }
        ntp.item.clip = pr
        placeOverlays()
        updateBlur(W, H)
    }

    private var indicatorTicking = false
    private func tickIndicator() {
        if indicatorTicking { return }
        indicatorTicking = true
        var last = Date()
        func apply() {
            let lo = indicatorSpan.lo.value, hi = indicatorSpan.hi.value
            // in flight the pill thins a little, like a drop
            let speed = abs(indicatorSpan.lo.velocity) + abs(indicatorSpan.hi.velocity)
            let squeeze = min(3, speed / 900)
            indicator.frame.go(Rect(x: lo, y: 6 + squeeze, w: max(10, hi - lo), h: 32 - 2 * squeeze), animate: false)
            gtk_widget_queue_allocate(stage.widget)
        }
        apply()
        every(ms: 8) { [weak self] in
            guard let self else { return false }
            let now = Date()
            let moving = self.indicatorSpan.step(min(0.05, now.timeIntervalSince(last)))
            last = now
            apply()
            self.indicatorTicking = moving
            return moving
        }
    }

    private func updateBlur(_ w: Double, _ h: Double) {
        guard blur, let native = Optional(OpaquePointer(window)) else { return }
        var sx = 0.0, sy = 0.0
        gtk_native_get_surface_transform(native, &sx, &sy)
        let r = (Int(sx), Int(sy), Int(w), Int(h), Int(radius))
        if r != blurRegion {
            blurRegion = r
            iris_blur_set(window, Int32(r.0), Int32(r.1), Int32(r.2), Int32(r.3), Int32(r.4))
        }
    }

    // MARK: tabs

    @discardableResult
    func newTab(_ url: String? = nil, container: String? = nil, after: Tab? = nil, select: Bool = true, related: UnsafeMutablePointer<WebKitWebView>? = nil, lazy: Bool = false) -> Tab {
        let t = Tab(browser: self, container: container)
        let it = stage.add(t.pill, .chrome, glass: Glass(radius: 16, tint: RGBA.white.alpha(0.22), bend: 4, rim: 9, dispersion: false), reactive: true)
        it.glassFollowsHover = true
        it.alpha.value = 0
        it.scale.value = 0.86
        t.pillItem = it
        stage.show(it, !fullscreen)
        wirePill(t)
        if let a = after, let i = tabs.firstIndex(where: { $0 === a }) { tabs.insert(t, at: i + 1) } else { tabs.append(t) }
        // the tab opens where it will sit
        if let i = tabs.firstIndex(where: { $0 === t }), i > 0 {
            let prev = tabs[i - 1].pillItem.frame.target
            it.frame.go(Rect(x: prev.maxX + 4, y: prev.y, w: prev.w, h: prev.h), animate: false)
        }
        if let related {
            t.ensureWeb(related: related)
        } else if let url, !url.isEmpty {
            if lazy { t.pending = url; t.title = Search.display(url); UI.setLabel(t.pillLabel, t.title) } else { t.load(url) }
        }
        if select || current == nil { self.select(t) } else { layout(stage.width, stage.height) }
        if select && (url ?? "").isEmpty && related == nil { idle { [weak self] in self?.focusAddress() } }
        return t
    }

    private func wirePill(_ t: Tab) {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(OpaquePointer(click), 0)
        onPress(Ptr(click), "pressed") { [unowned self, weak t] _, _, _ in
            guard let t else { return }
            let b = gtk_gesture_single_get_current_button(OpaquePointer(click))
            if b == 2 { self.close(t) } else if b == 1 { self.select(t) } else if b == 3 { self.tabMenu(t) }
        }
        gtk_widget_add_controller(t.pill, OpaquePointer(click))
        on(Ptr(t.close), "clicked") { [unowned self, weak t] in if let t { self.close(t) } }
    }

    /// a tab's page joins the stage (the first time it opens something)
    func attachPage(_ t: Tab) {
        guard let w = t.web, t.page == nil else { return }
        let it = stage.add(w, .page)
        it.clip = fullscreen ? 0 : 12
        it.animateFrames = false
        stage.place(it, card, animate: false)
        t.page = it
        if t === current {
            it.alpha.value = 0
            it.scale.value = 0.99
            stage.show(it, true)
            stage.show(ntp.item, false)
        } else {
            stage.show(it, false, animated: false)
        }
    }

    func select(_ t: Tab) {
        let old = current
        if old === t { layout(stage.width, stage.height); return }
        current = t
        if let p = t.pending { t.pending = nil; t.load(p) }
        if let op = old?.page { stage.show(op, false) }
        if let np = t.page {
            stage.raise(np)
            stage.show(np, true)
            stage.show(ntp.item, false)
        } else {
            ntp.refresh()
            stage.show(ntp.item, true)
        }
        old.map { gtk_widget_remove_css_class($0.pill, "selected") }
        gtk_widget_add_css_class(t.pill, "selected")
        indicator.glass?.tint = (Containers.shared.get(t.container).map { RGBA(hex: $0.color, 0.30) } ?? RGBA.white.alpha(0.70))
        closeMenu()
        find?.close()
        tabChanged(t)
        progressChanged(t)
        layout(stage.width, stage.height)
        if !editing { focusPage() }
    }

    func close(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === t }) else { return }
        if !t.url.isEmpty && !t.isPrivate { closed.append((t.url, t.container)) }
        tabs.remove(at: i)
        if t === current {
            current = nil
            if tabs.isEmpty {
                // the last tab: Iris stays, with a fresh one
                newTab()
            } else {
                select(tabs[min(i, tabs.count - 1)])
            }
        }
        stage.remove(t.pillItem)
        if let p = t.page { stage.remove(p) { t.destroy() } } else { t.destroy() }
        if t.isPrivate && !tabs.contains(where: { $0.isPrivate }) && !(app?.anyPrivate(except: self) ?? false) {
            Containers.shared.endPrivate()
        }
        layout(stage.width, stage.height)
    }

    func closeCurrent() { if let c = current { close(c) } }

    func reopenClosed() {
        guard let (u, c) = closed.popLast() else { return }
        newTab(u, container: c)
    }

    func cycle(_ d: Int) {
        guard let c = current, let i = tabs.firstIndex(where: { $0 === c }), tabs.count > 1 else { return }
        select(tabs[(i + d + tabs.count) % tabs.count])
    }

    func selectIndex(_ i: Int) {
        if i == 8 { if let l = tabs.last { select(l) }; return }
        if i < tabs.count { select(tabs[i]) }
    }

    func go(_ url: String) {
        guard !url.isEmpty else { return }
        closeSuggestions()
        let t = current ?? newTab()
        t.load(url)
        focusPage()
    }

    func tabChanged(_ t: Tab) {
        let label = t.title.isEmpty ? (t.url.isEmpty ? "New Tab" : Search.display(t.url)) : t.title
        UI.setLabel(t.pillLabel, label)
        gtk_widget_set_tooltip_text(t.pill, label)
        guard t === current else { return }
        gtk_widget_set_sensitive(back, t.canBack ? 1 : 0)
        gtk_widget_set_sensitive(forward, t.canForward ? 1 : 0)
        gtk_button_set_icon_name(UnsafeMutablePointer<GtkButton>(OpaquePointer(reload)), t.loading ? "process-stop-symbolic" : "view-refresh-symbolic")
        if let c = Containers.shared.get(t.container) {
            UI.setLabel(chip, c.name)
            gtk_widget_set_visible(chip, 1)
            if let p = address.parts.first { p.glass.tint = RGBA(hex: c.color, 0.92) }
        } else {
            gtk_widget_set_visible(chip, 0)
        }
        let host = Search.host(t.url)
        gtk_button_set_icon_name(UnsafeMutablePointer<GtkButton>(OpaquePointer(shieldButton)),
                                 Shields.shared.onFor(host) ? "security-high-symbolic" : "security-low-symbolic")
        showAddress()
        if t.page != nil { stage.show(ntp.item, false) }
        gtk_window_set_title(win, t.title.isEmpty ? "Iris" : t.title + " – Iris")
        stage.kick()
    }

    // MARK: pop-ups and new windows

    /// a page asks for a new window: links open as tabs; pop-ups from
    /// scripts only when you clicked, to the same site or a sign-in, and
    /// never to an ad server. True when handled.
    func newWindow(from t: Tab, decision d: OpaquePointer) -> Bool {
        let nav = webkit_navigation_policy_decision_get_navigation_action(d)
        guard let req = webkit_navigation_action_get_request(nav), let u = str(webkit_uri_request_get_uri(req)) else { return false }
        let host = Search.host(u) ?? ""
        let shields = Shields.shared.onFor(Search.host(t.url))
        if shields && ShieldRules.blocked(host) {
            webkit_policy_decision_ignore(cp(d))
            return true
        }
        let type = webkit_navigation_action_get_navigation_type(nav)
        if type == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED {
            webkit_policy_decision_ignore(cp(d))
            let background = webkit_navigation_action_get_mouse_button(nav) == 2
            newTab(u, container: t.container, after: t, select: !background)
            return true
        }
        let gesture = webkit_navigation_action_is_user_gesture(nav) != 0
        let pageSite = Search.host(t.url).map(Search.site) ?? ""
        let signIn = ShieldRules.never.contains { host == $0 || host.hasSuffix("." + $0) }
        if gesture && (Search.site(host) == pageSite || signIn || u == "about:blank") {
            return false // WebKit goes on and asks for the view ("create")
        }
        webkit_policy_decision_ignore(cp(d))
        if shields {
            toast("Pop-up blocked", action: ("Open", { [weak self] in self?.newTab(u, container: t.container, after: t) }))
        } else {
            newTab(u, container: t.container, after: t)
        }
        return true
    }

    func popup(from t: Tab, action: OpaquePointer?) -> UnsafeMutablePointer<WebKitWebView>? {
        guard let parent = t.webView else { return nil }
        let p = newTab(nil, container: t.container, after: t, select: false, related: parent)
        return p.webView
    }

    func openInBackground(_ u: String, from t: Tab) {
        newTab(u, container: t.container, after: t, select: false)
    }

    // MARK: fullscreen

    func pageFullscreen(_ on: Bool) {
        fullscreen = on
        if on { gtk_window_fullscreen(win) } else { gtk_window_unfullscreen(win) }
        closeMenu()
        layout(stage.width, stage.height)
        stage.relayout()
    }

    func toggleWindowFullscreen() {
        if gtk_window_is_fullscreen(win) != 0 {
            if fullscreen { current?.run("document.fullscreenElement && document.exitFullscreen()") }
            fullscreen = false
            gtk_window_unfullscreen(win)
        } else {
            gtk_window_fullscreen(win)
        }
        layout(stage.width, stage.height)
    }

    // MARK: session

    func saveSession() {
        let saved = tabs.filter { !$0.isPrivate && !($0.pending ?? $0.url).isEmpty }
            .map { Settings.SavedTab(url: $0.pending ?? $0.url, title: $0.title, container: $0.container) }
        if app?.isLast(self) ?? true {
            SettingsStore.shared.update { $0.session = saved }
        }
        History.shared.flush()
    }

    func restore(_ saved: [Settings.SavedTab]) {
        for (i, s) in saved.enumerated() {
            let t = newTab(s.url, container: Containers.shared.get(s.container) == nil ? nil : s.container, select: i == 0, lazy: i != 0)
            if i != 0, !s.title.isEmpty { t.title = s.title; UI.setLabel(t.pillLabel, s.title) }
        }
    }

    // MARK: overlays

    func pressed(_ x: Double, _ y: Double) {
        if let m = menu, !m.frame.rect.contains(x, y) { closeMenu() }
    }

    func closeMenu() {
        if let m = menu {
            stage.remove(m)
            menu = nil
            downloadsPanel = nil
        }
    }

    var downloadsPanel: DownloadsPanel?

    func placeOverlays() {
        suggestions?.place()
        find?.place()
        if let t = toastItem {
            let (w, h) = UI.natural(t.w)
            stage.place(t, Rect(x: card.midX - w / 2, y: card.maxY - h - 18, w: w, h: h), animate: false)
        }
        placeStatus()
    }

    /// a menu of glass, under r (or at a point)
    func openMenu(_ content: GtkW, under r: Rect, width: Double? = nil, alignRight: Bool = false) {
        closeMenu()
        let wrap = UI.box(true, 0)
        UI.cls(wrap, "iris-menu")
        UI.append(wrap, content)
        let it = stage.add(wrap, .overlay, glass: Glass(radius: 18, tint: RGBA(0.98, 0.98, 1, 0.70), bend: 9, rim: 18, lens: 0.02, blur: 3, shadow: 1))
        var (w, h) = UI.natural(wrap)
        if let width { w = width; h = UI.natural(wrap, forWidth: Int32(width)).1 }
        var x = alignRight ? r.maxX - w : r.x
        var y = r.maxY + 8
        x = min(max(8, x), stage.width - w - 8)
        if y + h > stage.height - 8 { y = max(8, r.y - h - 8) }
        it.frame.go(Rect(x: x, y: y, w: w, h: min(h, stage.height - 16)), animate: false)
        it.alpha.value = 0
        it.scale.value = 0.92
        stage.show(it, true)
        // each row lights up as glass under the pointer
        rows(of: content).forEach { stage.part(it, $0, Glass(radius: 10, tint: RGBA.white.alpha(0.45), bend: 3, rim: 8, dispersion: false)) }
        menu = it
    }

    func rows(of w: GtkW) -> [GtkW] {
        var out: [GtkW] = []
        var c = gtk_widget_get_first_child(w)
        while let child = c {
            if gtk_widget_has_css_class(child, "iris-row") != 0 { out.append(child) } else { out += rows(of: child) }
            c = gtk_widget_get_next_sibling(child)
        }
        return out
    }

    func toast(_ text: String, action: (String, () -> Void)? = nil) {
        if let t = toastItem { stage.remove(t) }
        if toastTimer != 0 { g_source_remove(toastTimer); toastTimer = 0 }
        let b = UI.box(false, 10)
        UI.cls(b, "iris-toast")
        gtk_widget_set_margin_start(b, 16); gtk_widget_set_margin_end(b, 8)
        gtk_widget_set_margin_top(b, 6); gtk_widget_set_margin_bottom(b, 6)
        UI.append(b, UI.label(text))
        if let (name, f) = action {
            let a = UI.textButton(name) { [weak self] in f(); self?.hideToast() }
            UI.append(b, a)
        }
        let x = UI.button("window-close-symbolic", "Dismiss") { [weak self] in self?.hideToast() }
        UI.cls(x, "small"); gtk_widget_set_size_request(x, 24, 24)
        UI.append(b, x)
        let it = stage.add(b, .overlay, glass: Glass(radius: 22, tint: RGBA.white.alpha(0.5), bend: 8, rim: 16, shadow: 1))
        let (w, h) = UI.natural(b)
        it.frame.go(Rect(x: card.midX - w / 2, y: card.maxY - h - 18, w: w, h: h), animate: false)
        it.alpha.value = 0
        it.scale.value = 0.9
        stage.show(it, true)
        toastItem = it
        toastTimer = after(ms: 6000) { [weak self] in self?.toastTimer = 0; self?.hideToast() }
    }

    func hideToast() {
        if let t = toastItem { stage.remove(t); toastItem = nil }
    }

    private func buildStatus() {
        statusLabel = UI.label("", "iris-dim")
        UI.ellipsize(statusLabel, chars: 10)
        gtk_label_set_max_width_chars(OpaquePointer(statusLabel), 70)
        gtk_widget_set_margin_start(statusLabel, 12); gtk_widget_set_margin_end(statusLabel, 12)
        gtk_widget_set_margin_top(statusLabel, 5); gtk_widget_set_margin_bottom(statusLabel, 5)
        gtk_widget_set_can_target(statusLabel, 0)
        status = stage.add(statusLabel, .overlay, glass: Glass(radius: 14, tint: RGBA.white.alpha(0.55), bend: 5, rim: 10, dispersion: false))
        stage.show(status, false, animated: false)
    }

    private func placeStatus() {
        let (w, h) = UI.natural(statusLabel)
        stage.place(status, Rect(x: card.x + 10, y: card.maxY - h - 10, w: min(w, card.w * 0.6), h: h), animate: false)
    }

    func hoverLink(_ t: Tab, _ link: String?) {
        guard t === current else { return }
        if let link, !link.hasPrefix("javascript:") {
            UI.setLabel(statusLabel, link)
            placeStatus()
            stage.show(status, true)
        } else if status.shown {
            stage.show(status, false)
        }
    }

    // MARK: downloads

    private func downloadChanged(_ d: Download?) {
        downloadsPanel?.update(d)
        if let d, d.done, d.received > 0, menu == nil || downloadsPanel == nil {
            if abs(d.started.timeIntervalSinceNow) < 3600, !d.failed, d.progress >= 1, !(d.name.isEmpty) {
                if d.done && lastToastedDownload !== d {
                    lastToastedDownload = d
                    toast("Downloaded \(d.name)", action: ("Open", { [weak self] in Downloads.shared.open(d, self?.window) }))
                }
            }
        } else if let d, !d.done, !d.failed, d.received == 0, downloadsPanel == nil, menu == nil {
            showDownloads()
        }
    }

    private weak var lastToastedDownload: Download?

    func showDownloads() {
        let panel = DownloadsPanel(self)
        openMenu(panel.box, under: stage.bounds(of: downloadsButton) ?? actions.frame.rect, width: 380, alignRight: true)
        downloadsPanel = panel
    }

    // MARK: permissions

    func permission(_ t: Tab, _ req: OpaquePointer) {
        let name = String(cString: g_type_name(UnsafeMutablePointer<GTypeInstance>(req).pointee.g_class.pointee.g_type))
        let what: String
        switch name {
        case "WebKitUserMediaPermissionRequest": what = "use your camera or microphone"
        case "WebKitGeolocationPermissionRequest": what = "know your location"
        case "WebKitNotificationPermissionRequest": what = "show notifications"
        case "WebKitClipboardPermissionRequest": what = "read your clipboard"
        case "WebKitPointerLockPermissionRequest": webkit_permission_request_allow(req); return
        default: what = "use a feature of your computer"
        }
        g_object_ref(Ptr(req))
        var answered = false
        let site = Search.display(t.url)
        toast("\(site.isEmpty ? "This page" : site) wants to \(what)", action: ("Allow", {
            answered = true
            webkit_permission_request_allow(req)
            g_object_unref(Ptr(req))
        }))
        after(ms: 6100) {
            if !answered { webkit_permission_request_deny(req); g_object_unref(Ptr(req)) }
        }
    }
}

