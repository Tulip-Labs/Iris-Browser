import Adwaita
import CAdwaita
import Foundation

final class IrisApp {
    static let version = "2.0.0"
    static let id = "io.github.tulip_labs.Iris"

    let app: Application
    private(set) var browsers: [Browser] = []
    private var started = false

    init() {
        app = MainActor.assumeIsolated { Application(id: IrisApp.id, flags: .handlesOpen) }
        let app = self.app
        MainActor.assumeIsolated {
            _ = app.onStartup { [unowned self] in self.startup() }
            _ = app.onActivate { [unowned self] in self.activate([]) }
            _ = app.onOpen { [unowned self] urls, _ in self.activate(urls.map(\.absoluteString)) }
        }
    }

    var gtk: UnsafeMutablePointer<GtkApplication> { let a = app; return MainActor.assumeIsolated { a.gtkApplicationPointer } }

    func run() -> Int { let a = app; return MainActor.assumeIsolated { a.run() } }

    private func startup() {
        g_set_prgname("iris")
        g_set_application_name("Iris")
        // light, like glass in daylight
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), .forceLight)
        let css = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(css, UI.css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(css), 600)
        if let icons = Resources.path("icons") {
            gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(gdk_display_get_default()), icons)
        }
        Containers.shared.sessionMade = { s in Downloads.shared.listen(s) }
        Shields.shared.start()
    }

    private func activate(_ urls: [String]) {
        if let b = browsers.last, started {
            for u in urls { b.newTab(u) }
            b.present()
            return
        }
        started = true
        let b = newWindow(empty: true)
        let saved = SettingsStore.shared.value.session
        if !saved.isEmpty { b.restore(saved) }
        for u in urls { b.newTab(u) }
        if b.tabs.isEmpty { b.newTab() }
        Updates.check(b, quiet: true)
    }

    @discardableResult
    func newWindow(empty: Bool = false) -> Browser {
        let b = Browser(app: self)
        browsers.append(b)
        if !empty { b.newTab() }
        b.present()
        return b
    }

    func closed(_ b: Browser) {
        browsers.removeAll { $0 === b }
    }

    func isLast(_ b: Browser) -> Bool { browsers.count <= 1 }

    func anyPrivate(except b: Browser) -> Bool {
        browsers.contains { $0 !== b && $0.tabs.contains { $0.isPrivate } }
    }

    func quit() {
        // every window's tabs open again next time
        let saved = browsers.flatMap { b in
            b.tabs.filter { !$0.isPrivate && !($0.pending ?? $0.url).isEmpty }
                .map { Settings.SavedTab(url: $0.pending ?? $0.url, title: $0.title, container: $0.container) }
        }
        SettingsStore.shared.update { $0.session = saved }
        History.shared.flush()
        let a = app
        MainActor.assumeIsolated { a.quit() }
    }

    func removeContainer(_ id: String) {
        for b in browsers { b.closeTabs(in: id) }
        Containers.shared.remove(id)
    }

    func shieldsChanged() {
        for b in browsers {
            for t in b.tabs {
                if let ucm = t.ucm { Shields.shared.apply(ucm, host: Search.host(t.url)) }
            }
            b.current?.reload()
            if let t = b.current { b.tabChanged(t) }
        }
    }
}
