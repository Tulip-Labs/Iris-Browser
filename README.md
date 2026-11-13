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
- **Lite results.** Google searches are shown on a page of Lite Go's own, in your theme.
  At the left: a picture carousel you drag or scroll sideways, a stack of big video
  cards, and the AI Mode answer with numbered citations and sources ("Answer by Google
  AI Mode" links to the original). At the right: the websites. A picture or video you
  open shows in that right column (the picture large, with its site; the video playing
  on its YouTube page), and "More" shows them all there; back returns to the websites.
- **Sign in to Google once**, on first launch, so Google trusts the background reading
  and never stops results or AI answers with human checks ("Not now" is possible). Ads, sponsored units and
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
- **Downloads.** An icon appears in the toolbar with the first download and wears a ring
  that fills as files arrive. The list (Ctrl+Shift+D) shows size, speed and time left,
  pauses, resumes and cancels, opens the file or its folder. Files go to your Downloads
  folder.
- **Split view** (Ctrl+Shift+S, or the toolbar): two pages side by side with a divider
  you drag. The pane you click takes the keyboard and the address bar. Picking another
  tab shows it alone; coming back to one of the pair shows both again.
- **Find in page** (Ctrl+F), **zoom** (Ctrl +, Ctrl -, Ctrl 0), **print** (Ctrl+P),
  **history** (Ctrl+H, searchable, by day) and **the last tabs brought back** when Lite Go
  starts (unloaded until you open them, so starting stays light).
- **Keeps memory low.** Background tabs are hidden at once, put to sleep (scripts
  suspended, low memory target) after a while, and unloaded later, keeping their address
  and title; they come back when you click them. Tabs playing sound stay awake. The plan
  follows the computer's RAM, with Saver, Balanced and Speed profiles, a live memory
  readout, and a Free memory now button. On computers with 4 GB or less the engine starts
  in its low-end mode with fewer renderer processes.
- **A balancer for the computer's resources.** The tab in front (both, in split view) and
  tabs playing sound have priority: every other page is told at once that nobody is
  looking, so the engine gives memory back while the page keeps running. When the pages
  together pass the plan's budget, or the computer runs short of free memory, background
  pages sleep right away and are then unloaded one by one, oldest first.
- **A memory limit for each page.** Each page process gets a cap (1 to 3 GB on the
  Balanced profile, by the computer's RAM): a page that goes past it is ended alone, with
  a Reload button, instead of slowing everything. On Windows the cap is a job object
  around each WebView2 page process; on Linux it is WebKit's own memory limit.
- **Loads what you are near.** Pictures and frames further down a page wait until you
  scroll close, and videos that do not play by themselves fetch only their first details.
  The web view decides what "near" is; what it has already started fetching is not
  stopped, so the saving is largest on long pages.
- **Lite Shields**, what Brave calls Shields, written in Go:
  - the filter lists real blockers use (EasyList, EasyPrivacy, uBlock filters), with
    exceptions, first and third party, resource types and per-site rules; downloaded
    and refreshed every few days, ~110,000 rules matched in microseconds
  - hiding what ads leave behind (site rules at once, generic rules matched to each
    page's own classes and ids), and cookie notices (EasyList Cookie)
  - links without tracking (utm_, fbclid, gclid and more), tracking redirects skipped,
    AMP pages opened at the source
  - fingerprinting protection (canvas, audio and hardware details vary slightly per
    site and session; sign-in and human-check pages left alone)
  - plus the built-in list of 100,000 domains, per-site off, a blocked counter and
    YouTube ad clean-up. Sign-in, messaging, human checks and YouTube playback are
    never blocked, and style sheets and fonts always load, so pages keep their look.
  - **adaptive:** a site is scanned on its first visits. Where three scans in a row find
    nothing to block or hide, the shield stands by and that site's requests go straight
    to the network; where something is found the shield stays on. Clean sites are
    scanned again every 15 visits or three days, and "Scan again" is in the menu.
    Private pages leave no record.
  - On Linux the request rules are compiled into WebKit's own content blocker, which
    already costs nothing per request; there the scan decides the hiding rules.
- **HTTPS-only, and a sandbox for what looks unsafe.** A site with no secure connection,
  or an address that looks dangerous (a known name on someone else's site, a real site
  hidden behind an @, a bare network address, look-alike letters), is stopped before it
  loads. "Open in a sandbox" opens it in a throwaway session that can download nothing,
  is refused camera, microphone, location, notifications and clipboard, saves no
  passwords or form data, and is wiped when the tab closes. "Trust it" opens it normally
  for the session. The check reads the address only: it is not a malware scanner.
- **Private, temporary, sandbox and container tabs, chosen on the new tab page.** Under
  the search, "Open this tab as" turns a new tab into any of them. Private tabs share one
  session that is never written to disk; a temporary tab is a fresh session of its own,
  gone when it closes (a second account, side by side); containers keep their own
  sign-ins, each with its own icon and color, made and edited right there.
- **Checks itself.** At every start Lite Go compares its program file with the SHA-256
  recorded when it was installed, and warns if they differ; the installer also marks the
  files read-only. This catches accidents, bad disks and careless changes, not someone
  able to replace both files. The Store package is stronger: Windows keeps it read-only
  and verifies it itself.
- **Tabs on top or at the side**, seven palettes from Flowcode (Crocus, Tulip, Spring Mix,
  Sakura, Meadow, Classic, Night), a custom title bar, full screen video, and shortcuts:
  Ctrl+T, Ctrl+Shift+N, Ctrl+W, Ctrl+Shift+T, Ctrl+L, Ctrl+J, Ctrl+F, Ctrl+H, Ctrl+P,
  Ctrl+Shift+S, Ctrl+Shift+D, Ctrl+Tab, Ctrl+1...9, Alt+Left, Alt+Right, Ctrl+R / F5,
  Ctrl+M (mute), F11. They work while a page has the keyboard too.
- **History** in SQLite (pure Go), for address suggestions. It is never kept for
  private or temporary tabs.
- **Installer:** a small Gio window that installs for the current user (no administrator
  rights), adds Start menu and desktop shortcuts, offers Lite Go in Windows' default
  apps, installs the WebView2 runtime if it is missing, and removes everything again.

## Platforms

| | Web engine | Status |
|---|---|---|
| Windows 10 and 11 (x64, ARM64) | Microsoft Edge WebView2, through Lite Go's own bindings in pure Go (no cgo) | Done, tested |
| Linux: native Wayland (GNOME, KDE, ...) and X11 | WebKitGTK 4.1, in a GTK window | Written: `./build-litego.sh linux`; first run pending |

Lite Go is for Windows and Linux. The Android and macOS versions were dropped.

Every system's own web engine sits inside Lite Go's window, and Lite Go drives it the
same way everywhere: tabs, Shields, results, the AI panel, the memory plan. No engine is
bundled: each comes with the system and is kept up to date by it.

On Linux the window itself is a GTK window, because Wayland does not let one
program's surface sit inside another's: GTK owns the window (with the desktop's own
shadow, corners and resize edges), Gio's GPU renderer draws Lite Go's interface into a
GL area in it, and each page's WebKitWebView sits over that area. One window, one
connection to the display, so it runs natively on Wayland and on X11 alike.

The web engine is behind one small interface (`webview.Engine` and `webview.View`), so
the rest of Lite Go is the same on both systems.

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

From Linux, `./build-litego.sh` cross-builds the same Windows files, and
`./build-litego.sh linux` builds Lite Go for Linux (it lists the packages it needs). Builds stay
well under 2 GB of memory. No C compiler is needed.

## Layout

| Folder | What it is |
|---|---|
| `webview` | The web engines: WebView2 from pure Go (COM vtables, profiles, private mode, sandbox, suspend, memory targets and caps, request filtering, downloads, popups, shortcuts) and WebKitGTK |
| `core` | Browser rules with no window: search, shield, adaptive scans, unsafe addresses, HTTPS, the memory plan, history, settings |
| `shell` | The interface: tabs, split view, address bar, suggestions, new tab page, downloads, history, the balancer, side panel |
| `ui`, `giox` | Flowcode's interface toolkit and its Gio backend |
| `setup` | The installer's screens and the install, update and removal |
| `cmd/litego`, `cmd/litego-setup` | The two programs |
| `raster` | A software renderer for tests and screenshots |

## License

PolyForm Noncommercial 1.0.0. See LICENSE.md, NOTICE and THIRD_PARTY_NOTICES.md.
Tulipan Labs (Cesar Jose Luis Torrecilla Gelvez).
