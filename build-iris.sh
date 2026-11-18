#!/bin/sh
# Iris builds.
#   ./build-iris.sh            on Linux: Iris for Linux, then the Windows files
#                                elsewhere: the Windows files
#   ./build-iris.sh linux      Iris for Linux only (fetches Chromium (CEF), needs the GTK development files)
#   ./build-iris.sh windows    the Windows files only (cross-built, no C compiler needed)
#   ./build-iris.sh packages   Iris for Linux as .deb and .rpm too (fetches nfpm)
#   ./build-iris.sh install    build for Linux and install for the current user (~/.local)
#   ./build-iris.sh uninstall  remove that install
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

build_linux() {
	need_linux_deps || return 1
	fetch_cef
	# The window is a GTK window, native on Wayland; the interface is drawn by
	# Gio's GPU renderer inside it, and the pages by Chromium (CEF, off screen).
	echo "Building Iris for Linux..."
	CGO_ENABLED=1 go test ./core ./shields ./shell ./update ./link
	rm -rf dist/linux
	mkdir -p dist/linux
	CGO_ENABLED=1 go build -tags "webkit cef novulkan" -trimpath -ldflags "-s -w" -o dist/linux/iris ./cmd/iris
	go run tools/sum.go dist/linux/iris # the record Iris checks itself against
	cef=third_party/cef
	gcc -O2 -fno-stack-protector -I"$cef" -DCEF_API_VERSION=15600 packaging/cef/helper.c -L"$cef/Release" -lcef -Wl,-rpath,'$ORIGIN' -o dist/linux/iris-helper
	strip dist/linux/iris-helper
	for f in libcef.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json v8_context_snapshot.bin chrome-sandbox; do
		cp "$cef/Release/$f" dist/linux/
	done
	cp -r "$cef/Resources/"* dist/linux/
	cp assets/icon.png dist/linux/io.github.tulip_labs.Iris.png
	cp packaging/linux/io.github.tulip_labs.Iris.desktop dist/linux/
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md packaging/linux/install.sh dist/linux/
	cp "$cef/LICENSE.txt" dist/linux/CEF-LICENSE.txt
	cp "$cef/CREDITS.html" dist/linux/CHROMIUM-CREDITS.html
	chmod +x dist/linux/install.sh
	arch=$(uname -m)
	rm -f "dist/Iris-linux-$arch.tar.gz"
	tar -C dist -czf "dist/Iris-linux-$arch.tar.gz" --transform "s,^linux,Iris-linux-$arch," linux
	legacy_tarball "$arch"
	du -sh dist/linux "dist/Iris-linux-$arch.tar.gz"
	echo "Done: dist/linux and dist/Iris-linux-$arch.tar.gz"
	echo "Install it with: ./build-iris.sh install   (or dist/linux/install.sh)"
}

# legacy_tarball makes LiteGo-linux-<arch>.tar.gz, the archive Iris 1.0.19
# and older (named Lite Go then) look for when they update themselves. It is
# the same program, with the three files their updater checks for: a
# lite-go-browser that starts iris (and is what they restart), its record,
# and a lite-go-helper. Once running, Iris moves the old install over to its
# own names (update.MigrateUserInstall).
legacy_tarball() {
	arch=$1
	rm -rf dist/legacy && cp -a dist/linux dist/legacy
	printf '#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")/iris" "$@"\n' > dist/legacy/lite-go-browser
	printf '#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")/iris-helper" "$@"\n' > dist/legacy/lite-go-helper
	chmod 755 dist/legacy/lite-go-browser dist/legacy/lite-go-helper
	cp dist/linux/iris.sha256 dist/legacy/lite-go-browser.sha256
	rm -f "dist/LiteGo-linux-$arch.tar.gz"
	tar -C dist -czf "dist/LiteGo-linux-$arch.tar.gz" --transform "s,^legacy,LiteGo-linux-$arch," legacy
	rm -rf dist/legacy
}

# version is the one the program reports (cmd/iris/main.go).
version() { sed -n 's/^const version = "\(.*\)"/\1/p' cmd/iris/main.go; }

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
	# the version goes into every field (nfpm fills it in only in some)
	for f in nfpm nfpm-transitional; do
		sed "s/\${VERSION}/$VERSION/g" "packaging/linux/$f.yaml" > "dist/$f.yaml"
	done
	for p in deb rpm; do
		$nfpm package --config dist/nfpm.yaml --packager $p --target dist/
	done
	# apt moves lite-go-browser (the name until 1.0.19) over through this
	$nfpm package --config dist/nfpm-transitional.yaml --packager deb --target "dist/lite-go-browser-transitional_${VERSION}_${ARCH}.deb"
	rm -f dist/nfpm.yaml dist/nfpm-transitional.yaml
	ls dist/*.deb dist/*.rpm
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
