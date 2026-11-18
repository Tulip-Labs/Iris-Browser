# Iris on Linux: two engines, one browser

This is the plan for Iris on Linux from 1.1 on. Windows keeps WebView2 and
is not part of it. Android keeps its own engine.

## What changes

| | Before (1.0) | After (1.1) |
|---|---|---|
| Light pages (articles, Wikipedia, search, docs) | Chromium (CEF, minimal build) | **Servo** |
| Heavy pages (YouTube, LinkedIn, Facebook, web apps, anything Servo cannot draw) | Chromium (CEF) | **Electron** (Chromium with H.264, H.265 and AAC) |
| How a page's frames reach the screen | copied through the processor, about 9 MB a frame | **shared on the graphics chip** (dmabuf), never copied |
| Interface | Gio, drawn by GTK | the same |
| Linux packages | .deb, .rpm, AUR, .tar.gz, Nix | **Flatpak** (first), **Snap**, **Nix** |

Why Electron and not CEF for the heavy engine: CEF's builds have H.264 and AAC
switched off when Chromium is compiled, and only a build of our own could
switch them on. Electron's builds have them on, so LinkedIn, X and the news
sites play with nothing to compile.

## The pieces

```
              Gio interface (Go)  ──  drawn by GTK 4, one window
                    │
              engine router (Go)
               │            │
        Servo engine   Electron engine
        (servo-capi,   (one helper process,
         in process)    started on demand)
               │            │
          frames on the graphics chip (dmabuf) → GTK textures
                    │
            shared session store (Go): cookies, sign-ins,
            history, settings, containers
```

### The router (Go, `shell/route.go`)

Each tab has an engine, chosen when it navigates:

1. **Electron** for the heavy list: youtube.com, linkedin.com, facebook.com,
   instagram.com, x.com, netflix.com, twitch.tv, web apps (docs.google.com,
   mail.google.com, outlook, figma, discord, slack, teams), and Google's
   sign-in pages (accounts.google.com).
2. **Electron** for a site Servo failed on: a page that crashes Servo, draws
   nothing, or that the reader moves with "Open in full engine" (in the three
   dots menu) is remembered per site.
3. **Servo** for everything else.

The list lives in `core/route.go` with tests, and the reader can move any site
either way from the three dots menu.

### The shared session store (Go, `core/session/`)

Iris keeps the cookies, not the engines. Each engine starts with an empty
cookie jar and:

- before a navigation, gets the cookies for that site from Iris;
- on every Set-Cookie (and `document.cookie` write), hands it to Iris.

So signing in to Google in one engine signs in both. Containers, private and
temporary tabs are separate jars in the same store, as now. History,
settings, passwords and the shield already live in Iris's Go code and work
with both engines unchanged.

### The Electron engine (`webview/electron/`)

One small Electron program (`helper/main.js`, a few hundred lines, no web
interface of its own) that Iris starts when the first heavy tab opens, and
drives over a Unix socket with short JSON messages: open, navigate, resize,
show, hide, input events, close, cookies. Pages are `BrowserWindow`s with
`offscreen: { useSharedTexture: true }`; each frame arrives as a dmabuf, which
a tiny native module passes to Iris with the file descriptors (SCM_RIGHTS), and
Iris hands to GTK as a `GdkDmabufTexture` (GTK 4.14+). Where the graphics chip
cannot share (software drawing), frames come through shared memory instead.

#### Keeping Electron light

Electron is Chromium plus Node.js; Iris keeps both on a diet:

- **Started on demand, stopped when idle.** The helper only runs while a heavy
  tab is open, and quits 2 minutes after the last one closes or rests: no
  memory at all while browsing light sites.
- **No Node.js in pages.** `nodeIntegration` off, `contextIsolation` and the
  sandbox on; Node runs only in the helper's main process (one small script).
- **Few processes.** One renderer per site (`process-per-site`), at most 3 on
  8 GB and less, 5 above; no spare renderer, no back-forward cache, no
  prerendering.
- **Hidden tabs cost nothing to draw.** A tab not on screen stops painting
  (`stopPainting`), is throttled, and after a minute rests (closed and
  restored from Iris's own copy of its history and scroll position), except
  tabs playing sound or video and YouTube, as now.
- **Paint only what changed, at the screen's rate.** Frames come only when
  the page changes, at most at the screen's refresh rate.
- **Video on the graphics chip.** VA-API decoding (H.264, H.265, VP9, AV1)
  where the driver has it.
- **Small V8 heaps.** `--max-old-space-size` sized to the computer's memory,
  `--optimize-for-size` on 8 GB and less.
- **Nothing in the background.** No crash reporter, component updater,
  spellchecker downloads, safe browsing pings, translate, or media router.
- **A small package.** Only the English and the reader's own locale files,
  no Electron sample apps, the helper as one plain script (no bundler; the
  only npm dependency is `electron-chrome-extensions`, see Extensions).

What the diet never touches, because pages break without it: the graphics
chip (GPU compositing, WebGL, WebGPU), JIT-compiled JavaScript, workers and
service workers (offline pages, YouTube), WebRTC (calls, Meet), notifications
and permissions, file pickers, clipboard, fullscreen, picture-in-picture, the
HTTP cache, password and form filling (Iris's own), and the codecs. Each
switch above is checked in CI against a page set (YouTube, LinkedIn video,
Google sign-in, a Meet test call, a service-worker page) before it ships.

Not in Electron's builds and so not in Iris: Widevine (Netflix, Disney+,
Spotify's web player need it). Those sites say so; playing them would need
Castlabs' Electron builds, which carry Widevine.

### The Servo engine (`webview/servo/`)

Servo from crates.io (0.x LTS), linked as a C library through `servo-capi`
and called from Go with cgo. It renders with WebRender into a GL texture of
its own context, shared with GTK the same way (dmabuf). Servo runs in Iris's
own process: no start-up cost for a light page.

## Extensions (Chrome Web Store, unpacked)

Extensions run in the Electron engine; Iris draws everything they show.

**In Electron.** The helper's main process carries `electron-chrome-extensions`
(the one npm dependency, vendored and pinned), which provides the
`chrome.tabs`, `chrome.runtime`, `chrome.webRequest`, `chrome.action` and
related APIs on top of Electron's own extension support. Extensions are
loaded unpacked with `session.loadExtension()`: Iris unpacks a .crx (from
the Web Store or a file) into its data folder first and checks its
signature; Electron never opens a .crx. Their background pages and service
workers run in the helper, which therefore also starts when an installed
extension needs to run, and stays as small as above otherwise.

**In Go and Gio.** Over the same socket the helper reports each extension's
icon, title, badge text and color, and popup address; Gio draws the icons and
their badges (an ad blocker's count, say) in the toolbar beside the address,
in Iris's own style. A click on an icon asks the helper to open the popup
(`chrome-extension://<id>/popup.html`) as an offscreen page of its own,
which Iris draws under the icon, sized to the popup's content, on the same
overlay over the pages that the right-click menu uses, and closes on a click
outside or Escape. Tabs the extensions see (`chrome.tabs`) are Iris's tabs,
mapped by Iris, Servo tabs included (their address and title).

**The limit.** Content scripts run only in pages Electron draws. When an
installed extension's content scripts match a site (a password manager on
a sign-in page, say), the router sends that site to Electron, and the reader
can turn that off per extension.

**Blocking in both engines, natively.** Iris Shields already matches
EasyList, EasyPrivacy and uBlock's lists in Go (about 110,000 rules in
microseconds). Both engines ask it before every request: Electron through
`session.webRequest.onBeforeRequest`, answered over the socket; Servo through
its embedding API's resource-load hook, answered in process. A proxy is not
used: for https it would see only the host name, not the address, and
blocking by host alone breaks sites. So an ad-blocking extension is optional,
not needed for the shield to work everywhere.

## Packaging (Linux)

- **Flatpak** (`packaging/flatpak/io.github.tulip_labs.Iris.yml`), the first
  way to install Iris on every distribution, Fedora Atomic included: built on
  `org.electronjs.Electron2.BaseApp`, with zypak for Chromium's sandbox, and
  the `org.freedesktop.Platform.ffmpeg-full` extension. Published on Flathub
  and as a .flatpak file on each GitHub release.
- **Snap** (`packaging/snap/snapcraft.yaml`) with the `desktop`, `wayland`,
  `x11`, `opengl`, `audio-playback`, `network` and `browser-support` plugs.
- **Nix** (`flake.nix`): Servo, Electron, fonts and the graphics drivers'
  paths set by the flake, so it runs on NixOS as is.

The .deb, .rpm, AUR and .tar.gz packages, their repositories and the in-app
updater for them are removed. Flatpak, Snap and Nix update Iris themselves.

## Order of work

1. Packaging: remove the old packages; Flatpak, Snap and Nix with the current
   engine, so there is something to install meanwhile.
2. The Electron engine with frames on the graphics chip; CEF removed.
3. The Servo engine, the router and the shared session store.
4. Measure: memory and frame times against 1.0 on the same pages, in CI.
