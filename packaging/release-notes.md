Iris 2.1.1: Iris for Android on System WebView again, and ads that open new tabs stopped.

**Android**
- **Pages open again.** Iris uses the phone's Android System WebView (Chromium, kept up to date by Google Play) instead of Cefrium, which left pages blank on some phones. Searching and going to sites work.
- **Ads that open new tabs are stopped**, not only those in the page:
  - A page cannot open a tab or window by itself, only when you tap.
  - A tapped link to an ad or tracker opens nothing.
  - A window a script opens stays hidden until Iris knows where it goes: the same site or a sign-in opens as a tab, an ad is closed unseen, and another site waits behind a "Pop-up stopped · Open" note.
  - A page that tries to send its own tab to an ad (a redirect, or a script without a tap on that link) stays where it is.
  - Every stopped pop-up counts in the Shields badge.
- Shields keep their three levels (Moderate, Aggressive, Ultra aggressive) and decide every request WebView is about to make, before it leaves the phone; what ads leave behind is hidden.
- Liquid Glass stays, with no Material Design. Pages follow the look (Light or Dark). Containers are WebView profiles (System WebView 123 and newer). File fields, calls (camera and microphone) and full-screen video work again.
- The APK is small again (no Chromium inside).

**Linux**
- No changes; the version follows Android's.

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
