//go:build linux && webkit && !electron

package webview

// The Chromium engine (CEF). The CEF distribution is unpacked in third_party/cef
// by build-iris.sh; libcef.so sits next to the program.

// #cgo pkg-config: gtk4
// #cgo LDFLAGS: -ldl
// #cgo CFLAGS: -I${SRCDIR}/../third_party/cef -DCEF_API_VERSION=15600
// #cgo LDFLAGS: -L${SRCDIR}/../third_party/cef/Release -lcef -lm -Wl,-rpath,$ORIGIN
import "C"

const engineName = ""
