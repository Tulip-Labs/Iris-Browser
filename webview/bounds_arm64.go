//go:build windows && arm64

package webview

// On ARM64 a 16-byte RECT travels in two registers.
func setBounds(ctrl uintptr, r rect) {
	lo := uint64(uint32(r.left)) | uint64(uint32(r.top))<<32
	hi := uint64(uint32(r.right)) | uint64(uint32(r.bottom))<<32
	call(ctrl, slotICoreWebView2Controller_SetBounds, uintptr(lo), uintptr(hi))
}
