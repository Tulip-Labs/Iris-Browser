import CAdwaita
import CSoup
import Foundation

/// New versions: Iris asks GitHub once a day and tells you when there is
/// one. It never installs anything itself; the Flatpak updates the way every
/// Flatpak does (your software centre, or flatpak update).
enum Updates {
    static let api = "https://api.github.com/repos/Tulip-Labs/Iris-Browser/releases/latest"
    private static var session: UnsafeMutablePointer<SoupSession>?

    /// 1 when a is newer than b ("2.0.1" > "2.0.0")
    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check(_ b: Browser, quiet: Bool) {
        let now = Date().timeIntervalSince1970
        if quiet && now - SettingsStore.shared.value.lastUpdateCheck < 86400 { return }
        if session == nil { session = soup_session_new() }
        guard let msg = soup_message_new("GET", api) else { return }
        let headers = soup_message_get_request_headers(msg)
        soup_message_headers_append(headers, "Accept", "application/vnd.github+json")
        soup_message_headers_append(headers, "User-Agent", "Iris/\(IrisApp.version)")
        let box = Unmanaged.passRetained(Box<(Data?) -> Void>({ [weak b] data in
            SettingsStore.shared.update { $0.lastUpdateCheck = now }
            guard let b else { return }
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String else {
                if !quiet { b.toast("Could not reach GitHub to check for updates") }
                return
            }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = j["html_url"] as? String ?? "https://github.com/Tulip-Labs/Iris-Browser/releases"
            if newer(v, than: IrisApp.version) {
                b.toast("Iris \(v) is out. Your software centre or flatpak update installs it.", action: ("What's new", { [weak b] in b?.newTab(page) }))
            } else if !quiet {
                b.toast("Iris \(IrisApp.version) is the newest version")
            }
        })).toOpaque()
        soup_session_send_and_read_async(session, msg, G_PRIORITY_DEFAULT, nil, { obj, res, d in
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
        g_object_unref(Ptr(msg))
    }
}
