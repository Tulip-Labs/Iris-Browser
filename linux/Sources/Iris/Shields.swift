import CAdwaita
import CWebKit
import Foundation

/// Iris Shields: ads, trackers and their pop-ups blocked inside WebKit
/// itself. The block list (about 100,000 ad and tracker domains, the same
/// list Iris has always shipped) becomes WebKit content rules, compiled once
/// and kept, so pages never wait on Iris to ask about a request.
enum ShieldRules {
    /// messaging, sign-in and human checks: never blocked
    static let never = ["whatsapp.com", "whatsapp.net", "accounts.google.com", "login.microsoftonline.com",
                        "login.live.com", "teams.microsoft.com", "meet.google.com", "challenges.cloudflare.com",
                        "hcaptcha.com", "recaptcha.net", "appleid.apple.com"]

    /// delivery networks that carry countless ordinary sites: a list entry
    /// naming one of them whole would break those sites, so it is dropped
    static let shared: Set<String> = ["cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "akamaihd.net",
        "akamaized.net", "akamai.net", "edgekey.net", "edgesuite.net", "fastly.net", "fastlylb.net", "azureedge.net",
        "azurefd.net", "azurewebsites.net", "windows.net", "blob.core.windows.net", "msecnd.net",
        "googleusercontent.com", "googleapis.com", "storage.googleapis.com", "gstatic.com", "cloudflare.com",
        "cloudflare.net", "jsdelivr.net", "unpkg.com", "github.io", "githubusercontent.com", "netlify.app",
        "vercel.app", "herokuapp.com", "firebaseapp.com", "web.app", "appspot.com", "b-cdn.net", "cdn77.org",
        "kxcdn.com", "digitaloceanspaces.com", "r2.dev", "pages.dev", "workers.dev", "wp.com", "cloudinary.com",
        "imgix.net", "ctfassets.net", "backblazeb2.com", "rackcdn.com", "llnwd.net", "hwcdn.net",
        "edgecastcdn.net", "wixstatic.com", "squarespace-cdn.com", "shopifycdn.com", "myshopify.com"]

    static let kinds = ["script", "image", "raw", "media", "popup"]

    static func hostPattern(_ d: String) -> String {
        "^[^:]+://+([^:/]+\\.)?" + NSRegularExpression.escapedPattern(for: d) + "[:/]"
    }

    static func usable(_ d: String) -> Bool {
        if d.isEmpty || shared.contains(d) || !d.contains(".") { return false }
        if never.contains(where: { d == $0 || d.hasSuffix("." + $0) || $0.hasSuffix("." + d) }) { return false }
        return d.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// the content rules for a list of domains, as WebKit's JSON
    static func json(domains: [String], max: Int = 150_000) -> String {
        var rules: [[String: Any]] = []
        for d in domains where usable(d) {
            rules.append(["trigger": ["url-filter": hostPattern(d), "resource-type": kinds], "action": ["type": "block"]])
            if rules.count >= max { break }
        }
        // YouTube's ad breaks, without touching what plays the video
        for p in ["^https?://(www\\.)?youtube\\.com/youtubei/v1/player/ad_break", "^https?://(www\\.)?youtube\\.com/pagead/",
                  "^https?://(www\\.)?youtube\\.com/api/stats/ads"] {
            rules.append(["trigger": ["url-filter": p, "resource-type": ["raw", "script", "image"]], "action": ["type": "block"]])
        }
        for d in never {
            rules.append(["trigger": ["url-filter": hostPattern(d)], "action": ["type": "ignore-previous-rules"]])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    /// the shipped list
    static func domains() -> [String] {
        guard let p = Resources.path("shield-domains.json.gz"), let d = gunzip(p),
              let list = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
        return list
    }

    /// the hosts of the list, for the pop-up check (read in the background
    /// at start; until then nothing counts as blocked)
    nonisolated(unsafe) static var blockedHosts: Set<String> = []

    static func loadHosts() {
        DispatchQueue.global(qos: .utility).async {
            let s = Set(domains().filter(usable))
            idle { blockedHosts = s }
        }
    }

    static func blocked(_ host: String) -> Bool {
        var h = Substring(host)
        while true {
            if blockedHosts.contains(String(h)) { return true }
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
    private(set) var filter: OpaquePointer?
    private var waiting: [OpaquePointer] = []
    private var managers: [(UnsafeMutableRawPointer, () -> String?)] = []
    private let store: OpaquePointer
    private let identifier: String

    private init() {
        let dir = Paths.cache + "/shields"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        store = webkit_user_content_filter_store_new(dir)
        identifier = "iris-shields-3"
    }

    var on: Bool { SettingsStore.shared.value.shields }

    func onFor(_ host: String?) -> Bool {
        guard on else { return false }
        guard let host else { return true }
        let site = Search.site(host)
        return !SettingsStore.shared.value.shieldsOff.contains(site)
    }

    func toggle(site: String) {
        SettingsStore.shared.update { s in
            if let i = s.shieldsOff.firstIndex(of: site) { s.shieldsOff.remove(at: i) } else { s.shieldsOff.append(site) }
        }
    }

    /// loads the compiled rules, or compiles them the first time (WebKit
    /// does that on threads of its own; pages open meanwhile)
    func start() {
        ShieldRules.loadHosts()
        let me = Unmanaged.passUnretained(self).toOpaque()
        webkit_user_content_filter_store_load(store, identifier, nil, { obj, res, d in
            let me = Unmanaged<Shields>.fromOpaque(d!).takeUnretainedValue()
            var err: UnsafeMutablePointer<GError>?
            if let f = webkit_user_content_filter_store_load_finish(OpaquePointer(obj), res, &err) {
                me.ready(f)
            } else {
                if let err { g_error_free(err) }
                me.compile()
            }
        }, me)
    }

    private func compile() {
        // the list is read and turned into rules away from the interface
        DispatchQueue.global(qos: .utility).async {
            let json = ShieldRules.json(domains: ShieldRules.domains())
            idle { self.save(json) }
        }
    }

    private func save(_ json: String) {
        let bytes = json.withCString { g_bytes_new($0, gsize(strlen($0))) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        webkit_user_content_filter_store_save(store, identifier, bytes, nil, { obj, res, d in
            let me = Unmanaged<Shields>.fromOpaque(d!).takeUnretainedValue()
            var err: UnsafeMutablePointer<GError>?
            if let f = webkit_user_content_filter_store_save_finish(OpaquePointer(obj), res, &err) {
                me.ready(f)
            } else if let err {
                FileHandle.standardError.write("Iris: the shield's rules did not compile: \(String(cString: err.pointee.message))\n".data(using: .utf8)!)
                g_error_free(err)
            }
        }, me)
        g_bytes_unref(bytes)
    }

    private func ready(_ f: OpaquePointer) {
        filter = f
        for ucm in waiting { webkit_user_content_manager_add_filter(ucm, f) }
        waiting.removeAll()
    }

    /// puts the shield on a page's content manager, or takes it off, for
    /// the site it is about to open
    func apply(_ ucm: OpaquePointer, host: String?) {
        let want = onFor(host)
        if let f = filter {
            webkit_user_content_manager_remove_filter(ucm, f)
            if want { webkit_user_content_manager_add_filter(ucm, f) }
        } else if want {
            if !waiting.contains(ucm) { waiting.append(ucm) }
        } else {
            waiting.removeAll { $0 == ucm }
        }
    }

    func forget(_ ucm: OpaquePointer) { waiting.removeAll { $0 == ucm } }
}
