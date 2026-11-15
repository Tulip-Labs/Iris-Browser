#!/bin/sh
# Lite Go builds.
#   ./build-litego.sh            on Linux: Lite Go for Linux, then the Windows files
#                                elsewhere: the Windows files
#   ./build-litego.sh linux      Lite Go for Linux only (fetches Chromium (CEF), needs the GTK development files)
#   ./build-litego.sh windows    the Windows files only (cross-built, no C compiler needed)
#   ./build-litego.sh packages   Lite Go for Linux as .deb and .rpm too (fetches nfpm)
#   ./build-litego.sh install    build for Linux and install for the current user (~/.local)
#   ./build-litego.sh uninstall  remove that install
set -e
cd "$(dirname "$0")"
export GOGC=50 GOMAXPROCS=2 GOFLAGS=-mod=mod
target=${1:-auto}
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"

need_linux_deps() {
	missing=""
	command -v gcc >/dev/null 2>&1 || missing="$missing gcc"
	command -v pkg-config >/dev/null 2>&1 || missing="$missing pkg-config"
	command -v curl >/dev/null 2>&1 || missing="$missing curl"
	command -v bzip2 >/dev/null 2>&1 || missing="$missing bzip2"
	if command -v pkg-config >/dev/null 2>&1; then
		for p in gtk+-3.0 epoxy; do
			pkg-config --exists "$p" || missing="$missing $p"
		done
	fi
	[ -z "$missing" ] && return 0
	cat >&2 <<MSG
Lite Go for Linux cannot be built yet. Missing:$missing
Install the build tools and development files, then run this again:
  Fedora:        sudo dnf install gcc pkgconf gtk3-devel libepoxy-devel curl bzip2
  Fedora Atomic: toolbox create && toolbox enter, then the Fedora line above
  Debian/Ubuntu: sudo apt install gcc pkg-config libgtk-3-dev libepoxy-dev curl bzip2
  Arch:          sudo pacman -S gcc pkgconf gtk3 libepoxy curl bzip2
MSG
	return 1
}

# fetch_cef unpacks the Chromium Embedded Framework named in
# packaging/cef/cef.env into third_party/cef (once; the download is about
# 300 MB, checked against its SHA-1), and strips libcef.so of its symbols.
fetch_cef() {
	. packaging/cef/cef.env
	dir=third_party/cef
	if [ -f "$dir/.version" ] && [ "$(cat "$dir/.version")" = "$CEF_VERSION" ]; then
		return 0
	fi
	echo "Fetching Chromium (CEF $CEF_VERSION)..."
	rm -rf "$dir" third_party/cef.tar.bz2
	mkdir -p "$dir"
	url="https://cef-builds.spotifycdn.com/$(printf %s "$CEF_FILE" | sed 's/+/%2B/g')"
	curl -fL --retry 3 -o third_party/cef.tar.bz2 "$url"
	echo "$CEF_SHA1  third_party/cef.tar.bz2" | sha1sum -c -
	tar -xjf third_party/cef.tar.bz2 -C "$dir" --strip-components=1
	rm -f third_party/cef.tar.bz2
	strip --strip-unneeded "$dir/Release/libcef.so" "$dir/Release/libvk_swiftshader.so" "$dir/Release/libvulkan.so.1"
	echo "$CEF_VERSION" > "$dir/.version"
}

build_linux() {
	need_linux_deps || return 1
	fetch_cef
	# The window is a GTK window, native on Wayland; the interface is drawn by
	# Gio's GPU renderer inside it, and the pages by Chromium (CEF, off screen).
	echo "Building Lite Go for Linux..."
	CGO_ENABLED=1 go test ./core ./shields ./shell
	rm -rf dist/linux
	mkdir -p dist/linux
	CGO_ENABLED=1 go build -tags "webkit cef novulkan" -trimpath -ldflags "-s -w" -o dist/linux/lite-go-browser ./cmd/litego
	go run tools/sum.go dist/linux/lite-go-browser # the record Lite Go checks itself against
	# lite-go starts it; copies from 1.0.7 and older, which update only that
	# one file, use it to move to the new layout
	install -m 755 packaging/linux/lite-go dist/linux/lite-go
	cef=third_party/cef
	gcc -O2 -fno-stack-protector -I"$cef" -DCEF_API_VERSION=15600 packaging/cef/helper.c -L"$cef/Release" -lcef -Wl,-rpath,'$ORIGIN' -o dist/linux/lite-go-helper
	strip dist/linux/lite-go-helper
	for f in libcef.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json v8_context_snapshot.bin chrome-sandbox; do
		cp "$cef/Release/$f" dist/linux/
	done
	cp -r "$cef/Resources/"* dist/linux/
	cp assets/icon.png dist/linux/lite-go.png
	cp packaging/linux/lite-go.desktop dist/linux/
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md packaging/linux/install.sh dist/linux/
	cp "$cef/LICENSE.txt" dist/linux/CEF-LICENSE.txt
	cp "$cef/CREDITS.html" dist/linux/CHROMIUM-CREDITS.html
	chmod +x dist/linux/install.sh
	arch=$(uname -m)
	rm -f "dist/LiteGo-linux-$arch.tar.gz"
	tar -C dist -czf "dist/LiteGo-linux-$arch.tar.gz" --transform "s,^linux,LiteGo-linux-$arch," linux
	du -sh dist/linux "dist/LiteGo-linux-$arch.tar.gz"
	echo "Done: dist/linux and dist/LiteGo-linux-$arch.tar.gz"
	echo "Install it with: ./build-litego.sh install   (or dist/linux/install.sh)"
}

# version is the one the program reports (cmd/litego/main.go).
version() { sed -n 's/^const version = "\(.*\)"/\1/p' cmd/litego/main.go; }

build_packages() {
	build_linux
	export VERSION
	VERSION=$(version)
	case "$(uname -m)" in
	x86_64) ARCH=amd64 ;;
	aarch64) ARCH=arm64 ;;
	*) ARCH=$(uname -m) ;;
	esac
	export ARCH
	nfpm="go run github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.41.0"
	for p in deb rpm; do
		$nfpm package --config packaging/linux/nfpm.yaml --packager $p --target dist/
	done
	ls dist/*.deb dist/*.rpm
}

build_windows() {
	echo "Building Lite Go for Windows..."
	ARCH=${GOARCH:-amd64}
	export CGO_ENABLED=0
	go test ./core ./shell ./setup ./shields
	mkdir -p "dist/Lite Go"
	GOOS=windows GOARCH=$ARCH go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist/Lite Go/Lite Go.exe" ./cmd/litego
	go run tools/sum.go "dist/Lite Go/Lite Go.exe" # the record Lite Go checks itself against
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "dist/Lite Go/"
	go run tools/gz.go "dist/Lite Go/Lite Go.exe" setup/payload/LiteGo.exe.gz
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md setup/payload/
	GOOS=windows GOARCH=$ARCH go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist/Lite Go Setup.exe" ./cmd/litego-setup
	(cd dist && rm -f LiteGo-portable.zip && zip -qr LiteGo-portable.zip "Lite Go")
	go run tools/msix.go -exe "dist/Lite Go/Lite Go.exe" -arch x64 -out dist/LiteGo_x64.msix
	GOOS=windows GOARCH=arm64 go build -trimpath -ldflags "-H windowsgui -s -w" -o dist/LiteGo-arm64.exe ./cmd/litego
	go run tools/msix.go -exe dist/LiteGo-arm64.exe -arch arm64 -out dist/LiteGo_arm64.msix
	go run tools/msix.go -bundle dist/LiteGo.msixbundle dist/LiteGo_x64.msix dist/LiteGo_arm64.msix
	rm -f dist/LiteGo-arm64.exe
	unset CGO_ENABLED
	echo "Done: dist/Lite Go Setup.exe, dist/Lite Go/Lite Go.exe and dist/LiteGo.msixbundle"
}

case "$target" in
auto)
	if [ "$(uname -s)" = Linux ]; then
		linux_ok=1
		build_linux || linux_ok=0
		build_windows
		if [ $linux_ok = 0 ]; then
			echo "The Windows files are built; Lite Go for Linux was skipped (see above)." >&2
			exit 1
		fi
	else
		build_windows
	fi
	;;
linux) build_linux ;;
packages) build_packages ;;
windows) build_windows ;;
install)
	build_linux
	dist/linux/install.sh
	;;
uninstall)
	packaging/linux/install.sh --remove
	;;
*)
	echo "usage: $0 [linux|packages|windows|install|uninstall]"
	exit 2
	;;
esac
