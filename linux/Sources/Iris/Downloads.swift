import CAdwaita
import CWebKit
import Foundation

/// Downloads go to your Downloads folder under the name the site gives
/// (with " (2)" and on when that name is taken).
final class Download {
    let dl: OpaquePointer
    var name = ""
    var path = ""
    var progress = 0.0
    var received: UInt64 = 0
    var done = false
    var failed = false
    var cancelled = false
    let started = Date()

    init(_ dl: OpaquePointer) {
        self.dl = dl
        g_object_ref(Ptr(dl))
    }

    deinit { g_object_unref(Ptr(dl)) }

    var status: String {
        if failed { return cancelled ? "Cancelled" : "Failed" }
        if done { return size(received) }
        let total = progress > 0.001 ? Double(received) / progress : 0
        return total > 0 ? "\(size(received)) of \(size(UInt64(total)))" : size(received)
    }

    private func size(_ b: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(b))
    }

    func cancel() { cancelled = true; webkit_download_cancel(dl) }
}

final class Downloads {
    static let shared = Downloads()
    private(set) var list: [Download] = []
    /// runs whenever a download starts, moves or ends
    var changed: [(Download?) -> Void] = []

    func listen(_ session: OpaquePointer) {
        on1(Ptr(session), "download-started") { [weak self] d in
            guard let self, let d else { return }
            self.started(OpaquePointer(d))
        }
    }

    private func notify(_ d: Download?) { changed.forEach { $0(d) } }

    func unique(_ name: String) -> String {
        let dir = Paths.downloads
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var clean = name.replacingOccurrences(of: "/", with: "_")
        if clean.isEmpty || clean == "." || clean == ".." { clean = "download" }
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        var p = dir + "/" + clean
        var n = 2
        let taken = { (p: String) in FileManager.default.fileExists(atPath: p) || self.list.contains { $0.path == p && !$0.failed } }
        while taken(p) {
            p = dir + "/" + stem + " (\(n))" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        return p
    }

    private func started(_ dl: OpaquePointer) {
        let d = Download(dl)
        list.insert(d, at: 0)
        onBool1(Ptr(dl), "decide-destination") { [weak self, weak d] name in
            guard let self, let d else { return false }
            let suggested = str(name?.assumingMemoryBound(to: CChar.self)) ?? "download"
            d.path = self.unique(suggested)
            d.name = (d.path as NSString).lastPathComponent
            webkit_download_set_destination(dl, d.path)
            self.notify(d)
            return true
        }
        on1(Ptr(dl), "created-destination") { [weak self, weak d] dest in
            guard let self, let d, let dest else { return }
            d.path = String(cString: dest.assumingMemoryBound(to: CChar.self))
            d.name = (d.path as NSString).lastPathComponent
            self.notify(d)
        }
        on1(Ptr(dl), "notify::estimated-progress") { [weak self, weak d] _ in
            guard let self, let d else { return }
            d.progress = webkit_download_get_estimated_progress(dl)
            d.received = UInt64(webkit_download_get_received_data_length(dl))
            self.notify(d)
        }
        on1(Ptr(dl), "failed") { [weak self, weak d] _ in
            guard let self, let d else { return }
            d.failed = true
            self.notify(d)
        }
        on(Ptr(dl), "finished") { [weak self, weak d] in
            guard let self, let d else { return }
            if !d.failed { d.done = true; d.progress = 1 }
            d.received = UInt64(webkit_download_get_received_data_length(dl))
            self.notify(d)
        }
        notify(d)
    }

    var active: Int { list.filter { !$0.done && !$0.failed }.count }

    func clearFinished() {
        list.removeAll { $0.done || $0.failed }
        notify(nil)
    }

    /// opens the file with the program meant for it
    func open(_ d: Download, _ window: GtkW?) {
        let f = g_file_new_for_path(d.path)
        let l = gtk_file_launcher_new(f)
        gtk_file_launcher_launch(l, window.map { UnsafeMutablePointer<GtkWindow>(OpaquePointer($0)) }, nil, nil, nil)
        g_object_unref(Ptr(l))
        g_object_unref(Ptr(f))
    }

    func showInFolder(_ d: Download, _ window: GtkW?) {
        let f = g_file_new_for_path(d.path)
        let l = gtk_file_launcher_new(f)
        gtk_file_launcher_open_containing_folder(l, window.map { UnsafeMutablePointer<GtkWindow>(OpaquePointer($0)) }, nil, nil, nil)
        g_object_unref(Ptr(l))
        g_object_unref(Ptr(f))
    }
}
