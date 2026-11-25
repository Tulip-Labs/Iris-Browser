<p align="center">
  <img src="assets/icon/iris-256.png" width="128" alt="Iris">
</p>

<h1 align="center">Iris</h1>

<p align="center"><i>Iris is the Greek goddess of the rainbow, who carries light between worlds.</i></p>

<p align="center">
  <b>A browser made of glass.</b><br>
  Linux: Odin, Wayland and WPE WebKit, in real Liquid Glass. No GTK.<br>
  Android: Kotlin, Jetpack Compose and Cefrium (its own Chromium). Every search asks Google AI Mode.
</p>

<p align="center">
  <img alt="Odin" src="https://img.shields.io/badge/Odin-dev--2026--11-3882D2?style=flat-square">
  <img alt="WPE WebKit" src="https://img.shields.io/badge/WPE_WebKit-2.54-2B8DD6?style=flat-square">
  <img alt="Wayland" src="https://img.shields.io/badge/Wayland-native-FFBC00?style=flat-square&logo=wayland&logoColor=black">
  <img alt="Kotlin" src="https://img.shields.io/badge/Kotlin-Compose-7F52FF?style=flat-square&logo=kotlin&logoColor=white">
  <img alt="Android 10 and newer" src="https://img.shields.io/badge/Android-10%2B-3DDC84?style=flat-square&logo=android&logoColor=white">
  <img alt="License: GPL 3.0" src="https://img.shields.io/badge/license-GPL%203.0-6B7280?style=flat-square">
</p>

<p align="center">
  <a href="#what-is-new-in-230">New</a> ·
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

## What is new in 2.3.0

- **Pinned tabs, sound and muting.** Pin a tab from its menu: it stays at the left as its icon. A tab playing sound shows a speaker; click it, or press Ctrl+M, to mute. Ctrl+Shift+T brings closed tabs back where they were, pinned or not; Ctrl+Shift+K duplicates a tab.
- **Reader** (Ctrl+Alt+R, or the button that shows in the address only on articles): the article alone, in a calm page of glass, light or dark, that runs no script.
- **Split View** (Ctrl+Shift+S): two tabs side by side, a divider to drag between them.
- **Compact mode** (Ctrl+Shift+C): the tabs and bar hide; they slide down in glass when the pointer reaches the top.
- **Peek** (Alt+click a link, or Peek Link in its menu): the link in a floating card of glass over the page. Esc or a click beside it closes it, and its view and process go with it; Enter, Ctrl+Enter or its expand button make it a tab.
- **Workspaces** (Alt+1…9): named sets of tabs, from the Containers menu or the command palette; each tab and workspace comes back next time.
- **Privacy Report** (in Shields): the trackers stopped on the page, and today. Only tracker names and numbers are kept, never the sites you visit.
- **Command palette** (Ctrl+K): your tabs in every workspace, Iris's commands and your history, by a fuzzy match.
- **HTTPS first**, on by default: http addresses are tried over https, with one click back to http (in the sandbox) when a site has none. **Forget everything on close**, if you want it: history, cookies, site data and tabs. **Copy Clean Link**: an address without its tracking.

## What is new in 2.2.7

- **No page can trap you in its dialogs.** A page that keeps opening alerts is stopped after a few, dialogs show over their own page only, and closing a tab closes its dialog.
- **The sandbox catches every form of an address**: an IP address written as one number or in hexadecimal opens in the sandbox like the dotted form, on Linux and Android.
- **Web pages open web addresses only** in new tabs, never files on your computer; and big site icons and long titles take less memory.

## What is new in 2.2.6

- **Cefrium is the only Android build now.** The WebView build is gone: in 2.2.5 nothing could be typed in it, while the Cefrium build worked. The one build carries its own Chromium (CEF, through Cefrium 0.21.0, Chromium 156), installs over 2.2.4's WebView build under the same name, Iris, and keeps its tabs and sign-ins. If you installed the separate "Iris Cefrium" build, uninstall it after installing this one.
- **Background audio still works**: audio keeps playing with the screen off or when Iris leaves, with play, pause and stop in the notification and on the lock screen.

## What is new in 2.2.4

- **Safer downloads, links and updates.** On Android, links from other apps open only when they are web addresses, downloads come only from the web, and updates only from Iris's own GitHub releases. On Linux, the sandbox downloads nothing from the right-click menu either, and downloaded files get safe names.
- **Lighter over a long day on Linux**: changing page titles and trimmed history no longer hold on to memory, and history, session and settings are written safely and readable by you alone.
- **No more update notice for the version you already have** on Linux.

## What was new in 2.2.3

- **Cefrium is back, as a build of its own.** Iris for Android comes in two builds now: the usual one, on Android System WebView, and a second one, **Iris Cefrium**, carrying its own Chromium (CEF, through Cefrium 0.21.0, Chromium 156), the same engine on every phone. Both install side by side; the Cefrium build does not carry the other build's tabs or sign-ins over. Its blank pages are fixed with the maintainer's fix for the renderer processes (issue #24).
- **Each build updates itself**: the Cefrium build takes the Cefrium APK, the WebView build the plain one.

## What was new in 2.2.0

- **Iris for Linux is now Odin and WPE WebKit, with no GTK.** Odin talks to Wayland, EGL, OpenGL ES, HarfBuzz, fontconfig and WPE directly, through foreign declarations checked against the real C headers.
  - Each page frame arrives from WPE as a DMA-BUF and Iris samples it in its own OpenGL ES renderer without a copy, so the Liquid Glass (now a shader) bends the live page.
  - The tabs, address bar, menus and dialogs are drawn by Iris itself, in the same frame as their glass: text shaped by HarfBuzz in the desktop's font, glyphs and icons rasterised by Iris.
  - Iris draws a page's own pop-ups in glass too: `<select>` lists, `alert()`, `confirm()` and `prompt()`; file fields use the desktop's portal.
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
- **Android in Kotlin with Jetpack Compose** (its engine is Cefrium, its own Chromium).
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
- **Iris Shields.** About 100,000 ad and tracker domains, built into Iris, become WPE content rules. They are compiled once and blocked inside the engine before a request leaves. You can turn Shields off for one site or everywhere.
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
- **A page's own pop-ups in glass.** `<select>` lists open as glass menus where the page put them; `alert()`, `confirm()` and `prompt()` are glass dialogs; file fields use the desktop's file chooser (through its portal).
- **Sharp at every scale.** Wayland's fractional scaling: WPE renders each page, and Iris its chrome, at the screen's own pixels, at 1.25, 1.5 or 2.

### Android

- **Engine.** Cefrium (its own Chromium, CEF, the same engine on every phone). The interface is Jetpack Compose drawn as Liquid Glass (no Material components). The tabs and their pages live in a ViewModel.
- **Look.** Light, in the colours of dawn. Every new tab is Google AI Mode in Iris's glass.
- **The sandbox.** Sites Iris does not trust open in a process of their own with WebView data made fresh each time, and none of your data.
- **Containers.** Cefrium profiles: each container keeps its own cookies, cache, localStorage and IndexedDB.
- **Shields.** Cefrium asks Iris before every request; ads and trackers never leave the phone. Ads that open new tabs are stopped too: a page opens no tab by itself, a tapped ad link opens nothing, and a script's window stays hidden until Iris knows it is not an ad. Moderate, Aggressive or Ultra aggressive, with uBlock Origin's lists, and the boxes ads leave are hidden.
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
| Ctrl+Shift+K | Duplicate tab |
| Ctrl+M | Mute or unmute the tab |
| Ctrl+L, F6 | Address bar |
| Ctrl+K | Command palette: tabs, commands, history |
| Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+1…8, Ctrl+9 | Change tab (Ctrl+9: the last) |
| Alt+1…9 | Change workspace |
| Ctrl+Alt+R | Reader |
| Ctrl+Shift+S | Split View |
| Ctrl+Shift+C | Compact mode |
| Alt+click a link | Peek; Enter or Ctrl+Enter makes it a tab, Esc closes it |
| Ctrl+R, F5 / Ctrl+Shift+R | Reload / reload without the cache |
| Alt+← / Alt+→ | Back / forward |
| Alt+Home | Google AI Mode |
| Ctrl+F | Find in page |
| Ctrl+Plus / Ctrl+Minus / Ctrl+0 | Zoom |
| Ctrl+Shift+Y, Ctrl+J | Downloads |
| F11 | Full screen |
| Ctrl+Q | Quit |

## Build

**Linux.** You need Odin (dev-2026-11 or newer), a C compiler to link with (clang, or gcc through `ODIN_CLANG_PATH`), and the development files of WPE WebKit 2.54 or newer built with WPEPlatform (`wpe-webkit-2.0`, `wpe-platform-2.0`), libsoup 3, HarfBuzz, fontconfig, Wayland (`wayland-client`, `wayland-egl`, `wayland-cursor`), xkbcommon, EGL and OpenGL ES. Arch Linux's packages have them all.

    cd linux
    ./build.sh test          # the tests
    ./build.sh check         # every C binding against the real headers
    ./build.sh               # a quick build to work on (no optimisation)
    ./build.sh release       # the optimised build, as the Flatpak ships it
    ./iris

Or the Flatpak, as CI builds it:

    flatpak-builder --user --install --force-clean build packaging/flatpak/io.github.tulip_labs.Iris.yml

**Android.** You need JDK 21.

    cd android
    ./gradlew assembleRelease

To let updates install over Iris, sign every release with the same key. Put the keystore in the repository's secrets (`IRIS_KEYSTORE` as base64, `IRIS_KEYSTORE_PASSWORD`, `IRIS_KEY_ALIAS`); `.github/workflows/android.yml` uses them.

## How it is made

```
linux/                      Iris for Linux (Odin; no GTK, no X11)
  build.sh                  builds, tests and checks (odin build src)
  plat/window.odin          the window: its own Wayland client (xdg-shell, fractional scale,
                            viewporter, cursor shapes, decorations, background blur), keys
                            through xkbcommon, EGL
  wl/                       Wayland's protocols as Odin tables (generated from the XML)
  src/
    platform.odin           Iris's WPEPlatform: its own display, views, toplevels and
                            clipboard (GObject subclasses written in Odin); each frame, a
                            DMA-BUF, becomes an EGL image sampled with no copy; Wayland's
                            input becomes WPE events
    render.odin             the OpenGL ES 3 renderer: the dawn, the page, Liquid Glass
    chrome.odin             the chrome, drawn each frame with its glass: tabs, bars, the
                            address, panels, menus, dialogs, notes; clicks and keys
    text.odin, text_ffi.odin  text: fontconfig finds the fonts, HarfBuzz shapes and gives
                            each glyph's outline, one atlas holds them
    raster.odin, icons.odin Iris's rasteriser (exact area coverage) for glyphs and the
                            line icons (SVG path data)
    line.odin               an editable line: cursor, selection, words, clipboard, undo
    browser.odin            the window's tabs, layout, input routing, pop-up rules
    features.odin, spaces.odin, layout.odin  pinned tabs, sound, closed tabs, https first,
                            clear on exit; workspaces; split view and compact mode
    reader.odin, reader.js, peek.odin, privacy.odin, palette.odin  the reader, the peek,
                            the privacy report, the command palette (engine-free)
    page_events.odin, wpe_extra.odin, cef_extra.odin  what the engines tell those
                            features, and their calls into each engine
    tab.odin                a WPE web view and its signals
    engine.odin             the web context, containers, downloads, the sandbox, light video
    shields.odin, rules.odin  the levels' lists, turned into WPE content rules and compiled
    portal.odin             file fields through the desktop's portal (D-Bus)
    glib.odin, wpe*.odin, soup_gen.odin  the C functions Iris calls, declared once
    main.odin, store.odin, search.odin, updates.odin, clipboard.odin
  abi/                      checks every foreign declaration, struct and protocol table
                            against the C headers (clang reads them)
  tools/                    makes the bindings and protocol tables from the headers
android/                    Iris for Android (Kotlin, Compose, Cefrium)
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

How the glass is drawn (Linux): each frame, Iris draws everything behind the glass (the dawn and the page) into one texture, and a blurred copy of it. Then each piece of glass is one shader pass over that texture:

- the middle is a gentle lens, a little magnified;
- towards the rim, what lies behind is pulled in from beyond the edge, more the nearer the edge, so lines curve as they cross it;
- red, green and blue bend by slightly different amounts at the rim (dispersion);
- panels mix in the blurred copy (frost), for reading;
- a faint tint, a line of light inside the top rim, the pointer's light, and a soft violet shadow below.

The chrome's words and icons are drawn right after each piece of its glass, in the same frame, at the screen's own pixels.

## Contributors

- [vejeta](https://github.com/vejeta) — maintainer of Cefrium; diagnosed the blank-pages issue on Android and proposed the one-line fix in `IrisApp.onCreate`.

## License

GPL 3.0. See [LICENSE](LICENSE), [NOTICE](NOTICE), [PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
