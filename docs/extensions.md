# Mozilla Add-ons in Iris (Chromium)

Iris (`Iris.Cef`) supports Mozilla Add-ons (`.xpi`) from [addons.mozilla.org](https://addons.mozilla.org/), for both Manifest V2 and Manifest V3 extensions, without the Chrome Web Store (no `.crx`, no `chrome.webstorePrivate`).

## Status in 2.6.0 (preview)

| Piece | State |
|---|---|
| "Add to Iris" on addons.mozilla.org pages: download from Mozilla's API, SHA-256 check, Zip-Slip-safe unpack, `manifest.json` (V2 and V3) read | Built and tested (`core/`, `linux/src/extensions.odin`) |
| Notice on Chrome Web Store pages with a button to the same extension on Mozilla's site | Built |
| Running add-ons: background pages and service workers, content scripts, the `browser.*` / `chrome.*` bridge, toolbar icons and popups, `contextualIdentities` to Containers | **Not built yet** |

It is off unless `IRIS_EXTENSIONS=1`, because installing an add-on that cannot run yet would only mislead. The rest of this page describes what Iris is built to support once the runtime lands.

## What works (target)

Almost all standard WebExtensions: ad and tracker blockers (such as uBlock Origin), password managers (Bitwarden, KeePassXC-Browser), page modifiers (Dark Reader, Stylus, SponsorBlock, Vimium), and container tools mapped to Iris's native Containers.

## What doesn't work

Iris draws its own native Wayland/OpenGL ES interface on top of a Chromium engine rather than Firefox's Gecko UI, so add-ons that depend on Firefox-exclusive internals are not supported:

- Firefox UI and sidebar extensions (`browser.theme`, `browser.sidebarAction`: Tree Style Tab, Sidebery)
- Mozilla account and sync integrations (Firefox Sync, Pocket, `about:` page overrides)
- Gecko-only experimental APIs (`browser.experiments.*` and the low-level `filterResponseData` stream hooks)

## How installs are kept safe

- Only addresses on `addons.mozilla.org` (and its CDN) are downloaded, over https, and only when Mozilla's API gives a SHA-256 for the file; the download must match it.
- Unpacking refuses any entry that would land outside the add-on's folder (`..`, absolute paths, backslashes, symbolic links), caps the entry count and the unpacked size, and moves the finished folder into place whole.
- The Rust code (`core/`) is a static library behind a flat C interface (`core/include/iris_core.h`, bound in `linux/src/core_ffi.odin`): only plain C types cross it, every pointer is checked for null, every opaque pointer has a `_create`/`_build` and a `_destroy`.
