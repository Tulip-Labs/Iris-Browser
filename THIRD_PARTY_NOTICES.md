# Third-party notices

Lite Go bundles or uses the following. Each keeps its own license.

| Component | Used for | License |
|---|---|---|
| Nunito (Vernon Adams, Cyreal, Jacques Le Bailly) | Interface font, embedded from `assets/fonts` | SIL Open Font License 1.1 |
| DejaVu Sans Mono (DejaVu fonts team, based on Bitstream Vera) | Monospace font, embedded from `assets/fonts` | Bitstream Vera license with DejaVu changes (public domain) |
| Gio (`gioui.org`, Elias Naur and contributors) | Window, input, GPU drawing and text shaping | MIT or The Unlicense (dual) |
| go-text/typesetting | Text shaping inside Gio | BSD 3-Clause or Unlicense (dual) |
| Go `x/image`, `x/sys`, `x/text`, `x/exp/shiny`, `x/net` (The Go Authors) | Fonts, rasterizing (tests), Windows calls, registry | BSD 3-Clause |
| SQLite (D. Richard Hipp and contributors) | Browsing history (address suggestions and Most visited) | Public domain |
| go-sqlite3 (Nuno Cruces) | Runs SQLite in pure Go | MIT |
| wazero (Tetrate) | WebAssembly runtime under go-sqlite3 | Apache License 2.0 |
| Ad and tracker domain list (`core/shield-domains.json.gz`, the same list as Lite Desktop) | The shield | Compiled from publicly available host blocklists; the original list sources are not recorded in this repository. Redistributors should verify the terms of the source lists. |
| Filter lists: EasyList, EasyPrivacy and EasyList Cookie (The EasyList authors); uBlock filters (Raymond Hill and contributors) | Lite Shields. Not bundled: Lite Go downloads them from their authors and keeps them in its data folder | EasyList: GPL v3 or CC BY-SA 3.0 (dual); uBlock filters: GPL v3 |
| Public Suffix List (Mozilla), through `golang.org/x/net/publicsuffix` | Telling first-party from third-party requests | MPL 2.0 (list), BSD 3-Clause (Go code) |
| WebKit (Apple and contributors) and WebKitGTK | The web engine on macOS and Linux; part of the system, not bundled | BSD 2-Clause and LGPL 2.1 |
| webview2-rs bindings (Bill Avery and contributors) | Reference for the WebView2 interface layout from which `webview/slots_windows.go` was generated | MIT |
| winres (Thomas Hibon) | Only `tools/icongen.go` uses it, to write the committed icon resources; not part of the built programs | 0BSD |

Microsoft Edge WebView2 Runtime is not bundled. It ships with Windows 10 and 11; when it is
missing, the setup downloads Microsoft's own bootstrapper from Microsoft and runs it, under
Microsoft's license terms for the runtime.

No other third-party code is included. The interface toolkit, the WebView2 bindings, the
browser core and the installer are Lite Go's own.

## Lite for Android

- **AndroidX WebKit** (`androidx.webkit:webkit`), Apache License 2.0, The Android Open Source Project.
- **Material Design icons** (the outlined system icons drawn in `android/app/src/main/res/drawable`), Apache License 2.0, Google.
- Android System WebView is part of Android and is not shipped with the app.
