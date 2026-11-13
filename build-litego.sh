#!/bin/sh
# Lite Go builds.
#   ./build-litego.sh          Windows files (cross-built from Linux)
#   ./build-litego.sh linux    lite-go for Linux, on Linux (WebKitGTK development files)
set -e
cd "$(dirname "$0")"
export GOGC=50 GOMAXPROCS=2 GOFLAGS=-mod=mod
target=${1:-windows}

case "$target" in
windows)
	export CGO_ENABLED=0
	ARCH=${GOARCH:-amd64}
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
	echo "Done: dist/Lite Go Setup.exe, dist/Lite Go/Lite Go.exe and dist/LiteGo.msixbundle"
	;;
linux)
	# The window is a GTK window, native on Wayland (GNOME, KDE, ...) and on X11;
	# the interface is drawn by Gio's GPU renderer inside it.
	#   Debian/Ubuntu: sudo apt install gcc pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libepoxy-dev
	#   Fedora:        sudo dnf install gcc pkgconf gtk3-devel webkit2gtk4.1-devel libepoxy-devel
	#   Arch:          sudo pacman -S gcc pkgconf gtk3 webkit2gtk-4.1 libepoxy
	export CGO_ENABLED=1
	go test ./core ./shields ./shell
	mkdir -p dist/linux
	go build -tags "webkit novulkan" -trimpath -ldflags "-s -w" -o dist/linux/lite-go ./cmd/litego
	go run tools/sum.go dist/linux/lite-go # the record Lite Go checks itself against
	cp assets/icon.png dist/linux/lite-go.png
	cat > dist/linux/lite-go.desktop <<DESK
[Desktop Entry]
Type=Application
Name=Lite Go
Comment=A light, fast browser
Exec=lite-go %U
Icon=lite-go
StartupWMClass=lite-go
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
DESK
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md dist/linux/
	echo "Done: dist/linux (install: copy lite-go and lite-go.sha256 to ~/.local/bin, the .desktop file to ~/.local/share/applications, the png to ~/.local/share/icons)"
	;;
*)
	echo "usage: $0 [windows|linux]"
	exit 2
	;;
esac
