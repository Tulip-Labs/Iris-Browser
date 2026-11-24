# Iris Linux: a second chance for CEF on the Odin stack — investigation

Date: 2026-11-24. Base: origin/main at `e2ac438` (2.2.5 merged; PR #28 for 2.2.6 open, NOT used).
Question: retry CEF as the Linux page engine, keeping the Odin UI/chrome, for the
Flatpak build. Read-only investigation — nothing implemented, pushed, or merged.

## Short answer

Feasible as an experiment, not yet justified as a replacement. The compositor path
is the easy part (CEF off-screen rendering drops straight into the renderer's
existing software-frame path, and the old Go/CEF code already proved it). The
hard parts are Shields (no WPE content rules in CEF — the matcher must be
rebuilt), the Flatpak security trade-off (CEF's renderer sandbox has to be off
inside a Flatpak), an H.264/AAC regression (stock CEF ships without proprietary
codecs), and an ~8x bigger bundle. Recommendation: run the small smoke test
first (Section 7), then decide with real numbers. If it ever ships, it lands
as 2.2.7 at the earliest, as a **separate build beside WPE first**, not a
replacement.

## 1. Why CEF was removed (PR #12)

PR #12, "Remove CEF: Electron is now the Linux engine, Servo for light pages",
merged 2026-11-20 (21 commits, +112/−2807, 31 files). Its body is terse:

> Removes CEF entirely. Electron is now the Linux engine (Servo for light
> pages when built); the fractional scale test now runs against Electron.
> Android still uses Cefrium (separate port) and flake.nix still builds CEF
> (noted in README).

What was deleted (mostly "Delete …" commits through the web UI):

- `webview/cef_linux.c` (2,089 lines), `webview/cgo_cef.go` (14),
  `webview/engine_linux.go` (466), `cmd/iris/engine_cef.go` (8)
- `packaging/cef/helper.c` (43), `packaging/cef/cef.env`
- `.github/workflows/cef-headers.yml` (fetched the newest stable CEF and
  published its headers on a `cef-headers` branch)

The reasons, reconstructed from the deleted code and the history around it
(the PR itself does not argue them one by one):

1. **A second engine to hand-maintain.** The desktop CEF engine was a
   Go/cgo binding: ~2,500 lines of hand-written C plus Go, a header-fetch
   workflow, and a helper binary — all maintained by hand, for one platform.
2. **Electron was a complete shell.** It needed no custom C bindings, no
   subprocess/helper management, and no header workflow. At that moment the
   desktop was consolidating (same week: "WebKitGTK for most pages, Electron
   for the heavy ones; Servo removed").
3. **CEF's process model was friction in the Flatpak.** The old code already
   carried the workaround: `no_sandbox` when no sandbox is available
   (`IRIS_NO_SANDBOX` env, `sandboxMissing` detection) and a separate
   `iris-helper` binary as `browser_subprocess_path`.
4. **It was a Go-era decision.** The stack then was Go + GTK. Two weeks later
   the Odin rewrite removed Electron too (2.2.0: "Iris for Linux rebuilt in
   Odin on Wayland and WPE WebKit, with no GTK"). So reason 2 no longer
   applies — the question today is CEF vs WPE WebKit on Odin, not CEF vs
   Electron. Reasons 1 and 3 still apply, in Odin form.

Old CEF facts worth keeping: it ran CEF 156.0.30 (Chromium 156.0.8078.96),
fetched from `cef-builds.spotifycdn.com/index.json`, and rendered
**windowless (OSR)** with `shared_texture_enabled = 0` — frames came through
the CPU (`onPaint`; `onAcceleratedPaint` was a stub) — "they work everywhere".
Message loop: external pump (`external_message_pump = 1`,
`multi_threaded_message_loop = 0`). Scale handling for fractional scales
(1.25 etc.) was in there.

## 2. The current Linux engine (what CEF would replace)

Odin + Wayland + WPE WebKit 2.54.3, no GTK, no X11. `linux/src/` is ~9,190
lines of Odin.

| Piece | File(s) | How WPE is wired in |
|---|---|---|
| Page views | `tab.odin` (409) | One `WebKitWebView` per tab, all sharing one `WebKitWebContext`; sandbox gets its own context; each container gets its own `WebKitNetworkSession`. Signals connected per view: `notify::uri/title/estimated-load-progress/is-loading`, `load-changed`, `decide-policy`, `create`, `load-failed-with-tls-errors`, `ready-to-show`, `close`, `context-menu`, `mouse-target-changed`, `permission-request`, `web-process-terminated`, `show-option-menu`, `script-dialog`. |
| Engine core | `engine.odin` (495) | Context/session/memory-pressure setup (each web process capped at ~1/6 of RAM), downloads (`download-started` on the network session), injected scripts (`aimode.js`, `youtube.js` via `#load`). |
| WPE bindings | `wpe.odin` (141) + `wpe_gen.odin` (261) | Hand-written + generated C bindings; `tools/bind.py` generates from headers, `linux/abi/check.sh` verifies every binding against the real headers with clang. |
| Renderer | `render.odin` (536) | OpenGL ES 3 through EGL. Each frame: the page's WPE frame arrives as a DMA-BUF, becomes an EGL image, and goes into a texture — zero copy. **Software frames (BGRA bytes) are also supported** — this is the slot CEF's `OnPaint` would fill. |
| Chrome | `chrome.odin` (1,690) | Fully Odin-drawn: tab strip, bars, address, panels, menus, dialogs. Hit areas are kept from what was drawn. No WebView in the chrome (the "its HTML" phrase in `render.odin`'s header comment is stale). |
| Shields | `shields.odin` (402), `rules.odin` (530), `shield-domains.txt.gz` | `rules.odin` converts EasyList/uBlock syntax to **WebKit content-rule JSON**; `shields.odin` compiles it with `WebKitUserContentFilterStore` (async save/load) and installs it on each view's `WebKitUserContentManager`. |
| Find/zoom/dialogs | `chrome.odin`, `search.odin` (420) | `WebKitFindController`, `webkit_web_view_set_zoom_level`, WebKit permission/file-chooser/script-dialog/context-menu signals. |
| Platform | `platform.odin` (413) | Wayland display, EGL, input, clipboard, portal (file chooser, screen share via PipeWire). |

API surface to re-implement: **205 distinct `webkit_*`/`wpe_*` symbols** are
used across `linux/src/`. That is the size of the engine layer a CEF swap
must replace or mirror.

Flatpak (`packaging/flatpak/io.github.tulip_labs.Iris.yml`, 160 lines):
GNOME 50 runtime/SDK; builds **WPE WebKit 2.54.3 from source**
(`wpewebkit-2.54.3.tar.xz`, `PORT=WPE`, `ENABLE_WPE_PLATFORM=ON`; "a few
hours to build the first time; CI keeps the built module in its cache");
GStreamer libav via the `ffmpeg-full` extension for H.264/H.265/AAC;
a syscall filter for WebKit's process sandbox. `finish-args` already include
`--share=ipc`, `--socket=wayland`, `--socket=pulseaudio`, `--device=all`,
`xdg-run/pipewire-0`, `xdg-download` — the first two and the device line are
exactly the ones CEF needs too. The Iris module builds the Odin app with
`linux/build.sh install`. Bundle today: **~39.4 MB** (`Iris-x86_64.flatpak`).

CI (`.github/workflows/linux.yml`, 182 lines): the `odin` job builds in
seconds in an Arch container against system `wpewebkit`; the `flatpak` job
(timeout 345 min) builds WPE inside the bundle, caches it keyed on the
manifest hash, then installs the bundle and starts Iris under headless Weston
for 40 s. The fractional-scale test runs Iris under sway at 1.25.

## 3. CEF availability (checked 2026-11-24)

- Current stable, from `https://cef-builds.spotifycdn.com/index.json`:
  **CEF 156.0.32+g3d1f4ab, Chromium 156.0.8078.109**.
- `cef_binary_156.0.32+…_linux64_minimal.tar.bz2`: **318.0 MB compressed**
  (verified by download of the index only, not the tarball).
  Standard distribution is 665.1 MB; the `minimal` one is the right pick.
- Extracted size was **not measured here** (downloading 318 MB was out of
  scope); a minimal distribution typically extracts to roughly 600 MB–1 GB
  (libcef.so alone is a few hundred MB). Treat the bundle impact below as an
  estimate until the smoke test measures it.
- Same Chromium major as Android's Cefrium 0.21.0 (156.0.8078.96): near
  parity — one engine version across Linux and Android, if that is the goal.
- The **C API is still shipped** (`include/capi/cef_*_capi.h`). Odin would
  bind it exactly like the WPE bindings: a `cef.txt` list for
  `tools/bind.py`, verification through `linux/abi/check.sh`. No C++ wrapper
  (`libcef_dll_wrapper`) is needed for the C API.
- Note: Android's Cefrium SDK is a different thing (Android-only, Java/Kotlin
  SDK). Desktop CEF is the standard binary distribution from the Spotify CDN.

## 4. What survives vs what breaks

**Survives untouched** (Odin-drawn or engine-independent):
- Liquid Glass chrome (`chrome.odin`), tab strip, panels, menus, dialogs' UI.
- The renderer shell: EGL/OpenGL ES, the scene composition, the glass blur.
- AI Mode new-tab page and the YouTube script: both are injected JS
  (`#load("aimode.js")`, `#load("youtube.js")`, shared with Android, CI
  checks they match). They ride on any engine that runs JS.
- Downloads UI, history, containers' UI, settings/store.

**Needs a CEF equivalent (moderate):**
- Page lifecycle: `CefLifeSpanHandler` (create/close/popup), `CefLoadHandler`
  (loading state, title, URL, errors, TLS errors), `CefDisplayHandler`.
- Input: OSR needs explicit event forwarding — `SendKeyEvent`,
  `SendMouseClickEvent`/`SendMouseMoveEvent`/`SendMouseWheelEvent`,
  `SendFocusEvent`, and IME via `ImeSetComposition`/`ImeCommitText`.
  The old code did all of this. (Lesson from Android 2.2.5: never lie to
  the engine about visibility to keep media alive — CEF OSR input is
  explicit forwarding, so no such hack is needed.)
- Downloads: `CefDownloadHandler::OnBeforeDownload`/`OnDownloadUpdated`
  replaces the `download-started` signal.
- Find in page: `CefFindHandler` + `CefBrowserHost::Find` replaces
  `WebKitFindController`.
- Zoom: `CefBrowserHost::SetZoomLevel` — trivial.
- Dialogs/permissions/menus: `CefJSDialogHandler`, `CefDialogHandler` (file
  chooser), `CefPermissionHandler`, `CefContextMenuHandler`,
  `CefLifeSpanHandler::OnBeforePopup`, `CefKeyboardHandler`. Iris's
  Odin-drawn dialogs survive; the wiring is new.
- Memory pressure: CEF has no equivalent of WebKit's memory-pressure
  settings; per-process limits would need `CefBrowserHost`/`CefCommandLine`
  flags or OS-side limits. Minor.
- Sandbox feature (untrusted sites): a fresh ephemeral `CefRequestContext`
  (in-memory cache, no cookies/storage) per sandboxed tab, plus per-container
  request contexts with separate cache paths. Chromium's process model gives
  real site isolation — better than WPE here — **except** for the sandbox
  caveat in Section 5.

**Hard — the two real rewrites:**
- **Shields.** There are no WPE content rules in CEF. `rules.odin` today
  emits WebKit JSON; CEF needs a matcher evaluated per request in
  `CefRequestHandler::OnBeforeResourceLoad` (Android's shield already runs
  in ~12 µs per request on the network thread — the same budget applies),
  plus cosmetic hiding delivered as injected CSS/JS
  (`CefFrame::ExecuteJavaScript` at document start). The list parsing can be
  reused; the matching engine and the compile/store pipeline cannot.
- **Compositor (feasible, with a perf cost).** On Linux, CEF's accelerated
  OSR path (`OnAcceleratedPaint` / shared texture) is **not supported
  upstream** — the CEF maintainer's answer is the Ozone layer, and the old
  Iris code deliberately ran `shared_texture_enabled = 0`. So pages come
  through software `OnPaint` (BGRA, per dirty rect) and are uploaded to a
  texture. The renderer already has that path. Cost: a CPU copy + upload per
  frame; video-heavy pages and smooth scrolling will use noticeably more CPU
  than today's zero-copy DMA-BUF frames, and there is no GPU compositing
  for pages. The old code lived with this; whether it is acceptable now is a
  device-test question.

**Regressions to state plainly:**
- **H.264/AAC.** Stock CEF binaries are built without proprietary codecs.
  YouTube falls back to VP9/Opus (fine), but H.264-only video (many news
  sites, social video, some conferencing) would fail, and the "light video"
  H.264 preference would go away. The Flatpak's `ffmpeg-full` extension
  would become dead weight for CEF (GStreamer is WebKit's decoder, not
  Chromium's). Fixing it means building CEF/Chromium from source with
  proprietary codecs — a multi-hour build no CI here can carry. Widevine
  DRM is absent in both engines, so that is parity, not a regression.
- **Bundle size.** ~39.4 MB today → the CEF minimal tarball alone is 318 MB
  compressed; the installed bundle would land roughly in the 150–250 MB
  range (estimate, unmeasured). The upside: no more multi-hour WPE build in
  CI — the flatpak job becomes download + unpack + link, and the
  WPE cache dance disappears.
- **Renderer sandbox off.** See Section 5.

## 5. Flatpak + CEF process model

- Subprocesses: on Linux `browser_subprocess_path` defaults to the main
  executable — the Iris binary re-execs itself with `--type=renderer` etc.
  via `CefExecuteProcess`, which must be called early in `main()`, before
  `CefInitialize`. The old code instead shipped a tiny `iris-helper` binary
  (43 lines, `cef_execute_process`, with a zygote note: it must `_exit`
  from `cef_execute_process` and is built with `-fno-stack-protector`).
  Either shape works inside a Flatpak — it is the same binary, same sandbox.
- **Sandbox: `no_sandbox = 1` is required.** Chromium's SUID sandbox needs
  a setuid `chrome-sandbox` helper, which cannot exist inside a Flatpak.
  The old code already did this (`no_sandbox` when no sandbox is
  available). Electron Flatpaks do the same. Consequence: renderer processes
  run unsandboxed *inside* the Flatpak sandbox — Flatpak's bubblewrap
  sandbox and Iris's own untrusted-site sandbox become the only isolation.
  That weakens the story Iris currently tells ("automatic sandbox for sites
  it does not trust", backed today by WebKit's process sandbox + a syscall
  filter). The Flatpak sandbox still confines files/network/devices, but a
  renderer exploit would have the run of the app's own permissions.
- `--share=ipc` (already in `finish-args`) covers Chromium's `/dev/shm`
  needs. `--device=all` (already set) covers the GPU process. Crashpad can
  run as a subprocess or be disabled.
- OSR needs no window, so Wayland-vs-X11 does not matter for the page; the
  Iris window stays Wayland + EGL as today. External message pump
  (`external_message_pump = 1`) integrates CEF's loop with the glib main
  loop, as the old code did.

## 6. What still exists locally (reusable or not)

- **The old CEF code is in git history** (parent of PR #12, base
  `3a12ecb`): `webview/cef_linux.c`, `webview/engine_linux.go`,
  `packaging/cef/helper.c`, `packaging/cef/cef.env`, `cef-headers.yml`.
  Reference only — Go/cgo + GTK era; the settings, flags, OSR wiring,
  subprocess helper and fractional-scale handling are still instructive,
  but nothing ports line-for-line to Odin.
- **No live CEF references remain** in the repo outside Android's Cefrium
  (`git grep -i cef` on text files: only `android.yml`'s libcef.so check
  comment and `build.gradle.kts`'s "Iris carries its own Chromium (CEF) now").
- **Stash `stash@{0}` ("On main: local PR11+flathub work")** holds
  `flake.nix`, the metainfo file, and `webview/servo/servo_linux.c` — Servo,
  not CEF. Do not pop it; nothing CEF-reusable in it.
- **PR #11's nix fix `cd7f365`** is a mozjs assembler fix (`AS="$CC"`) for
  the Servo/nix build. Not CEF-related.
- Untracked `webview/` in the clone holds only `electron/` leftovers.
- Reusable for real: the binding/verification tooling (`tools/bind.py`,
  `linux/abi/check.sh`), the renderer's software-frame path, the injected
  JS, the Flatpak `finish-args`, and the old code's CEF settings as a
  checklist.

## 7. Verdicts

| Item | Verdict | Note |
|---|---|---|
| Keep Odin UI/chrome, swap engine | **Feasible** | Chrome is Odin-drawn; only the engine layer changes. |
| Bind CEF C API from Odin | **Feasible** | Same pattern as the WPE bindings; C API still shipped. |
| Page → texture (OSR) | **Feasible** | Software `OnPaint` into the existing BGRA path; no GPU compositing on Linux. |
| Input/IME/popups/dialogs/downloads/find/zoom | **Feasible** | Standard CEF handlers; moderate work, old code as reference. |
| Sandbox feature (untrusted sites) | **Feasible, weaker** | Request contexts give isolation; renderer sandbox is off in Flatpak. |
| Shields | **Hard** | Matcher + cosmetic injection must be rebuilt; biggest functional rewrite. |
| H.264/AAC video | **Blocker for parity** | Stock CEF lacks proprietary codecs; no CI-feasible fix. |
| Bundle size (~39 MB → ~150–250 MB est.) | **Hard** | 318 MB compressed download; user-visible, Flathub-visible. |
| Flatpak process model | **Feasible** | `no_sandbox`, helper/main-binary re-exec, `--share=ipc` already set. |
| CI time | **Improves** | No more multi-hour WPE build; download + unpack instead. |
| One engine everywhere (CEF 156 ≈ Cefrium 156) | **Feasible** | Near version parity with Android. |

**Overall recommendation:** worth the retry as an experiment, not as a
committed replacement. The honest reasons to want CEF are one Chromium
across Linux and Android and Chromium's wider site compatibility; the honest
costs are the Shields rewrite, the H.264 regression, the sandbox trade-off,
and the bundle size. WPE works today — nothing in the current Linux build is
broken in a way CEF would fix, so this is a capability bet, not a repair.

**Smallest first step (proves it before touching Iris):** a minimal Odin
program — a scratch dir, not in `linux/src/` yet — that (1) downloads the
pinned CEF 156 minimal tarball in CI and unpacks it, (2) generates C API
bindings for a handful of functions via `tools/bind.py` and verifies them
with `linux/abi/check.sh`, (3) initialises CEF with `no_sandbox = 1`,
`windowless_rendering_enabled = 1`, external message pump, subprocess via
the main binary, (4) opens `about:blank` and one real page off-screen and
dumps one `OnPaint` frame to a PPM. That proves the download, the binding,
the subprocess spawn inside the CI/Flatpak environment, and the paint path —
for a day or two of work and zero Iris changes. If the frame lands, the next
step is a `cef` branch of Iris with the engine behind a build flag.

**If it ships:** earliest **2.2.7** (after 2.2.6). Ship it as a **separate
build beside WPE first** — a second Flatpak/app-id for testing, the way
Cefrium returned as a separate flavor on Android — and replace WPE only
after a device test passes on real hardware (page loads, typing, video,
Shields on a known ad-heavy page, sandbox site isolation). A full
replacement without that proving step would trade a working engine for an
unproven one.

**Rough cost of the full swap:** ~3–5k lines touched/added (CEF bindings
~1.5–2.5k, engine/tab rewrite ~1.5k, Shields matcher + injection, dialogs/
downloads/find wiring ~0.5k), Flatpak manifest rework (drop the `wpewebkit`
module, add a `cef` module, drop or keep `ffmpeg-full`), CI rework
(`linux.yml` odin job needs the CEF tarball too), plus ongoing CEF release
tracking (a new CEF roughly every 4 weeks vs WPE's slower cadence). Several
weeks of focused work, not days.
