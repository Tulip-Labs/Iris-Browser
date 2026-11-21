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
