Lite Go: a light, fast browser in Go and Gio for Windows 10 and 11.

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
- Linux: build from source with `./build-litego.sh linux` (first run pending).

## What is in it

Lite results for Google searches, Ask AI, Lite Shields with adaptive scanning, HTTPS-only with a sandbox for unsafe addresses, split view, a download manager, the phone link, find, zoom, print, history, private, temporary and container tabs, and a memory plan with a balancer. See the README for the full list.

Licensed under GPL 3.0.
