# Third-party notices

Iris bundles or uses the following. Each keeps its own license.

| Component | Used for | License |
|---|---|---|
| swift-adwaita (Sergey Armodin and contributors) | Swift interface to GTK 4 and libadwaita (Linux) | MIT |
| GTK 4, libadwaita, GLib, libsoup (The GNOME Project) | Window, widgets, rendering, networking (Linux); from the GNOME runtime | LGPL 2.1 or later |
| Chromium Embedded Framework (CEF) and Chromium (The Chromium Authors) | The web engine on Linux; the CEF binary distribution, with libcef.so | BSD 3-Clause (with the licenses of the components Chromium bundles) |
| Swift standard library and Foundation (Apple and the Swift project) | Linked into Iris for Linux | Apache License 2.0 with Runtime Library Exception |
| ext-background-effect-v1 protocol code (wayland-scanner output) | Asking the compositor for blur | MIT |
| Ad and tracker domain list, Linux (`linux/src/shield-domains.txt.gz`, made by `linux/tools/shield-domains.sh`) | Iris Shields | From hagezi/dns-blocklists Pro mini (GPL-3.0), StevenBlack/hosts (MIT) and the whole-domain rules of EasyList, EasyPrivacy and uBlock Origin's filters (GPL-3.0 / CC BY-SA 3.0) |
| Ad and tracker domain list, Android (`shield-domains.json.gz` in the app's assets) | Iris Shields | Compiled from publicly available host blocklists; the original list sources are not recorded in this repository. Redistributors should verify the terms of the source lists. |
| Filter lists fetched at run time (EasyList, EasyPrivacy, EasyList Cookie, Fanboy's annoyance lists, uBlock Origin's filters) | Iris Shields | GPL-3.0 / CC BY-SA 3.0, from uBlock Origin's mirrors |
| adblock-rust (Brave Software), with serde_json, sha2 and zip (Rust crates, `core/Cargo.lock`) | Ad blocking engine and the Mozilla add-on installer, Iris (Chromium) for Linux | MPL-2.0 (adblock-rust, whose source is at github.com/brave/adblock-rust), MIT or Apache License 2.0 (the others) |
| Android System WebView (Google and the Chromium authors) | The web engine on Android; part of the phone, not bundled | BSD 3-Clause and the licenses Chromium lists |
| AndroidX WebKit and SwipeRefreshLayout (Google) | Containers (WebView profiles) and pull to reload | Apache License 2.0 |
| Jetpack Compose, Material 3, AndroidX (Google and the Android Open Source Project) | The Android interface | Apache License 2.0 |
| Kotlin and kotlinx.coroutines (JetBrains) | The Android app | Apache License 2.0 |

The browser itself, its Liquid Glass rendering and the Iris icon are Iris's own.
