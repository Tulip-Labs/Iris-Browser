# H.264, H.265, AAC and DRM in Iris (Chromium)

## What is and is not possible

- **Free codecs** (VP8, VP9, AV1, Opus, Vorbis, FLAC, MP3, WebM, MP4 with those): in every CEF.
- **H.264, H.265, AAC**: compiled into Chromium's media library, which is inside `libcef.so`. They cannot be added to a CEF that was built without them (no `libffmpeg.so` swap as in Electron or NW.js: CEF has no separate one). They need a CEF built with `proprietary_codecs=true ffmpeg_branding=Chrome`. Those codecs are patented; shipping a build that has them can need licences (MPEG LA/Via LA pools, Access Advance for H.265). That decision is yours as the publisher. Iris (WebKit) plays them today through the system's GStreamer.
- **DRM (Widevine)**: Google's licence does not allow another browser to ship the CDM. Iris copies the one from an installed Chrome, Chromium, Brave, Edge, Vivaldi, Opera or Firefox (`src/cef_drm.odin`). Without proprietary codecs, many Widevine services still fail (their streams are H.264), so DRM and the codec build go together.

## Building a CEF with the codecs

The free GitHub runners cannot do it (14 GB of disk; it needs 150 GB, 32 GB of RAM, hours). Use a larger runner or your own machine:

1. Make a larger runner (Settings, Actions, Runners) with 150 GB+ of disk and 32+ cores, or register a self-hosted one, and give it a label, for example `cef-big`.
2. Run the workflow **cef-codecs** (Actions tab), giving that label. It publishes `cef_binary_..._minimal.tar.bz2` and its SHA-256 to a release `cef-codecs-<version>`.
3. `sh packaging/flatpak/use-codecs.sh URL SHA256`, then build the Flatpak as usual.

The workflow was written without being run (it needs that runner): the first run may need small fixes.
