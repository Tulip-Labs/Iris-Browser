import CAdwaita
import Foundation

/// Iris's look, as in Ember: Light, Dark, or Auto (the system's choice,
/// light when it has none). Ember sets the system's choice by the time of
/// day, so on niri with Ember, Auto turns dark at night with the desktop.
enum Appearance: String, Codable, CaseIterable {
    case auto, light, dark

    var title: String { ["auto": "Auto", "light": "Light", "dark": "Dark"][rawValue]! }
}

enum Look {
    /// dark now (Dark, or Auto with the system dark)
    nonisolated(unsafe) static var dark = false
    /// called when the look changes, to redraw every window
    nonisolated(unsafe) static var changed: [() -> Void] = []

    static var ink: RGBA { dark ? RGBA(0.96, 0.96, 0.97) : RGBA(0.11, 0.11, 0.13) }

    /// a glass tint by how much of the material shows (0.2 for bars, 0.7
    /// for panels): white over light, smoky over dark
    static func tint(_ level: Double, panel: Bool = false) -> RGBA {
        if !dark { return panel ? RGBA(0.98, 0.98, 1, level) : RGBA.white.alpha(level) }
        return panel ? RGBA(0.12, 0.11, 0.17, min(0.9, level + 0.12)) : RGBA(1, 1, 1, level * 0.32)
    }

    /// the rims of light are quieter in the dark
    static var rim: Double { dark ? 0.6 : 1 }

    /// applies the setting: libadwaita (and so WebKit's
    /// prefers-color-scheme) follows it, and so does Iris's own drawing
    static func apply() {
        let sm = adw_style_manager_get_default()
        let a = SettingsStore.shared.value.appearance
        adw_style_manager_set_color_scheme(sm, a == .dark ? .forceDark : a == .light ? .forceLight : .preferLight)
        refresh()
    }

    static func refresh() {
        let d = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        guard d != dark || !started else { return }
        dark = d
        started = true
        UI.reloadCSS()
        changed.forEach { $0() }
    }

    nonisolated(unsafe) private static var started = false

    /// follows the system while Auto
    static func watch() {
        on1(Ptr(adw_style_manager_get_default()), "notify::dark") { _ in Look.refresh() }
        apply()
    }
}
