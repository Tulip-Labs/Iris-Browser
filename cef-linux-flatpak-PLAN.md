# Iris on Linux with CEF: the Flatpak beside WPE — plan

Date: 2026-11-24. Base: origin/main at `c363bb7` (CEF smoke test merged,
PR #29). Ordered by Cesar 2026-11-24 21:47: build Iris with CEF as a
separate Flatpak beside the WPE build, with GitHub Actions doing the heavy
lifting. WPE is not replaced — Cesar tests the CEF build first.

Read `cef-linux-retry-INVESTIGATION.md` first for the costs: Shields is the
biggest rewrite, stock CEF has no H.264/AAC, the bundle grows from ~39 MB
to ~150–250 MB, and the renderer sandbox must be off inside the Flatpak
(`no_sandbox`). This plan is the sequence that pays those costs in order,
each slice proven by CI before the next starts. Nothing here ships until
Cesar tests it on real hardware.

## Ground rules (all slices)

- **WPE is the default and stays untouched** until a slice says otherwise.
  The WPE build, its Flatpak (`Iris-x86_64.flatpak`) and its CI keep
  passing on every slice. A slice that breaks them is reverted.
- **Actions does the heavy lifting.** The full CEF download, build and run
  cycles run in GitHub Actions. Local work is typechecks, the ABI check,
  tiny compiles and the smoke harness (the CEF tree is already extracted
  in `experiments/cef-smoke/` for that). Keep log excerpts tiny; stop at a
  second distinct failure mode and report it.
- **No push from the VM.** Commits land locally on `cef-linux-flatpak`
  and are pushed by the parent via the browser route (workflow files
  block the connector snapshot push). A slice is "done" when its commits
  are local AND its CI is green on the pushed branch.
- **The tab-close guarantee is a release gate, not a nice-to-have.**
  Cesar's hard requirement, proven in the smoke test: a closed tab really
  dies. The rules live in `linux/src/cef/README.md` and in the code:
  one `CefRequestContext` per tab (its own renderer), `CloseBrowser`
  with force, every reference dropped in `OnBeforeClose`, tabs matched
  by browser identifier, never by pointer (CEF hands `OnBeforeClose` a
  different wrapper than `OnAfterCreated`). There is no
  `--process-per-tab` switch in CEF 156.
- **Version 2.2.7 belongs to the CEF build.** The WPE build stays 2.2.6
  until it moves too. The version bump (and what `versions.sh` checks
  for a two-flavor Linux) is slice 4 work, not slice 1.

## The seam (why slice 1 looks the way it does)

The browser talks to a page through two things, both in `linux/src`:

- `Page` (`platform.odin`): the frame as a GL texture (`tex`), and the
  input it is sent (`page_place`, `page_set_visible`, `page_focus`,
  `page_pointer`, `page_key`), plus `on_frame` / `on_cursor` /
  `on_fullscreen` callbacks. The WPE implementation feeds it from DMA-BUF
  frames or, for software frames, from BGRA bytes via `texture_upload`
  — that BGRA path is exactly where a CEF `OnPaint` frame goes.
- `Tab` (`tab.odin`): navigation and state on `Tab.web`
  (`^WebKitWebView`) — load, back, forward, reload, stop, zoom, run JS —
  plus the signal wiring in `tab_connect`.

So the engine is a second implementation of that surface, not a rewrite
of the browser. Slice 1 builds it as its own Odin package,
`linux/src/cef/` (`package cef`), and proves it with the smoke harness
rewritten as a thin client of that package. The browser keeps using WPE
until slice 2 wires the seam in.

The chrome needs no engine work: it is Odin-drawn (`chrome.odin`), not a
web view. What does need a CEF equivalent, in slice 2, is everything
`Tab` and `Browser` currently ask WebKit for: navigation, JS eval with a
result, find, dialogs, permissions, file chooser, context menu, pop-ups,
downloads, favicon.

## Slices

### Slice 1 — the engine seam (this task)

- `linux/src/cef/`: the CEF C API bindings (`cef.odin`, `cef_gen.odin`
  via `tools/bind.py`, `cef.txt`), and `engine.odin` — `Engine` +
  `Browser`: init/shutdown, one browser per tab with its own request
  context, load/back/forward/reload/stop, zoom, resize/hide/focus,
  mouse/key/wheel input, fire-and-forget JS, find, frames as BGRA bytes
  with an `on_frame` callback, title/URL/loading/cursor/fullscreen
  callbacks, close with the tab-close rules. The engine hands the
  caller BGRA bytes; the renderer owns the texture (the same split as
  WPE's software-frame path).
- `experiments/cef-smoke/main.odin` rewritten as a thin harness over
  that package (same two scenarios, same PASS lines: tab close frees
  memory, one settled frame). The old smoke-test bindings move into
  `linux/src/cef/`; nothing is duplicated.
- `.github/workflows/cef-smoke.yml` updated to the new paths (bindings
  regen + ABI check against `linux/src/cef/`, build + run the harness,
  `odin test` of the `cef` package), and its push trigger widened to
  all branches like `linux.yml`.
- Proves in CI: bindings regenerate identically, ABI check passes, the
  harness passes both scenarios. No Iris code changes, no Flatpak
  changes, WPE untouched.

### Slice 2 — the Tab seam and the browser flag — DONE (local commits c992ef3 + the seam commit below; CI still to prove)

- `Tab` holds a page that can be WPE or CEF: the `Page` surface grows
  a CEF implementation fed by `linux/src/cef`, and `tab_*` navigation
  calls go through it. The chrome, history, containers and session
  code do not change; they only ever see `Tab` and `Page`.
- Engine choice at startup (`--engine=cef`, default WPE) so both
  builds are the same binary until the Flatpak split in slice 4.
  `main.odin` gains the subprocess re-exec (`CefExecuteProcess` first,
  before anything else — subprocesses re-enter `main`) and the
  `cef_api_hash` call.
- Input mapping (`plat` events → CEF event flags, key codes, mouse
  buttons), JS eval **with a result** (decided: a console-message
  round-trip — the code runs as an expression inside a wrapper that
  prints `[iris-eval:N]` + the value; see `eval_js`), favicon via
  the display handler (URL from the engine, bytes fetched by the
  browser over libsoup, PNG/JPEG decoded, ICO left blank).
- Decisions that differ from the first draft of this plan:
  - **The stub ships with the WPE build.** The first draft said the
    WPE binary never needs libcef.so at run time (`--as-needed`
    drops the DT_NEEDED). That is wrong, verified by a linker
    experiment: a reference in dead code still records DT_NEEDED,
    and the binary refuses to start without the file. The WPE
    binary links libcef and needs it at run time, so the stub
    (`linux/cef-stub.c`, inert — loaded, never called) ships with
    the WPE build and its Flatpak (`build.sh install` puts it in
    `/app/lib`). The alternative (dlopen at run time, only in CEF
    mode) is a bigger redesign and was not taken.
  - **The CEF frame is uploaded in the Page's on_frame callback**
    (`texture_upload` of the engine's BGRA buffer, on the pump
    thread while the GL context is current) — the renderer never
    sees the engine's buffer directly.
  - **A closing CEF tab frees asynchronously**: `tab_free` asks
    the engine to close it and returns; the engine's `on_close`
    frees the Tab then (directly when the tab is already out of
    `b.tabs`, via `browser_close_later` when the page closed
    itself). The engine's nav procs guard on `browser == nil`, so
    calls before creation return false instead of crashing.
  - `--cef-check` is the headless proof (one browser, example.org,
    title + `1+1` evals + a settled 800x600 frame), not a Weston
    GUI run — the render-check draws nothing in this mode, because
    there is no GL context before a window exists.
- Proves in CI: both engines build; the CEF binary starts headless,
  loads a page, and `--cef-check` passes (load + title + eval +
  frame). The smoke job's tab-close check still passes. WPE jobs
  stay green.
- Deferred to slice 2b (same slice, second commit): dialogs (JS,
  file chooser, permissions, context menu, option menu), find UI,
  downloads via `CefDownloadHandler`, pop-ups via
  `OnBeforePopup`/`OnAfterCreated` as a related tab.

### Slice 3 — Shields for CEF

- The list parsing in `rules.odin` is reused; the matching engine is
  new: a matcher evaluated per request in
  `CefRequestHandler::OnBeforeResourceLoad` (same ~12 µs/request
  budget as Android's shield), plus cosmetic hiding as injected CSS/JS
  at document start (`CefFrame::ExecuteJavaScript`).
- `shields_apply` grows a CEF path beside the WPE content-rule path;
  the level/host API (`shields_on_for`, `host_blocked`) does not change.
- Proves in CI: matcher unit tests, plus a headless load of a known
  ad-heavy page asserting the blocked requests never leave.

### Slice 4 — the Flatpak and version 2.2.7

- New app id (proposed: `io.github.tulip_labs.IrisCEF`, launcher name
  "Iris CEF", file `IrisCEF-x86_64.flatpak`), new manifest
  `packaging/flatpak/io.github.tulip_labs.IrisCEF.yml`: a `cef` module
  (download + unpack the pinned minimal tarball) replaces the
  `wpewebkit` module; `ffmpeg-full` drops out (CEF does not use
  GStreamer); `no_sandbox` and the subprocess layout documented
  (libcef.so + `Resources/icudtl.dat` + `*.pak` next to the binary in
  `/app/libexec`, since CEF resolves ICU data from the libcef.so
  directory); cache/state paths namespaced so the two builds never
  share a profile.
- Version 2.2.7 for the CEF build; `versions.sh` and the release
  workflow learn the two-flavor Linux.
- New CI job (or workflow) that builds the CEF Flatpak and starts it
  under headless Weston.
- Proves in CI: the Flatpak builds, installs, and starts.

### Slice 5 — the tab-close check, on the real build

- The smoke test's measurement ported to the real CEF Flatpak: open 3
  tabs under headless Weston, close 2, assert the CEF process tree
  shrinks and total RSS falls (same thresholds as the smoke test).
- This is the release gate for 2.2.7. If it fails, the release does not
  happen — the WPE bug must not recur in CEF form.

### Slice 6 — polish and the device test (only on Cesar's word)

- H.264/AAC regression disclosed in the release notes (YouTube falls
  back to VP9; H.264-only video fails; no CI-feasible fix — building
  CEF from source is out of scope).
- The sandbox story written down honestly: renderer sandbox off inside
  the Flatpak, Flatpak bubblewrap + ephemeral request contexts as the
  remaining isolation.
- Find/dialogs/downloads parity pass, then Cesar's device test
  (page loads, typing, video, Shields on an ad-heavy page, sandbox
  site isolation). Only after it passes is any replacement of WPE
  discussed — and only if he orders it.

## What is deliberately not in this plan

- Building CEF/Chromium from source (for proprietary codecs or
  anything else): multi-hour builds no CI here can carry.
- Replacing WPE, merging the two Flatpaks, or touching the WPE
  Flatpak/manifest/CI: none of that happens in any slice.
- A release of anything: 2.2.7 ships only after slice 5 passes and
  Cesar says so.
