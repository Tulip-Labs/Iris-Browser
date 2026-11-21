#!/bin/sh
# Iris for Linux, in dist/linux: the program with WebKitGTK. Needs the GTK
# and WebKitGTK development files; the Flatpak, the Snap and the container
# package that folder (packaging/). Iris for Android builds in android/.
#   ./build-iris.sh [linux]
set -e
cd "$(dirname "$0")"
export GOGC=50 GOMAXPROCS=2 GOFLAGS="${GOFLAGS:--mod=mod}"
target=${1:-linux}

need_linux_deps() {
	missing=""
	command -v gcc >/dev/null 2>&1 || missing="$missing gcc"
	command -v pkg-config >/dev/null 2>&1 || missing="$missing pkg-config"
	if command -v pkg-config >/dev/null 2>&1; then
		for p in gtk4 epoxy webkitgtk-6.0; do
			pkg-config --exists "$p" || missing="$missing $p"
		done
	fi
	[ -z "$missing" ] && return 0
	cat >&2 <<MSG
Iris for Linux cannot be built yet. Missing:$missing
Install the build tools and development files, then run this again:
  Fedora:        sudo dnf install gcc pkgconf gtk4-devel libepoxy-devel webkitgtk6.0-devel
  Fedora Atomic: toolbox create && toolbox enter, then the Fedora line above
  Debian/Ubuntu: sudo apt install gcc pkg-config libgtk-4-dev libepoxy-dev libwebkitgtk-6.0-dev
  Arch:          sudo pacman -S gcc pkgconf gtk4 libepoxy webkitgtk-6.0
MSG
	return 1
}

# version is the one the program reports (cmd/iris/main.go).
version() { sed -n 's/^const version = "\(.*\)"/\1/p' cmd/iris/main.go; }

build_linux() {
	need_linux_deps || return 1
	# The window is a GTK window, native on Wayland; the interface is drawn by
	# Gio's GPU renderer inside it; the pages are WebKitGTK's (from the
	# system, the Flatpak's GNOME runtime, the Snap or nixpkgs).
	echo "Building Iris for Linux..."
	CGO_ENABLED=1 go test ./core ./shields ./shell ./update ./link
	rm -rf dist/linux
	mkdir -p dist/linux
	CGO_ENABLED=1 go build -tags webkit -trimpath -ldflags "-s -w" -o dist/linux/iris ./cmd/iris
	go run tools/sum.go dist/linux/iris # the record Iris checks itself against
	cp assets/icon.png dist/linux/io.github.tulip_labs.Iris.png
	cp packaging/linux/io.github.tulip_labs.Iris.desktop packaging/linux/io.github.tulip_labs.Iris.metainfo.xml dist/linux/
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md dist/linux/
	version > dist/linux/VERSION
	du -sh dist/linux
	echo "Done: dist/linux (packaged by packaging/flatpak and packaging/snap)"
}

case "$target" in
linux) build_linux ;;
*)
	echo "usage: $0 [linux]"
	exit 2
	;;
esac
