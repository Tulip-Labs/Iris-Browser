#!/bin/sh
# Iris for Linux: Odin, Wayland, EGL/GLES and WPE WebKit (no GTK, no X11).
#   ./build.sh              a quick build for working on it (no optimisation): ./iris
#   ./build.sh release      the optimised build, as the Flatpak ships it
#   ./build.sh test         the tests
#   ./build.sh check        the hand-written C bindings against the real headers
#   ./build.sh install DIR  release build into DIR/libexec/iris
# Needs Odin (dev-2026-11 or newer), a C compiler for linking (gcc or clang;
# ODIN_CLANG_PATH picks it) and the development files of WPE WebKit 2.54+
# with WPEPlatform, libsoup 3, wayland, wayland-egl, xkbcommon, EGL and GLES.
set -eu
cd "$(dirname "$0")"
LIBS="wpe-webkit-2.0 wpe-platform-2.0 wpe-platform-headless-2.0 libsoup-3.0 glib-2.0 gio-2.0 wayland-client wayland-egl wayland-cursor xkbcommon egl glesv2"
# the folders the libraries are in, for the linker (WPE in /app/lib in the Flatpak)
LDIRS=$(pkg-config --libs-only-L $LIBS | tr -s ' ')
[ -n "${ODIN_CLANG_PATH:-}" ] || { command -v clang >/dev/null || export ODIN_CLANG_PATH=$(command -v gcc); }
odin_build() { odin build src -collection:iris=. -extra-linker-flags:"$LDIRS -Wl,--as-needed" "$@"; }
case "${1:-dev}" in
dev) odin_build -o:none -debug -out:iris ;;
release) odin_build -o:speed -out:iris ;;
test) odin test src -collection:iris=. -extra-linker-flags:"$LDIRS" -o:none ;;
check) sh abi/check.sh ;;
install)
	odin_build -o:speed -out:iris
	install -Dm755 iris "$2/libexec/iris"
	;;
*) echo "usage: $0 [dev|release|test|check|install DIR]" >&2; exit 2 ;;
esac
