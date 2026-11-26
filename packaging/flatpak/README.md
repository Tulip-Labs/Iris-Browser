# Iris as a Flatpak

`io.github.tulip_labs.Iris.Cef.yml` builds Iris (Chromium), app ID
`io.github.tulip_labs.Iris.Cef`: the Odin app from `linux/` (Wayland, EGL and
OpenGL ES, no GTK) with Chromium, through CEF, as its page engine. It uses the
GNOME 50 SDK, and CEF 156.0.32 from its minimal binary distribution,
downloaded rather than built: the bundle builds in minutes. libcef.so, its
`.pak` files, `icudtl.dat` and `locales/` go to `/app/lib/iris-cef` (CEF reads
the ICU data from libcef.so's folder). Iris itself is built with
`CEF_DIR=... linux/build.sh release`.

CI builds it on every push (`.github/workflows/linux.yml`, jobs `odin-cef` and
`flatpak-cef`), and each release (tags `cef-v*`) carries the bundle,
`Iris-Cef-x86_64.flatpak`:

    flatpak install --user Iris-Cef-x86_64.flatpak

The bundle needs the GNOME 50 runtime, which Flatpak installs from Flathub
when the Flathub remote is set up (`flatpak remote-add --if-not-exists --user
flathub https://dl.flathub.org/repo/flathub.flatpakrepo`).

To build it yourself:

    flatpak install --user flathub org.gnome.Sdk//50
    flatpak-builder --user --install --force-clean build packaging/flatpak/io.github.tulip_labs.Iris.Cef.yml

## Flathub

Every source in the manifest is fixed by checksum or commit, and
Flathub asks that manifests and submissions be made by people, not AI tools.
That submission is for a person on the team to prepare.

## The page sandbox

Pages run inside Flatpak's sandbox. Chromium's own renderer sandbox is off
(`no_sandbox`): it needs a setuid helper or user namespaces, which a Flatpak
has neither of.

## Glass and the compositor

The window is translucent. Where the compositor offers background blur
through the `ext-background-effect-v1` protocol (niri 26.04 and newer, and
others that adopt it), Iris asks for it, shaped like the window; elsewhere
the window stays nearly solid.

## Its own releases (tags `cef-v*`)

Iris for Linux is delivered apart from Android: a tag
`cef-vX.Y.Z` runs `.github/workflows/release-cef.yml`, which builds this
Flatpak (linux.yml's `odin-cef` and `flatpak-cef` jobs) and publishes a
release "Iris (Chromium) X.Y.Z" with only `Iris-Cef-x86_64.flatpak` and
`SHA256SUMS`, its notes from `packaging/release-notes-cef.md`. It is never
marked latest, so Android's update check
(`releases/latest`) never sees it; Iris (Chromium) looks for the newest
`cef-v*` release itself and links to its bundle. Its version is
`CEF_VERSION` in `linux/src/version_cef.odin`; `packaging/check/versions-cef.sh`
checks it against the notes and the tag.

    # CEF_VERSION and the top line of release-notes-cef.md say 2.4.0
    sh packaging/check/versions-cef.sh cef-v2.4.0
    git tag cef-v2.4.0 && git push origin cef-v2.4.0

CI also runs Speedometer 3.1 in this Flatpak and in Google Chrome (job
`bench`, informational) and puts both scores and their ratio in the job
summary. Runners have no GPU, so both draw in software: the ratio is Iris's
overhead next to Chrome, not a real-world score. Iris runs it through
`IRIS_CEF_BENCH_URL=<url>`: it loads the page, waits for the score, prints
`SPEEDOMETER <score>` and exits.

The tarball's sha256 in the manifest is a placeholder until CI prints the
real one (job `flatpak-cef`, as a warning): pin it then.

What to know about it:

- **Chromium's renderer sandbox is off** (`no_sandbox`): see above. Renderers
  run inside Flatpak's sandbox only.
- **No H.264/H.265/AAC**: CEF's binaries ship Chromium's ffmpeg without the
  proprietary codecs (VP9, AV1 and Opus play; YouTube works). The
  ffmpeg-full extension cannot help (Chromium does not use GStreamer).
- Pages are drawn on the GPU: Chromium hands Iris each frame as a DMA-BUF,
  copied on the GPU into the page's texture, with no pixel through the CPU.
  `IRIS_CEF_GPU=0` goes back to software frames (SwiftShader, copied on the
  CPU: more CPU).
- Much larger: libcef.so alone is a few hundred MB.

How a closed tab's memory comes back: every normal tab shares one request
context (one cookie jar, so a sign-in is everywhere; containers, private
tabs and each sandboxed tab have their own). A context per tab would also
force a renderer per tab, but would split sign-ins, so instead Chromium
runs with `--site-per-process`, each renderer reports its pid to the
browser process, the tab is closed with `CloseBrowser(force)` and every
reference to it goes in `OnBeforeClose` (matched by browser id). A few
seconds later each pid the tab reported that is still alive, still Iris's
own descendant and used by no open tab is killed. Same-site tabs that
Chromium put in one renderer keep it until the last of them closes.
