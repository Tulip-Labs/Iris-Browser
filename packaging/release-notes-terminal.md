Iris Terminal 1.0.0: a clear-glass terminal for niri, zsh and Fedora's immutable desktops.

Iris Terminal is a terminal emulator written in Odin (no GTK, no VTE, no X11). It draws a colourless clear glass window in the house style of Iris, with the text sharp at any scale, and it sleeps until something happens: no background service, no timers, no CPU when nothing changes.

- **A real terminal.** `xterm-256color` with truecolor; UTF-8, wide and combining characters; 256 and 24-bit colour; bold, italic, dim, strike, reverse and five underline styles; cursor styles; alternate screen; a 10 000-line scrollback; mouse reporting (X10, 1000, 1002, 1003, SGR), bracketed paste, focus events, synchronized output; OSC 0/2 titles, 7 (folder), 8 (links, Ctrl+click opens them with `xdg-open`), 52 (copy to the clipboard, write only), 133 (jump between prompts with Ctrl+Shift+Up/Down). Works with zsh, vim, nvim, tmux, htop, less and fzf.
- **Glass.** A translucent window with a soft rim of light, a subtle glow on the cursor, a subtle flash for the bell and one light fade-in. Black glass by default; the light theme follows the GNOME colour scheme. On niri 26.04 and newer, `iris-terminal --setup-niri` makes niri blur what is behind it (rounded corners and no border background on older niri).
- **Fonts and symbols.** fontconfig finds MesloLGS NF, JetBrainsMono Nerd Font, FiraCode Nerd Font, Symbols Nerd Font Mono, DejaVu Sans Mono (one is built in). HarfBuzz shaping with ligatures. Box drawing, blocks, braille and the powerline separators are drawn by the terminal itself, so they join perfectly. `iris-terminal --install-fonts` downloads MesloLGS NF into `~/.local/share/fonts`, only when you run it.
- **zsh at home.** `iris-terminal --setup-zsh` (offered once on the first run) writes a refined config to `~/.config/iris-terminal/zsh` and adds one block to `~/.zshrc` after a backup: history, a completion menu, autosuggestions and syntax highlighting when their plugins are installed, and a fast built-in prompt with the git branch, exit status, folder, duration and container name. `iris-terminal --remove-zsh` undoes it.
- **Fedora immutable.** Works as it is on Silverblue and Kinoite (user install, nothing layered). `--container NAME` opens inside a distrobox/toolbox; Ctrl+Shift+T opens a window in your container; the container name shows in the title bar and in the prompt (devbox and nix too).
- **Keys.** Ctrl+Shift+C/V copy and paste, selection copies to the primary selection (middle click pastes), double and triple click, Alt+drag for a block, Shift+drag while a program uses the mouse, Ctrl+Shift+F searches the scrollback, Ctrl+= / Ctrl+- / Ctrl+0 change the font size, Ctrl+Shift+N opens a new window (a new process: no tabs, no splits), Shift+PgUp/PgDn scroll.
- **Settings** are a text file, `~/.config/iris-terminal/config`, reloaded as you save it (`iris-terminal --write-config` writes a commented one). No settings window.

**Install** (Linux x86_64, Wayland, GPU or software GLES 3)
- `tar xzf iris-terminal-x86_64.tar.gz && cd iris-terminal-x86_64 && ./install.sh`
- `iris-terminal --setup-niri`, `iris-terminal --setup-zsh`
- To remove: `./install.sh --remove` (undoes the niri and zsh setup first).

**Limits**
- No colour emoji (glyphs are drawn from outlines only); emoji in a text font show as outlines or boxes.
- No kitty keyboard protocol or modifyOtherKeys, no sixel or images, no input method (IME) support, no cursor blink.
- Selection does not scroll by itself while dragging past the edge; U+FE0F does not widen a character.
- The blur needs niri 26.04 or newer (or another compositor with ext-background-effect); without it the glass is a little more opaque.
- The Wayland, GL, font and zsh parts were proved by CI under a headless sway, not on a real niri desktop.
