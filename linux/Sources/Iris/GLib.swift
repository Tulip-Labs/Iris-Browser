import CAdwaita
import Foundation

// Small bridges from Swift closures to GLib's C callbacks: signals, idles,
// timeouts, GValues and GObject construction.

typealias Ptr = UnsafeMutableRawPointer

final class Box<T> {
    let f: T
    init(_ f: T) { self.f = f }
}

private let releaseBox: GClosureNotify = { data, _ in
    if let data { Unmanaged<AnyObject>.fromOpaque(data).release() }
}

@discardableResult
private func connect(_ obj: Ptr?, _ name: String, _ cb: GCallback, _ box: AnyObject, after: Bool = false) -> gulong {
    let data = Unmanaged.passRetained(box).toOpaque()
    return g_signal_connect_data(obj, name, cb, data, releaseBox, GConnectFlags(rawValue: after ? 1 : 0))
}

private func unbox<T>(_ d: Ptr?) -> T { Unmanaged<Box<T>>.fromOpaque(d!).takeUnretainedValue().f }

/// signal(instance)
@discardableResult
func on(_ obj: Ptr?, _ name: String, after: Bool = false, _ f: @escaping () -> Void) -> gulong {
    let cb: @convention(c) (Ptr?, Ptr?) -> Void = { _, d in (unbox(d) as () -> Void)() }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f), after: after)
}

/// signal(instance, a)
@discardableResult
func on1(_ obj: Ptr?, _ name: String, _ f: @escaping (Ptr?) -> Void) -> gulong {
    let cb: @convention(c) (Ptr?, Ptr?, Ptr?) -> Void = { _, a, d in (unbox(d) as (Ptr?) -> Void)(a) }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, a, b)
@discardableResult
func on2(_ obj: Ptr?, _ name: String, _ f: @escaping (Ptr?, Ptr?) -> Void) -> gulong {
    let cb: @convention(c) (Ptr?, Ptr?, Ptr?, Ptr?) -> Void = { _, a, b, d in (unbox(d) as (Ptr?, Ptr?) -> Void)(a, b) }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, uint)
@discardableResult
func onUInt(_ obj: Ptr?, _ name: String, _ f: @escaping (UInt32) -> Void) -> gulong {
    let cb: @convention(c) (Ptr?, UInt32, Ptr?) -> Void = { _, a, d in (unbox(d) as (UInt32) -> Void)(a) }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance) -> gboolean
@discardableResult
func onBool0(_ obj: Ptr?, _ name: String, _ f: @escaping () -> Bool) -> gulong {
    let cb: @convention(c) (Ptr?, Ptr?) -> gboolean = { _, d in (unbox(d) as () -> Bool)() ? 1 : 0 }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, a) -> gboolean
@discardableResult
func onBool1(_ obj: Ptr?, _ name: String, _ f: @escaping (Ptr?) -> Bool) -> gulong {
    let cb: @convention(c) (Ptr?, Ptr?, Ptr?) -> gboolean = { _, a, d in (unbox(d) as (Ptr?) -> Bool)(a) ? 1 : 0 }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, a, b) -> gboolean
@discardableResult
func onBool2(_ obj: Ptr?, _ name: String, _ f: @escaping (Ptr?, Ptr?) -> Bool) -> gulong {
    let cb: @convention(c) (Ptr?, Ptr?, Ptr?, Ptr?) -> gboolean = { _, a, b, d in (unbox(d) as (Ptr?, Ptr?) -> Bool)(a, b) ? 1 : 0 }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, a, uint) -> Void (policy decisions)
@discardableResult
func onBoolPtrUInt(_ obj: Ptr?, _ name: String, _ f: @escaping (Ptr?, UInt32) -> Bool) -> gulong {
    let cb: @convention(c) (Ptr?, Ptr?, UInt32, Ptr?) -> gboolean = { _, a, b, d in (unbox(d) as (Ptr?, UInt32) -> Bool)(a, b) ? 1 : 0 }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, uint keyval, uint keycode, uint state) -> gboolean (key-pressed)
@discardableResult
func onKey(_ obj: Ptr?, _ f: @escaping (UInt32, UInt32) -> Bool) -> gulong {
    let cb: @convention(c) (Ptr?, UInt32, UInt32, UInt32, Ptr?) -> gboolean = { _, key, _, state, d in
        (unbox(d) as (UInt32, UInt32) -> Bool)(key, state) ? 1 : 0
    }
    return connect(obj, "key-pressed", unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, double, double) (motion, enter)
@discardableResult
func onXY(_ obj: Ptr?, _ name: String, _ f: @escaping (Double, Double) -> Void) -> gulong {
    let cb: @convention(c) (Ptr?, Double, Double, Ptr?) -> Void = { _, x, y, d in (unbox(d) as (Double, Double) -> Void)(x, y) }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// signal(instance, int n, double, double) (pressed, released)
@discardableResult
func onPress(_ obj: Ptr?, _ name: String, _ f: @escaping (Int32, Double, Double) -> Void) -> gulong {
    let cb: @convention(c) (Ptr?, Int32, Double, Double, Ptr?) -> Void = { _, n, x, y, d in (unbox(d) as (Int32, Double, Double) -> Void)(n, x, y) }
    return connect(obj, name, unsafeBitCast(cb, to: GCallback.self), Box(f))
}

/// a callback on GLib's main loop when it is next idle
func idle(_ f: @escaping () -> Void) {
    let data = Unmanaged.passRetained(Box(f)).toOpaque()
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, { d in
        let b = Unmanaged<Box<() -> Void>>.fromOpaque(d!)
        b.takeUnretainedValue().f()
        b.release()
        return 0
    }, data, nil)
}

/// a callback after ms milliseconds; returns the source id
@discardableResult
func after(ms: UInt32, _ f: @escaping () -> Void) -> UInt32 {
    let data = Unmanaged.passRetained(Box(f)).toOpaque()
    return g_timeout_add_full(G_PRIORITY_DEFAULT, ms, { d in
        Unmanaged<Box<() -> Void>>.fromOpaque(d!).takeUnretainedValue().f()
        return 0
    }, data, { d in Unmanaged<Box<() -> Void>>.fromOpaque(d!).release() })
}

/// a callback every ms milliseconds while it returns true
@discardableResult
func every(ms: UInt32, _ f: @escaping () -> Bool) -> UInt32 {
    let data = Unmanaged.passRetained(Box(f)).toOpaque()
    return g_timeout_add_full(G_PRIORITY_DEFAULT, ms, { d in
        Unmanaged<Box<() -> Bool>>.fromOpaque(d!).takeUnretainedValue().f() ? 1 : 0
    }, data, { d in Unmanaged<Box<() -> Bool>>.fromOpaque(d!).release() })
}

func str(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }
func str(_ p: UnsafeMutablePointer<CChar>?) -> String? { p.map { String(cString: $0) } }

/// a string GLib allocated, taken and freed
func takeStr(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { g_free(p) }
    return String(cString: p)
}

/// one property for gnew
enum Prop {
    case object(String, Ptr?, GType)
    case bool(String, Bool)
    case string(String, String)
    case boxed(String, Ptr?, GType)
}

/// g_object_new with properties (the variadic form is out of Swift's reach)
func gnew(_ type: GType, _ props: [Prop]) -> Ptr {
    var names: [UnsafePointer<CChar>?] = []
    var values = [GValue](repeating: GValue(), count: props.count)
    var owned: [UnsafeMutablePointer<CChar>] = []
    for (i, p) in props.enumerated() {
        switch p {
        case let .object(n, v, t):
            let s = strdup(n)!; owned.append(s); names.append(UnsafePointer(s))
            g_value_init(&values[i], t)
            g_value_set_object(&values[i], v)
        case let .bool(n, v):
            let s = strdup(n)!; owned.append(s); names.append(UnsafePointer(s))
            g_value_init(&values[i], GType(5 << 2)) // G_TYPE_BOOLEAN
            g_value_set_boolean(&values[i], v ? 1 : 0)
        case let .boxed(n, v, t):
            let s = strdup(n)!; owned.append(s); names.append(UnsafePointer(s))
            g_value_init(&values[i], t)
            g_value_set_boxed(&values[i], v)
        case let .string(n, v):
            let s = strdup(n)!; owned.append(s); names.append(UnsafePointer(s))
            g_value_init(&values[i], GType(16 << 2)) // G_TYPE_STRING
            g_value_set_string(&values[i], v)
        }
    }
    let obj = names.withUnsafeMutableBufferPointer { n in
        values.withUnsafeBufferPointer { v in
            g_object_new_with_properties(type, guint(props.count), n.baseAddress, v.baseAddress)
        }
    }
    for i in values.indices { g_value_unset(&values[i]) }
    owned.forEach { free($0) }
    return Ptr(obj!)
}

func gptr<T>(_ p: Ptr?) -> UnsafeMutablePointer<T>? { p?.assumingMemoryBound(to: T.self) }
func gptr<T>(_ p: OpaquePointer?) -> UnsafeMutablePointer<T>? { p.map { UnsafeMutablePointer<T>($0) } }

func unref(_ p: Ptr?) { if let p { g_object_unref(p) } }

extension OpaquePointer {
    /// lets OpaquePointer(x) take an OpaquePointer too, so a call site reads
    /// the same whichever way the C header declared the type
    init(_ p: OpaquePointer) { self = p }
}

/// a GObject pointer as the type a C function wants
@inline(__always) func cp<T>(_ p: OpaquePointer?) -> UnsafeMutablePointer<T>? { p.map { UnsafeMutablePointer<T>($0) } }
@inline(__always) func cp<T, U>(_ p: UnsafeMutablePointer<U>?) -> UnsafeMutablePointer<T>? { p.map { UnsafeMutablePointer<T>(OpaquePointer($0)) } }
