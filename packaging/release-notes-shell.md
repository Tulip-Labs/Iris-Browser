Iris Shell 1.0.0: the background and the window glass for niri.

Iris Shell is not a desktop environment and has no menu, launcher, bar or cards: niri keeps its own keys and does everything it did. The shell is only:

- **The background.** A clear glass background on every screen (a wlr-layer-shell surface on the background layer: no input, nothing reserved), with the Iris ring of colour, light or dark with your desktop (GNOME `color-scheme`; black glass by default).
- **The window glass.** In the gaps between windows, a soft halo behind each window in that window's colour, strongest along its border, as if the glass reflected it. It follows the window when you scroll, and changes when what you watch changes (YouTube is red, GitHub grey; other apps get a steady colour of their own). When the compositor offers `ext-image-copy-capture-v1`, the colour is read from the window's own pixels (a few samples a second, one window at a time).
- **niri set up for it.** `iris-shell --setup-niri` writes `~/.config/niri/iris-shell.kdl` (starts the shell with niri, gaps, rounded corners, a glass focus ring, soft shadows), adds one `include` line to `config.kdl` after a backup, and hides Waybar. `iris-shell --remove-niri` undoes all of it.

It sleeps until something changes: no timers while the picture is still, one 300 ms ease when a colour, a window or the theme changes. One shell at a time: starting it again replaces the old one. No background services.

**Install** (Linux x86_64, needs niri 25.11 or newer)
- `tar xzf iris-shell-x86_64.tar.gz && cd iris-shell-x86_64 && ./install.sh`
- `iris-shell --setup-niri`
- To remove: `./install.sh --remove` (runs `--remove-niri` first).

**Limits**
- Halos need the window layout niri 25.11 reports; floating windows get none.
- The shell draws at half resolution, scaled up by the compositor: the glass is soft, and it keeps memory low.
- niri may not offer window capture; then colours come from the app id and title.
