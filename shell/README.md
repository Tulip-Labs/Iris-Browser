# Iris Shell for niri

Iris Shell is the background and the window glass for [niri](https://github.com/YaLTeR/niri), and nothing else. There is no menu, dashboard, launcher, terminal, file or memory card: niri keeps its own keys and does everything it did. Written in Odin on Wayland and EGL/GLES (no GTK, no GLib, no Go).

What it draws:

1. **The background.** One wlr-layer-shell surface per screen, on the background layer (no input, nothing reserved: exclusive zone -1). Clear, colourless glass in graphite (dark) or near white (light), with the Iris ring of colour from the Iris icon: the spectrum from red through green to blue, gathered at the lower rim, lit from above, never purple.
2. **The window glass.** In the gaps between windows, a soft halo behind each window in that window's colour, strongest along its border, like a reflection of what the window shows. It moves with the window when niri scrolls, and changes colour when the window's title changes (a YouTube tab is red; switch to GitHub and the halo eases to grey).
3. **niri set up for it.** `iris-shell --setup-niri` writes the settings that give the glass room to show.

## Install

From the release (`iris-shell-x86_64.tar.gz`, Linux x86_64; it needs libwayland-client, libwayland-egl, EGL and GLESv2, which any desktop with niri has):

```sh
tar xzf iris-shell-x86_64.tar.gz && cd iris-shell-x86_64
./install.sh               # ~/.local/bin/iris-shell (put that folder in PATH: niri starts programs with it)
iris-shell --setup-niri    # niri 25.11 or newer
```

niri reloads its settings by itself; the shell starts with your next sign-in, or run `iris-shell &` now. To remove everything: `./install.sh --remove` (it runs `iris-shell --remove-niri` first).

From source: `sh shell/build.sh release` (needs Odin dev-2026-11 or newer, a C compiler, and the development files of wayland, wayland-egl, EGL and GLES), then `sh shell/build.sh package`.

## Commands

| | |
|---|---|
| `iris-shell` | start the shell. A shell that is already running is asked to leave first, so starting it again restarts it. |
| `iris-shell --setup-niri` | write `~/.config/niri/iris-shell.kdl`, add `include "iris-shell.kdl"` to `config.kdl` (after a backup, `config.kdl.before-iris-shell`) and comment out the line that starts Waybar (marked `// hidden by Iris Shell:`). Safe to run twice. |
| `iris-shell --remove-niri` | put Waybar's line back, take the include out, delete `iris-shell.kdl`. |
| `iris-shell --dark` / `--light` / `--auto` | set GNOME's `color-scheme` (apps follow it, as with Ember) and tell the running shell. |
| `iris-shell --quit`, `--status`, `--version` | |
| `iris-shell --check` | map the background, draw one frame and exit 0 (used by CI). |

Environment: `IRIS_THEME=dark\|light` fixes the theme, `IRIS_SHELL_ANIM=0` turns the animation off, `IRIS_SHELL_CAPTURE=0` never reads a window's pixels, `IRIS_SHELL_FULLRES=1` draws at full resolution, `IRIS_SHELL_DEBUG=1` logs what it does.

`iris-shell.kdl` starts the shell (`spawn-at-startup "iris-shell"`), sets gaps of 16, rounded windows (radius 18), a clear glass focus ring, soft shadows, the overview's backdrop, and a `layer-rule` that shows the background behind the overview. It follows light and dark: the running shell rewrites the file when the theme changes (and only when it is still the file the shell wrote). Put your own settings in `config.kdl`.

## How it works

- **Windows.** The shell connects to `$NIRI_SOCKET`, sends `"EventStream"`, and reads one JSON object per line: `WindowsChanged`, `WindowOpenedOrChanged`, `WindowClosed`, `WindowFocusChanged`, `WindowLayoutsChanged`, `WorkspacesChanged`, `WorkspaceActivated`, `OverviewOpenedOrClosed`. With niri 25.11's window `layout` it knows each tiled window's rectangle in its workspace view. For each output it draws the windows of that output's active workspace.
- **Colour.** From a small table (a site's name in the title: YouTube, GitHub, Reddit, Spotify, ...; or an app: terminals, code editors), else a steady hue made from the app id, nudged a little by the title. The hues run from red to blue only. If the compositor advertises `ext-foreign-toplevel-list-v1`, `ext-foreign-toplevel-image-capture-source-manager-v1` and `ext-image-copy-capture-v1`, the colour comes from the window's own pixels instead (see limits).
- **Drawing.** One full-screen triangle and one shader per output: ground, ring, and up to 16 halos. The buffer is half the output's size, scaled up by the compositor through wp_viewporter (the glass is soft anyway; a quarter of the memory and fill work).
- **Animation.** One ease of about 300 ms (ease-out cubic) moves every halo's position, size, colour and strength, and the light/dark mix, from what is shown to the new scene. It runs on frame callbacks and only while it runs.
- **Sleeping.** One `poll` over the Wayland socket, niri's socket, the control socket, an inotify watch on the dconf database (to notice a theme change), and a self-pipe for signals. No timers while the picture is still, so idle CPU is zero. The theme is read with `gsettings get` (a short child process) only when dconf changed.
- **One at a time.** The control socket `$XDG_RUNTIME_DIR/iris-shell.sock` is also how `--quit`, `--status` and `--dark` reach the running shell.

The Wayland bindings are the Iris browser's (`linux/wl`, copied here unchanged; CI checks the copy) plus `wl/protocols_shell.odin`, generated by `tools/gen.sh` from `protocols/*.xml`: wlr-layer-shell and the ext capture protocols. `abi/check.sh` compares those tables with wayland-scanner's.

## Honest limits

- **Not run on niri by the author.** It was written without a niri or any compositor at hand. It is type-checked, its logic is tested (niri's JSON events, scenes, animation, colours, the KDL and `config.kdl` edits), and CI runs it on a headless sway (which has layer-shell). Everything that touches real niri (the layout fields, the halos lining up with the windows, `include`) is unproven until someone runs it. Please report what you see.
- **Where the halos are.** Window positions are in niri's workspace view. They match the screen when nothing reserves space at its edges (Waybar hidden; niri `struts` of zero). Floating windows have no tile position, so they get no halo. In the overview the halos fade out.
- **Window capture is probably not on niri.** The compositor must offer all three protocols; niri may not, and then the colours come from the app id and the title (that is what you get). When it is offered, the protocol cannot ask for a small copy: each sample is one whole window in a shared-memory buffer for a moment (one window at a time, 2 a second, only windows on screen, a 24 x 24 grid of pixels read, then the buffer is freed). That costs a timer wake-up and a memory spike of one window's size while it runs. After three failures it switches itself off. This path is untested against a real compositor.
- **Memory.** The shell's own data is tiny, but Mesa's EGL and GLES drivers add several megabytes to any program that uses them; whether the total is under 15 MB depends on the driver and was not measured. CI prints the shell's VmRSS from a software-rendered run.
- **Light and dark** follow GNOME's `color-scheme` (`gsettings`), so a desktop without it stays dark, unless `IRIS_THEME` or `--dark` / `--light` say otherwise. `--dark` and `--light` do not write GTK 3's `settings.ini`.
- **Waybar** is hidden by editing the line that starts it in `config.kdl`. If something else starts it (a systemd unit, an autostart file), stop that too.
- Needs niri 25.11 or newer for `include` and for window layouts. Needs a compositor with wlr-layer-shell (niri, sway, Hyprland). The release binary is built on a current Arch, so it needs a similarly recent glibc.
- Licence: GPL-3.0, as the rest of Iris.
