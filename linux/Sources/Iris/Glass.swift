import CAdwaita
import Foundation

// Liquid Glass, drawn with GTK's own render nodes (no shaders of Iris's, so
// it runs the same on GTK's GL and Vulkan renderers, at any scale).
//
// Not frosted glass: what lies behind stays sharp. Glass bends it:
// - the middle magnifies a little, like a lens;
// - towards the rim the picture is pulled in from beyond the edge, in three
//   steps that grow towards the edge, so straight lines curve as they cross
//   it, and the outermost step splits red and blue a little (dispersion);
// - a rim of light runs round it, brightest where the light comes from
//   (top left) and again opposite, plus a soft inner highlight;
// - the pointer lights the glass where it is, and a press presses it in.

typealias Snap = OpaquePointer // GtkSnapshot *
typealias Node = OpaquePointer // GskRenderNode *

struct RGBA {
    var r, g, b, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: String, _ a: Double = 1) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, a)
    }
    func alpha(_ x: Double) -> RGBA { RGBA(r, g, b, a * x) }
    var gdk: GdkRGBA { GdkRGBA(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a)) }
    static let white = RGBA(1, 1, 1)
    static let black = RGBA(0, 0, 0)
    static let ink = RGBA(0.11, 0.11, 0.13)
}

struct Glass {
    var radius: Double
    /// how much of the material shows (0 none, 1 all): hovers fade it in
    var amount = 1.0
    var tint = RGBA.white.alpha(0.16)
    /// refraction at the rim, in pixels pulled in from beyond the edge
    var bend = 7.0
    /// width of the bending rim
    var rim = 14.0
    /// lens magnification of the middle
    var lens = 0.025
    /// a touch of softening, for legibility (not frost)
    var blur = 0.0
    var dispersion = true
    var shadow = 0.0
    var rimLight = 1.0
}

func grect(_ r: Rect) -> graphene_rect_t {
    graphene_rect_t(origin: graphene_point_t(x: Float(r.x), y: Float(r.y)), size: graphene_size_t(width: Float(r.w), height: Float(r.h)))
}

func gpoint(_ x: Double, _ y: Double) -> graphene_point_t { graphene_point_t(x: Float(x), y: Float(y)) }

func rrect(_ r: Rect, _ radius: Double) -> GskRoundedRect {
    var rr = GskRoundedRect()
    var g = grect(r)
    gsk_rounded_rect_init_from_rect(&rr, &g, Float(min(radius, min(r.w, r.h) / 2)))
    return rr
}

enum Draw {
    static func color(_ s: Snap, _ c: RGBA, _ r: Rect) {
        var col = c.gdk
        var g = grect(r)
        gtk_snapshot_append_color(s, &col, &g)
    }

    static func rounded(_ s: Snap, _ c: RGBA, _ r: Rect, _ radius: Double) {
        var rr = rrect(r, radius)
        gtk_snapshot_push_rounded_clip(s, &rr)
        color(s, c, r)
        gtk_snapshot_pop(s)
    }

    static func linear(_ s: Snap, _ r: Rect, from: (Double, Double), to: (Double, Double), _ stops: [(Double, RGBA)]) {
        var g = grect(r)
        var a = gpoint(from.0, from.1), b = gpoint(to.0, to.1)
        let cs = stops.map { GskColorStop(offset: Float($0.0), color: $0.1.gdk) }
        cs.withUnsafeBufferPointer { gtk_snapshot_append_linear_gradient(s, &g, &a, &b, $0.baseAddress, gsize(cs.count)) }
    }

    static func radial(_ s: Snap, _ r: Rect, center: (Double, Double), radius: Double, _ stops: [(Double, RGBA)]) {
        var g = grect(r)
        var c = gpoint(center.0, center.1)
        let cs = stops.map { GskColorStop(offset: Float($0.0), color: $0.1.gdk) }
        cs.withUnsafeBufferPointer {
            gtk_snapshot_append_radial_gradient(s, &g, &c, Float(radius), Float(radius), 0, 1, $0.baseAddress, gsize(cs.count))
        }
    }

    static func inset(_ s: Snap, _ r: Rect, _ radius: Double, _ c: RGBA, dx: Double = 0, dy: Double = 0, spread: Double = 0, blur: Double) {
        var rr = rrect(r, radius)
        var col = c.gdk
        gtk_snapshot_append_inset_shadow(s, &rr, &col, Float(dx), Float(dy), Float(spread), Float(blur))
    }

    static func outset(_ s: Snap, _ r: Rect, _ radius: Double, _ c: RGBA, dx: Double = 0, dy: Double = 0, spread: Double = 0, blur: Double) {
        var rr = rrect(r, radius)
        var col = c.gdk
        gtk_snapshot_append_outset_shadow(s, &rr, &col, Float(dx), Float(dy), Float(spread), Float(blur))
    }

    /// a stroke along a rounded rectangle, painted with a gradient
    static func rimStroke(_ s: Snap, _ r: Rect, _ radius: Double, width: Double, _ paint: () -> Void) {
        guard let b = gsk_path_builder_new() else { return }
        var rr = rrect(r.inset(width / 2), max(0, radius - width / 2))
        gsk_path_builder_add_rounded_rect(b, &rr)
        let path = gsk_path_builder_free_to_path(b)
        let stroke = gsk_stroke_new(Float(width))
        gtk_snapshot_push_stroke(s, path, stroke)
        paint()
        gtk_snapshot_pop(s)
        gsk_stroke_free(stroke)
        gsk_path_unref(path)
    }

    /// draws `scene` scaled about (cx, cy) so the edges of r move by d
    /// pixels inwards (d > 0: content from beyond the edge comes in)
    static func bent(_ s: Snap, _ scene: Node, _ r: Rect, d: Double, lens: Double = 0, blur: Double = 0) {
        let sx = max(0.2, 1 - 2 * d / max(r.w, 1)) * (1 + lens)
        let sy = max(0.2, 1 - 2 * d / max(r.h, 1)) * (1 + lens)
        // shrinking the picture about the middle pulls in what is beyond the edge
        gtk_snapshot_save(s)
        var c = gpoint(r.midX, r.midY)
        gtk_snapshot_translate(s, &c)
        gtk_snapshot_scale(s, Float(sx), Float(sy))
        var back = gpoint(-r.midX, -r.midY)
        gtk_snapshot_translate(s, &back)
        // only the part of the scene this glass can show (so the renderer
        // never works on the whole window for a small piece of glass)
        var need = grect(r.inset(-(abs(d) + blur * 3 + 4)))
        gtk_snapshot_push_clip(s, &need)
        if blur > 0 { gtk_snapshot_push_blur(s, blur) }
        gtk_snapshot_append_node(s, scene)
        if blur > 0 { gtk_snapshot_pop(s) }
        gtk_snapshot_pop(s)
        gtk_snapshot_restore(s)
    }

    /// keeps one colour channel of what follows (dispersion)
    static func channel(_ s: Snap, _ i: Int, _ body: () -> Void) {
        var m = graphene_matrix_t()
        var f: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        f[i * 5] = 1
        f.withUnsafeMutableBufferPointer { _ = graphene_matrix_init_from_float(&m, $0.baseAddress) }
        var off = graphene_vec4_t()
        graphene_vec4_init(&off, 0, 0, 0, 0)
        gtk_snapshot_push_color_matrix(s, &m, &off)
        body()
        gtk_snapshot_pop(s)
    }

    /// what follows is seen only where `mask` is opaque
    static func masked(_ s: Snap, mask: () -> Void, _ body: () -> Void) {
        gtk_snapshot_push_mask(s, GSK_MASK_MODE_ALPHA)
        mask()
        gtk_snapshot_pop(s)
        body()
        gtk_snapshot_pop(s)
    }

    /// Liquid Glass over `scene` (what lies behind, as one node) in r.
    /// pointer is where the pointer is (nil when away), hover and press 0...1.
    static func glass(_ s: Snap, _ scene: Node?, _ r: Rect, _ g: Glass, pointer: (Double, Double)? = nil,
                      hover: Double = 0, press: Double = 0) {
        guard g.amount > 0.004, r.w > 1, r.h > 1 else { return }
        let fade = g.amount < 0.999
        if fade { gtk_snapshot_push_opacity(s, g.amount) }
        let rad = min(g.radius, min(r.w, r.h) / 2)
        if g.shadow > 0 {
            outset(s, r, rad, RGBA.black.alpha(0.10 * g.shadow), dy: 2, blur: 12)
        }
        var rr = rrect(r, rad)
        gtk_snapshot_push_rounded_clip(s, &rr)
        if let scene {
            let bend = g.bend * (1 + 0.35 * press)
            // the body: a gentle lens
            bent(s, scene, r, d: 0, lens: g.lens + 0.012 * press, blur: g.blur)
            // the rim: three steps, each nearer the edge and bending more
            let steps: [(Double, Double)] = [(0.4, 1.0), (0.72, 0.62), (1.0, 0.34)]
            for (i, (k, width)) in steps.enumerated() {
                let w = max(2, g.rim * width)
                masked(s, mask: {
                    inset(s, r, rad, RGBA.white, spread: w * 0.35, blur: w)
                }) {
                    if g.dispersion && i == steps.count - 1 {
                        // red bends a little less and blue a little more
                        gtk_snapshot_push_blend(s, GSK_BLEND_MODE_SCREEN)
                        channel(s, 0) { bent(s, scene, r, d: bend * k * 0.86, blur: g.blur) }
                        gtk_snapshot_pop(s)
                        gtk_snapshot_push_blend(s, GSK_BLEND_MODE_SCREEN)
                        channel(s, 1) { bent(s, scene, r, d: bend * k, blur: g.blur) }
                        gtk_snapshot_pop(s)
                        channel(s, 2) { bent(s, scene, r, d: bend * k * 1.14, blur: g.blur) }
                        gtk_snapshot_pop(s)
                        gtk_snapshot_pop(s)
                    } else {
                        bent(s, scene, r, d: bend * k, blur: g.blur)
                    }
                }
            }
        }
        // the glass itself: a faint tint, lighter when hovered or pressed
        color(s, g.tint.alpha(1 + 0.6 * hover + 0.9 * press), r)
        // light from above: a bright line just inside the top, a soft
        // shade inside the bottom
        inset(s, r, rad, RGBA.white.alpha(0.55 * g.rimLight), dy: 1.2, blur: 1.6)
        inset(s, r, rad, RGBA.white.alpha(0.22 * g.rimLight), dy: 0, spread: 0, blur: min(r.h, r.w) * 0.35)
        inset(s, r, rad, RGBA.black.alpha(0.05 * g.rimLight), dy: -1.2, blur: 3)
        // the pointer lights the glass where it is
        if let p = pointer, hover > 0.01 {
            let reach = max(r.h, min(r.w, 160)) * 0.9
            radial(s, r, center: p, radius: reach, [(0, RGBA.white.alpha(0.30 * hover)), (1, RGBA.white.alpha(0))])
        }
        gtk_snapshot_pop(s)
        // the rim of light
        if g.rimLight > 0 {
            rimStroke(s, r, rad, width: 1) {
                linear(s, r, from: (r.x, r.y), to: (r.maxX, r.maxY), [
                    (0, RGBA.white.alpha(0.95 * g.rimLight)),
                    (0.35, RGBA.white.alpha(0.18 * g.rimLight)),
                    (0.62, RGBA.white.alpha(0.10 * g.rimLight)),
                    (1, RGBA.white.alpha(0.70 * g.rimLight)),
                ])
            }
            // and a hair of shade outside it, so glass reads on white pages
            rimStroke(s, r.inset(-0.5), rad + 0.5, width: 0.6) {
                color(s, RGBA.black.alpha(0.10 * g.rimLight), r.inset(-1))
            }
        }
        if fade { gtk_snapshot_pop(s) }
    }
}
