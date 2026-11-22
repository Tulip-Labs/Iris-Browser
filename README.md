<p align="center">
  <img src="assets/icon/iris-256.png" width="128" alt="Iris">
</p>

<h1 align="center">Iris</h1>

<p align="center"><i>Iris is the Greek goddess of the rainbow, who carries light between worlds.</i></p>

<p align="center">
  <b>A browser made of glass.</b><br>
  Linux: Zig, libadwaita and WPE WebKit, in real Liquid Glass.<br>
  Android: Kotlin, Jetpack Compose and Android System WebView. Every search asks Google AI Mode.
</p>

<p align="center">
  <img alt="Zig" src="https://img.shields.io/badge/Zig-0.15-F7A41D?style=flat-square&logo=zig&logoColor=white">
  <img alt="WPE WebKit" src="https://img.shields.io/badge/WPE_WebKit-2.54-2B8DD6?style=flat-square">
  <img alt="libadwaita" src="https://img.shields.io/badge/GNOME-libadwaita-4A86CF?style=flat-square&logo=gnome&logoColor=white">
  <img alt="Kotlin" src="https://img.shields.io/badge/Kotlin-Compose-7F52FF?style=flat-square&logo=kotlin&logoColor=white">
  <img alt="Android 10 and newer" src="https://img.shields.io/badge/Android-10%2B-3DDC84?style=flat-square&logo=android&logoColor=white">
  <img alt="License: GPL 3.0" src="https://img.shields.io/badge/license-GPL%203.0-6B7280?style=flat-square">
</p>

<p align="center">
  <a href="#what-is-new-in-220">New</a> ·
  <a href="#what-it-does">Features</a> ·
  <a href="#install">Install</a> ·
  <a href="#shortcuts">Shortcuts</a> ·
  <a href="#build">Build</a> ·
  <a href="#how-it-is-made">How it is made</a>
</p>

<p align="center">
  <img src="assets/icon/iris-256.png" width="160" alt="Iris's icon: a clear glass ring on a white tile, light entering and leaving as a rainbow">
</p>

---

## What is new in 2.2.0

- **Iris for Linux is now Zig and WPE WebKit.** No Swift, no binding layers: Zig calls GTK, libadwaita and WPE through their C headers.
  - Each page frame arrives from WPE as a DMA-BUF and goes into GTK as a texture without a copy, so the Liquid Glass bends the live page.
  - Iris draws a page's own pop-ups in glass too: `<select>` lists, `alert()`, `confirm()` and `prompt()`.
  - The ad and tracker domains are compiled into Iris as Zig arrays, and the lists become WPE content rules inside the engine.
  - Every tab stays awake: no sleeping tabs.
- **Every new tab is Google AI Mode**, in Iris's Liquid Glass; the start page is gone, and your tabs still open where you left them.
- **Faster**: the next new tab is loaded ahead, Google's names are looked up early, and results open without Google's redirect.
- **An automatic sandbox** for sites Iris does not trust (http, a bare IP, a failing certificate): processes and a throwaway world of their own, and none of your data.
- **Light only**, in the colours of dawn, and **a new icon**: a clear glass ring, light entering and leaving as a rainbow.
- **No menu**: Ctrl+F finds, Ctrl+plus and minus zoom; the downloads button shows only while it has something to show.
- **Android on System WebView again**, with ads that open new tabs stopped.

## What was new in 2.1.0

- **Light, Dark or Auto**, as in [Ember](https://github.com/Tulip-Labs/Ember). Auto follows the system; with Ember on niri it turns dark at night. Pages follow the look.
- **The new-tab page is Iris herself**, Ember's wallpaper: the goddess of the rainbow in liquid glass, light by day and dark by night.
- **Shields with three levels**, as in Brave, stopping ads and trackers inside the engine before a request leaves the device, with uBlock Origin's lists:

  | Level | What it stops |
  |---|---|
  | Moderate | Ads and trackers from other sites (EasyList, EasyPrivacy). A site's own requests always load. |
  | Aggressive (default) | Also a site's own ads and trackers, uBlock Origin's filters, and the empty boxes ads leave. |
  | Ultra aggressive | Also cookie notices, newsletter and sign-up pop-ups and other annoyances. |

  uBlock Origin's fixes for sites the lists would break stay on at every level, and Shields can be turned off for one site.
- **Android: Chromium inside Iris again** (Cefrium), the same engine on every phone, and **Liquid Glass with no Material Design**: Iris's own bars, panels, switches and line icons.
- **A new icon.**

## What was new in 2.0.1

- **Lighter on Linux.**
  - All tabs share one WebKit web context: one pool of web processes and caches. Containers keep their own cookies and storage.
  - Each web process has a memory limit and gives memory back early.
  - Sleeping tabs: a background tab sleeps after 10 minutes, and no more than 3 stay awake (never one playing sound).
- **Less work for the GPU.** The glass chrome is kept as one picture while nothing in it changes, so a playing video redraws only itself.
- **Light video.** YouTube sends H.264 instead of VP9 or AV1, a fraction of the processor time. It's a switch in the menu.
- **Clean video.** Decoding on the graphics chip is off by default, because some drivers broke the picture into blocks. A menu switch turns it on.
- **History** (Ctrl+H), **container icons**, and **calls** (WebRTC with camera, microphone and screen sharing).
- **Android on System WebView.** Kotlin and Compose on the phone's own Chromium:
  - containers through WebView profiles;
  - Shields that stop ad and tracker domains;
  - pop-up rules, a downloads manager, pull to reload, and auto-update.

## What was new in 2.0.0

Iris is made again from the start.

- **Linux in Swift.** swift-adwaita (GTK 4 and libadwaita), WebKitGTK for the pages, installed as a Flatpak.
- **Real Liquid Glass.** Not frosted glass: what lies behind stays sharp, and the glass bends it.
  - At the rim, the picture is pulled in from beyond the edge, with a touch of colour splitting.
  - A rim of light runs round each piece, and the pointer lights the glass where it is.
- **A translucent window.** Where the compositor offers background blur (niri 26.04 and newer, through `ext-background-effect-v1`), the desktop shows through it, blurred.
- **Springs.** Tabs slide into place. The selected tab's glass slides from tab to tab and stretches on the way. Menus open and close as glass.
- **Containers, worlds apart.** On both platforms, each container keeps its own cookies, storage, cache and sign-ins.
- **Ads open no tabs.** A pop-up needs your click, and goes only to the same site or a sign-in page. Anything else is stopped, with an Open button if you meant it.
- **Android in Kotlin with Jetpack Compose** (its engine is Android System WebView).
- **A new icon.** The goddess in liquid glass, rising out of her rainbow.
- **Fewer packages.** Windows, Nix, the Snap and the container image are gone. Linux ships as a Flatpak.

## What it does

### Linux

- **Liquid Glass chrome.** The tabs, the address bar and the button groups float as glass.
  - The page's own colour reaches up under the toolbar (as Safari's does), so the glass has something to bend.
  - Menus, suggestions, find, downloads and notices are glass over the page itself.
- **Google AI Mode in every new tab**, in Iris's glass: the dawn behind it, its panels clear, the question box of glass. The next new tab is loaded ahead, so it opens at once.
- **Search.** Type an address, or anything else to ask Google AI Mode. Iris asks it to answer from high-quality, current sources. `yt cats` searches YouTube.
- **Containers.**
  - Personal, Work, Shopping and Banking to start with, and any you add.
  - Each is a WPE network session of its own on disk.
  - Open a new tab in a container, or open the current page in another one.
  - Removing a container deletes everything its sites kept.
- **Private tabs.** One in-memory world, gone when the last private tab closes.
- **The sandbox.** Sites Iris does not trust (http, a bare IP, a failing certificate) open in it without asking: a WPE web context of its own (its own web processes, in WebKit's process sandbox), a network session per tab in memory only, and no downloads, camera, microphone, location, clipboard, WebGL, WebRTC or pop-ups. Its tabs have an orange rim.
- **Iris Shields.** About 100,000 ad and tracker domains, compiled into Iris as Zig arrays, become WPE content rules. They are compiled once and blocked inside the engine before a request leaves. You can turn Shields off for one site or everywhere.
- **Cookies stay home.** Third-party cookies are refused, and WebKit's tracking prevention is on.
- **Pop-ups.**
  - Links that open a new window open as a tab next to yours.
  - Script pop-ups need your click, and go only to the same site or a sign-in page.
- **Right click.** Iris's own glass menu:
  - links: open in a new tab or in a container, copy, download;
  - images and video: open, copy the address, save;
  - selected text: copy, or ask Google AI Mode about it;
  - text fields: cut, copy, paste, select all;
  - the page: back, forward, reload, select all.
- **Downloads.** Saved to your Downloads folder, shown in a glass panel with progress. The button appears while a file comes in and then shows how many finished, until you open it.
- **The rest.**
  - No menu: find in page with Ctrl+F, zoom with Ctrl+plus, minus and 0.
  - Full screen for videos and with F11.
  - Your tabs come back next time.
  - A daily check for a newer Iris.
- **A page's own pop-ups in glass.** `<select>` lists open as glass menus where the page put them; `alert()`, `confirm()` and `prompt()` are Adwaita dialogs; file fields use the desktop's file chooser.
- **Sharp at every scale.** WPE renders each page at the window's scale and GTK draws everything, at 1.25, 1.5 or 2.

### Android

- **Engine.** Android System WebView (Chromium, kept up to date by the phone). The interface is Jetpack Compose drawn as Liquid Glass (no Material components). The tabs and their pages live in a ViewModel.
- **Look.** Light, in the colours of dawn. Every new tab is Google AI Mode in Iris's glass.
- **The sandbox.** Sites Iris does not trust open in a process of their own with WebView data made fresh each time, and none of your data.
- **Containers.** WebView profiles (System WebView 123 and newer): each container keeps its own cookies, cache, localStorage and IndexedDB.
- **Shields.** WebView asks Iris before every request; ads and trackers never leave the phone. Ads that open new tabs are stopped too: a page opens no tab by itself, a tapped ad link opens nothing, and a script's window stays hidden until Iris knows it is not an ad. Moderate, Aggressive or Ultra aggressive, with uBlock Origin's lists, and the boxes ads leave are hidden.
- **Tabs.**
  - A strip of tabs on top with one "+" (long-press it to pick a container).
  - The bottom bar has back, forward, home, Shields, containers, and downloads while there are any (with the number finished).
- **Downloads manager.** Files go to the phone's Downloads folder (no storage permission needed), with progress, open and delete.
- **Calls** in the browser (camera and microphone, asked once), file fields and full-screen video.
- **Auto-update.** Iris checks GitHub once a day, downloads the new APK and has Android install it over itself.
- **Closing tabs.** Closing the tab you are on opens the one beside it; closing the last tab leaves a fresh one.

## Install

**Linux (Flatpak):**

    flatpak install --user Iris-x86_64.flatpak

Download it from the [releases](https://github.com/Tulip-Labs/Iris-Browser/releases). It needs the GNOME 50 runtime, which Flatpak installs from Flathub.

On niri, the blur behind the window comes on by itself on 26.04 and newer. No window rule is needed.

**Android:** `Iris-android.apk` from the releases. It needs Android 10 or newer. After this install, Iris updates itself.

## Shortcuts

| Keys | Does |
|---|---|
| Ctrl+T / Ctrl+Shift+T | New tab / open the last closed tab again |
| Ctrl+Shift+N | New private tab |
| Ctrl+N | New window |
| Ctrl+W | Close tab |
| Ctrl+L, Ctrl+K, F6 | Address bar |
| Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+1…9 | Change tab |
| Ctrl+R, F5 / Ctrl+Shift+R | Reload / reload without the cache |
| Alt+← / Alt+→ | Back / forward |
| Alt+Home | Google AI Mode |
| Ctrl+F | Find in page |
| Ctrl+Plus / Ctrl+Minus / Ctrl+0 | Zoom |
| Ctrl+Shift+Y, Ctrl+J | Downloads |
| F11 | Full screen |
| Ctrl+Q | Quit |

## Build

**Linux.** You need Zig 0.15.2 and the development files of libadwaita, GTK 4.14 or newer, WPE WebKit 2.54 or newer built with WPEPlatform (`wpe-webkit-2.0`, `wpe-platform-2.0`), libsoup 3, Wayland and libdrm. Arch Linux's `wpewebkit` package has them.

    cd linux
    zig build test
    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/iris

Or the Flatpak, as CI builds it:

    flatpak-builder --user --install --force-clean build packaging/flatpak/io.github.tulip_labs.Iris.yml

**Android.** You need JDK 21.

    cd android
    ./gradlew assembleRelease

To let updates install over Iris, sign every release with the same key. Put the keystore in the repository's secrets (`IRIS_KEYSTORE` as base64, `IRIS_KEYSTORE_PASSWORD`, `IRIS_KEY_ALIAS`); `.github/workflows/android.yml` uses them.

## How it is made

```
linux/                      Iris for Linux (Zig, through the C headers)
  build.zig                 links libadwaita, GTK, WPE WebKit and WPEPlatform; translates
                            their headers (src/c.h) with Zig's translate-c
  src/
    webview.zig             Iris's WPEPlatform: its own display, views, toplevels and
                            clipboard; each frame (DMA-BUF) becomes a GdkDmabufTexture
                            without a copy; GTK's input becomes WPE events
    stage.zig               the window's content: one GTK widget that lays out every piece
                            and draws it in layers (back, pages, chrome, overlays)
    glass.zig               Liquid Glass from GTK render nodes: lens, rim refraction in three
                            steps, dispersion, rim light, pointer light
    browser.zig             a window: tabs, address, toolbar, pop-up rules, layout
    tab.zig                 a WPE web view and its signals
    engine.zig              the web context, containers, downloads, the sandbox, light video
    shields.zig, rules.zig  the levels' lists, turned into WPE content rules and compiled
    overlays.zig            menus, suggestions, find, downloads, the right-click menu, and
                            a page's own <select> lists, dialogs and file fields
    app.zig, keys.zig, store.zig, search.zig, updates.zig, ui.zig, core.zig
  tools/domains.zig         the ad and tracker domains as a sorted Zig array, at build time
  c/                        ext-background-effect-v1: blur behind the window
android/                    Iris for Android (Kotlin, Compose, System WebView)
  app/src/main/java/org/tulipanlabs/iris/
    Browser.kt              tabs and their Chromium pages in a ViewModel, profiles, pop-up rules
    Shields.kt, ShieldCore.kt  the levels, the lists, every request's answer
    Filters.kt              the filter engine (ABP and uBlock syntax)
    ui/                     Compose drawn as Liquid Glass: tab strip, address, page,
                            sheets, switches, line icons, the look
    Downloads.kt, Updater.kt, Store.kt, Search.kt
packaging/                  the Flatpak manifest, desktop file and metainfo
assets/icon/                the icon (SVG) and its renders
```

How the glass is drawn: each frame, the window first draws everything behind the glass (its tint and the page) into one scene. It then draws each piece of glass over that scene:

- a slightly magnified copy of what lies behind;
- three copies pulled in from beyond the edge, each seen only through a mask that fades in towards the rim, so lines curve as they cross it;
- red and blue split a little at the outermost step;
- a faint tint, the rim of light and the pointer's light.

Every step is a GTK render node (clip, transform, mask, blend, colour matrix, gradients), so it runs on GTK's GL and Vulkan renderers alike, at any scale.

## License

GPL 3.0. See [LICENSE](LICENSE), [NOTICE](NOTICE), [PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
