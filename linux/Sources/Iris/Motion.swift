import Foundation

/// A value that springs to where the interface wants it: positions, sizes,
/// fades, hovers and presses all move this way, so a change is felt as well
/// as seen. Critically damped by default (no wobble); `bounce` lets a little
/// overshoot through, the liquid feel of a glass pill settling.
struct Spring {
    var value: Double
    var target: Double
    var velocity: Double = 0
    var stiffness: Double
    var damping: Double

    init(_ v: Double, stiffness: Double = 380, bounce: Double = 0) {
        value = v
        target = v
        self.stiffness = stiffness
        // damping ratio 1 is critical; bounce 0.2 is a ratio of 0.8
        damping = 2 * (1 - bounce) * stiffness.squareRoot()
    }

    var settled: Bool { abs(velocity) < 0.02 && abs(target - value) < 0.02 }

    mutating func snap(_ v: Double) {
        value = v
        target = v
        velocity = 0
    }

    /// moves dt seconds on; true while still moving
    @discardableResult
    mutating func step(_ dt: Double) -> Bool {
        if settled {
            value = target
            velocity = 0
            return false
        }
        // a few small steps keep a stiff spring stable at 60 Hz and below
        let n = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n {
            let a = stiffness * (target - value) - damping * velocity
            velocity += a * h
            value += velocity * h
        }
        return true
    }
}

/// a rectangle in logical pixels
struct Rect: Equatable {
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0
    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }
    func inset(_ d: Double) -> Rect { Rect(x: x + d, y: y + d, w: max(0, w - 2 * d), h: max(0, h - 2 * d)) }
    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
}

/// four springs for a moving, resizing rectangle
struct SpringRect {
    var x, y, w, h: Spring
    var fresh = true

    init(stiffness: Double = 420, bounce: Double = 0.12) {
        x = Spring(0, stiffness: stiffness, bounce: bounce)
        y = Spring(0, stiffness: stiffness, bounce: bounce)
        w = Spring(0, stiffness: stiffness, bounce: bounce)
        h = Spring(0, stiffness: stiffness, bounce: bounce)
    }

    var rect: Rect { Rect(x: x.value, y: y.value, w: max(0, w.value), h: max(0, h.value)) }
    var target: Rect { Rect(x: x.target, y: y.target, w: w.target, h: h.target) }
    var settled: Bool { x.settled && y.settled && w.settled && h.settled }

    mutating func go(_ r: Rect, animate: Bool) {
        if fresh || !animate {
            x.snap(r.x); y.snap(r.y); w.snap(r.w); h.snap(r.h)
            fresh = false
            return
        }
        x.target = r.x; y.target = r.y; w.target = r.w; h.target = r.h
    }

    mutating func step(_ dt: Double) -> Bool {
        var m = x.step(dt)
        m = y.step(dt) || m
        m = w.step(dt) || m
        m = h.step(dt) || m
        return m
    }
}

/// The liquid edge of a sliding glass pill: the side it travels towards
/// leads and the other follows, so the pill stretches in flight and settles
/// back to its shape.
struct LiquidSpan {
    var lo = Spring(0, stiffness: 520, bounce: 0.18)
    var hi = Spring(0, stiffness: 520, bounce: 0.18)
    var fresh = true

    mutating func go(_ a: Double, _ b: Double, animate: Bool) {
        if fresh || !animate {
            lo.snap(a); hi.snap(b); fresh = false
            return
        }
        let right = a > lo.target
        // the leading edge is quicker, the trailing one softer
        lo.stiffness = right ? 260 : 620
        hi.stiffness = right ? 620 : 260
        lo.damping = 2 * 0.82 * lo.stiffness.squareRoot()
        hi.damping = 2 * 0.82 * hi.stiffness.squareRoot()
        lo.target = a
        hi.target = b
    }

    mutating func step(_ dt: Double) -> Bool {
        let m = lo.step(dt)
        return hi.step(dt) || m
    }

    var settled: Bool { lo.settled && hi.settled }
}
