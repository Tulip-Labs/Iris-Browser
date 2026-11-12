//go:build windows && amd64

package webview

import "unsafe"

// On x64 a 16-byte RECT is passed by reference.
func setBounds(ctrl uintptr, r rect) {
	call(ctrl, slotICoreWebView2Controller_SetBounds, uintptr(unsafe.Pointer(&r)))
}
