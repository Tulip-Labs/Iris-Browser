#!/bin/sh
# Every hand-written C binding against the real headers: each foreign
# procedure's parameters and result (machine types, as clang reads the
# headers), each marked struct's size and offsets, and the Wayland protocol
# tables against wayland-scanner's. Run from anywhere: sh abi/check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
MODS="wpe-webkit-2.0 wpe-platform-2.0 wpe-platform-headless-2.0 libsoup-3.0 glib-2.0 gio-unix-2.0 wayland-client wayland-egl wayland-cursor xkbcommon egl glesv2 libdrm"
HEADERS="wpe/webkit.h wpe/wpe-platform.h wpe/headless/wpe-headless.h libsoup/soup.h glib.h glib-object.h glib-unix.h gio/gio.h wayland-client.h wayland-egl.h wayland-cursor.h xkbcommon/xkbcommon.h EGL/egl.h EGL/eglext.h drm_fourcc.h"
python3 abi/check.py --headers "$HEADERS" --cflags "$(pkg-config --cflags $MODS)" \
	--import iris="$here/src" --import wl="$here/wl" --import plat="$here/plat" \
	src/*.odin plat/*.odin wl/client.odin
sh abi/check-wayland.sh
