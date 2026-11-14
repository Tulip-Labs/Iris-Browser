#!/bin/sh
# Installs Lite Go for the current user (no root needed): the program to
# ~/.local/bin, its menu entry and its icon to ~/.local/share.
#   ./install.sh            install (from the folder with lite-go in it)
#   ./install.sh --remove   remove it again
# Lite Go needs WebKitGTK 4.1 and GTK 3 on the system; most desktops have
# them. Otherwise: Fedora "webkit2gtk4.1", Debian/Ubuntu "libwebkit2gtk-4.1-0",
# Arch "webkit2gtk-4.1" (on Fedora Atomic: rpm-ostree install webkit2gtk4.1).
set -eu
cd "$(dirname "$0")"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"

if [ "${1:-}" = "--remove" ]; then
	rm -f "$BIN/lite-go" "$BIN/lite-go.sha256" "$SHARE/applications/lite-go.desktop" "$SHARE/icons/hicolor/256x256/apps/lite-go.png"
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$SHARE/applications" || true
	echo "Lite Go is removed (your settings stay in "~/.config/Lite Go")."
	exit 0
fi

[ -x ./lite-go ] || { echo "Run this from the folder that has lite-go in it (dist/linux)." >&2; exit 1; }
mkdir -p "$BIN" "$SHARE/applications" "$SHARE/icons/hicolor/256x256/apps"
install -m 755 lite-go "$BIN/lite-go"
install -m 644 lite-go.sha256 "$BIN/lite-go.sha256"
sed "s#^Exec=lite-go#Exec=$BIN/lite-go#" lite-go.desktop > "$SHARE/applications/lite-go.desktop"
install -m 644 lite-go.png "$SHARE/icons/hicolor/256x256/apps/lite-go.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$SHARE/applications" || true
if command -v ldd >/dev/null 2>&1 && ldd "$BIN/lite-go" | grep -q "not found"; then
	echo "Installed, but some system libraries are missing:" >&2
	ldd "$BIN/lite-go" | grep "not found" >&2
	echo "Install WebKitGTK 4.1 (see the top of this script)." >&2
fi
echo "Lite Go is installed: it is in your app list, or run lite-go."
