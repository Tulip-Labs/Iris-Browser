The first public build of Lite Go: a light, fast browser in Go and Gio for Windows 10 and 11.

## Downloads

| File | What it is |
|---|---|
| `LiteGo-Setup.exe` | The installer. Installs for the current user, no administrator rights. |
| `LiteGo-portable.zip` | The app in a folder: unzip and run `Lite Go.exe`. |
| `LiteGo.msixbundle` | The Windows package (x64 and ARM64), for the Microsoft Store or sideloading with your own certificate. |
| `SHA256SUMS.txt` | Checksums of the three files. |

## Before you install

- The files are not signed, so Windows SmartScreen shows "Windows protected your PC". Choose **More info**, then **Run anyway**.
- Pages are shown by Microsoft Edge WebView2, which Windows 11 already has; the installer gets it if it is missing.
- Downloads, split view, the per-page memory limit and the sandbox are new and have been tested with a stand-in engine, not yet on many real PCs. If pages close unexpectedly, turn off the limit under Memory in the menu and open an issue.
- Linux: build from source with `./build-litego.sh linux` (first run pending).

## What is in it

Lite results for Google searches, Ask AI, Lite Shields with adaptive scanning, HTTPS-only with a sandbox for unsafe addresses, split view, a download manager, find, zoom, print, history, private, temporary and container tabs, and a memory plan with a balancer and a cap for each page. See the README for the full list.

Licensed under GPL 3.0.
