Iris (Chromium) 2.4.0: the Chromium build of Iris, now with releases of its own.

**Linux (Flatpak, `io.github.tulip_labs.Iris.Cef`)**
- **Its own releases.** Iris (Chromium) now ships on its own tags (`cef-v2.4.0`), apart from the WPE build and Android: a release here carries only `Iris-Cef-x86_64.flatpak` and its `SHA256SUMS`. It installs beside the WPE build (`io.github.tulip_labs.Iris`), which keeps its own releases.
- **Updates**: Iris (Chromium) checks these releases once a day and links to the new bundle when there is one: `flatpak install --user Iris-Cef-x86_64.flatpak` installs it over the old one.
- Still experimental: CEF 156 (Chromium 156), no H.264/AAC, no input methods yet, and Chromium's own sandbox is off inside the Flatpak (pages run in Flatpak's sandbox).
