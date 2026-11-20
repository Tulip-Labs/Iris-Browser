<p align="center">
  <img src="assets/icon.png" width="112" alt="Iris">
</p>

<h1 align="center">Iris</h1>

<p align="center"><i>Formerly Lite Go. Iris is the Greek goddess of the rainbow, who carries light between worlds.</i></p>

<p align="center">
  <b>A light, fast browser written in Go.</b><br>
  One light Liquid Glass interface, drawn with Gio and sharp at every display scale.<br>
  Pages: WebKitGTK and Electron on Linux; Electron on Windows. Every search asks Google AI Mode.
</p>

<p align="center">
  <img alt="Go" src="https://img.shields.io/badge/Go-1.24-00ADD8?style=flat-square&logo=go&logoColor=white">
  <img alt="Interface: Gio" src="https://img.shields.io/badge/interface-Gio-8A3FA0?style=flat-square">
  <img alt="Windows 10 and 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square">
  <img alt="Linux: Wayland and X11" src="https://img.shields.io/badge/Linux-Wayland%20%7C%20X11-333333?style=flat-square&logo=linux&logoColor=white">
  <img alt="License: GPL 3.0" src="https://img.shields.io/badge/license-GPL%203.0-6B7280?style=flat-square">
</p>

<p align="center">
  <a href="#whats-new-in-1025">New</a> ·
  <a href="#what-it-does">Features</a> ·
  <a href="#shortcuts">Shortcuts</a> ·
  <a href="#platforms">Platforms</a> ·
  <a href="#build">Build</a> ·
  <a href="#how-it-is-made">How it is made</a>
</p>

<p align="center">
  <img src="assets/screens/glass.png" width="860" alt="Iris in light Liquid Glass: the new tab page">
</p>

---

## What's new in 1.0.25

- **Liquid Glass, light.** One look for the whole browser: frosted white panes with bright rims over an airy backdrop, near-black text, colorless glass controls and a soft blue focus ring. The palettes and their chooser are gone.
- **Every search asks Google AI Mode,** with an instruction to answer from high-quality, authoritative and current sources, cite them, and stay clear, precise and concise. The address bar shows only your words. Iris's own results page and its filters over Google are gone.
- **Backgrounds.** Six built-in backdrops behind the glass (Sky is the default), a plain one, or your own picture: Menu, Look, Background.
- **Linux: WebKitGTK and Electron.** Most pages are drawn by WebKitGTK (the engine of GNOME Web); video, social sites, web apps and sign-ins go to Electron (Chromium with H.264, H.265 and AAC). One cookie store is shared both ways, so a sign-in in one engine works in the other. Shields run in WebKit as compiled content rules. Servo and Chromium (CEF) are gone. Flatpak, Snap and Nix all carry the new engines.
- **Windows: Electron.** Electron replaces WebView2 and comes inside the installer, the portable zip and the MSIX, so Iris no longer depends on the system's Edge runtime.
- **Sharp on Linux.** The interface reaches the screen pixel for pixel at scales 1 to 2 (it used to go through sRGB twice and look washed out and soft).

## Why Iris

Most browsers spend your memory on their web engine without asking what each page is worth.
Iris puts a small Go program around the engines (WebKitGTK and Electron on Linux, Electron
on Windows) that decides what each page may cost and which engine draws it.

<table>
<tr>
<td width="33%" valign="top">

**Light**

A background tab rests within a minute: its page closes and its memory goes back, and it comes back where you left it. A closed tab frees its memory at once. Nothing runs in the background.

</td>
<td width="33%" valign="top">

**Fast**

Compact tabs on top, one slim bar under them, and a new tab page drawn by Iris itself:
the name and a search, nothing else.

</td>
<td width="33%" valign="top">

**Clean**

Ads, trackers, cookie notices and tracking links are removed. Every search is answered by
Google AI Mode from the best current sources. No bookmarks, no tiles, no feeds.

</td>
</tr>
</table>

## A look

<table>
<tr>
<td width="50%"><img src="assets/screens/new-tab.png" alt="The new tab page"></td>
<td width="50%"><img src="assets/screens/split-view.png" alt="Split view"></td>
</tr>
<tr>
<td align="center"><sub><b>New tab.</b> The name and a search.</sub></td>
<td align="center"><sub><b>Split view.</b> Two pages, one divider to drag.</sub></td>
</tr>
<tr>
<td width="50%"><img src="assets/screens/downloads.png" alt="The downloads list"></td>
<td width="50%"><img src="assets/screens/sandbox.png" alt="A page stopped, with the sandbox offered"></td>
</tr>
<tr>
<td align="center"><sub><b>Downloads.</b> A ring on the icon, a list at the side.</sub></td>
<td align="center"><sub><b>Sandbox.</b> Unsafe addresses are stopped first.</sub></td>
</tr>
<tr>
<td width="50%"><img src="assets/screens/ai.png" alt="Ask AI: Google AI Mode's answer beside the page, with its sources"></td>
<td width="50%"><img src="assets/screens/tabs.png" alt="The tabs on top"></td>
</tr>
<tr>
<td align="center"><sub><b>Ask AI.</b> Google AI Mode beside any page, with its sources.</sub></td>
<td align="center"><sub><b>Tabs.</b> A compact strip on top, centered.</sub></td>
</tr>
<tr>
<td width="50%"><img src="assets/screens/menu.png" alt="The menu"></td>
<td width="50%"><img src="assets/screens/search.png" alt="Typing a search: Ask Google AI Mode"></td>
</tr>
<tr>
<td align="center"><sub><b>The menu.</b> Tools, then the settings in sections that open in place.</sub></td>
<td align="center"><sub><b>Search.</b> Every search asks Google AI Mode.</sub></td>
</tr>
</table>

<table>
<tr>
<td width="33%"><img src="assets/screens/android-results.png" alt="Iris results on Android"></td>
<td width="33%"><img src="assets/screens/android-palettes.png" alt="The palettes on Android"></td>
<td width="33%"><img src="assets/screens/android-new-tab.png" alt="Private and container tabs on Android"></td>
</tr>
<tr>
<td align="center"><sub><b>Iris for Android.</b> Iris results.</sub></td>
<td align="center"><sub>Eleven palettes.</sub></td>
<td align="center"><sub>Hold + for private and container tabs.</sub></td>
</tr>
</table>

<sub>The desktop pictures are drawn by the test suite with Iris's software renderer (page areas
and thumbnails are placeholders) and refreshed by CI (`.github/workflows/screens.yml`) whenever
the interface changes; the Android ones come from an emulator.</sub>

## What it does

### Browsing

| | |
|---|---|
| **Search** | Words typed in the address bar or on the new tab page open Google AI Mode in the tab, with a short instruction after them: answer from high-quality, authoritative and up-to-date sources (official sites, documentation, peer-reviewed research, reputable news), cite them, and be clear, precise and concise. The address bar and the tab show only your words. Type `yt ` before words to search YouTube. |
| **The look** | Liquid Glass, light: frosted white panes with bright rims over an airy backdrop, near-black text, colorless glass controls, and Apple's system blue only for the ring around what has the keyboard. One look, no palettes to pick. |
| **Websites in new tabs** | A result, an address typed while a site is open, or a link to another website opens in a new tab beside the one you are on. Back from its first page (or closing it) returns there. Sign-in steps stay in their tab. |
| **Ask AI** (Ctrl+J) | On any page, a side panel sends your question and the page's text (or your selection) to Google AI Mode and writes the answer with its sources. No API key. |
| **Split view** | Two pages side by side. The pane you click takes the keyboard and the address bar. |
| **Downloads** | A toolbar icon with a progress ring; a list with speed, time left, pause, resume, cancel, open and show in folder. |
| **One slim bar** | Back, forward and reload at the left, the address in the middle, then the shield and the menu. It narrows to what is needed on a small window. A Sign in button shows only while Iris is not signed in to Google. |
| **The menu** | Tools (private tab, history, downloads, reopen, split view, find, print, free memory), zoom, your name for the AI answers, and the settings in sections that open in place: containers, extensions, memory, history and data, about and updates. |
| **The usual** | Find in page, zoom, print, a searchable history by day, reopen a closed tab, and the last tabs brought back at start (unloaded until you open them). |
| **Tabs** | A compact strip on top, centered, above the bar; tabs shrink to their icons as more open, and the strip scrolls with the wheel when they do not fit. The arrow beside + opens private, temporary, sandbox and container tabs. Containers keep their own sign-ins, each with an icon and a color. |

### Memory

| | |
|---|---|
| **The plan** | Background tabs are hidden at once and rest soon after (20 seconds on Saver, a minute on Balanced, ten on Speed): the page closes and gives its memory back, keeping its address, title and scroll position, so it comes back where it was (hydration). A closed tab frees its memory at once. Tabs playing sound or video (and for ten minutes after they pause) and YouTube tabs never rest. Chromium itself is trimmed: pages of one site share a process, at most three page processes run on 8 GB or less (five above), the back-and-forward page cache and Chromium's background services (updates, translate, media routing, crash reports) are off, and only the changed part of each frame is copied. Nothing is prepared ahead of time and nothing keeps running once the window closes. |
| **The balancer** | The tab in front (both, in split view) has priority. Every other page is told at once that nobody is looking, so the engine gives memory back. When the pages pass the budget, or the computer runs short, background pages sleep and then unload, oldest first. |

### Iris Shields

| | |
|---|---|
| **Filter lists** | EasyList, EasyPrivacy and uBlock filters, about 110,000 rules matched in microseconds, refreshed every few days, plus a built-in list of 100,000 domains. |
| **Adaptive** | A site is scanned on its first visits. Where three scans find nothing, the shield stands by and the site's requests go straight to the network; where something is found, it stays on. Clean sites are scanned again every 15 visits or three days. |
| **What ads leave behind** | Empty boxes and cookie notices are hidden. Tracking parameters are cut from links, tracking redirects skipped, AMP pages opened at the source. |
| **Fingerprinting** | Canvas, audio and hardware details vary slightly per site and session. Sign-in and human-check pages are left alone. |
| **Videos** | Iris plays what its Electron plays: VP9, AV1 and VP8 video with Opus and Vorbis sound (YouTube and most sites), and H.264 and H.265 video with AAC sound (some LinkedIn, X and news videos), which Electron's Chromium builds carry. |
| **YouTube** | YouTube shows a warning when it sees an ad blocker, so on YouTube the shield blocks nothing and Iris does not touch the player's data. When an ad starts, Iris mutes it, plays it at 16× to its end and presses Skip; the video then goes on with its own sound and speed. The ad boxes around the videos are hidden, and if the warning still comes, it is closed and the video resumes. YouTube tabs never rest. |
| **Never broken** | Sign-in, messaging, human checks and YouTube playback are never blocked. Pictures, video, style sheets and fonts always load: the shield checks scripts and data requests, where ads and trackers start, and never blocks a whole hosting network. |

### Safety

| | |
|---|---|
| **HTTPS-only** | Addresses go straight to HTTPS. A site without it is stopped before it loads. |
| **Sandbox** | A site without HTTPS, or an address that looks dangerous (a known name on someone else's site, a real site hidden behind an `@`, a bare network address, look-alike letters), can be opened in a throwaway session: no downloads, no camera, microphone, location, notifications or clipboard, nothing saved, wiped when the tab closes. The check reads the address only; it is not a malware scanner. |
| **Checks itself** | At every start Iris compares its program file with the SHA-256 recorded at install and warns if they differ. This catches accidents and careless changes. The Store package is stronger: Windows keeps it read-only and verifies it. |
| **Private by kind** | Private tabs share one session never written to disk. A temporary tab is a fresh session of its own. History is never kept for either. |

## Shortcuts

| Keys | Action | Keys | Action |
|---|---|---|---|
| `Ctrl` `T` | New tab | `Ctrl` `F` | Find in page |
| `Ctrl` `Shift` `N` | Private tab | `Ctrl` `H` | History |
| `Ctrl` `W` | Close tab | `Ctrl` `P` | Print |
| `Ctrl` `Shift` `T` | Reopen closed tab | `Ctrl` `Shift` `S` | Split view |
| `Ctrl` `L` | Address bar | `Ctrl` `Shift` `D` | Downloads |
| `Ctrl` `J` | Ask AI | `Ctrl` `+` `-` `0` | Zoom |
| `Ctrl` `Tab` | Next tab | `Ctrl` `M` | Mute tab |
| `Ctrl` `1`...`9` | Go to tab | `Alt` `Left` / `Right` | Back, forward |
| `Ctrl` `R` / `F5` | Reload | `F11` | Full screen |
| `Ctrl` `,` | Menu | | |

They work while a page has the keyboard too.

## Platforms

| System | Web engine | Status |
|---|---|---|
| Windows 10 and 11 (x64, ARM64) | Electron (Chromium with H.264 and AAC), carried by Iris; the program itself stays pure Go (no cgo) | New in 1.0.25: built on every push and started on a Windows runner, where Electron must draw a test page. Still needs a pass on a real PC. |
| Linux on Wayland (niri, KDE, Sway, Hyprland and others) | WebKitGTK 6 for most pages, Electron (Chromium with H.264 and AAC) for video, social sites, web apps and sign-ins; one shared cookie store | Built on every push; the Flatpak is installed and started on Wayland, and Iris is checked at a fractional scale (1.25), where the interface reaches the screen pixel for pixel. Packages: Flatpak, Snap and Nix. |
| Android 10 and newer (64-bit) | Chromium, carried by the app (CEF for Android, through Cefrium) | **Iris for Android**, a separate app in Kotlin (`android/`): the desktop's light Liquid Glass and its six backgrounds, the desktop's tab strip on top, shields, containers, phone and tablet layouts, and sync with the computer. `Iris-android.apk` is in each release. |

Iris carries its own Electron (Chromium, with H.264 and AAC) on both systems, and each release
brings the newer one. On Linux, WebKitGTK comes from the GNOME runtime (Flatpak), the Snap
itself or nixpkgs, and runs its web processes in a bubblewrap sandbox. The Nix package uses
nixpkgs' WebKitGTK and Electron.

On Linux the window is a GTK window, because Wayland does not let one program's surface sit
inside another's. GTK owns the window, Gio's GPU renderer draws the interface into a GL area
in it. WebKitGTK pages are GTK widgets placed in that window, with rounded corners; Electron
draws its pages off screen, and Iris paints them into their area and passes them the
pointer, the wheel and the keys. One window, one connection to the display. Chrome
extensions run in the Electron engine; the shields do the work of an ad blocker in both.

## Install on Windows

```
winget install TulipLabs.Iris
```

Or download `Iris-Setup.exe` from the [releases](https://github.com/Tulip-Labs/Iris-Browser/releases) (installs for the current user, no administrator rights; `Iris-Setup.exe --silent` installs without a window). Iris updates itself; `winget upgrade TulipLabs.Iris` works too.

Extensions from the Chrome Web Store run in Iris on Windows (Electron draws every page there): open an extension's page in the store and choose **Add to Iris**. Iris checks each package's signature before adding it.

## Install on Linux

Iris for Linux comes as a Flatpak, a Snap, a Nix package or a container image. It needs a Wayland session.

**Flatpak** (every distribution, Fedora Atomic, SteamOS, Mint and Ubuntu included): download `Iris-x86_64.flatpak` from the [latest release](https://github.com/Tulip-Labs/Iris-Browser/releases/latest), then

```sh
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user Iris-x86_64.flatpak
```

(The first line lets Flatpak fetch the GNOME 50 runtime Iris runs on.) Iris on Flathub is planned; until then a new release is installed the same way.

**Snap** (Ubuntu and other systems with Snap): download `Iris-x86_64.snap` from the latest release and run `sudo snap install --dangerous Iris-x86_64.snap` (the Snap Store listing is planned).

**Nix** (NixOS and Nix anywhere): `nix profile install github:Tulip-Labs/Iris-Browser`, or try it with `nix run github:Tulip-Labs/Iris-Browser`. Fonts and graphics drivers are found on their own, NixOS's `/run/opengl-driver` included.

**Podman or Docker**: `podman pull ghcr.io/tulip-labs/iris-browser`, then `packaging/container/iris-podman` (see [packaging/container](packaging/container/README.md); Flatpak stays the recommended way).

**Updates.** Flatpak, Snap and Nix update Iris; Iris itself only says, in Settings, About Iris, when a new version is out. The `.deb`, `.rpm`, AUR and `.tar.gz` packages of Iris 1.0 are no longer made: remove them (`sudo apt remove iris-browser`, `sudo dnf remove iris-browser`, `rpm-ostree uninstall iris-browser`) and install the Flatpak.

## Build

**Windows.** Double-click `build-iris.bat`. It installs Go with winget if needed, runs the
tests and makes:

| File | What it is |
|---|---|
| `dist\Iris Setup.exe` | The installer: current user only, no administrator rights |
| `dist\Iris\Iris.exe` | The portable app (also `dist\Iris-portable.zip`) |
| `dist\Iris.msixbundle` | For the Microsoft Store, packed without the Windows SDK |

No C compiler is needed, and builds stay well under 2 GB of memory.

**Linux.** On Linux, `./build-iris.sh` builds Iris for Linux first and then the Windows
files. It fetches Electron (through npm, once), checks for the build tools and the GTK
and WebKitGTK development files and says what to install if
something is missing:

```sh
# Fedora
sudo dnf install gcc pkgconf gtk4-devel webkitgtk6.0-devel libepoxy-devel nodejs npm
# Fedora Atomic (Silverblue, Kinoite): build inside a toolbox
toolbox create && toolbox enter   # then the Fedora line above
# Debian, Ubuntu
sudo apt install gcc pkg-config libgtk-4-dev libwebkitgtk-6.0-dev libepoxy-dev nodejs npm
# Arch
sudo pacman -S gcc pkgconf gtk4 webkitgtk-6.0 libepoxy nodejs npm

./build-iris.sh             # Linux (dist/linux), then Windows
./build-iris.sh linux       # Linux only
./build-iris.sh windows     # Windows only
```

Then package `dist/linux` as a Flatpak (`flatpak-builder --user --install build packaging/flatpak/io.github.tulip_labs.Iris.yml`)
or a Snap (see `packaging/snap/snapcraft.yaml`), or build the Nix flake (`nix build`).

**Tests.**

```sh
go test ./core ./shell ./shields ./ui
SHOTS=shots go test ./shell   # also writes screenshots of every screen
```

<details>
<summary><b>Getting it onto other PCs without warnings</b></summary>

<br>

Windows warns about programs not signed by a known publisher. For a free app
the clean route is the Microsoft Store:

1. Registration is free for individual developers: create an account in Partner Center.
2. Reserve the name "Iris", then copy *Package/Identity/Name* and *Publisher* from
   Product identity into `packaging/msix.json`.
3. Build and upload `dist\Iris.msixbundle`. The Store signs it, so it installs without
   warnings and updates itself.

The whole submission, with the listing texts, is in [packaging/STORE.md](packaging/STORE.md).

`packaging/test-install.ps1` signs a package with a certificate made on your own PC, to try
the MSIX first. The setup `.exe` and the portable app stay unsigned: SmartScreen shows
"Windows protected your PC" (More info, Run anyway) until a code-signing certificate is
used, which is a paid service.

</details>

## How it is made

```
cmd/iris          the program: window, resident process, system hooks
    |
  shell             the interface: tabs, split view, address bar, new tab page,
    |               downloads, history, the balancer, the Ask AI panel
    |
    +-- ui, giox    the interface toolkit (light Liquid Glass) and its Gio backend
    +-- core        rules with no window: search, shields, adaptive scans, unsafe
    |               addresses, HTTPS, the memory plan, history, settings
    +-- shields     filter lists, hiding rules, link cleaning, fingerprinting
    +-- webview     one small interface over the engines:
                      WebKitGTK in process, for most pages (Linux)
                      Electron through a helper process, drawn off screen into Iris's
                      window (Linux and Windows)
                      route: which engine draws a page; one cookie bridge between them
```

| Folder | What it is |
|---|---|
| `setup`, `cmd/iris-setup` | The installer: its screens, install, update and removal |
| `raster` | A software renderer, for tests and screenshots |
| `packaging`, `tools` | MSIX packing and build helpers |

The web engine sits behind `webview.Engine` and `webview.View`, so everything above it is
the same on both systems, and the whole interface can be tested with a stand-in engine.

## License

[GNU General Public License 3.0](LICENSE). You may use, share and change Iris, and sell
copies; copies and changed versions must keep the copyright notice, stay under the GPL and
come with their source. See also [NOTICE](NOTICE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). What Iris does with data: [PRIVACY.md](PRIVACY.md).

<p align="center">
  <sub>Tulipan Labs · Cesar Jose Luis Torrecilla Gelvez</sub>
</p>
