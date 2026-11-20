# Iris's web engines

| System | Most pages | Heavy pages | Interface |
|---|---|---|---|
| Linux | **WebKitGTK 6** (from the system, the Flatpak's GNOME runtime, the Snap or nixpkgs) | **Electron** (Chromium with H.264, H.265 and AAC), started on demand | Gio, in a GTK 4 window |
| Windows | **Electron**, carried by Iris | (the same Electron) | Gio, in a Win32 window |
| Android | Cefrium (Chromium) | | Kotlin |

## Linux

```
                 Gio interface (Go), one GTK 4 window
                              │
                    engine router (webview/route)
                 │                              │
       WebKitGTK engine                  Electron engine
   (webview/webkit_linux.c,          (one helper process,
    engine_webkit.go)                 webview/electron/helper)
   pages are GTK widgets,             pages drawn off screen,
   children of Iris's view            copied into Iris's view
                 │                              │
                 └──── cookie bridge (core/session) ────┘
                      one store, every jar, both engines
```

### Which engine draws a page (`core/route`)

1. **Electron** for the heavy list: video (YouTube, Netflix, Twitch...),
   social sites (LinkedIn, Facebook, Instagram, X, Reddit, TikTok...), web
   apps (Google Docs, Gmail, Drive, Meet, Outlook, Teams, Figma, Discord,
   Slack, Notion, Canva) and sign-in pages (Google, Microsoft, Apple).
2. **Electron** for a site WebKit failed on (its page process crashed), or
   one the reader moved with "Open in full engine"; remembered per site and
   tried in WebKit again after a month.
3. **WebKitGTK** for everything else.

Containers and private tabs route the same way: WebKit has a network
session per container, one for private tabs (in memory) and one for
sandbox tabs (in memory, never shared). A pop-up stays with the engine of
the page that opened it, so `window.opener` keeps working.

### WebKitGTK pages

Each page is a `WebKitWebView`, a child widget of Iris's view, placed where
the tab's page goes (on a whole pixel of the screen at any scale). GTK draws
it on the graphics chip and gives it the pointer, touch, the wheel, the input
method and the keys itself. Iris keeps:

- its **shortcuts**: a key controller in the capture phase sends Ctrl+T,
  Ctrl+L, Alt+Left and the rest to Iris before the page sees them;
- its **menus**: while Iris draws a menu over the pages they take no input;
- **navigation policy**: HTTPS-only, unsafe addresses, links to another
  website in a new tab, tracking parameters cut from links, and the router's
  move to Electron, all decided before a navigation starts;
- **downloads** (to the Downloads folder, refused in a sandbox) and
  **permissions** (pointer lock, storage access and clipboard; never the
  camera, the microphone, the location or notifications).

**The shield** in WebKit is WebKit's own content blocker: Iris converts its
lists (the 100,000 built-in domains and the host, start and plain rules of
EasyList, EasyPrivacy and uBlock, with their kinds, party and domains) into
WebKit's rule format (`shields.ContentRules`), and WebKit compiles them once
(a few seconds, in the background) and keeps the result on disk. Sign-in,
messaging and human checks are never blocked; on YouTube and on sites where
the reader turned the shield off nothing is. Hiding rules and the YouTube
helpers run as page scripts, as in Electron.

**The sandbox**: WebKit's page processes run in bubblewrap (Flatpak's own
sandbox inside the Flatpak). On a system where it cannot run, WebKit is
left out and Electron draws every page; `IRIS_NO_SANDBOX=1` is the reader's
choice to run pages without it.

**Scale**: WebKitGTK draws a page at the next whole scale and GTK shrinks it
to a fractional one (1.25, 1.5), as in GNOME Web. Iris's interface is drawn
at the exact scale.

### The cookie bridge

Iris owns the cookies (`core/session`, kept in `cookies.sqlite`). WebKit
says when a jar changed; Iris reads it and reports the differences. Electron
reports each change (`session.cookies` "changed"). Each change goes to the
other engine; an engine's echo of a cookie it was just given changes
nothing, so nothing loops. A page waits for its jar's cookies before it
loads, so a sign-in in one engine is a sign-in in the other at once.

### Electron

One helper process for every heavy tab and every extension, started on
demand and gone two minutes after the last needs it; a memory budget,
hidden pages that stop painting, one renderer per site, nothing running in
the background. Chrome extensions run there; their content scripts only in
Electron's pages.

## Windows

Electron alone, with the same helper and the same `engine_electron.go` as on
Linux. What differs (`electron_windows.go`, `winpresent`):

- **The line to the helper** is TCP on 127.0.0.1 (Node on Windows has no Unix
  sockets) with a random port. Iris passes a random token in `IRIS_TOKEN`; the
  helper sends it first and Iris drops any connection that does not.
- **Drawing**: each page is a child window of Iris's window, painted from the
  helper's frames with StretchDIBits. Its region is rounded (12 px, square in
  full screen) and has a hole where Iris's menus overlap the page.
- **Shipping**: `build-iris.sh windows` stages Electron for x64 and ARM64 from
  npm into `electron/` beside `Iris.exe`, with the helper as
  `resources/app`. The setup embeds it as `payload/electron.zip` and unpacks it
  next to the program (`.new`, then swapped in, so an update is never half
  done); the portable zip and the MSIX (`tools/msix.go -extra`) carry it as a
  folder.
- **CI**: `windows.yml` builds the portable app and starts it on a Windows
  runner, which must show Electron's console line from a test page.

## Packaging (Linux)

- **Flatpak**: the GNOME 50 runtime carries GTK 4, WebKitGTK 6 and
  GStreamer; the ffmpeg-full extension adds H.264 and AAC for WebKit.
- **Snap**: WebKitGTK 6, its GStreamer plugins and bubblewrap are staged
  with the program; the GNOME extension brings GTK.
- **Nix**: `webkitgtk_6_0`, GStreamer and glib-networking from nixpkgs, and
  nixpkgs' Electron.
