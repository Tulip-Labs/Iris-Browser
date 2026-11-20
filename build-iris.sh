#!/bin/sh
# Iris builds.
#   ./build-iris.sh            on Linux: Iris for Linux, then the Windows files
#                                elsewhere: the Windows files
#   ./build-iris.sh linux      Iris for Linux only, in dist/linux (fetches Electron
#                                through npm, needs the GTK development files and
#                                Node.js); the Flatpak and the Snap package that
#                                folder (packaging/flatpak, packaging/snap)
#   ./build-iris.sh windows    the Windows files only (cross-built, no C compiler needed)
set -e
cd "$(dirname "$0")"
export GOGC=50 GOMAXPROCS=2 GOFLAGS=-mod=mod
target=${1:-auto}

need_linux_deps() {
	missing=""
	command -v gcc >/dev/null 2>&1 || missing="$missing gcc"
	command -v pkg-config >/dev/null 2>&1 || missing="$missing pkg-config"
	command -v node >/dev/null 2>&1 || missing="$missing node"
	command -v npm >/dev/null 2>&1 || missing="$missing npm"
	if command -v pkg-config >/dev/null 2>&1; then
		for p in gtk4 epoxy webkitgtk-6.0; do
			pkg-config --exists "$p" || missing="$missing $p"
		done
	fi
	[ -z "$missing" ] && return 0
	cat >&2 <<MSG
Iris for Linux cannot be built yet. Missing:$missing
Install the build tools and development files, then run this again:
  Fedora:        sudo dnf install gcc pkgconf gtk4-devel libepoxy-devel webkitgtk6.0-devel nodejs npm
  Fedora Atomic: toolbox create && toolbox enter, then the Fedora line above
  Debian/Ubuntu: sudo apt install gcc pkg-config libgtk-4-dev libepoxy-dev libwebkitgtk-6.0-dev nodejs npm
  Arch:          sudo pacman -S gcc pkgconf gtk4 libepoxy webkitgtk-6.0 nodejs npm
MSG
	return 1
}

# version is the one the program reports (cmd/iris/main.go).
version() { sed -n 's/^const version = "\(.*\)"/\1/p' cmd/iris/main.go; }

build_linux() {
	need_linux_deps || return 1
	# The window is a GTK window, native on Wayland; the interface is drawn by
	# Gio's GPU renderer inside it; the pages are WebKitGTK's (from the
	# system) and, for the heavy sites, Electron's.
	echo "Building Iris for Linux..."
	CGO_ENABLED=1 go test ./core ./shields ./shell ./update ./link
	rm -rf dist/linux
	# The program, Electron and Iris's helper (webview/electron/build.sh)
	sh webview/electron/build.sh dist/linux
	go run tools/sum.go dist/linux/iris # the record Iris checks itself against
	cp assets/icon.png dist/linux/io.github.tulip_labs.Iris.png
	cp packaging/linux/io.github.tulip_labs.Iris.desktop packaging/linux/io.github.tulip_labs.Iris.metainfo.xml dist/linux/
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md dist/linux/
	version > dist/linux/VERSION
	du -sh dist/linux
	echo "Done: dist/linux (packaged by packaging/flatpak and packaging/snap)"
}

build_windows() {
	echo "Building Iris for Windows..."
	ARCH=${GOARCH:-amd64}
	export CGO_ENABLED=0
	go test ./core ./shell ./setup ./shields
	mkdir -p "dist/Iris"
	GOOS=windows GOARCH=$ARCH go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist/Iris/Iris.exe" ./cmd/iris
	go run tools/sum.go "dist/Iris/Iris.exe" # the record Iris checks itself against
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "dist/Iris/"
	go run tools/gz.go "dist/Iris/Iris.exe" setup/payload/Iris.exe.gz
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md setup/payload/
	GOOS=windows GOARCH=$ARCH go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist/Iris Setup.exe" ./cmd/iris-setup
	(cd dist && rm -f Iris-portable.zip && zip -qr Iris-portable.zip "Iris")
	go run tools/msix.go -exe "dist/Iris/Iris.exe" -arch x64 -out dist/Iris_x64.msix
	GOOS=windows GOARCH=arm64 go build -trimpath -ldflags "-H windowsgui -s -w" -o dist/Iris-arm64.exe ./cmd/iris
	go run tools/msix.go -exe dist/Iris-arm64.exe -arch arm64 -out dist/Iris_arm64.msix
	go run tools/msix.go -bundle dist/Iris.msixbundle dist/Iris_x64.msix dist/Iris_arm64.msix
	rm -f dist/Iris-arm64.exe
	unset CGO_ENABLED
	echo "Done: dist/Iris Setup.exe, dist/Iris/Iris.exe and dist/Iris.msixbundle"
}

case "$target" in
auto)
	if [ "$(uname -s)" = Linux ]; then
		linux_ok=1
		build_linux || linux_ok=0
		build_windows
		if [ $linux_ok = 0 ]; then
			echo "The Windows files are built; Iris for Linux was skipped (see above)." >&2
			exit 1
		fi
	else
		build_windows
	fi
	;;
linux) build_linux ;;
windows) build_windows ;;
*)
	echo "usage: $0 [linux|windows]"
	exit 2
	;;
esac
