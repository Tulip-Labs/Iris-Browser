//go:build windows && amd64

package webview

import (
	"math"
	"unsafe"
)

// On x64 a 16-byte RECT is passed by reference.
func setBounds(ctrl uintptr, r rect) {
	call(ctrl, slotICoreWebView2Controller_SetBounds, uintptr(unsafe.Pointer(&r)))
}

// On x64 the first four arguments also travel in the XMM registers (Go's
// system call code copies them there), so a double goes as its bits.
func setZoom(ctrl uintptr, f float64) bool {
	if failed(call(ctrl, slotICoreWebView2Controller_SetZoomFactor, uintptr(math.Float64bits(f)))) {
		return false
	}
	var got float64
	call(ctrl, slotICoreWebView2Controller_ZoomFactor, uintptr(unsafe.Pointer(&got)))
	return math.Abs(got-f) < 0.01
}
