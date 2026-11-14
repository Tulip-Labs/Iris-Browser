#!/bin/sh
# Installs Lite Go for the current user (no root needed): the program folder
# to ~/.local/lib/lite-go-browser, the command lite-go to ~/.local/bin, and
# its menu entry and icon to ~/.local/share.
#   ./install.sh            install (from the unpacked LiteGo-linux folder)
#   ./install.sh --remove   remove it again
# Lite Go carries its own Chromium; it needs GTK 3 and the libraries every
# desktop has (NSS, ALSA, libdrm, libgbm, libxkbcommon).
set -eu
cd "$(dirname "$0")"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
LIB="$HOME/.local/lib/lite-go-browser"

if [ "${1:-}" = "--remove" ]; then
	rm -rf "$LIB" "$LIB.new" "$LIB.old"
	rm -f "$BIN/lite-go" "$BIN/lite-go.sha256" "$SHARE/applications/lite-go.desktop" "$SHARE/icons/hicolor/256x256/apps/lite-go.png"
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$SHARE/applications" || true
	echo "Lite Go is removed (your settings stay in "~/.config/Lite Go")."
	exit 0
fi

[ -x ./lite-go-browser ] && [ -f ./libcef.so ] || { echo "Run this from the unpacked LiteGo-linux folder." >&2; exit 1; }
mkdir -p "$BIN" "$SHARE/applications" "$SHARE/icons/hicolor/256x256/apps" "$(dirname "$LIB")"
# the new folder goes in with one rename (a running Lite Go keeps going)
rm -rf "$LIB.new" "$LIB.old"
mkdir "$LIB.new"
cp -r . "$LIB.new/"
rm -f "$LIB.new/install.sh"
[ -d "$LIB" ] && mv "$LIB" "$LIB.old"
mv "$LIB.new" "$LIB"
rm -rf "$LIB.old"
rm -f "$BIN/lite-go" "$BIN/lite-go.sha256" # 1.0.7 and older: the program itself
ln -s "$LIB/lite-go-browser" "$BIN/lite-go"
sed "s#^Exec=lite-go#Exec=$BIN/lite-go#" lite-go.desktop > "$SHARE/applications/lite-go.desktop"
install -m 644 lite-go.png "$SHARE/icons/hicolor/256x256/apps/lite-go.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$SHARE/applications" || true
if command -v ldd >/dev/null 2>&1 && ldd "$LIB/libcef.so" | grep -q "not found"; then
	echo "Installed, but some system libraries are missing:" >&2
	ldd "$LIB/libcef.so" "$LIB/lite-go-browser" | grep "not found" | sort -u >&2
fi
echo "Lite Go is installed: it is in your app list, or run lite-go."
