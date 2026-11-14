//go:build linux && webkit && !cef

package webview

// #cgo pkg-config: gtk+-3.0 webkit2gtk-4.1
import "C"

const engineName = "WebKitGTK "
