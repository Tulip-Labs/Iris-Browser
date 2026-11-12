#!/bin/sh
# Lite Go builds.
#   ./build-litego.sh          Windows files (cross-built from macOS or Linux)
#   ./build-litego.sh mac      Lite Go.app, on a Mac (Xcode command line tools)
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
	cp LICENSE.md NOTICE THIRD_PARTY_NOTICES.md "dist/Lite Go/"
	go run tools/gz.go "dist/Lite Go/Lite Go.exe" setup/payload/LiteGo.exe.gz
	cp LICENSE.md NOTICE THIRD_PARTY_NOTICES.md setup/payload/
	GOOS=windows GOARCH=$ARCH go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist/Lite Go Setup.exe" ./cmd/litego-setup
	(cd dist && rm -f LiteGo-portable.zip && zip -qr LiteGo-portable.zip "Lite Go")
	go run tools/msix.go -exe "dist/Lite Go/Lite Go.exe" -arch x64 -out dist/LiteGo_x64.msix
	GOOS=windows GOARCH=arm64 go build -trimpath -ldflags "-H windowsgui -s -w" -o dist/LiteGo-arm64.exe ./cmd/litego
	go run tools/msix.go -exe dist/LiteGo-arm64.exe -arch arm64 -out dist/LiteGo_arm64.msix
	go run tools/msix.go -bundle dist/LiteGo.msixbundle dist/LiteGo_x64.msix dist/LiteGo_arm64.msix
	rm -f dist/LiteGo-arm64.exe
	echo "Done: dist/Lite Go Setup.exe, dist/Lite Go/Lite Go.exe and dist/LiteGo.msixbundle"
	;;
mac)
	# WebKit comes with macOS; this needs only Go and the Xcode command line tools
	export CGO_ENABLED=1
	go test ./core ./shields
	app="dist/Lite Go.app"
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	go build -trimpath -ldflags "-s -w" -o "$app/Contents/MacOS/Lite Go" ./cmd/litego
	# the icon, from assets/icon.png
	set=dist/LiteGo.iconset
	mkdir -p "$set"
	for s in 16 32 128 256 512; do
		sips -z $s $s assets/icon.png --out "$set/icon_${s}x${s}.png" >/dev/null
		sips -z $((s * 2)) $((s * 2)) assets/icon.png --out "$set/icon_${s}x${s}@2x.png" >/dev/null
	done
	iconutil -c icns "$set" -o "$app/Contents/Resources/LiteGo.icns" && rm -rf "$set"
	cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>Lite Go</string>
	<key>CFBundleDisplayName</key><string>Lite Go</string>
	<key>CFBundleIdentifier</key><string>com.tulipanlabs.litego</string>
	<key>CFBundleVersion</key><string>1.0.0</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleExecutable</key><string>Lite Go</string>
	<key>CFBundleIconFile</key><string>LiteGo</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>CFBundleURLTypes</key><array><dict>
		<key>CFBundleURLName</key><string>Web site URL</string>
		<key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
	</dict></array>
</dict></plist>
PLIST
	cp LICENSE.md NOTICE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
	codesign --force --deep -s - "$app" 2>/dev/null || true # ad-hoc signature: runs on this Mac
	echo "Done: $app"
	;;
linux)
	# Debian/Ubuntu: sudo apt install gcc pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev \
	#   libwayland-dev libx11-dev libx11-xcb-dev libxkbcommon-x11-dev libgles2-mesa-dev \
	#   libegl1-mesa-dev libffi-dev libxcursor-dev libvulkan-dev
	export CGO_ENABLED=1
	go test ./core ./shields
	mkdir -p dist/linux
	go build -tags webkit -trimpath -ldflags "-s -w" -o dist/linux/lite-go ./cmd/litego
	cp assets/icon.png dist/linux/lite-go.png
	cat > dist/linux/lite-go.desktop <<DESK
[Desktop Entry]
Type=Application
Name=Lite Go
Comment=A light, fast browser
Exec=lite-go %U
Icon=lite-go
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
DESK
	cp LICENSE.md NOTICE THIRD_PARTY_NOTICES.md dist/linux/
	echo "Done: dist/linux (install: copy lite-go to ~/.local/bin, the .desktop file to ~/.local/share/applications, the png to ~/.local/share/icons)"
	;;
*)
	echo "usage: $0 [windows|mac|linux]"
	exit 2
	;;
esac
