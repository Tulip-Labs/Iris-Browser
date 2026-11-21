import CAdwaita
import Foundation

/// Where Iris keeps things: ~/.local/share/iris and ~/.cache/iris (inside the
/// Flatpak, the app's own ~/.var/app/io.github.tulip_labs.Iris/...).
enum Paths {
    static let data: String = {
        let d = (str(g_get_user_data_dir()) ?? NSHomeDirectory() + "/.local/share") + "/iris"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    static let cache: String = {
        let d = (str(g_get_user_cache_dir()) ?? NSHomeDirectory() + "/.cache") + "/iris"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()
    static var downloads: String {
        str(g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD)) ?? NSHomeDirectory() + "/Downloads"
    }
}

/// a JSON file of one Codable value
struct JSONFile<T: Codable> {
    let path: String
    init(_ name: String) { path = Paths.data + "/" + name }

    func load() -> T? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func save(_ v: T) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        // written beside and moved over, so a crash never leaves half a file
        let tmp = path + ".new"
        if FileManager.default.createFile(atPath: tmp, contents: d) {
            _ = rename(tmp, path)
        }
    }
}

struct Settings: Codable {
    var shields = true
    /// sites where the shield is off
    var shieldsOff: [String] = []
    /// the pages open when Iris last closed, to open again
    var session: [SavedTab] = []
    var lastUpdateCheck: Double = 0
    var skippedVersion: String?
    /// YouTube sends H.264, which every computer decodes cheaply, instead
    /// of VP9 or AV1 (much lighter on the processor, and on the battery)
    var lightVideo = true
    /// the graphics chip decodes video (VA-API); off by default, because
    /// some drivers break up the picture in blocks
    var hardwareVideo = false
    /// tabs left alone for a while give back their memory
    var sleepTabs = true

    struct SavedTab: Codable {
        var url: String
        var title: String
        var container: String?
    }

    init() {}

    // a settings file from an older Iris lacks the newer keys: they take
    // their defaults instead of the whole file being thrown away
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        shields = try c.decodeIfPresent(Bool.self, forKey: .shields) ?? true
        shieldsOff = try c.decodeIfPresent([String].self, forKey: .shieldsOff) ?? []
        session = try c.decodeIfPresent([SavedTab].self, forKey: .session) ?? []
        lastUpdateCheck = try c.decodeIfPresent(Double.self, forKey: .lastUpdateCheck) ?? 0
        skippedVersion = try c.decodeIfPresent(String.self, forKey: .skippedVersion)
        lightVideo = try c.decodeIfPresent(Bool.self, forKey: .lightVideo) ?? true
        hardwareVideo = try c.decodeIfPresent(Bool.self, forKey: .hardwareVideo) ?? false
        sleepTabs = try c.decodeIfPresent(Bool.self, forKey: .sleepTabs) ?? true
    }
}

final class SettingsStore {
    static let shared = SettingsStore()
    private let file = JSONFile<Settings>("settings.json")
    var value: Settings

    private init() { value = file.load() ?? Settings() }

    func update(_ f: (inout Settings) -> Void) {
        f(&value)
        file.save(value)
    }
}

/// where Iris's own files (the icon, the shield's list) are
enum Resources {
    static func path(_ name: String) -> String? {
        Bundle.module.path(forResource: name, ofType: nil, inDirectory: "Resources")
            ?? Bundle.module.path(forResource: name, ofType: nil)
    }
}
