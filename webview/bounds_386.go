//go:build windows && 386

package webview

import "math"

// On x86 the RECT is pushed on the stack field by field.
func setBounds(ctrl uintptr, r rect) {
	call(ctrl, slotICoreWebView2Controller_SetBounds, uintptr(r.left), uintptr(r.top), uintptr(r.right), uintptr(r.bottom))
}

// On x86 a double is two words on the stack.
func setZoom(ctrl uintptr, f float64) bool {
	b := math.Float64bits(f)
	return !failed(call(ctrl, slotICoreWebView2Controller_SetZoomFactor, uintptr(uint32(b)), uintptr(uint32(b>>32))))
}
