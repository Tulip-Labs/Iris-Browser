# Iris's web engines

| System | Pages | Interface |
|---|---|---|
| Linux | **WebKitGTK 6** (from the system, the Flatpak's GNOME runtime, the Snap, nixpkgs or the container image) | Gio, in a GTK 4 window |
| Android | **Chromium** through Cefrium (CEF for Android), carried by the app | Kotlin (Android views), the desktop's Liquid Glass and tab strip |

Iris for Windows (Electron) ended with 1.0.25.

## Linux

```
          Gio interface (Go), one GTK 4 window (cmd/iris/gtk_linux.c)
                                │
                   WebKitGTK engine (webview/engine_webkit.go,
                   webview/webkit_linux.c): each page a GTK widget,
                   a child of Iris's view; each cookie jar a WebKit
                   network session
```

### Pages

Each page is a `WebKitWebView`, a child widget of Iris's view, placed where
the tab's page goes (on a whole pixel of the screen at any scale) with
rounded corners. GTK draws it on the graphics chip and gives it the pointer,
touch, the wheel, the input method and the keys itself. Iris keeps:

- its **shortcuts**: a key controller in the capture phase sends Ctrl+T,
  Ctrl+L, Alt+Left and the rest to Iris before the page sees them;
- its **menus**: while Iris draws a menu over the pages they take no input;
- **navigation policy**: HTTPS-only, unsafe addresses, links to another
  website in a new tab and tracking parameters cut from links, all decided
  before a navigation starts;
- **downloads** (to the Downloads folder, refused in a sandbox) and
  **permissions** (pointer lock, storage access and clipboard; never the
  camera, the microphone, the location or notifications).

**Cookies and sessions.** The default jar, each container, private tabs (in
memory) and sandbox tabs (in memory, never shared) each have a WebKit
network session. A saved jar keeps its cookies in WebKit's own store
(`cookies.sqlite` in its folder under Iris's data folder). A pop-up opens in
its opener's session, so `window.opener` keeps working.

**The shield** is WebKit's own content blocker: Iris converts its lists (the
built-in domains and the host, start and plain rules of EasyList,
EasyPrivacy and uBlock, with their kinds, party and domains) into WebKit's
rule format (`shields.ContentRules`), and WebKit compiles them once (a few
seconds, in the background) and keeps the result on disk. Sign-in, messaging
and human checks are never blocked; on YouTube and on sites where the reader
turned the shield off nothing is. Hiding rules and the YouTube helpers run
as page scripts.

**Video** goes through GStreamer: VP9, AV1 and VP8 with Opus and Vorbis
everywhere; H.264 and AAC with GStreamer's libav plugin (the Flatpak's
ffmpeg-full extension, the Snap, Nix) or OpenH264.

**The sandbox**: WebKit's page processes run in bubblewrap (through
flatpak-spawn inside the Flatpak). Where it cannot run, Iris shows no pages
and says why; `IRIS_NO_SANDBOX=1` is the reader's choice to run pages
without it.

**Memory**: a hidden WebKit page keeps its memory, so Iris's balancer unloads
background pages (oldest first) when the pages pass their budget or the
computer runs short (`webview.SleepFreesMemory` is false).

**Scale**: WebKitGTK draws a page at the next whole scale and GTK shrinks it
to a fractional one (1.25, 1.5), as in GNOME Web. Iris's interface is drawn
by Gio at the exact scale into an sRGB texture, copied texel for texel.

**Extensions**: WebKitGTK runs no browser extensions, so Iris has none; the
shield does the work of an ad blocker.

## Android

Iris for Android (`android/`) is a Kotlin app with its own Chromium (CEF for
Android, through Cefrium): H.264 and AAC play, and containers keep their
sign-ins apart. It shares the desktop's look (one light Liquid Glass, the tab
strip on top) and its search (Google AI Mode with the same instruction).

## Packaging (Linux)

- **Flatpak**: the GNOME 50 runtime carries GTK 4, WebKitGTK 6 and
  GStreamer; the ffmpeg-full extension adds H.264 and AAC.
- **Snap**: WebKitGTK 6, its GStreamer plugins and bubblewrap are staged
  with the program; the GNOME extension brings GTK.
- **Nix**: `webkitgtk_6_0`, GStreamer and glib-networking from nixpkgs.
- **Container**: Fedora's WebKitGTK, Mesa (OpenGL, Vulkan, VA-API) and
  GStreamer (`packaging/container`).
