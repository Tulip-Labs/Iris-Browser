#!/bin/sh
# Builds Iris for Linux with the Electron page engine into a folder (default
# dist/linux-electron): the program, Electron, and Iris's helper with the one
# library it needs (electron-chrome-extensions). Electron is trimmed to what
# Iris uses: English and Spanish strings only, no sample files.
set -e
cd "$(dirname "$0")/../.."
out=${1:-dist/linux-electron}
mkdir -p "$out"
# Servo for the light pages, when its bridge is built (webview/servo/lib,
# from .github/workflows/servo-lib.yml or cargo in webview/servo/rust)
tags="webkit electron"
if [ -f webview/servo/lib/libirisservo.so ]; then
	tags="$tags servo"
	cp webview/servo/lib/libirisservo.so "$out/"
	echo "With Servo for light pages"
fi
CGO_ENABLED=1 go build -tags "$tags" -trimpath -ldflags "-s -w" -o "$out/iris" ./cmd/iris

helper=webview/electron/helper
(cd "$helper" && npm install --no-audit --no-fund --loglevel=error)
# Electron's binary comes from its own installer, which npm may skip
if [ ! -x "$helper/node_modules/electron/dist/electron" ]; then
	(cd "$helper/node_modules/electron" && node install.js)
fi
[ -x "$helper/node_modules/electron/dist/electron" ] || { ls -la "$helper/node_modules/electron"; echo "Electron's binary is missing"; exit 1; }
echo "Electron $(cat "$helper/node_modules/electron/dist/version" 2>/dev/null)"
rm -rf "$out/electron" "$out/electron-helper"
cp -a "$helper/node_modules/electron/dist" "$out/electron"
# only the strings Iris's readers use (Chromium falls back to English)
find "$out/electron/locales" -name '*.pak' ! -name 'en-US.pak' ! -name 'es.pak' ! -name 'es-419.pak' -delete
rm -f "$out/electron/resources/default_app.asar"

# the helper is Electron's app (resources/app), with its one runtime library:
# Electron starts it with nothing to open (default_app.asar, which opens a
# folder given on the command line, is left out above)
app="$out/electron/resources/app"
mkdir -p "$app"
cp "$helper/main.js" "$helper/preload.js" "$helper/package.json" "$app/"
tmp=$(mktemp -d)
cp "$helper/package.json" "$tmp/"
(cd "$tmp" && npm install --omit=dev --no-audit --no-fund --loglevel=error)
[ -d "$tmp/node_modules" ] && cp -a "$tmp/node_modules" "$app/"
rm -rf "$tmp"
du -sh "$out/iris" "$out/electron" "$app" | sed 's/^/size: /'
