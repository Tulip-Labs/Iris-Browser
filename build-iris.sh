#!/bin/sh
# Iris builds.
#   ./build-iris.sh            on Linux: Iris for Linux, then the Windows files
#                                elsewhere: the Windows files
#   ./build-iris.sh linux      Iris for Linux only, in dist/linux (fetches Chromium (CEF),
#                                needs the GTK development files); the Flatpak and the
#                                Snap package that folder (packaging/flatpak, packaging/snap)
#   ./build-iris.sh windows    the Windows files only (cross-built, no C compiler needed)
set -e
cd "$(dirname "$0")"
export GOGC=50 GOMAXPROCS=2 GOFLAGS=-mod=mod
target=${1:-auto}

need_linux_deps() {
	missing=""
	command -v gcc >/dev/null 2>&1 || missing="$missing gcc"
	command -v pkg-config >/dev/null 2>&1 || missing="$missing pkg-config"
	command -v curl >/dev/null 2>&1 || missing="$missing curl"
	command -v bzip2 >/dev/null 2>&1 || missing="$missing bzip2"
	if command -v pkg-config >/dev/null 2>&1; then
		for p in gtk4 epoxy; do
			pkg-config --exists "$p" || missing="$missing $p"
		done
	fi
	[ -z "$missing" ] && return 0
	cat >&2 <<MSG
Iris for Linux cannot be built yet. Missing:$missing
Install the build tools and development files, then run this again:
  Fedora:        sudo dnf install gcc pkgconf gtk4-devel libepoxy-devel curl bzip2
  Fedora Atomic: toolbox create && toolbox enter, then the Fedora line above
  Debian/Ubuntu: sudo apt install gcc pkg-config libgtk-4-dev libepoxy-dev curl bzip2
  Arch:          sudo pacman -S gcc pkgconf gtk4 libepoxy curl bzip2
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

# version is the one the program reports (cmd/iris/main.go).
version() { sed -n 's/^const version = "\(.*\)"/\1/p' cmd/iris/main.go; }

build_linux() {
	need_linux_deps || return 1
	fetch_cef
	# The window is a GTK window, native on Wayland; the interface is drawn by
	# Gio's GPU renderer inside it, and the pages by Chromium (CEF, off screen).
	echo "Building Iris for Linux..."
	CGO_ENABLED=1 go test ./core ./shields ./shell ./update ./link
	rm -rf dist/linux
	mkdir -p dist/linux
	# Servo for the light pages, when its bridge is built (webview/servo/lib,
	# from .github/workflows/servo-lib.yml or cargo in webview/servo/rust)
	tags="webkit cef novulkan"
	if [ -f webview/servo/lib/libirisservo.so ]; then
		tags="$tags servo"
		cp webview/servo/lib/libirisservo.so dist/linux/
		echo "With Servo for light pages"
	fi
	CGO_ENABLED=1 go build -tags "$tags" -trimpath -ldflags "-s -w" -o dist/linux/iris ./cmd/iris
	go run tools/sum.go dist/linux/iris # the record Iris checks itself against
	cef=third_party/cef
	gcc -O2 -fno-stack-protector -I"$cef" -DCEF_API_VERSION=15600 packaging/cef/helper.c -L"$cef/Release" -lcef -Wl,-rpath,'$ORIGIN' -o dist/linux/iris-helper
	strip dist/linux/iris-helper
	for f in libcef.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json v8_context_snapshot.bin chrome-sandbox; do
		cp "$cef/Release/$f" dist/linux/
	done
	cp -r "$cef/Resources/"* dist/linux/
	cp assets/icon.png dist/linux/io.github.tulip_labs.Iris.png
	cp packaging/linux/io.github.tulip_labs.Iris.desktop packaging/linux/io.github.tulip_labs.Iris.metainfo.xml dist/linux/
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md dist/linux/
	version > dist/linux/VERSION
	cp "$cef/LICENSE.txt" dist/linux/CEF-LICENSE.txt
	cp "$cef/CREDITS.html" dist/linux/CHROMIUM-CREDITS.html
	du -sh dist/linux
	echo "Done: dist/linux (packaged by packaging/flatpak and packaging/snap)"
}

build_windows() {
	echo "Building Iris for Windows..."
	go test ./core ./shell ./setup ./shields
	mkdir -p "dist/Iris"
	# the page engine: Electron's Windows build, staged next to the program
	# (the program looks for electron/electron.exe beside itself)
	stage_electron_windows x64 || return 1
	# Servo for the light pages, when its bridge is built (webview/servo/lib,
	# from .github/workflows/servo-lib.yml or cargo xwin in webview/servo/rust)
	tags=""
	export CGO_ENABLED=0
	extra_x64=""
	if [ -f webview/servo/lib/irisservo.dll ]; then
		# the bridge is C: the build needs a Windows C compiler (cgo)
		cc=${MINGW_CC:-x86_64-w64-mingw32-gcc}
		if ! command -v "$cc" >/dev/null 2>&1; then
			echo "Servo's bridge is built but no Windows C compiler ($cc) was found;" >&2
			echo "install MinGW (Debian/Ubuntu: sudo apt install gcc-mingw-w64-x86-64 gcc-mingw-w64-aarch64)" >&2
			echo "or remove webview/servo/lib/irisservo.dll to build without Servo." >&2
			return 1
		fi
		tags="servo"
		export CGO_ENABLED=1 CC="$cc"
		cp webview/servo/lib/irisservo.dll dist/Iris/
		extra_x64="-extra dist/Iris/irisservo.dll"
		echo "With Servo for light pages (x64)"
	fi
	GOOS=windows GOARCH=amd64 go build -tags "$tags" -trimpath -ldflags "-H windowsgui -s -w" -o "dist/Iris/Iris.exe" ./cmd/iris
	go run tools/sum.go "dist/Iris/Iris.exe" # the record Iris checks itself against
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "dist/Iris/"
	# shellcheck disable=SC2086 # $extra_x64 is empty without Servo
	go run tools/msix.go -exe "dist/Iris/Iris.exe" -arch x64 -extra dist/Iris/electron $extra_x64 -out dist/Iris_x64.msix
	# ARM64: the same, Electron-only (Servo's bridge is built for x64; the
	# arm64 bridge is the same cargo xwin build for aarch64-pc-windows-msvc)
	export CGO_ENABLED=0
	unset CC
	mkdir -p "dist/Iris-arm64"
	stage_electron_windows arm64 || return 1
	GOOS=windows GOARCH=arm64 go build -trimpath -ldflags "-H windowsgui -s -w" -o dist/Iris-arm64/Iris.exe ./cmd/iris
	go run tools/sum.go "dist/Iris-arm64/Iris.exe"
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "dist/Iris-arm64/"
	go run tools/msix.go -exe dist/Iris-arm64/Iris.exe -arch arm64 -extra dist/Iris-arm64/electron -out dist/Iris_arm64.msix
	go run tools/msix.go -bundle dist/Iris.msixbundle dist/Iris_x64.msix dist/Iris_arm64.msix
	unset CGO_ENABLED
	echo "Done: dist/Iris.msixbundle (the only Windows package)"
}

# stage_electron_windows stages Electron's Windows build into dist/<dir>/electron:
# the binary (from npm, for the architecture given: x64 or arm64) and Iris's
# helper as its app (resources/app). Needs node and npm.
stage_electron_windows() {
	earch=$1 # x64 or arm64
	dir=dist/Iris
	[ "$earch" = arm64 ] && dir=dist/Iris-arm64
	command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || {
		echo "Node and npm are needed to fetch Electron for Windows." >&2
		return 1
	}
	helper=webview/electron/helper
	tmp=$(mktemp -d)
	cp "$helper/package.json" "$helper/main.js" "$helper/preload.js" "$tmp/"
	(cd "$tmp" && npm_config_platform=win32 npm_config_arch=$earch npm install --no-audit --no-fund --loglevel=error)
	# Electron's binary comes from its own installer, which npm may skip
	if [ ! -x "$tmp/node_modules/electron/dist/electron.exe" ]; then
		(cd "$tmp/node_modules/electron" && npm_config_platform=win32 npm_config_arch=$earch node install.js)
	fi
	if [ ! -x "$tmp/node_modules/electron/dist/electron.exe" ]; then
		echo "Electron's Windows binary is missing" >&2
		rm -rf "$tmp"
		return 1
	fi
	echo "Electron $(cat "$tmp/node_modules/electron/dist/version" 2>/dev/null) for Windows $earch"
	mkdir -p "$dir"
	rm -rf "$dir/electron"
	cp -a --no-preserve=ownership "$tmp/node_modules/electron/dist" "$dir/electron"
	# only the strings Iris's readers use (Chromium falls back to English)
	find "$dir/electron/locales" -name '*.pak' ! -name 'en-US.pak' ! -name 'es.pak' ! -name 'es-419.pak' -delete
	rm -f "$dir/electron/resources/default_app.asar"
	# the helper is Electron's app (resources/app), with its one runtime library
	app="$dir/electron/resources/app"
	mkdir -p "$app"
	cp "$helper/main.js" "$helper/preload.js" "$helper/package.json" "$app/"
	# the helper only needs the one runtime library, not the Electron package
	# itself (its binary is already in electron/) nor the CLIs (.bin points
	# into the Electron package, so its links would dangle after the removal)
	rm -rf "$tmp/node_modules/electron" "$tmp/node_modules/@electron" "$tmp/node_modules/.bin"
	cp -a --no-preserve=ownership "$tmp/node_modules" "$app/"
	cp "$dir/electron/version" "$dir/ELECTRON_VERSION" 2>/dev/null || true
	rm -rf "$tmp"
	du -sh "$dir/electron" | sed 's/^/size: /'
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
