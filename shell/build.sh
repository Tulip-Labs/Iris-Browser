#!/bin/sh
# Iris Shell for niri: Odin, Wayland and EGL/GLES (no GTK, no X11, no GLib).
#   ./build.sh              a quick build for working on it: ./iris-shell
#   ./build.sh release      the optimised build
#   ./build.sh test         the tests (the logic: niri's events, colours, KDL, setup)
#   ./build.sh check        odin check, with vet (no libraries needed)
#   ./build.sh abi          the hand-written Wayland tables against wayland-scanner's
#   ./build.sh package      release build, then dist/iris-shell-x86_64.tar.gz and SHA256SUMS
# Needs Odin (dev-2026-11 or newer), a C compiler for linking (gcc or clang;
# ODIN_CLANG_PATH picks it) and the development files of wayland,
# wayland-egl, EGL and GLES.
set -eu
cd "$(dirname "$0")"
LIBS="wayland-client wayland-egl egl glesv2"
[ -n "${ODIN_CLANG_PATH:-}" ] || { command -v clang >/dev/null || export ODIN_CLANG_PATH=$(command -v gcc); }
ldirs() { pkg-config --libs-only-L $LIBS 2>/dev/null | tr -s ' ' || true; }
odin_build() { odin build src -extra-linker-flags:"$(ldirs) -Wl,--as-needed" "$@"; }
case "${1:-dev}" in
dev) odin_build -o:none -debug -out:iris-shell ;;
release) odin_build -o:speed -out:iris-shell ;;
test) odin test logic -out:logic.test -o:none && rm -f logic.test ;;
check) odin check src -vet && odin check logic -no-entry-point -vet ;;
abi) sh abi/check.sh ;;
package)
	odin_build -o:speed -out:iris-shell
	sh packaging/package.sh ;;
*) echo "usage: $0 [dev|release|test|check|abi|package]" >&2; exit 2 ;;
esac
