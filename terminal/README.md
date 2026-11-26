# Iris Terminal

A clear-glass terminal for niri, zsh and Fedora's immutable desktops
(Silverblue, Kinoite). Written in Odin: no GTK, no VTE, no Go, no X11. Wayland,
EGL/GLES, HarfBuzz and fontconfig, nothing else.

It follows the house style of Iris: colourless clear glass (black by default,
light when the GNOME colour scheme is light), no background service, no timers,
no CPU when nothing changes, no tabs, no plugins.

## Install

```sh
tar xzf iris-terminal-x86_64.tar.gz && cd iris-terminal-x86_64 && ./install.sh
iris-terminal --setup-niri      # rounded glass; blur on niri 26.04 and newer
iris-terminal --setup-zsh       # the refined zsh (also offered once, on the first run)
iris-terminal --install-fonts   # MesloLGS NF, only if you ask for it
```

`install.sh` puts the binary in `~/.local/bin`, a launcher entry and an icon in
`~/.local/share`. Nothing is layered, nothing needs root. `./install.sh --remove`
undoes `--setup-niri` and `--setup-zsh` and deletes it all (your settings stay).

Build it yourself: `./build.sh release` (Odin dev-2026-11 or newer, a C compiler for
linking, and the development files of wayland, wayland-egl, EGL, GLES, xkbcommon,
fontconfig and harfbuzz). `./build.sh test` runs the unit tests, `./build.sh check`
type-checks, `./build.sh package` makes the tarball.

## Keys

| | |
|---|---|
| Ctrl+Shift+C / Ctrl+Shift+V | copy / paste (selecting also fills the primary selection: middle click pastes it) |
| click, double click, triple click, drag | select characters, a word, a line; Alt+drag a block; Shift+drag while a program uses the mouse |
| Ctrl+click | open a link (OSC 8, or a URL on screen) with `xdg-open` |
| Shift+PgUp / PgDn, Shift+Home / End, wheel | scroll the history |
| Ctrl+Shift+Up / Down | jump to the previous / next shell prompt (needs the zsh setup, or any shell that sends OSC 133) |
| Ctrl+Shift+F | search the history (Enter / Shift+Enter: next / previous, Esc closes) |
| Ctrl+= / Ctrl+- / Ctrl+0 | font size bigger / smaller / as configured |
| Ctrl+Shift+N | a new window (a new process; there are no tabs and no splits) |
| Ctrl+Shift+T | a new window inside your distrobox/toolbox container (`container` in the settings, else the first one `distrobox list` shows) |

## Settings

A text file, `~/.config/iris-terminal/config`, one `key = value` per line, reloaded
as soon as you save it. `iris-terminal --write-config` writes a commented one with
every default. There is no settings window.

Fonts: `font` is a list of families; the first installed one is the main font and the
others fill in what it lacks. The default list is MesloLGS NF, JetBrainsMono Nerd Font,
FiraCode Nerd Font, Symbols Nerd Font Mono, DejaVu Sans Mono (one copy of DejaVu Sans
Mono is built in, so there is always a font). `iris-terminal --fonts` says what it found.

## zsh

`iris-terminal --setup-zsh` writes `~/.config/iris-terminal/zsh/init.zsh` and adds one
block to `~/.zshrc` (a backup is kept as `.zshrc.before-iris-terminal`).
`--remove-zsh` takes both out. The config sets up history, a completion menu, a few
keys, loads zsh-autosuggestions and zsh-syntax-highlighting if they are installed
(`/usr/share/zsh*`, `~/.local/share`, Homebrew), and a prompt that reads the git branch
from `.git/HEAD` without starting a process: folder, branch, the container name,
devbox/nix, the exit status and the duration of slow commands. It uses powerline/Nerd
glyphs only when the font has them (`IRIS_TERMINAL_NERD`, set by the terminal) and
sends OSC 7 (folder) and OSC 133 (prompt marks). `IRIS_PROMPT=0` before the block keeps
your own prompt.

## Containers

`iris-terminal --container NAME` runs `distrobox enter NAME` in the window; the name is
shown in the title bar and in the prompt. Inside a container, `toolbox` and `distrobox`
are both recognised by the prompt (`CONTAINER_ID`, `/run/.containerenv`).

## For tests

`--exec CMD` runs CMD instead of a shell, `--dump-screen FILE` / `--dump-state FILE` /
`--dump-frame FILE` write what the screen holds, the cells' colours and attributes, and
the frame as a picture when it ends; `--no-window` does the same without any window.
CI (`.github/workflows/terminal.yml`) uses them under a headless sway.

## Limits

- No colour emoji: glyphs are drawn from outlines only, so colour fonts (Noto Color
  Emoji) draw nothing. No sixel or other image protocols.
- No kitty keyboard protocol and no modifyOtherKeys: keys are xterm's classic ones.
- No input method (IME, text-input-v3) support; dead keys and the compose key work
  (libxkbcommon).
- The cursor does not blink. The selection does not scroll by itself while you drag
  past the edge. A character followed by U+FE0F is not widened. The colour of curly
  underlines (SGR 58) is ignored: they take the text colour.
- Blur needs niri 26.04 or newer (a window rule) or a compositor with
  `ext-background-effect-v1`; without it the glass is a little more opaque.
- It was proved by tests under a headless sway with software rendering, and with real
  vim, less, tmux and zsh; it has not been run on a real GPU and a real niri session
  by its author.
- Resizing reflows the main screen's lines (wrapped lines rejoin), but not the
  alternate screen: full-screen programs redraw on SIGWINCH.

## Licence

GPL-3.0-or-later (the repository's LICENSE). The built-in fallback font is DejaVu Sans
Mono under the Bitstream Vera licence (`THIRD_PARTY_NOTICES.txt`).
