import CAdwaita
import CSoup
import CWebKit
import Foundation

/// Iris Shields, as in Brave: ads and trackers are stopped inside WebKit
/// before a request leaves the computer. The filter lists uBlock Origin
/// uses (EasyList, EasyPrivacy, uBlock's own, and for Ultra its annoyance
/// lists), with uBlock's fixes for broken sites, become WebKit content
/// rules for the chosen level (Moderate, Aggressive, Ultra aggressive),
/// compiled once and kept; Iris's own list of about 100,000 ad and tracker
/// domains covers the first start, until the lists have come.
enum ShieldHosts {
    /// the hosts of Iris's list, for the pop-up check (read in the
    /// background at start; until then nothing counts as blocked)
    nonisolated(unsafe) static var hosts: Set<String> = []

    static func domains() -> [String] {
        guard let p = Resources.path("shield-domains.json.gz"), let d = gunzip(p),
              let list = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return list
    }

    static func load() {
        DispatchQueue.global(qos: .utility).async {
            let s = Set(domains().filter(ShieldConverter.usable))
            idle { hosts = s }
        }
    }

    static func blocked(_ host: String) -> Bool {
        var h = Substring(host)
        while true {
            if hosts.contains(String(h)) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = h[h.index(after: dot)...]
            if !h.contains(".") { return false }
        }
    }
}

/// a gzip file's contents, through GIO
func gunzip(_ path: String) -> Data? {
    let file = g_file_new_for_path(path)
    defer { g_object_unref(Ptr(file)) }
    guard let raw = g_file_read(file, nil, nil) else { return nil }
    defer { g_object_unref(Ptr(raw)) }
    let z = g_zlib_decompressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP)
    defer { g_object_unref(Ptr(z)) }
    let stream = g_converter_input_stream_new(UnsafeMutablePointer<GInputStream>(OpaquePointer(raw)), OpaquePointer(Ptr(z)))
    defer { g_object_unref(Ptr(stream)) }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = buf.withUnsafeMutableBytes { g_input_stream_read(UnsafeMutablePointer<GInputStream>(OpaquePointer(stream)), $0.baseAddress, gsize($0.count), nil, nil) }
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

final class Shields {
    static let shared = Shields()
    /// the content rules in force (one level's, in parts)
    private(set) var filters: [OpaquePointer] = []
    private var filtersLevel: ShieldLevel?
    private var waiting: [OpaquePointer] = []
    private let store: OpaquePointer
    private let dir = Paths.cache + "/shields"
    private var listsDir: String { dir + "/lists" }
    private var building: ShieldLevel?
    private var session: UnsafeMutablePointer<SoupSession>?
    /// a new set of rules is in place: pages already open take it
    var installed: (() -> Void)?

    var ready: Bool { !filters.isEmpty }
    var level: ShieldLevel { SettingsStore.shared.value.shieldLevel }

    private init() {
        try? FileManager.default.createDirectory(atPath: dir + "/lists", withIntermediateDirectories: true)
        store = webkit_user_content_filter_store_new(dir)
    }

    var on: Bool { SettingsStore.shared.value.shields }

    func onFor(_ host: String?) -> Bool {
        guard on else { return false }
        guard let host else { return true }
        return !SettingsStore.shared.value.shieldsOff.contains(Search.site(host))
    }

    func toggle(site: String) {
        SettingsStore.shared.update { s in
            if let i = s.shieldsOff.firstIndex(of: site) { s.shieldsOff.remove(at: i) } else { s.shieldsOff.append(site) }
        }
    }

    // MARK: the rules

    private func idsPath(_ l: ShieldLevel) -> String { dir + "/\(l.rawValue).ids" }

    /// the compiled rules of the level, kept from before; else they are made
    func start() {
        _ = Shields.t0
        ShieldHosts.load()
        load(level)
        // the lists are fetched again every four days
        after(ms: 8000) { [weak self] in self?.refreshLists() }
    }

    func levelChanged() {
        load(level)
    }

    private func load(_ l: ShieldLevel) {
        // a hand-made rule list, for checks (IRIS_SHIELDS_JSON=file)
        if let p = getenv("IRIS_SHIELDS_JSON").flatMap({ String(cString: $0) }), let j = try? String(contentsOfFile: p, encoding: .utf8) {
            compile([j], l)
            return
        }
        guard let text = try? String(contentsOfFile: idsPath(l), encoding: .utf8) else { build(l); return }
        let ids = text.split(separator: "\n").map(String.init)
        guard !ids.isEmpty else { build(l); return }
        var got: [OpaquePointer?] = Array(repeating: nil, count: ids.count)
        var left = ids.count
        var failed = false
        for (i, id) in ids.enumerated() {
            let box = Unmanaged.passRetained(Box<(OpaquePointer?) -> Void>({ [weak self] f in
                got[i] = f
                if f == nil { failed = true }
                left -= 1
                guard left == 0, let self else { return }
                if failed { got.compactMap { $0 }.forEach { webkit_user_content_filter_unref($0) }; self.build(l) } else { self.install(got.compactMap { $0 }, l) }
            })).toOpaque()
            webkit_user_content_filter_store_load(store, id, nil, { obj, res, d in
                let f = Unmanaged<Box<(OpaquePointer?) -> Void>>.fromOpaque(d!)
                var err: UnsafeMutablePointer<GError>?
                let filter = webkit_user_content_filter_store_load_finish(OpaquePointer(obj), res, &err)
                if let err { g_error_free(err) }
                f.takeUnretainedValue().f(filter)
                f.release()
            }, box)
        }
    }

    private func listPath(_ l: ShieldList) -> String { listsDir + "/\(l.rawValue).txt" }

    /// turns the level's lists (those already here) into rules and compiles
    /// them; lists not here yet are fetched first
    private func build(_ l: ShieldLevel) {
        guard building == nil else { return }
        let missing = l.lists.filter { !FileManager.default.fileExists(atPath: listPath($0)) }
        if !missing.isEmpty && !fetchTried.contains(l) {
            fetchTried.insert(l)
            fetch(missing) { [weak self] in self?.build(l) }
            return
        }
        building = l
        let paths = l.lists.map(listPath)
        DispatchQueue.global(qos: .utility).async {
            var c = ShieldConverter(level: l)
            var any = false
            for p in paths {
                if let t = try? String(contentsOfFile: p, encoding: .utf8) { c.add(list: t); any = true }
            }
            // Iris's own domain list, until the lists have come
            if !any { c.add(domains: ShieldHosts.domains()) }
            let parts = c.finish(maxRules: Int(getenv("IRIS_SHIELDS_PART").flatMap { Int(String(cString: $0)) } ?? 120_000))
            idle { [weak self] in self?.compile(parts, l) }
        }
    }

    private var fetchTried = Set<ShieldLevel>()

    private func compile(_ parts: [String], _ l: ShieldLevel) {
        let stamp = String(Int(Date().timeIntervalSince1970))
        let ids = parts.indices.map { "iris-\(l.rawValue)-\(stamp)-\($0)" }
        var got: [OpaquePointer?] = Array(repeating: nil, count: parts.count)
        var left = parts.count
        for (i, json) in parts.enumerated() {
            let bytes = json.withCString { g_bytes_new($0, gsize(strlen($0))) }
            let box = Unmanaged.passRetained(Box<(OpaquePointer?) -> Void>({ [weak self] f in
                got[i] = f
                left -= 1
                guard left == 0, let self else { return }
                self.building = nil
                let made = got.compactMap { $0 }
                guard made.count == parts.count else {
                    made.forEach { webkit_user_content_filter_unref($0) }
                    return
                }
                let old = (try? String(contentsOfFile: self.idsPath(l), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
                try? ids.joined(separator: "\n").write(toFile: self.idsPath(l), atomically: true, encoding: .utf8)
                for id in old where !ids.contains(id) { webkit_user_content_filter_store_remove(self.store, id, nil, nil, nil) }
                self.install(made, l)
            })).toOpaque()
            webkit_user_content_filter_store_save(store, ids[i], bytes, nil, { obj, res, d in
                let f = Unmanaged<Box<(OpaquePointer?) -> Void>>.fromOpaque(d!)
                var err: UnsafeMutablePointer<GError>?
                let filter = webkit_user_content_filter_store_save_finish(OpaquePointer(obj), res, &err)
                if let err {
                    FileHandle.standardError.write("Iris: the shield's rules did not compile: \(String(cString: err.pointee.message))\n".data(using: .utf8)!)
                    g_error_free(err)
                }
                f.takeUnretainedValue().f(filter)
                f.release()
            }, box)
            g_bytes_unref(bytes)
        }
    }

    static let debug = getenv("IRIS_SHIELDS_DEBUG") != nil
    static let t0 = Date()

    private func install(_ made: [OpaquePointer], _ l: ShieldLevel) {
        if Shields.debug { fputs("shields: \(made.count) rule lists for \(l.rawValue) after \(Int(Date().timeIntervalSince(Shields.t0))) s\n", stderr) }
        guard l == level else { made.forEach { webkit_user_content_filter_unref($0) }; return }
        filters.forEach { webkit_user_content_filter_unref($0) }
        filters = made
        filtersLevel = l
        let w = waiting
        waiting.removeAll()
        for ucm in w { for f in filters { webkit_user_content_manager_add_filter(ucm, f) } }
        installed?()
    }

    // MARK: the lists

    /// fetches the lists that are missing or older than four days, then
    /// makes the level's rules again if any changed
    func refreshLists() {
        let old = ShieldList.allCases.filter { l in
            guard let a = try? FileManager.default.attributesOfItem(atPath: listPath(l)), let m = a[.modificationDate] as? Date else { return level.lists.contains(l) }
            return Date().timeIntervalSince(m) > 4 * 86400 && level.lists.contains(l)
        }
        guard !old.isEmpty else { return }
        fetch(old) { [weak self] in
            guard let self else { return }
            // every level's kept rules are made again from the new lists
            for l in ShieldLevel.allCases where l != self.level { try? FileManager.default.removeItem(atPath: self.idsPath(l)) }
            self.build(self.level)
        }
    }

    private func fetch(_ lists: [ShieldList], then: @escaping () -> Void) {
        var left = lists.count
        for l in lists {
            get(l.urls) { [weak self] data in
                if let self, let data, data.count > 1000, let text = String(data: data, encoding: .utf8),
                   text.hasPrefix("!") || text.hasPrefix("[") {
                    // written whole, never half
                    let tmp = self.listPath(l) + ".new"
                    if FileManager.default.createFile(atPath: tmp, contents: data) { _ = rename(tmp, self.listPath(l)) }
                }
                left -= 1
                if left == 0 { then() }
            }
        }
    }

    /// the first address that answers 200
    private func get(_ urls: [String], _ done: @escaping (Data?) -> Void) {
        guard let u = urls.first else { done(nil); return }
        if session == nil { session = soup_session_new() }
        guard let msg = soup_message_new("GET", u) else { get(Array(urls.dropFirst()), done); return }
        soup_message_headers_append(soup_message_get_request_headers(msg), "User-Agent", "Iris/\(IrisApp.version)")
        // the message stays until its answer is read (for its status)
        let box = Unmanaged.passRetained(Box<(Data?) -> Void>({ [weak self] data in
            let status = soup_message_get_status(msg).rawValue
            g_object_unref(Ptr(msg))
            if status == 200, let data { done(data) } else { self?.get(Array(urls.dropFirst()), done) }
        })).toOpaque()
        soup_session_send_and_read_async(session, msg, G_PRIORITY_LOW, nil, { obj, res, d in
            let f = Unmanaged<Box<(Data?) -> Void>>.fromOpaque(d!)
            var err: UnsafeMutablePointer<GError>?
            var out: Data?
            if let bytes = soup_session_send_and_read_finish(cp(OpaquePointer(obj)), res, &err) {
                var n: gsize = 0
                if let p = g_bytes_get_data(bytes, &n) { out = Data(bytes: p, count: Int(n)) }
                g_bytes_unref(bytes)
            }
            if let err { g_error_free(err) }
            f.takeUnretainedValue().f(out)
            f.release()
        }, box)
    }

    // MARK: pages

    /// puts the rules on a page's content manager, or takes them off, for
    /// the site it is about to open
    func apply(_ ucm: OpaquePointer, host: String?) {
        let want = onFor(host)
        webkit_user_content_manager_remove_all_filters(ucm)
        waiting.removeAll { $0 == ucm }
        guard want else { return }
        if Shields.debug { fputs("shields: apply to \(host ?? "-"): \(filters.count) lists\n", stderr) }
        if filters.isEmpty { waiting.append(ucm) } else { for f in filters { webkit_user_content_manager_add_filter(ucm, f) } }
    }

    func forget(_ ucm: OpaquePointer) { waiting.removeAll { $0 == ucm } }
}
