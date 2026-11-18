#!/bin/sh
# Installs Iris for the current user (no root needed): the program folder
# to ~/.local/lib/iris-browser, the command iris to ~/.local/bin, and its
# menu entry and icon to ~/.local/share.
#   ./install.sh            install (from the unpacked Iris-linux folder)
#   ./install.sh --remove   remove it again
# Iris carries its own Chromium; it needs GTK 4 and the libraries every
# desktop has (NSS, ALSA, libdrm, libgbm, libxkbcommon).
set -eu
cd "$(dirname "$0")"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
LIB="$HOME/.local/lib/iris-browser"
ID=io.github.tulip_labs.Iris
# what Iris was installed as until 1.0.19 (Lite Go)
OLD="$HOME/.local/lib/lite-go-browser"
old_files() {
	rm -rf "$OLD" "$OLD.new" "$OLD.old"
	rm -f "$BIN/lite-go" "$BIN/lite-go.sha256" "$SHARE/applications/lite-go.desktop" "$SHARE/icons/hicolor/256x256/apps/lite-go.png"
}

if [ "${1:-}" = "--remove" ]; then
	rm -rf "$LIB" "$LIB.new" "$LIB.old"
	old_files
	rm -f "$BIN/iris" "$SHARE/applications/$ID.desktop" "$SHARE/icons/hicolor/256x256/apps/$ID.png"
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$SHARE/applications" || true
	echo "Iris is removed (your settings stay in ~/.config/Iris)."
	exit 0
fi

[ -x ./iris ] && [ -f ./libcef.so ] || { echo "Run this from the unpacked Iris-linux folder." >&2; exit 1; }
mkdir -p "$BIN" "$SHARE/applications" "$SHARE/icons/hicolor/256x256/apps" "$(dirname "$LIB")"
# the new folder goes in with one rename (a running Iris keeps going)
rm -rf "$LIB.new" "$LIB.old"
mkdir "$LIB.new"
cp -r . "$LIB.new/"
rm -f "$LIB.new/install.sh" "$LIB.new/lite-go-browser" "$LIB.new/lite-go-browser.sha256" "$LIB.new/lite-go-helper"
[ -d "$LIB" ] && mv "$LIB" "$LIB.old"
mv "$LIB.new" "$LIB"
rm -rf "$LIB.old"
old_files
ln -sf "$LIB/iris" "$BIN/iris"
sed "s#^Exec=iris#Exec=$BIN/iris#" "$ID.desktop" > "$SHARE/applications/$ID.desktop"
install -m 644 "$ID.png" "$SHARE/icons/hicolor/256x256/apps/$ID.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$SHARE/applications" || true
if command -v ldd >/dev/null 2>&1 && ldd "$LIB/libcef.so" | grep -q "not found"; then
	echo "Installed, but some system libraries are missing:" >&2
	ldd "$LIB/libcef.so" "$LIB/iris" | grep "not found" | sort -u >&2
fi
echo "Iris is installed: it is in your app list, or run iris."
