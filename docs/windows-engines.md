# Iris on Windows: Servo + Electron

Windows uses the same two engines as Linux from 1.1 on: **Servo** for light
pages, **Electron** for heavy pages. WebView2 is gone: it was one engine doing
both jobs, it needed a runtime Microsoft installs separately, and it could
not run the shared session store the same way (its cookies lived in its own
profiles). The router (`webview/route`, `core/route`) picks the engine per
tab exactly as on Linux, and the two engines share Iris's own cookie store.

## How the engines reach the screen

Linux has GTK as the compositor: the C code turns each page's frames into a
`GdkTexture` the window draws (`electron_linux.c`, `servo_linux.c`). Windows
has no GTK. Gio owns the window (an `HWND`), and the pages live in it as
**child windows of Iris's own**, one per page view, painted by Iris:

```
              Gio interface (Go)  ──  drawn by ANGLE into the HWND
                    │
              engine router (Go)
               │            │
        Servo engine   Electron engine
        (in process,   (one helper process,
         irisservo.dll)  started on demand)
               │            │
          frames (BGRA pixels) → child HWND, painted with GDI
          (StretchDIBits)      → input back over the same path
```

The presenter (`webview/winpresent`, a pure-Go subpackage with no cgo)
owns those child windows:

- one window class (`IrisPage`), one child `HWND` per page view, positioned
  by `SetBounds` in physical pixels, shown and hidden with the tab;
- each frame's pixels are kept per view and painted on `WM_PAINT` with
  `StretchDIBits` (32-bit BGRA, top-down). One texel on one screen pixel
  when the frame matches the view's size, as on Linux;
- the scale comes from the window's DPI (`GetDpiForWindow` / 96), read live
  on every bounds change, as the Electron engine does on Linux;
- the child window takes the pointer, the wheel and the keys over a page and
  hands them to the engine, exactly as the GTK code does on Linux: Iris's own
  shortcuts are checked first (through the view's `Events.Key`), then the
  keys and typed text go to the page. Mouse buttons 4/5 go back and forward.
- `onMain` (work the engine needs on the window's thread) posts to a
  message-only window owned by the presenter; Gio's message loop on the
  window's thread dispatches it there.

This is a CPU copy per frame (about 9 MB a frame at 1080p), where Linux
shares frames on the graphics chip. A D3D shared-texture path is the next
step, not this one; Electron already draws off screen at the window's scale,
so the copy is one texel on one screen pixel, not a resample.

## The Electron engine on Windows

The engine (`webview/engine_electron.go`) is the same code as on Linux: one
helper process, driven over a socket with short JSON messages, frames as
pixels. Only the platform layer differs:

- **Socket.** Go's `net.Listen("unix", ...)` and Node's
  `net.createConnection(path)` both speak AF_UNIX on Windows 10 (build
  17063+) and 11, so the transport is unchanged. The socket lives in
  `%TEMP%` with a short name (`iris-electron-<pid>-<nanos>.sock`).
- **Display flags.** The `--ozone-platform=wayland|x11|headless` switches
  are Linux-only; on Windows Electron picks its native platform itself.
- **Memory.** The `/proc` readings are replaced by `GlobalMemoryStatusEx`
  (total memory) and a process-tree walk with `Toolhelp32Snapshot` +
  `GetProcessMemoryInfo` (the helper's memory), the same calls the old
  WebView2 engine used for its own memory.
- **Files.** Electron for Windows is staged per architecture from npm
  (`stage_electron_windows` in `build-iris.sh` / `build-iris.bat`: the
  Electron binary for win32-x64 or win32-arm64 plus Iris's helper as
  `resources/app`) and shipped in the MSIX next to `Iris.exe` as `electron/`.
  The Electron version it staged is written to `ELECTRON_VERSION` next to
  the program, which the setup's installer reads when it fetches Electron
  later. The helper's `main.js` is unchanged apart from the socket path: its
  `/dev/dri` video check is guarded and simply does not apply on Windows.
- **Extensions.** They run in the Electron helper, as on Linux
  (`route.Wrap` hands the router an `ExtensionHost`).

## The Servo engine on Windows

The Rust bridge (`webview/servo/rust/`, the `servo` crate 0.4.0) is
platform-independent: every page renders into a **software** context, and
the bridge exposes the same C API on every system (`irisservo.h`). Only
the presentation layer is per-platform. On Windows:

- the bridge is built as `irisservo.dll` (the `servo-lib` workflow's Windows
  job, `x86_64-pc-windows-msvc` via cargo-xwin; SpiderMonkey does not build
  with a MinGW compiler, so the MSVC target is the one) and Iris links it
  with cgo: the x64 build runs `CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc
  -tags servo`, linking the MinGW import library `libirisservo.dll.a`
  (generated from the DLL's exports) from `webview/servo/lib/`. The DLL
  ships next to `Iris.exe` in the MSIX. Strings the DLL allocates are freed
  inside the DLL (`iris_servo_free`), so the two runtimes never free each
  other's memory;
- when the bridge is not built (an ARM64 install, or a build without the
  DLL), the build has no `servo` tag and the router sends every tab to
  Electron, exactly as the Linux build without Servo does. Servo is never a
  reason Iris does not start;
- its frames arrive as RGBA pixels through `onFrame` and go through the same
  presenter as Electron's, and its input through the same child windows;
- its memory budget reads this process's own memory (`GetProcessMemoryInfo`)
  and the computer's total (`GlobalMemoryStatusEx`), as on Linux.

ARM64: the MSIX carries an ARM64 `Iris.exe` and an ARM64 Electron, but no
Servo DLL yet (the Windows ARM64 Rust toolchain is not set up in CI); ARM64
runs Electron-only until then.

## What WebView2 did that is now done elsewhere

| WebView2 | Now |
|---|---|
| Pages in a child `HWND` | Pages in Iris's own child `HWND`s (the presenter) |
| Its own profiles and cookies | Iris's shared session store (`core/session`), both engines |
| Its own downloads | Electron's downloads, reported over the socket (as on Linux) |
| Extensions in the engine | Extensions in the Electron helper (as on Linux) |
| SmartScreen / tracking prevention | Iris Shields (as on Linux); the HTTPS-only and sandbox rules are Iris's own |
| The installer fetched the runtime | Nothing to fetch: Electron and Servo ship inside the MSIX |

The installer (`setup/`) no longer downloads Microsoft's WebView2
bootstrapper: it downloads Electron's Windows build (the version from
`ELECTRON_VERSION`, or the latest Electron release) and copies Iris's helper
into it. The updater still serves copies installed by earlier Setup builds.

## Implementation (branch `windows-servo-electron`)

What the branch does, per file:

- `webview/winpresent/present_windows.go` (new subpackage): the presenter —
  one `IrisPage` child `HWND` per page view, GDI painting, pointer/wheel/key
  input, DPI scale, message-only window for `onMain`.
- `webview/registry_windows.go` (new): the Windows `wkView` table and engine
  choice, plus `vkFromChar` for the key names.
- `webview/engine_electron.go` split: the helper protocol, views, policy,
  downloads, extensions and memory watch stay shared; `electron_linux.go`
  (new) holds the Linux cgo glue and `/proc` readings, `electron_windows.go`
  (new) the presenter calls and Windows memory readings. The engine is
  chosen on Windows by `webview.New()` (tag `windows`), as on Linux.
- `webview/servo/servo.go` split the same way: shared code with platform
  hooks; `servo_linux.go` (new) the Linux cgo layer, `servo_windows.go`
  (new) + `servo_windows.c` (new) the Windows cgo layer, including the
  PR #11-equivalent scale refresh in `lsvBounds`.
- `cmd/iris/engine_windows.go`, `engine_windows_servo.go`, `engine_other.go`
  (new): the same engine selection as Linux — `route.Wrap(servo.New(...),
  webview.New(), rules.Open(conf))` with the `servo` tag, plain
  `webview.New()` without it. `host_gio.go` calls `newEngine(r.conf)`.
- `setup/install_windows.go`: downloads Electron instead of the WebView2
  bootstrapper; `setup/payload/README.md` documents `ELECTRON_VERSION` and
  the `electron-helper/` payload.
- `tools/msix.go`: repeatable `-extra` so the MSIX carries `electron/` (and
  `irisservo.dll` on x64).
- `build-iris.sh` / `build-iris.bat`: stage Electron per architecture from
  npm, build x64 with `-tags servo` + MinGW when `webview/servo/lib/
  irisservo.dll` exists, build ARM64 Electron-only, pack both MSIXes and
  the bundle. The ARM64 Servo DLL (aarch64-pc-windows-msvc via cargo xwin)
  is a separate follow-up build.
- Docs: README, PRIVACY.md, THIRD_PARTY_NOTICES.md, `docs/engines.md`,
  `packaging/STORE.md`, `cmd/iris/main.go`, `webview/api.go`, `shell/`
  (engine-missing message, About line, memory report) no longer say
  Windows uses WebView2. The old WebView2 files are deleted
  (`engine_windows.go`, `com_windows.go`, `extensions_windows.go`,
  `slots_windows.go`, `bounds_386/amd64/arm64.go`).
- Workflows: `servo-lib.yml` gains a Windows job (cargo-xwin MSVC build +
  MinGW import library, artifact `libirisservo-windows`); `release.yml`'s
  windows job builds it first (reusable workflow), then downloads the
  artifact, installs Node and MinGW, and runs `./build-iris.sh windows`.

WebView2 is deleted, not kept as a fallback: Electron (heavy) + Servo
(light) cover the pages, and extensions run in Electron's helper.

## What is not in this change

- **No D3D shared-texture path.** Frames are copied through the processor,
  as above. Measured on Linux at 9 MB a frame; the presenter copies only the
  rectangle that changed, as the GTK code does.
- **No IME (input-method) support in pages yet.** Typed text reaches pages
  through `WM_CHAR`; dead keys and IME composition do not, where WebView2
  handled them natively. That is the next input item.
- **No Windows CI smoke test.** The Electron workflow tests the engine on
  Linux (sway, headless); a Windows run (a real Windows runner driving the
  window) is still to be added. The Windows build is verified by
  cross-compilation (`GOOS=windows go build ./...`) and by the MSIX packing
  structurally, not by running it.
- **No Servo on ARM64** (see above).
- **No `IRIS_SCALE` change.** The override works the same on Windows.
