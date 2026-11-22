Iris 2.1.1: Google AI Mode in every new tab, a light look in the colours of dawn, an automatic sandbox for sites Iris does not trust, a new icon, and Android on System WebView again.

**Both**
- **Every new tab is Google AI Mode**, ready for a question, dressed in Iris's Liquid Glass: the dawn behind the page, its panels clear, and the question box made of glass. (Only AI Mode is restyled; no other page.) The Iris start page is gone. Your tabs still open where you left them.
- **Faster.** The next new tab is already loaded in the background, so it opens at once; Google's names are looked up before your first question; and a result you open goes straight to the site, without Google's redirect. On Linux, a link's site is looked up while the pointer rests on it.
- **The sandbox, automatic.** A site Iris does not trust (no encryption, a bare IP address, or a certificate that fails) opens in the sandbox without asking: web processes of its own, a world in memory that sees none of your cookies, storage or sign-ins and is wiped when you close it, and no downloads, camera, microphone, location, clipboard or pop-ups. Going on to a trusted site takes you out of it.
- **Ads that open new tabs are stopped** (Android, see below; Linux already did).
- **Light only**, and lighter: Iris's glass over a dawn of lilac, rose and peach, with a deep violet ink.
- **A new icon**: Iris's profile, her hair in sheets of liquid glass.
- **No more menu.** Find in page (Ctrl+F) and zoom (Ctrl+plus, minus and 0) stay as keys. The downloads button appears while a file comes in, then stays with the number finished until you open it.
- Tabs no longer sleep in the background.

**Android**
- **Pages open again.** Iris uses the phone's Android System WebView instead of Cefrium, which left pages blank on some phones.
- **Ads that open new tabs are stopped**: a page opens no tab by itself, a tapped ad link opens nothing, a script's window stays hidden until Iris knows where it goes, and a page cannot send its own tab to an ad.
- The sandbox runs in a process of its own, with WebView data that is made fresh each time.
- File fields, calls (camera and microphone) and full-screen video work again. The APK is small again.

**Linux**
- The sandbox is a WebKit web context of its own, each page in WebKit's bubblewrap sandbox, with a network session per sandboxed tab that lives in memory only. Its tabs have an orange rim.

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
