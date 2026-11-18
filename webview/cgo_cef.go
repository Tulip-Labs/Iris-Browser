//go:build linux && webkit

package webview

// The Chromium engine (CEF). The CEF distribution is unpacked in third_party/cef
// by build-litego.sh; libcef.so sits next to the program.

// #cgo pkg-config: gtk+-3.0 epoxy
// #cgo CFLAGS: -I${SRCDIR}/../third_party/cef -DCEF_API_VERSION=15600
// #cgo LDFLAGS: -L${SRCDIR}/../third_party/cef/Release -lcef -lm -Wl,-rpath,$ORIGIN
import "C"

const engineName = ""
