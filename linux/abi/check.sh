#!/bin/sh
# Every hand-written C binding against the real headers: each foreign
# procedure's parameters and result (machine types, as clang reads the
# headers), each marked struct's size and offsets, and the Wayland protocol
# tables against wayland-scanner's. Run from anywhere: sh abi/check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
MODS="harfbuzz fontconfig libsoup-3.0 glib-2.0 gio-unix-2.0 wayland-client wayland-egl wayland-cursor xkbcommon egl glesv2 libdrm"
HEADERS="hb.h fontconfig/fontconfig.h libsoup/soup.h glib.h glib-object.h glib-unix.h gio/gio.h wayland-client.h wayland-egl.h wayland-cursor.h xkbcommon/xkbcommon.h EGL/egl.h EGL/eglext.h drm_fourcc.h iris_core.h"
python3 abi/check.py --headers "$HEADERS" --cflags "$(pkg-config --cflags $MODS) -I$here/../core/include" \
	--import iris="$here/src" --import wl="$here/wl" --import plat="$here/plat" \
	$(ls src/*.odin | grep -v "/cef_") plat/*.odin wl/client.odin
sh abi/check-wayland.sh
# the CEF bindings: abi/check-cef.sh (needs the CEF headers, CEF_DIR)
