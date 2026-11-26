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
