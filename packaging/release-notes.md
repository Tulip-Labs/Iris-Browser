Iris 2.0.0 is a new Iris, made again from the start.

**Linux: Swift, libadwaita and WebKitGTK, in Liquid Glass**
- Written in Swift with swift-adwaita; pages by WebKitGTK; installed as a Flatpak.
- Real Liquid Glass, not frosted: the glass bends what lies behind it (pulled in at the rim, with a touch of colour splitting), with a rim of light and a highlight that follows the pointer. Drawn by GTK's own renderer, sharp at every display scale (niri at 1.25 included).
- A translucent window: on compositors that offer background blur (niri 26.04 and newer, through ext-background-effect), the desktop shows through, blurred.
- Springs everywhere: tabs slide into place, the selected tab's glass slides from tab to tab and stretches on the way, menus open and close as glass.
- Containers are worlds apart: each has its own cookies, storage, cache and sign-ins on disk. Private tabs leave nothing.
- Iris Shields block about 100,000 ad and tracker domains inside WebKit; per site or everywhere.
- Ads open no tabs: a pop-up needs your click, and goes only to the same site or a sign-in page. Anything else is stopped, with an Open button if you wanted it.
- Iris's own glass menu on a right click (links, images, video, selections, text fields, the page), a downloads panel, find in page.
- Updates: Iris tells you when a new version is out; Flatpak installs it.

**Android: Kotlin, Jetpack Compose and GeckoView**
- Firefox's engine (GeckoView) with Material 3; containers through GeckoView's contextId; one engine runtime for all tabs.
- Shields: Firefox's strict tracking protection, cookie banners refused, and uBlock Origin built in.
- A downloads manager, pull down to reload, and Iris updates itself from GitHub.
- Closing the tab you are on no longer closes Iris. Ads open no tabs.
- A cleaner bar: no tab counter, one "+" (in the tab strip), no placeholder text, no shields label, no AI star; downloads where the menu was.

**Also**
- A new icon: Iris, goddess of the rainbow, in liquid glass.
- Windows, Nix, the Snap and the container image are gone; Linux ships as a Flatpak.

**Install**
- Linux: `flatpak install --user Iris-x86_64.flatpak` (needs the GNOME 50 runtime from Flathub).
- Android: `Iris-android.apk`. Earlier versions were signed with a different key, so Android may ask you to uninstall the old Iris first; from 2.0.0 on, updates install over it.
