import CAdwaita
import CWebKit
import Foundation

/// A container is a world of its own: its own cookies, storage, cache,
/// sign-ins and site data, in a WebKit network session of its own on disk.
/// A site in Work never sees what it knows of you in Personal. Private tabs
/// share one session that lives in memory only and is gone when the last
/// private tab closes.
struct Container: Codable, Equatable {
    var id: String
    var name: String
    var color: String

    static let palette = ["#0a84ff", "#ff9f0a", "#30d158", "#ff375f", "#bf5af2", "#64d2ff", "#ffd60a", "#ac8e68"]
    static let privateID = "private"
}

final class Containers {
    static let shared = Containers()
    private let file = JSONFile<[Container]>("containers.json")
    private(set) var list: [Container]
    private var sessions: [String: OpaquePointer] = [:]
    /// runs for each new session (downloads listen to it)
    var sessionMade: ((OpaquePointer) -> Void)?

    private init() {
        list = file.load() ?? [
            Container(id: UUID().uuidString.lowercased(), name: "Personal", color: Container.palette[0]),
            Container(id: UUID().uuidString.lowercased(), name: "Work", color: Container.palette[1]),
            Container(id: UUID().uuidString.lowercased(), name: "Shopping", color: Container.palette[3]),
            Container(id: UUID().uuidString.lowercased(), name: "Banking", color: Container.palette[2]),
        ]
        file.save(list)
    }

    func get(_ id: String?) -> Container? {
        guard let id else { return nil }
        if id == Container.privateID { return Container(id: id, name: "Private", color: "#5e5ce6") }
        return list.first { $0.id == id }
    }

    private func dirs(_ id: String?) -> (String, String) {
        let key = id.map { "containers/" + $0 } ?? "default"
        return (Paths.data + "/web/" + key, Paths.cache + "/web/" + key)
    }

    /// the session of a container (nil: the default world)
    func session(_ id: String?) -> OpaquePointer {
        let key = id ?? ""
        if let s = sessions[key] { return s }
        let s: OpaquePointer
        if id == Container.privateID {
            s = webkit_network_session_new_ephemeral()
        } else {
            let (data, cache) = dirs(id)
            try? FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
            s = webkit_network_session_new(data, cache)
            let cookies = webkit_network_session_get_cookie_manager(s)
            webkit_cookie_manager_set_persistent_storage(cookies, data + "/cookies.sqlite", WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE)
        }
        let cookies = webkit_network_session_get_cookie_manager(s)
        // no cookies for sites other than the one you are on
        webkit_cookie_manager_set_accept_policy(cookies, WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY)
        webkit_network_session_set_itp_enabled(s, 1)
        webkit_website_data_manager_set_favicons_enabled(webkit_network_session_get_website_data_manager(s), 1)
        sessions[key] = s
        sessionMade?(s)
        return s
    }

    /// the private session ends with the last private tab
    func endPrivate() {
        if let s = sessions.removeValue(forKey: Container.privateID) { g_object_unref(Ptr(s)) }
    }

    @discardableResult
    func add(_ name: String) -> Container {
        let used = Set(list.map(\.color))
        let color = Container.palette.first { !used.contains($0) } ?? Container.palette[list.count % Container.palette.count]
        let c = Container(id: UUID().uuidString.lowercased(), name: name, color: color)
        list.append(c)
        file.save(list)
        return c
    }

    func rename(_ id: String, _ name: String) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].name = name
        file.save(list)
    }

    /// removes a container and everything its sites kept
    func remove(_ id: String) {
        list.removeAll { $0.id == id }
        file.save(list)
        let (data, cache) = dirs(id)
        if let s = sessions.removeValue(forKey: id) {
            let dm = webkit_network_session_get_website_data_manager(s)
            webkit_website_data_manager_clear(dm, WEBKIT_WEBSITE_DATA_ALL, 0, nil, nil, nil)
            g_object_unref(Ptr(s))
        }
        try? FileManager.default.removeItem(atPath: data)
        try? FileManager.default.removeItem(atPath: cache)
    }
}
