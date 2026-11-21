// swift-tools-version: 6.1
//
// Iris for Linux: Swift, swift-adwaita (libadwaita and GTK 4) and WebKitGTK 6.
//
// swift-adwaita comes from deps/swift-adwaita when that folder exists (the
// Flatpak build has no network, so the manifest puts the pinned checkout
// there), or from IRIS_ADWAITA (a local copy), or else from GitHub at the
// pinned release.
import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let localAdwaita: String? = {
    if let p = ProcessInfo.processInfo.environment["IRIS_ADWAITA"], !p.isEmpty { return p }
    let vendored = here + "/deps/swift-adwaita"
    return FileManager.default.fileExists(atPath: vendored + "/Package.swift") ? vendored : nil
}()

let adwaita: Package.Dependency = localAdwaita.map { .package(path: $0) }
    ?? .package(url: "https://github.com/makoni/swift-adwaita.git", exact: "2.0.2")

let package = Package(
    name: "Iris",
    dependencies: [adwaita],
    targets: [
        .systemLibrary(name: "CSoup", pkgConfig: "libsoup-3.0"),
        .systemLibrary(name: "CWaylandGtk", path: "Sources/CWaylandGtk", pkgConfig: "gtk4-wayland"),
        // the compositor's background blur (ext-background-effect-v1); the
        // protocol code is wayland-scanner's output
        .target(name: "CBlur", dependencies: ["CWaylandGtk"]),
        .executableTarget(
            name: "Iris",
            dependencies: [
                .product(name: "Adwaita", package: "swift-adwaita"),
                .product(name: "AdwaitaWebKit", package: "swift-adwaita"),
                "CSoup", "CBlur",
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "IrisTests", dependencies: ["Iris"]),
    ],
    swiftLanguageModes: [.v5]
)
