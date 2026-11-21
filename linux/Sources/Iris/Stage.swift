import CAdwaita
import Foundation

// The Stage is Iris's window content: one GTK widget (a GObject subclass
// made here, in Swift) that lays out every piece of the browser itself and
// draws them in layers, so the glass of each layer can bend what lies
// behind it:
//
//   back     the window's own tint (and the desktop, blurred by the
//            compositor where it can)
//   page     the pages (WebKit web views) and the new-tab page
//   chrome   tabs, address and buttons: glass over the back and the pages
//   overlay  menus, suggestions, downloads, find, notices: glass over all
//
// Every piece moves on springs: frames, fades, presses and hovers.

enum Layer: Int, Comparable {
    case back = 0, page, chrome, overlay
    static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }
}

typealias GtkW = UnsafeMutablePointer<GtkWidget>

/// a sub-widget drawn on its own glass (a button inside a group)
final class Part {
    let w: GtkW
    var glass: Glass
    var hover = Spring(0, stiffness: 420)
    var press = Spring(0, stiffness: 900)
    /// glass shows only when hovered or pressed (plain buttons)
    var onlyActive: Bool
    init(_ w: GtkW, _ g: Glass, onlyActive: Bool) { self.w = w; glass = g; self.onlyActive = onlyActive }
}

final class Item {
    let w: GtkW
    var layer: Layer
    var frame = SpringRect()
    var glass: Glass?
    var parts: [Part] = []
    var alpha = Spring(1, stiffness: 260)
    var scale = Spring(1, stiffness: 520, bounce: 0.28)
    var hover = Spring(0, stiffness: 420)
    var press = Spring(0, stiffness: 900)
    /// a page's rounded clip
    var clip: Double?
    /// shown at all (an item fading out stays until its alpha reaches 0)
    var shown = true
    var dying = false
    var onGone: (() -> Void)?
    /// what to draw under the widget (the new-tab page's colours)
    var behind: ((Snap, Rect) -> Void)?
    /// what to draw over the widget (the address bar's progress)
    var front: ((Snap, Rect) -> Void)?
    /// the glass shows only while hovered (tabs that are not selected)
    var glassFollowsHover = false
    /// reads the widget's hover and press for its glass
    var reactive = false
    var animateFrames = true

    init(_ w: GtkW, _ layer: Layer) { self.w = w; self.layer = layer }

    func moving(_ dt: Double) -> Bool {
        var m = animateFrames ? frame.step(dt) : false
        m = alpha.step(dt) || m
        m = scale.step(dt) || m
        m = hover.step(dt) || m
        m = press.step(dt) || m
        for p in parts {
            m = p.hover.step(dt) || m
            m = p.press.step(dt) || m
        }
        return m
    }
}

private var stageParentDispose: (@convention(c) (UnsafeMutablePointer<GObject>?) -> Void)?

private let stageType: GType = {
    var info = GTypeInfo()
    info.class_size = guint16(MemoryLayout<GtkWidgetClass>.size)
    info.instance_size = guint16(MemoryLayout<GtkWidget>.size)
    info.class_init = { klass, _ in
        let parent = g_type_class_peek_parent(klass)!.assumingMemoryBound(to: GObjectClass.self)
        stageParentDispose = parent.pointee.dispose
        let oc = klass!.assumingMemoryBound(to: GObjectClass.self)
        oc.pointee.dispose = { obj in
            if let obj { Stage.of(Ptr(obj))?.releaseChildren() }
            stageParentDispose?(obj)
        }
        let wc = klass!.assumingMemoryBound(to: GtkWidgetClass.self)
        wc.pointee.snapshot = { w, s in
            if let w, let s { Stage.of(Ptr(w))?.snapshot(s) }
        }
        wc.pointee.size_allocate = { w, width, height, _ in
            if let w { Stage.of(Ptr(w))?.allocate(Double(width), Double(height)) }
        }
        wc.pointee.measure = { _, orientation, _, minimum, natural, minB, natB in
            let m: Int32 = orientation == GTK_ORIENTATION_HORIZONTAL ? 420 : 300
            minimum?.pointee = m
            natural?.pointee = orientation == GTK_ORIENTATION_HORIZONTAL ? 1280 : 820
            minB?.pointee = -1
            natB?.pointee = -1
        }
        gtk_widget_class_set_css_name(wc, "iris-stage")
    }
    return g_type_register_static(gtk_widget_get_type(), "IrisStage", &info, GTypeFlags(rawValue: 0))
}()

final class Stage {
    let widget: GtkW
    private(set) var items: [Item] = []
    var width = 0.0, height = 0.0
    /// Browser places every item for a size
    var layout: ((Double, Double) -> Void)?
    /// the back layer
    var background: ((Snap, Double, Double) -> Void)?
    /// drawn into the scene after the pages (the page's colour reaching up)
    var afterPages: ((Snap) -> Void)?
    var pointer: (Double, Double)?
    /// the height of the chrome (tabs and toolbar), kept as one picture
    /// while nothing in it changes, so a playing video redraws only itself
    var chromeHeight = 0.0
    /// the chrome is drawn live (no picture) while this says so (typing)
    var chromeLive: () -> Bool = { false }
    private var chromeDirty = true
    private var chromeTex: OpaquePointer?
    private var chromeTexRect = Rect()
    private var chromeTexKey = ""
    private var inChrome = false
    var animations = true
    private var ticking = false
    private var lastFrame: Int64 = 0
    private var laidOut = false

    static func of(_ p: Ptr) -> Stage? {
        guard let d = g_object_get_data(p.assumingMemoryBound(to: GObject.self), "iris-stage") else { return nil }
        return Unmanaged<Stage>.fromOpaque(d).takeUnretainedValue()
    }

    init() {
        widget = gnew(stageType, []).assumingMemoryBound(to: GtkWidget.self)
        g_object_set_data(gptr(Ptr(widget)), "iris-stage", Unmanaged.passUnretained(self).toOpaque())
        gtk_widget_set_focusable(widget, 0)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        // the pointer, for the light it casts on glass
        let motion = gtk_event_controller_motion_new()
        gtk_event_controller_set_propagation_phase(motion, GTK_PHASE_CAPTURE)
        onXY(Ptr(motion), "motion") { [unowned self] x, y in
            self.pointer = (x, y)
            // in the chrome, anything may light up: draw it afresh
            if y < self.chromeHeight + 8 || self.inChrome {
                self.inChrome = y < self.chromeHeight + 8
                self.dirtyChrome()
            }
            if self.items.contains(where: { $0.reactive && $0.hover.value > 0.01 }) || self.items.contains(where: { $0.parts.contains { $0.hover.value > 0.01 } }) {
                gtk_widget_queue_draw(self.widget)
            }
        }
        on(Ptr(motion), "leave") { [unowned self] in self.pointer = nil; self.inChrome = false; self.dirtyChrome(); self.kick() }
        gtk_widget_add_controller(widget, motion)
        var anim: gboolean = 1
        g_object_get_property_bool(gtk_settings_get_default(), "gtk-enable-animations", &anim)
        animations = anim != 0
    }

    func releaseChildren() {
        for it in items { gtk_widget_unparent(it.w) }
        items.removeAll()
    }

    @discardableResult
    func add(_ w: GtkW, _ layer: Layer, glass: Glass? = nil, reactive: Bool = false) -> Item {
        let it = Item(w, layer)
        it.glass = glass
        it.reactive = reactive
        items.append(it)
        gtk_widget_set_parent(w, widget)
        if reactive { watch(w) }
        restack()
        return it
    }

    func part(_ it: Item, _ w: GtkW, _ g: Glass, onlyActive: Bool = true) {
        it.parts.append(Part(w, g, onlyActive: onlyActive))
        watch(w)
    }

    private func watch(_ w: GtkW) {
        on1(Ptr(w), "state-flags-changed") { [unowned self] _ in self.kick() }
    }

    /// fades an item out (and lets it go); onGone runs once it is gone
    func remove(_ it: Item, animated: Bool = true, then: (() -> Void)? = nil) {
        if !animated || !animations {
            drop(it)
            then?()
            return
        }
        it.dying = true
        it.onGone = then
        it.alpha.target = 0
        it.scale.target = 0.96
        kick()
    }

    private func drop(_ it: Item) {
        guard let i = items.firstIndex(where: { $0 === it }) else { return }
        items.remove(at: i)
        gtk_widget_unparent(it.w)
    }

    /// the order GTK picks and draws children in: layer by layer
    func restack() {
        let sorted = items.enumerated().sorted { a, b in
            a.element.layer == b.element.layer ? a.offset < b.offset : a.element.layer < b.element.layer
        }.map(\.element)
        items = sorted
        for it in items { gtk_widget_insert_before(it.w, widget, nil) }
    }

    func raise(_ it: Item) {
        if let i = items.firstIndex(where: { $0 === it }) {
            items.remove(at: i)
            items.append(it)
            restack()
        }
    }

    /// shows or hides an item, fading
    func show(_ it: Item, _ on: Bool, animated: Bool = true) {
        it.shown = on
        if on { gtk_widget_set_child_visible(it.w, 1) }
        if animated && animations {
            it.alpha.target = on ? 1 : 0
            if on && it.alpha.value < 0.01 { it.scale.value = it.layer == .overlay ? 0.94 : 0.985 }
            it.scale.target = 1
        } else {
            it.alpha.snap(on ? 1 : 0)
            it.scale.snap(1)
            if !on { gtk_widget_set_child_visible(it.w, 0) }
        }
        kick()
        gtk_widget_queue_allocate(widget)
    }

    func place(_ it: Item, _ r: Rect, animate: Bool = true) {
        it.frame.go(r, animate: animate && animations && laidOut)
        if !it.frame.settled { kick() }
    }

    func relayout() { gtk_widget_queue_allocate(widget) }

    // MARK: motion

    /// something in the chrome changed: its picture is made again
    func dirtyChrome() {
        chromeDirty = true
        gtk_widget_queue_draw(widget)
    }

    /// renders a node to a texture on the GPU, aligned to the screen's
    /// pixels (at fractional scales too); drawn with drawTexture, it lands
    /// texel for texel
    func renderTexture(_ node: Node, _ r: Rect) -> (OpaquePointer, Rect)? {
        guard let native = gtk_widget_get_native(widget), let renderer = gtk_native_get_renderer(native),
              let surface = gtk_native_get_surface(native) else { return nil }
        let s = gdk_surface_get_scale(surface)
        // where the stage's origin falls between screen pixels
        var sx = 0.0, sy = 0.0
        gtk_native_get_surface_transform(native, &sx, &sy)
        var o = graphene_point_t(), at = graphene_point_t()
        _ = gtk_widget_compute_point(widget, UnsafeMutablePointer<GtkWidget>(OpaquePointer(native)), &o, &at)
        let dx = (Double(at.x) + sx + r.x) * s, dy = (Double(at.y) + sy + r.y) * s
        let fx = dx - dx.rounded(.down), fy = dy - dy.rounded(.down)
        guard let sub = gtk_snapshot_new() else { return nil }
        var t = gpoint(fx, fy)
        gtk_snapshot_translate(sub, &t)
        gtk_snapshot_scale(sub, Float(s), Float(s))
        var back = gpoint(-r.x, -r.y)
        gtk_snapshot_translate(sub, &back)
        gtk_snapshot_append_node(sub, node)
        guard let scaled = gtk_snapshot_free_to_node(sub) else { return nil }
        let pw = (r.w * s + fx).rounded(.up), ph = (r.h * s + fy).rounded(.up)
        var vp = grect(Rect(x: 0, y: 0, w: pw, h: ph))
        let tex = gsk_renderer_render_texture(renderer, scaled, &vp)
        gsk_render_node_unref(scaled)
        guard let tex else { return nil }
        return (OpaquePointer(tex), Rect(x: r.x - fx / s, y: r.y - fy / s, w: pw / s, h: ph / s))
    }

    static func drawTexture(_ s: Snap, _ tex: OpaquePointer, _ r: Rect) {
        var g = grect(r)
        gtk_snapshot_append_texture(s, tex, &g)
    }

    func kick() {
        chromeDirty = true
        gtk_widget_queue_draw(widget)
        if ticking { return }
        ticking = true
        lastFrame = 0
        let data = Unmanaged.passUnretained(self).toOpaque()
        gtk_widget_add_tick_callback(widget, { w, clock, d in
            let st = Unmanaged<Stage>.fromOpaque(d!).takeUnretainedValue()
            return st.tick(Int64(gdk_frame_clock_get_frame_time(clock))) ? 1 : 0
        }, data, nil)
    }

    private static let debugFrames = getenv("IRIS_FRAMES") != nil
    /// IRIS_NO_CACHE=1 draws the chrome live every frame (to compare)
    static let noCache = getenv("IRIS_NO_CACHE") != nil

    private func tick(_ now: Int64) -> Bool {
        if Stage.debugFrames && lastFrame != 0 { fputs("frame \(Double(now - lastFrame) / 1000) ms\n", stderr) }
        let dt = lastFrame == 0 ? 1.0 / 60 : min(1.0 / 20, Double(now - lastFrame) / 1_000_000)
        lastFrame = now
        var moving = false
        var framesMoved = false
        for it in items {
            readState(it)
            let before = it.frame.rect
            if it.moving(animations ? dt : 10) { moving = true }
            if it.frame.rect != before { framesMoved = true }
        }
        // what has faded out goes
        for it in items where it.dying && it.alpha.value < 0.01 {
            let then = it.onGone
            drop(it)
            then?()
        }
        for it in items where !it.shown && !it.dying && it.alpha.value < 0.01 && it.alpha.target == 0 {
            gtk_widget_set_child_visible(it.w, 0)
        }
        if framesMoved { gtk_widget_queue_allocate(widget) }
        gtk_widget_queue_draw(widget)
        if !moving { ticking = false }
        return moving
    }

    private func flags(_ w: GtkW) -> (hover: Bool, press: Bool) {
        let f = gtk_widget_get_state_flags(w).rawValue
        return (f & GTK_STATE_FLAG_PRELIGHT.rawValue != 0, f & GTK_STATE_FLAG_ACTIVE.rawValue != 0)
    }

    private func readState(_ it: Item) {
        if it.reactive {
            let f = flags(it.w)
            it.hover.target = f.hover ? 1 : 0
            it.press.target = f.press ? 1 : 0
        }
        for p in it.parts {
            let f = flags(p.w)
            p.hover.target = f.hover ? 1 : 0
            p.press.target = f.press ? 1 : 0
        }
    }

    // MARK: layout

    func allocate(_ w: Double, _ h: Double) {
        let resized = w != width || h != height
        width = w
        height = h
        if resized || !laidOut { layout?(w, h); chromeDirty = true }
        laidOut = true
        for it in items where gtk_widget_get_child_visible(it.w) != 0 {
            let r = it.frame.rect
            var p = gpoint(r.x, r.y)
            let t = gsk_transform_translate(nil, &p)
            gtk_widget_allocate(it.w, Int32(max(0, r.w.rounded())), Int32(max(0, r.h.rounded())), -1, t)
        }
    }

    /// where a widget inside the stage is, in the stage's units
    func bounds(of w: GtkW) -> Rect? {
        // the widget's whole allocation (compute_bounds gives only its content)
        var o = graphene_point_t(), out = graphene_point_t()
        guard gtk_widget_get_mapped(w) != 0, gtk_widget_compute_point(w, widget, &o, &out) != 0 else { return nil }
        return Rect(x: Double(out.x), y: Double(out.y), w: Double(gtk_widget_get_width(w)), h: Double(gtk_widget_get_height(w)))
    }

    /// a page's picture as a node (for the colour reaching up from it)
    func node(of it: Item) -> Node? {
        guard gtk_widget_get_child_visible(it.w) != 0, let sub = gtk_snapshot_new() else { return nil }
        gtk_widget_snapshot_child(widget, it.w, sub)
        return gtk_snapshot_free_to_node(sub)
    }

    // MARK: drawing

    func snapshot(_ s: Snap) {
        let sub = gtk_snapshot_new()!
        background?(sub, width, height)
        for it in items where it.layer <= .page { draw(sub, it, scene: nil) }
        afterPages?(sub)
        let scene = gtk_snapshot_free_to_node(sub)
        if let scene { gtk_snapshot_append_node(s, scene) }

        // the chrome: drawn live while it moves or you type in it, otherwise
        // kept as one picture made again only when something in it changes
        var chrome: Node?
        let key = "\(width)x\(height)/\(chromeHeight)"
        let live = ticking || chromeLive() || chromeHeight <= 0 || Stage.noCache
        if !live && !chromeDirty && chromeTex != nil && key == chromeTexKey {
            chrome = gsk_texture_node_new(chromeTex, [grect(chromeTexRect)])
        } else {
            let sub2 = gtk_snapshot_new()!
            for it in items where it.layer == .chrome { draw(sub2, it, scene: scene) }
            chrome = gtk_snapshot_free_to_node(sub2)
            if let c = chrome, !live, let (tex, r) = renderTexture(c, Rect(x: 0, y: 0, w: width, h: chromeHeight)) {
                if let old = chromeTex { g_object_unref(Ptr(old)) }
                chromeTex = tex
                chromeTexRect = r
                chromeTexKey = key
                chromeDirty = false
                gsk_render_node_unref(c)
                chrome = gsk_texture_node_new(tex, [grect(r)])
            } else if live {
                chromeDirty = true
            }
        }
        if let chrome { gtk_snapshot_append_node(s, chrome) }

        if items.contains(where: { $0.layer == .overlay && gtk_widget_get_child_visible($0.w) != 0 }) {
            var nodes: [OpaquePointer?] = [scene, chrome].filter { $0 != nil }
            let all = nodes.withUnsafeMutableBufferPointer { gsk_container_node_new($0.baseAddress, guint($0.count)) }
            for it in items where it.layer == .overlay { draw(s, it, scene: all) }
            if let all { gsk_render_node_unref(all) }
        }
        if let scene { gsk_render_node_unref(scene) }
        if let chrome { gsk_render_node_unref(chrome) }
    }

    private func draw(_ s: Snap, _ it: Item, scene: Node?) {
        guard gtk_widget_get_child_visible(it.w) != 0, it.alpha.value > 0.003 else { return }
        let r = it.frame.rect
        gtk_snapshot_save(s)
        let a = min(1, max(0, it.alpha.value))
        if a < 0.999 { gtk_snapshot_push_opacity(s, a) }
        let k = it.scale.value * (1 - 0.03 * it.press.value)
        if abs(k - 1) > 0.0005 {
            var c = gpoint(r.midX, r.midY)
            gtk_snapshot_translate(s, &c)
            gtk_snapshot_scale(s, Float(k), Float(k))
            var b = gpoint(-r.midX, -r.midY)
            gtk_snapshot_translate(s, &b)
        }
        if let c = it.clip {
            var rr = rrect(r, c)
            gtk_snapshot_push_rounded_clip(s, &rr)
        }
        it.behind?(s, r)
        if var g = it.glass {
            if it.glassFollowsHover { g.amount *= max(it.hover.value, it.press.value) }
            Draw.glass(s, scene, r, g, pointer: pointer, hover: it.hover.value, press: it.press.value)
        }
        for p in it.parts {
            let on = max(p.hover.value, p.press.value)
            if p.onlyActive && on < 0.004 { continue }
            guard let b = bounds(of: p.w) else { continue }
            var g = p.glass
            if p.onlyActive { g.amount *= on }
            Draw.glass(s, scene, b, g, pointer: pointer, hover: p.hover.value, press: p.press.value)
        }
        gtk_widget_snapshot_child(widget, it.w, s)
        it.front?(s, r)
        if it.clip != nil { gtk_snapshot_pop(s) }
        if a < 0.999 { gtk_snapshot_pop(s) }
        gtk_snapshot_restore(s)
    }
}

/// g_object_get for one boolean property
func g_object_get_property_bool(_ obj: OpaquePointer?, _ name: String, _ out: inout gboolean) {
    guard let obj else { return }
    var v = GValue()
    g_value_init(&v, GType(5 << 2))
    g_object_get_property(UnsafeMutablePointer<GObject>(obj), name, &v)
    out = g_value_get_boolean(&v)
    g_value_unset(&v)
}
