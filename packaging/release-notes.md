Iris (formerly Lite Go): a light, fast browser in Go and Gio for Windows 10 and 11, Linux and Android.

## New in 1.0.16

- **Pages open again on every setup.** In 1.0.15, Chromium handed its frames straight to the graphics chip; on some computers (inside a toolbox, with some drivers) it could not allocate those buffers and sent no frame at all, so pages stayed blank. Pages are now uploaded to the graphics chip from the processor by default, which works everywhere; the direct hand-off is opt-in with `LITEGO_GPU=1`.
- **Video codecs come with Iris.** Installing Iris now installs ffmpeg too, so H.264 and H.265 videos (LinkedIn, X, news sites) play out of the box: on Fedora `ffmpeg-free` with Cisco's `openh264` (H.264; RPM Fusion's full `ffmpeg` adds H.265), on Debian, Ubuntu, Arch and Nix their ffmpeg (both).
- **A quiet terminal.** Chromium no longer prints its messages about the system bus, the battery or VA-API (common inside a toolbox, and harmless); `LITEGO_CEF_VERBOSE=1` shows them.

## New in 1.0.15

**Faster and sharper pages.** Each page is now drawn by the graphics chip: on a computer with a GPU, Chromium hands its frames straight to it (dmabuf), with no copy through the processor; elsewhere the changed parts are uploaded as textures. Pages are drawn pixel for pixel. Videos on YouTube and other sites are decoded by the graphics chip (VA-API), and Chromium's shader cache is kept between runs. 

**H.264 and H.265 videos look better.** The converter now decodes on the graphics chip, encodes VP9 there when it can (VP8 at a much sharper quality otherwise), up to 1080p, and also takes H.265 (HEVC) videos. H.265 needs an ffmpeg with that decoder (on Fedora: RPM Fusion's `ffmpeg`).

**Security fixes**
- A web page could crash Iris, or answer Iris's own scripts, by printing a special console message. Each script result now carries a secret for that one call and counts only from the page it was sent to.
- The video converter could be used by any page to reach this computer or its local network, read the converted result, or (with GStreamer) write a file. It now answers only a page's own video element, fetches only public addresses, and lets no script read it.
- Windows a page opens without a click are no longer opened; at most six downloads start in half a minute; downloaded file names are cleaned; launchers, scripts and installers in the downloads list are shown in their folder rather than opened.
- The settings (which hold the sync key), history and site data are now readable by your account only.
- A pasted `javascript:` link in the address bar is a search, never run; "note: something" is a search too.
- Phone uploads are size-limited and never overwrite each other.
- Android: pages can no longer open other apps without a tap, and app links cannot grant access to Iris's files.

## New in 1.0.14

- **Iris for Android runs on its own Chromium.** The phone app now carries Chromium 156, the same engine as Iris on the computer (CEF for Android, through Cefrium), in place of the system WebView. Pages, YouTube and Google look and behave the same as on the computer, H.264 and AAC videos play, and containers keep their sign-ins apart on every phone.
- **The phone app is Iris too**: the new name and icon, the ten clear glass themes of the desktop (the theme choice still syncs), and glass result cards.
- The Android app needs Android 10 or newer on a 64-bit phone, and is larger (Chromium is inside).

## New in 1.0.13

- **Lite Go is now Iris**, after the Greek goddess of the rainbow, who carries light between worlds. A new icon to match: an iris of light in a drop of smoked glass. Your settings, tabs, history and sign-ins stay where they were, the package keeps its name (`lite-go-browser`) so updates come as before, and the command `iris` starts it besides `lite-go`.
- **Colorless liquid glass.** Icons, buttons, cards and text are clear glass with no color of their own; only the backdrop keeps the theme's color. Containers and tab kinds tell apart by their icons.
- **Pages follow the theme**: a dark theme shows pages in their dark mode, a light theme in their light mode.
- **Cleaner search results**: no tags or goggles; the websites are glass cards, and the AI answer starts right under its title.

## New in 1.0.12

- **Sharp pages on fractional screen scales.** Chromium now draws at exactly the window's scale, so pages are no longer stretched (soft, or blocky in 1.0.10–1.0.11).
- **H.264 videos play** (LinkedIn, X and many news sites). Lite Go's Chromium has no H.264, so when such a video cannot play, Lite Go converts it on the fly with the system's ffmpeg (or GStreamer) and plays that. It uses some processor while a video plays. Install ffmpeg if it is missing (Fedora Atomic: `rpm-ostree install ffmpeg-free`).
- **New glass themes**, in the spirit of Apple's Liquid Glass, shared with Ember. **Liquid** is the new default: black, clear glass panes and glossy liquid icons. Also Graphite, Deep Sea, Ember and Aurora (dark), and Daylight, Mist, Rose, Sunrise and Mint (light). The old palettes are gone; a saved one switches to Liquid.

## New in 1.0.11

- **YouTube no longer sees an ad blocker.** On YouTube the shield now blocks nothing and Lite Go leaves the player's data alone (what YouTube checks). Instead, an ad that starts is muted, played at 16× to its end and skipped, and the video goes on as it was; the ad boxes are hidden, and YouTube's ad blocker notice, if it still comes, is closed.

## New in 1.0.10

- **Sharper pages on Linux.** Chromium's frames are painted pixel for pixel at the screen's real scale, with no smoothing.
- **Tabs back on top**, more compact and centered: a slim strip above the bar, in place of the full-page grid. The arrow beside + opens private, temporary, sandbox and container tabs.
- **YouTube and tabs playing sound or video never rest**, nor for ten minutes after they pause.
- **Less memory and less work.** Pages of one site share a process and fewer page processes run; Chromium's back-and-forward page cache and its background services are off; only the changed part of each frame is copied; Lite Go wakes up less often when idle.

## New in 1.0.9

- **A new look, lighter on the screen.** One slim bar: back, forward and reload at the left, a compact address in the middle, the tabs button, the shield and the menu at the right. The tab strip, the corner mark and the status bar are gone, and it fits any window size.
- **Tabs as a grid of cards**, like a phone (the tabs button, or Ctrl+Shift+A): find a tab by typing, pick one with the arrows and Enter, and open private, temporary, sandbox or container tabs from the same place.
- **Settings live in the menu**, in sections that open in place. Gone: the settings page, Search and On startup, the Quit button, the phone link and Proton Pass. A Sign in button shows only while Lite Go is not signed in to Google.
- **Lite results, redesigned.** The AI answer leads, written for you (add your name in the menu), tagged with its topic, the strength of its sources and how complete it is; citations show the site they come from. Goggles re-rank the links in one click (Forums, Academic, Tech, News, Small web, No shops). Websites come as a stack of cards that keeps loading while Google has relevant ones; pictures and videos as stacks of cards, each picture in its own shape and sharp at the front.
- **Websites open in new tabs**: from the results, from the address bar while a site is open, and links to other websites. Back from the first page returns to where you came from.
- **Memory goes back early**: background tabs rest within a minute and come back where they were; a closed tab frees its memory at once; nothing is prepared ahead of time, and nothing keeps running after the window closes.
- **The new tab page** is the name and a search, nothing else. The palettes of Ember come along: Ember Glow, Sunset, Terracotta, Midnight, Ember Night, Aurora and Abyss.
- **Linux:** pages were drawn at half size on scaled screens; fixed. WebKitGTK is gone entirely, with what it kept on disk. The Nix package now uses Chromium too.

## New in 1.0.8

- **Lite Go for Linux now runs on Chromium** (Chromium 156, through CEF), in place of WebKitGTK: videos play (YouTube included), pages draw and scroll the way they do in Chrome, and the shields check every request again. It runs on Wayland. Your settings, history and containers stay; sign-ins and site data start fresh, because Chromium keeps them its own way.
- Lite Go for Linux is now a folder with Chromium inside, so the packages are bigger (about 110 MB). The apt repository moved to the GitHub releases; the package moves your sources line over by itself.
- The Flatpak is paused until Chromium is packaged for Flatpak's sandbox. Chrome extensions do not run in an embedded Chromium; the shields block ads and trackers.

## New in 1.0.7

- The Linux packages bring the video players along: GStreamer's VP9 player and, where the system offers them, OpenH264 and libav for H.264.

## New in 1.0.6

- **YouTube plays on Linux systems without H.264** (Fedora without OpenH264 or RPM Fusion, for one): Light YouTube now asks for H.264 only where it can actually play it, and uses VP9 otherwise.

## New in 1.0.5

- **Linux: much less memory.** Each page has a memory limit and gives memory back early; computers with 8 GB or less use smaller caches; when memory runs short, background tabs are unloaded quickly (they reload when you open them) so the system never has to close the browser.
- **Linux: resizing** (niri's column widths, Super+R, Super+F, dragging) redraws at the new size at once.

## New in 1.0.4

- **Lite Go for Linux**, tested on Debian, Ubuntu, Fedora, openSUSE and Arch: `.deb`, `.rpm`, Flatpak (`LiteGo-x86_64.flatpak`), an AUR recipe (`PKGBUILD`), a Nix flake and a `.tar.gz` for any distribution. apt and dnf repositories: see the README.
- **Updates from GitHub**: Lite Go checks the latest release every few hours and checks each download against `SHA256SUMS`. Turn it off in Settings, About Lite Go.
- **Downloads keep going** when you switch tabs, when the tab that started one goes to sleep, and when you close that tab.

## New in 1.0.3

- **Settings page** in a tab of its own, like Chromium's, with the sections at the left.
- **Status bar** along the bottom, as in Vivaldi: shield count, memory, downloads, history, find, print, split view and zoom.
- **Container tabs from the + button** (its arrow, or right-click), as in Brave; pick each container's icon and color under Settings, Containers.
- **Removed:** Muse, the AI button and the memory pill from the toolbar. Ask AI is still on Ctrl+J; Proton Pass is in the menu; the phone link is under Settings, Phone and sync.
- **Lite for Android:** the palettes show properly (they were drawn with no height), the four pastel palettes, containers (hold the + button), Lite results for Web searches, and layouts for tablets and landscape.

## New in 1.0.2

- **Opens maximized**, and remembers the size and state you leave the window in.
- **Muse and Proton Pass in the side panel** (menu, or Ctrl+Shift+M for Muse): the sites themselves beside the page you are on, kept signed in. Muse is Meta's AI agent and is available in the US only.
- **Sync with Lite for Android**, with no account and no server: history, open tabs and the palette are traded directly whenever the phone and the computer are on the same Wi-Fi, sealed with a key only they share. Pair from Menu, Phone.
- **Lite for Android is back**: `Lite-android.apk` below.

## New in 1.0.1

- **Phone link:** scan a QR code with your phone and move files both ways, with nothing to install on the phone (same Wi-Fi).
- **Four pastel palettes** that merge three colors: Peach Sky, Mint Lilac, Sorbet and Lagoon.
- **Pictures always load.** The shield no longer blocks whole hosting networks (this broke pictures on Coursera and others) and no longer checks pictures and video at all, which also makes pages load faster.
- **Removed:** the memory limit for each page and the loader that delayed pictures.

## Downloads

| File | What it is |
|---|---|
| `LiteGo-Setup.exe` | The installer. Installs for the current user, no administrator rights. |
| `LiteGo-portable.zip` | The app in a folder: unzip and run `Lite Go.exe`. |
| `LiteGo.msixbundle` | The Windows package (x64 and ARM64), for the Microsoft Store or sideloading with your own certificate. |
| `SHA256SUMS.txt` | Checksums of the three Windows files. |
| `Lite-android.apk` | Lite for Android 8 and newer. Allow installing from your browser or file manager when Android asks. |

## Before you install

- The files are not signed, so Windows SmartScreen shows "Windows protected your PC". Choose **More info**, then **Run anyway**.
- Pages are shown by Microsoft Edge WebView2, which Windows 11 already has; the installer gets it if it is missing.
- Downloads, split view, the sandbox and the phone link are new and have been tested with a stand-in engine, not yet on many real PCs. If something misbehaves, open an issue.

## What is in it

Lite results for Google searches, Ask AI, Lite Shields with adaptive scanning, HTTPS-only with a sandbox for unsafe addresses, split view, a download manager, the phone link, find, zoom, print, history, private, temporary and container tabs, and a memory plan with a balancer. See the README for the full list.

Licensed under GPL 3.0.
