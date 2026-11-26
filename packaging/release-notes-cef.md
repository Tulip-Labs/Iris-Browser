Iris (Chromium) 2.6.0: Brave's ad-block engine, Mozilla add-on installer (preview), stricter privacy.

- **Brave's engine.** Ad and tracker blocking now runs on adblock-rust, the engine Brave's Shields use, from Iris's own Rust library (`core/`). On top of what blocked before it handles redirect stand-ins (a harmless replacement for a tracker's script), `$removeparam`, uBlock's cosmetic filters and scriptlets (resources refreshed every four days, lists as before). Until it is built after a list update, the previous matcher answers.
- **Privacy defaults.** Third-party cookies are blocked, WebRTC sends no UDP outside a proxy (`IRIS_WEBRTC=relaxed` lets calls use UDP, showing only your public address), and Chromium's ad APIs stay off.
- **Mozilla add-ons (preview, `IRIS_EXTENSIONS=1`).** On an add-on page of addons.mozilla.org, "Add to Iris" downloads the latest `.xpi` from Mozilla's API, checks it against Mozilla's SHA-256, unpacks it safely (no path outside its folder, no links, size limits) and reads its manifest (Manifest V2 and V3). On a Chrome Web Store page, a notice offers the same extension on Mozilla's site. **Add-ons are installed but not run yet**: background pages, content scripts and the `browser.*` bridge come in a later release, which is why this is off by default.
- Install needs Rust to build from source: the Flatpak does it.

**Install**
- `flatpak install --user --reinstall Iris-Cef-x86_64.flatpak`

---

Iris (Chromium) 2.5.0: DRM, Brave-style link cleaning and less tracking.

- **DRM (Widevine).** Iris never carries Google's CDM (its licence does not allow it): it copies the one an installed Chrome, Chromium, Brave, Edge, Vivaldi, Opera or Firefox already has into its own folder, and Chromium uses it from the next start. `IRIS_WIDEVINE_DIR` names a folder by hand, `IRIS_WIDEVINE=0` turns it off. In the Flatpak, only the browsers' CDM folders are readable (read-only), nothing else of theirs. Not tested against a live service here: tell me which site fails.
- **Debouncing and De-AMP.** Links through Facebook's, Instagram's, YouTube's, Slack's, LinkedIn's, Steam's, DuckDuckGo's and Bing's click redirectors, and Google AMP viewers, open the real page directly, on top of the Google results and tracking-parameter cleaning that were already there.
- **Less tracking, as Brave's Shields.** Chromium's advertising APIs are off (Topics, Protected Audience, attribution reporting, shared storage, private state tokens, related website sets), and WebRTC shows pages only the public address of your connection, never your local one.
- **Codecs.** Unchanged in this release: this Chromium plays VP8, VP9, AV1, Opus and Vorbis, not H.264, H.265 or AAC. Those are compiled into Chromium itself and cannot be added afterwards. `packaging/codecs.md` and the `cef-codecs` workflow build a CEF that has them (you run it once, on a large runner).

**Install**
- `flatpak install --user --reinstall Iris-Cef-x86_64.flatpak`

---

Iris (Chromium) 2.4.3: starts again after Iris closed on its own.

- A lock Chromium left in the profile when Iris closed or crashed is cleared when no Iris is running, so the next start works. If starting fails, the reason is printed in the terminal.

**Install**
- `flatpak install --user --reinstall Iris-Cef-x86_64.flatpak`

---

Iris (Chromium) 2.4.2: one Iris at a time, and no more blank pages.

- YouTube plays again: a script meant for the other engine hid the video formats this Chromium plays, and the ad blocker was not the cause.
- Links opened in a normal tab no longer show garbage characters: normal tabs now live in their own profile, made the way a container's is. You sign in again once.
- No made-up containers: none exist at the start; the docs said otherwise.

**Linux (Flatpak, `io.github.tulip_labs.Iris.Cef`)**
- **Opening Iris again works.** Starting it while it's already open (the launcher clicked again, `flatpak run` again, a link opened from another app) now opens a tab in the Iris you already have. Before, the second start failed with "Iris could not start its page engine".
- **No more blank pages on GPUs where Chromium sends no frames.** If a page has loaded and nothing has appeared 3 seconds later, Iris shows that tab with CPU frames and uses them from then on. `IRIS_CEF_GPU=1` tries the GPU again.

**Install**
- `flatpak install --user --reinstall Iris-Cef-x86_64.flatpak`

---

Iris (Chromium) 2.4.1: the page scripts work again.

**Linux (Flatpak, `io.github.tulip_labs.Iris.Cef`)**
- **Copy, paste, reader, the audio indicator, page shortcuts and tab freezing work.** In 2.4.0, every script Iris runs inside a page failed before it started. Odin's text formatting reads `{` as a placeholder, so each script came out with "%!(MISSING CLOSE BRACE)" in it. Separately, the marker on every answer was being dropped. Both are fixed, and CI now refuses a format string like that.
- **Background tabs really freeze now.** The message that freezes them was built the same broken way.

**Install**
- `flatpak install --user --reinstall Iris-Cef-x86_64.flatpak`

---

Iris (Chromium) 2.4.0: the Chromium build of Iris, now with releases of its own.

**Linux (Flatpak, `io.github.tulip_labs.Iris.Cef`)**
- **Its own releases.** Iris (Chromium) now ships on its own tags (`cef-v2.4.0`), apart from the WPE build and Android: a release here carries only `Iris-Cef-x86_64.flatpak` and its `SHA256SUMS`. It installs beside the WPE build (`io.github.tulip_labs.Iris`), which keeps its own releases.
- **Updates**: Iris (Chromium) checks these releases once a day and links to the new bundle when there is one: `flatpak install --user Iris-Cef-x86_64.flatpak` installs it over the old one.
- **Installing this one by hand (from 2.3.0).** Iris (Chromium) 2.3.0 looks for updates among the WPE build's releases and never sees these `cef-v` releases: download `Iris-Cef-x86_64.flatpak` once and run `flatpak install --user --reinstall Iris-Cef-x86_64.flatpak`. From 2.4.0 on it tells you itself.
- **On the GPU by default.** Chromium now draws pages on your graphics card (ANGLE on OpenGL, GPU rasterization, VA-API video) and hands each frame to Iris without a copy through the CPU: far less CPU while browsing and scrolling. If your GPU or driver gives trouble, start Iris with `IRIS_CEF_GPU=0` to go back to software drawing (`flatpak run --env=IRIS_CEF_GPU=0 io.github.tulip_labs.Iris.Cef`); Iris also falls back by itself, and remembers it, if your system cannot share frames with it.
- **Tabs you leave are frozen.** A tab out of sight stops its timers, animations and network work at once and costs next to no CPU; it is exactly as you left it when you come back (nothing reloads). Tabs playing sound or video, with a live connection (chats, calls), downloading, asking before you leave, or a sign-in pop-up open are never frozen (`IRIS_CEF_FREEZE=0` turns freezing off).
- **Light tabs sleep after 10 minutes.** An article or documentation page you have not looked at for 10 minutes gives its memory back; Iris keeps its picture, address and scroll position and loads it again when you return (its back/forward history starts over). Anything with typed text, a session, media, a web app or a pop-up stays awake (`IRIS_CEF_SLEEP=0` turns sleeping off).
- Still experimental: CEF 156 (Chromium 156), no H.264/AAC, no input methods yet, and Chromium's own sandbox is off inside the Flatpak (pages run in Flatpak's sandbox).
