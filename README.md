<p align="center"><img src="assets/icon.png" width="96" alt=""></p>

<h1 align="center">Lite Go</h1>

<p align="center">A light, fast browser written in Go. The interface is drawn with Gio in
Flowcode's Material 3 and liquid-glass look; pages are shown by the system web view.</p>

---

Lite Go is the Go edition of Lite. It keeps Lite's rules (Google AI Mode first, the shield,
HTTPS-only, clean YouTube) and adds tight control of the web engine's memory. There are no
bookmarks or shortcut tiles: the new tab page is just the search, and the address bar
suggests from history.

## What it does

- **Opens instantly.** Lite Go runs once and stays ready in the background (a small part
  of it, with no pages), from Windows sign-in and after you close the window, so a click
  shows the window at once. Clicking again opens a new tab in the same window. "Quit
  Lite Go" in the menu ends it completely; the setting can be turned off.
- **Lite results.** Google searches are shown on one calm page of Lite Go's own, in your
  theme: the AI Mode answer with numbered citations and sources ("Answer by Google AI
  Mode" links to the original), the best links, a picture carousel you drag or scroll
  sideways, a stack of big video cards, then the rest. Ads, sponsored units and
  promotions are removed; links are ranked by source quality (references, official
  sites, docs, research and real discussions rise; shops, coupon and download farms and
  listicles sink; at most two per site), and you can raise, lower or hide any site.
  "On Google" shows the original; Back returns from a page to the results.
- **Ask AI** on any page (Ctrl+J): a side panel that sends your question, the page's
  address and its text (or your selection) to Google AI Mode and writes the answer as
  text, with its sources. No API key needed.
- **Opens Google and YouTube fast.** The new tab page is drawn by Lite Go itself, so it
  appears at once; while you type, a page is prepared in the background, so the first
  result opens without waiting for the engine. Addresses go straight to HTTPS.
- **Search modes:** AI Mode (default), Web, Images, Videos and YouTube, in English (US).
  Type `yt ` before words to search YouTube from any mode.
- **Keeps memory low.** Background tabs are hidden at once, put to sleep (scripts
  suspended, low memory target) after a while, and unloaded later, keeping their address
  and title; they come back when you click them. Tabs playing sound stay awake. The plan
  follows the computer's RAM, with Saver, Balanced and Speed profiles, a live memory
  readout, and a Free memory now button. On computers with 4 GB or less the engine starts
  in its low-end mode with fewer renderer processes.
- **Shield** against ads and trackers (about 100,000 domains, the same list as Lite
  Desktop), per-site allow, a blocked counter, and YouTube ad clean-up. Sign-in,
  messaging, human checks and YouTube playback are never blocked.
- **HTTPS-only**, with an "Open anyway" choice when a site has no secure connection.
- **Private, temporary and container tabs.** Private tabs share one session that is never
  written to disk; a temporary tab is a fresh session of its own, gone when it closes (a
  second account, side by side); containers keep their own sign-ins, each with its own
  icon and color (tuned to the theme), shown on its tabs and in the address bar.
- **Tabs on top or at the side**, seven palettes from Flowcode (Crocus, Tulip, Spring Mix,
  Sakura, Meadow, Classic, Night), a custom title bar, full screen video, and shortcuts:
  Ctrl+T, Ctrl+Shift+N, Ctrl+W, Ctrl+Shift+T, Ctrl+L, Ctrl+J, Ctrl+Tab, Ctrl+1...9, Alt+Left,
  Alt+Right, Ctrl+R / F5, Ctrl+M (mute), F11. They work while a page has the keyboard too.
- **History** in SQLite (pure Go), for address suggestions. It is never kept for
  private or temporary tabs.
- **Installer:** a small Gio window that installs for the current user (no administrator
  rights), adds Start menu and desktop shortcuts, offers Lite Go in Windows' default
  apps, installs the WebView2 runtime if it is missing, and removes everything again.

## Platforms

| | Web engine | Status |
|---|---|---|
| Windows 10 and 11 (x64, ARM64) | Microsoft Edge WebView2, through Lite Go's own bindings in pure Go (no cgo) | Done |
| macOS | WKWebView | Next: the `webview` package is ready for it |
| Linux | WebKitGTK | Next |

The web engine is behind one small interface (`webview.Engine` and `webview.View`), so
the rest of Lite Go is the same on every system.

## Getting it onto other PCs without warnings

Windows warns about programs that are not signed by a known publisher. For a free,
noncommercial app the clean route is the **Microsoft Store**:

1. Registration is free for individual developers: create an account in Partner Center.
2. Reserve the name "Lite Go", then copy *Package/Identity/Name* and *Publisher* from
   Product identity into `packaging/msix.json`.
3. Build (below) and upload `dist\LiteGo.msixbundle`. The Store signs it with Microsoft's
   certificate, so it installs on any Windows 10 or 11 PC without warnings and updates
   itself.

`packaging/test-install.ps1` signs a package with a certificate made on your own PC, to
try the MSIX before submitting it. The setup `.exe` and the portable app stay unsigned:
Windows SmartScreen shows "Windows protected your PC" (More info, Run anyway) until a
code-signing certificate is used, which is a paid service.

## Build

On Windows, double-click **build-litego.bat**. It installs Go with winget if needed, runs
the tests, and makes:

- `dist\Lite Go Setup.exe`: the installer
- `dist\Lite Go\Lite Go.exe`: the portable app (and `dist\LiteGo-portable.zip`)
- `dist\LiteGo.msixbundle` (and `LiteGo_x64.msix`, `LiteGo_arm64.msix`): for the Store,
  packed by `tools/msix.go` without the Windows SDK

From macOS or Linux, `./build-litego.sh` cross-builds the same Windows files. Builds stay
well under 2 GB of memory. No C compiler is needed.

## Layout

| Folder | What it is |
|---|---|
| `webview` | The web engine: WebView2 from pure Go (COM vtables, profiles, private mode, suspend, memory targets, request filtering, popups, shortcuts) |
| `core` | Browser rules with no window: search, shield, HTTPS, the memory plan, history, settings |
| `shell` | The interface: tabs, address bar, suggestions, new tab page, side panel |
| `ui`, `giox` | Flowcode's interface toolkit and its Gio backend |
| `setup` | The installer's screens and the install, update and removal |
| `cmd/litego`, `cmd/litego-setup` | The two programs |
| `raster` | A software renderer for tests and screenshots |

## License

PolyForm Noncommercial 1.0.0. See LICENSE.md, NOTICE and THIRD_PARTY_NOTICES.md.
Tulipan Labs (Cesar Jose Luis Torrecilla Gelvez).
