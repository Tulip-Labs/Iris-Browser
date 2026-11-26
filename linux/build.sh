#!/bin/sh
# Iris (Chromium) for Linux: Odin, Wayland, EGL/GLES and CEF (no GTK, no X11).
#   ./build.sh              a quick build for working on it (no optimisation): ./iris
#   ./build.sh release      the optimised build, as the Flatpak ships it
#   ./build.sh test         the tests
#   ./build.sh check        the hand-written C bindings against the real headers
#   ./build.sh check-types  type-check (odin check, no libraries)
#   ./build.sh install DIR  release build into DIR/libexec/iris
# Needs Odin (dev-2026-11 or newer), a C compiler for linking (gcc or clang;
# ODIN_CLANG_PATH picks it), Rust (cargo: ../core is built first, CORE_PREBUILT=1
# when it was), the development files of libsoup 3, wayland, wayland-egl,
# xkbcommon, EGL and GLES, and CEF: CEF_DIR is the CEF binary distribution
# (its Release/ has libcef.so) and CEF_RPATH where libcef.so is at run time
# (default /app/lib/iris-cef, as the Flatpak installs it).
set -eu
cd "$(dirname "$0")"
LIBS="harfbuzz fontconfig libsoup-3.0 glib-2.0 gio-2.0 wayland-client wayland-egl wayland-cursor xkbcommon egl glesv2"
case "${1:-dev}" in
check-types) exec odin check src -collection:iris=. ;;
check) sh abi/check.sh && sh abi/check-cef.sh; exit ;;
esac
[ -n "${CEF_DIR:-}" ] && [ -f "$CEF_DIR/Release/libcef.so" ] || { echo "CEF_DIR is needed (with Release/libcef.so)" >&2; exit 2; }
RPATH=${CEF_RPATH:-/app/lib/iris-cef}
# Iris's Rust core (../core: adblock-rust, the add-on installer), a static library
CORE_DIR=$(cd "${CORE_DIR:-../core}" && pwd)
[ "${CORE_PREBUILT:-0}" = 1 ] || (cd "$CORE_DIR" && cargo build --release --locked)
[ -f "$CORE_DIR/target/release/libiris_core.a" ] || { echo "$CORE_DIR/target/release/libiris_core.a is missing (cargo build --release in core/)" >&2; exit 2; }
EXTRA="-L$CEF_DIR/Release -L$CORE_DIR/target/release -Wl,-rpath,$RPATH -pthread"
DEFINE="-define:IRIS_CEF_DIR=$RPATH"
# the folders the libraries are in, for the linker
LDIRS=$(pkg-config --libs-only-L $LIBS | tr -s ' ')
[ -n "${ODIN_CLANG_PATH:-}" ] || { command -v clang >/dev/null || export ODIN_CLANG_PATH=$(command -v gcc); }
odin_build() { odin build src -collection:iris=. $DEFINE -extra-linker-flags:"$LDIRS $EXTRA -Wl,--as-needed" "$@"; }
case "${1:-dev}" in
dev) odin_build -o:none -debug -out:iris ;;
release) odin_build -o:speed -out:iris ;;
test) odin test src -collection:iris=. $DEFINE -extra-linker-flags:"$LDIRS $EXTRA -Wl,--as-needed" -o:none ;;
install)
	odin_build -o:speed -out:iris
	install -Dm755 iris "$2/libexec/iris"
	;;
*) echo "usage: [CEF_DIR=...] $0 [dev|release|test|check|check-types|install DIR]" >&2; exit 2 ;;
esac
