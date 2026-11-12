#!/bin/sh
# Cross-build Lite Go for Windows from macOS or Linux (the browser itself runs on Windows for now).
set -e
cd "$(dirname "$0")"
export GOGC=50 GOMAXPROCS=2 GOFLAGS=-mod=mod CGO_ENABLED=0
ARCH=${GOARCH:-amd64}
go test ./core ./shell ./setup
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
echo "Done: dist/Lite Go Setup.exe and dist/Lite Go/Lite Go.exe"
