Iris 2.2.6: the WebView build is gone — Cefrium is the only Android build.

**Android**
- **One Android build, on Cefrium.** The WebView build is removed: in 2.2.5 nothing could be typed in it, while the Cefrium build worked. Cefrium carries its own Chromium (CEF, through Cefrium 0.21.0, Chromium 156), the same engine on every phone.
- **It installs over 2.2.4's WebView build** — the same app id (`org.tulipanlabs.lite`), the same name in the launcher (Iris), the same tabs and sign-ins. If you installed the separate "Iris Cefrium" build from 2.2.3–2.2.5, uninstall that one after installing this, so you do not keep two Irises.
- **Background audio still works**: audio keeps playing with the screen off or when Iris leaves, with play, pause and stop in the notification and on the lock screen, on by default (turn it off in the Shields panel, under Background audio). Swiping Iris away from recents still stops the sound.

**Linux**
- The same version number as Android; nothing else changed.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer). It installs over 2.2.4.

---

Iris 2.2.5: audio keeps playing in the background, like Brave.

**Android**
- **Audio keeps playing when the screen goes off or you leave Iris.** Play anything — a video, a song, a YouTube video — and it keeps playing in the background, with play, pause and stop in the notification and on the lock screen. Tapping the notification brings you back to the page.
- **Background audio is on by default.** Turn it off in the Shields panel, under Background audio; the sound then stops when Iris leaves the screen, as before.
- **Iris asks for the notification permission the first time audio plays**, so the playback controls can show. Saying no changes nothing about the sound: the audio still plays, and the controls still show from the lock screen.
- **How it works:** the page that plays is not paused when Iris leaves the screen, a foreground service keeps it alive, and the page is kept visible to Chromium so YouTube does not pause it when it hides. The service stops when the sound stops, the tab closes, or you stop it from the notification. Swiping Iris away from recents still stops the sound — the page belongs to the app's window, so it goes with it.

**Linux**
- The same version number as Android; nothing else changed.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer). It installs over 2.2.4. `Iris-android-cefrium.apk` installs over the Cefrium build.

---

Iris 2.2.4: safer downloads, links and updates, and lighter on memory over a long day.

**Linux**
- **No more update notice for the version you already have.** Iris 2.2.3 for Linux still called itself 2.2.2, so it told you every day that 2.2.3 was out. Each part of Iris now carries the same version, and the release checks it.
- **Lighter over a long day.** A page that keeps changing its title (a chat, a mail inbox, a timer) no longer leaves a copy of every title in memory, and the oldest history entries really let go of their memory when the history is trimmed. The list of closed tabs keeps the last 25.
- **History, session and settings are written safely and privately**: each file reaches the disk before it replaces the old one, so a power cut leaves the old file or the new one, never an empty one; and they are readable by you alone.
- **The sandbox downloads nothing, from the right-click menu either.** "Download Link", "Save Image" and "Save Video" are gone from pages in the sandbox, as downloads already were.
- **Downloads get a safe file name**: no folders, no control characters, no hidden files, and a name too long for the disk is shortened with its extension kept. The folder button beside a download now finds files with spaces or symbols in their names.
- **The address bar can no longer be fooled by a backslash** in an address, and Google questions typed in Google's own search box show with spaces, not plus signs.
- **`iris example.com` and `iris ./page.html` open what you mean** from a terminal; anything that is not an address (a `javascript:` link from another program) becomes a question, and never runs.
- A container removed since a tab was closed no longer stops that tab from reopening; and "Ask Google AI Mode" from the right-click menu no longer reads a tab you closed in the meantime.

**Android**
- **Links from other apps open only when they are web addresses.** Another app can no longer hand Iris a `javascript:`, `file:` or `intent:` address.
- **Downloads come only from the web**, and a server's error page is no longer saved as your file.
- **Updates come only from Iris's own releases on GitHub**, over https. The Cefrium build no longer tries to install the WebView build's APK when a release lacks its own, a download cut short is never handed to Android's installer, and a failed update leaves nothing behind.
- The download bar moves every megabyte instead of on every read, which is lighter on the phone.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer). It installs over 2.2.3. `Iris-android-cefrium.apk` installs over the Cefrium build.

---

Iris 2.2.3: Cefrium is back, as a build of its own.

**Android**
- **Iris Cefrium, a second Android build beside the WebView one.** It carries its own Chromium (CEF, through Cefrium 0.21.0, Chromium 156), the same engine on every phone, and installs side by side with the usual build (its own id, `org.tulipanlabs.lite.cefrium`, and its own name in the launcher). It does not carry the WebView build's tabs or sign-ins over. Its blank pages are fixed with the maintainer's fix for the renderer processes (issue #24): the Application now leaves those processes at once, and the next Cefrium release keeps it out of them by itself.
- **Each build updates itself**: the Cefrium build takes the Cefrium APK, the WebView build the plain one.
- The WebView build is unchanged: the same pages, the same Shields, the same sandbox.

**Install**
- Android: `Iris-android.apk` (Android 10 and newer). It installs over 2.2.2. `Iris-android-cefrium.apk` installs beside it.

---

Iris 2.2.2: YouTube with no ads, and a closed tab is really closed on Linux.

**Both**
- **YouTube with no ads, and nothing for YouTube to notice**, as uBlock Origin's and Brave's YouTube filters work: the player's answer loses its ads before the player reads it, so no ad is ever scheduled and no request is blocked for YouTube to find; YouTube's ad blocker notice is taken out the same way. A feed ad that still appears is hidden, and an ad that still plays is skipped, muted. The same script on Linux and Android.

**Linux**
- **Closing a tab now ends its page.** Since 2.2.0, a closed tab's page lived on out of sight: a video kept playing and its memory was never given back, so closing tabs did not lower Iris's memory. Iris held one reference too many on each page; it now lets go of it.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer). It installs over 2.2.1.

---

Iris 2.2.1: Iris for Linux opens and stays open in the Flatpak again.

**Linux**
- **Iris no longer closes a few seconds after it opens** (2.2.0 in the Flatpak, seen on Fedora). WebKit names its sandboxed web processes after the program, and Iris's name was not a valid application ID, so the Flatpak portal refused to start them and Iris stopped. Iris now uses its own ID, io.github.tulip_labs.Iris, and WebKit's process sandbox stays on.
- Each web process's memory limit is applied again (2.2.0 passed it to WebKit the wrong way, with a warning in the terminal).

**Android**
- The same version number as Linux; nothing else changed.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer). It installs over 2.2.0.

---

Iris 2.2.0: Iris for Linux rebuilt in Odin on Wayland and WPE WebKit, with no GTK; Google AI Mode in every new tab, a light look in the colours of dawn, an automatic sandbox for sites Iris does not trust, a new icon, and Android on System WebView again.

**Linux: Odin, Wayland and WPE WebKit, no GTK**
- **No Swift, no Zig, no GTK.** Iris for Linux is Odin, talking to Wayland, EGL, OpenGL ES and WPE WebKit directly. Every C function, struct and Wayland table it declares is checked against the real headers in CI.
- **The page in the glass, without a copy.** Iris brings its own WPEPlatform display and views: each frame WPE renders arrives as a DMA-BUF and Iris samples it in its own OpenGL ES renderer, so the Liquid Glass, now a shader, bends the live page.
- **The chrome is Odin too.** Tabs, address bar, menus, panels and dialogs are drawn by Iris itself in the same frame as their glass: text shaped by HarfBuzz in the desktop's own font (fontconfig, with fallbacks for every script), glyphs and line icons rasterised by Iris at the screen's own pixels. No HTML, no second web view.
- **A page's own pop-ups in glass**: `<select>` lists as glass menus, `alert()`, `confirm()` and `prompt()` as glass dialogs, file fields through the desktop's portal (never in the sandbox).
- **Shields inside the engine.** About 100,000 ad and tracker domains are built into Iris; the lists become WPE content rules, compiled once and kept.
- **Every tab stays awake.** Sleeping tabs are gone.
- **Wayland only**, with fractional scaling, the compositor's cursor shapes and background blur where offered.
- The Flatpak builds WPE WebKit 2.54.3 itself (no Flatpak runtime ships it); WebKit's process sandbox stays on (flatpak-spawn inside the Flatpak).

**Both**
- **Every new tab is Google AI Mode**, ready for a question, dressed in Iris's Liquid Glass: the dawn behind the page, its panels clear, and the question box made of glass. (Only AI Mode is restyled; no other page.) The Iris start page is gone. Your tabs still open where you left them.
- **Faster.** The next new tab is already loaded in the background, so it opens at once; Google's names are looked up before your first question; and a result you open goes straight to the site, without Google's redirect. On Linux, a link's site is looked up while the pointer rests on it.
- **The sandbox, automatic.** A site Iris does not trust (no encryption, a bare IP address, or a certificate that fails) opens in the sandbox without asking: web processes of its own, a world in memory that sees none of your cookies, storage or sign-ins and is wiped when you close it, and no downloads, camera, microphone, location, clipboard or pop-ups. Going on to a trusted site takes you out of it.
- **Ads that open new tabs are stopped** (Android, see below; Linux already did).
- **Light only**, and lighter: Iris's glass over a dawn of lilac, rose and peach, with a deep violet ink.
- **A new icon**: a clear glass ring on a white tile, light entering and leaving as a rainbow.
- **No more menu.** Find in page (Ctrl+F) and zoom (Ctrl+plus, minus and 0) stay as keys. The downloads button appears while a file comes in, then stays with the number finished until you open it.
- Tabs no longer sleep in the background.

**Android**
- **Pages open again.** Iris uses the phone's Android System WebView instead of Cefrium, which left pages blank on some phones.
- **Ads that open new tabs are stopped**: a page opens no tab by itself, a tapped ad link opens nothing, a script's window stays hidden until Iris knows where it goes, and a page cannot send its own tab to an ad.
- The sandbox runs in a process of its own, with WebView data that is made fresh each time.
- File fields, calls (camera and microphone) and full-screen video work again. The APK is small again.

**Linux**
- The sandbox is a WPE web context of its own, each page in WebKit's process sandbox, with a network session per sandboxed tab that lives in memory only. Its tabs have an orange rim.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer). It installs over 2.1.0.

---

Iris 2.1.0: Ember's Light and Dark looks, Shields with three levels, Iris for Android on its own Chromium again, and a new icon.

**Both**
- **Light, Dark or Auto**, as in Ember. Auto follows the system (light when it has none); with Ember on niri the system turns dark at night, so Iris does too. Pages follow the look.
- **The new-tab page is Iris herself**: the goddess of the rainbow in liquid glass, Ember's wallpaper, light by day and dark by night.
- **Shields, Moderate, Aggressive or Ultra aggressive**, as in Brave. Ads and trackers are stopped inside the engine before a request leaves the device, with the lists uBlock Origin uses:
  - Moderate: ads and trackers from other sites (EasyList, EasyPrivacy). A site's own requests always load.
  - Aggressive (the default): also a site's own ads and trackers, uBlock Origin's filters, and the empty boxes ads leave.
  - Ultra aggressive: also cookie notices (EasyList Cookie), newsletter and sign-up pop-ups and other annoyances (uBlock's list).
  - uBlock Origin's fixes for sites the lists would break are on at every level, and Shields can be turned off for one site.
  - The lists are fetched again every four days.
- **A new icon.**

**Linux**
- The lists become WebKit content rules, compiled once in the background (about 40 seconds the first time, then kept) and swapped in for open pages.
- Glass, menus and the window take the look's colours as they draw.

**Android**
- **Chromium inside Iris again (Cefrium)**: the same engine on every phone, whatever its WebView is, with H.264 and AAC.
- Shields decide every request Chromium is about to make, on its network thread, in about 12 microseconds, and hide what ads leave behind.
- **Liquid Glass, no Material Design**: Iris's own glass bars, buttons, panels, switches and line icons, in light and dark.
- Containers and private tabs are Cefrium profiles; the YouTube ad skipper is back (YouTube sees no ad blocker).

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer, 64-bit). It is larger again, because Chromium is inside.

---

Iris 2.0.1: lighter, history, container icons, calls, and Iris for Android on System WebView.

**Linux**
- Lighter on memory:
  - every tab shares one WebKit web context (one pool of web processes and caches), and containers keep their own cookies and storage;
  - each web process has a memory limit and gives memory back early;
  - background tabs sleep after 10 minutes, no more than 3 stay awake, and a tab playing sound never sleeps.
- Lighter on the GPU: the glass chrome is kept as one picture while nothing in it changes, so a playing video redraws only itself. In a test with software rendering, an animated page drew 2.1 times the frames.
- Light video on YouTube (on by default): YouTube sends H.264 instead of VP9 or AV1, a fraction of the processor time. It's a switch in the menu.
- Video in blocks: decoding on the graphics chip is now off by default, because some drivers broke the picture into blocks. A menu switch turns it back on from the next start.
- History: in the menu and with Ctrl+H, by day, and searchable.
- Container icons: twelve to choose from when making a container. They show on tabs, in menus and in the address bar.
- Calls: WebRTC with the camera, microphone and screen sharing (the Flatpak can now reach cameras and PipeWire).

**Android**
- Iris for Android now runs on Android System WebView: a small APK, the phone's own up-to-date Chromium, and good battery life.
- Containers through WebView profiles (each with its own cookies and storage).
- Shields stop requests to about 100,000 ad and tracker domains.
- Ads open no tabs.
- A downloads manager, pull to reload, calls, sleeping tabs and auto-update.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak`
- Android: `Iris-android.apk` (Android 10 and newer). Updates install over it when every release is signed with the same key.
