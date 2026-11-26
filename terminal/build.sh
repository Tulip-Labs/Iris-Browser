#!/bin/sh
# Iris Terminal for niri and Fedora's immutable desktops: Odin, Wayland and
# EGL/GLES (no GTK, no VTE, no X11).
#   ./build.sh              a quick build for working on it: ./iris-terminal
#   ./build.sh release      the optimised build
#   ./build.sh test         the unit tests (the emulator, keys, config, setup)
#   ./build.sh check        odin check, with vet (no libraries needed)
#   ./build.sh abi          the hand-written Wayland tables against wayland-scanner's
#   ./build.sh package      release build, then dist/iris-terminal-x86_64.tar.gz and SHA256SUMS
# Needs Odin (dev-2026-11 or newer), a C compiler for linking (gcc or clang;
# ODIN_CLANG_PATH picks it) and the development files of wayland,
# wayland-egl, EGL, GLES, xkbcommon, fontconfig and harfbuzz.
set -eu
cd "$(dirname "$0")"
LIBS="wayland-client wayland-egl wayland-cursor egl glesv2 xkbcommon fontconfig harfbuzz"
[ -n "${ODIN_CLANG_PATH:-}" ] || { command -v clang >/dev/null || export ODIN_CLANG_PATH=$(command -v gcc); }
ldirs() { pkg-config --libs-only-L $LIBS 2>/dev/null | tr -s ' ' || true; }
odin_build() { odin build src -extra-linker-flags:"$(ldirs) -Wl,--as-needed" "$@"; }
case "${1:-dev}" in
dev) odin_build -o:none -debug -out:iris-terminal ;;
release) odin_build -o:speed -out:iris-terminal ;;
test) odin test term -out:term.test -o:none && rm -f term.test ;;
check) odin check src -vet && odin check term -no-entry-point -vet ;;
abi) sh abi/check.sh ;;
package)
	odin_build -o:speed -out:iris-terminal
	sh packaging/package.sh ;;
*) echo "usage: $0 [dev|release|test|check|abi|package]" >&2; exit 2 ;;
esac
