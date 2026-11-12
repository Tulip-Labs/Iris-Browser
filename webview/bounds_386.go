//go:build windows && 386

package webview

// On x86 the RECT is pushed on the stack field by field.
func setBounds(ctrl uintptr, r rect) {
	call(ctrl, slotICoreWebView2Controller_SetBounds, uintptr(r.left), uintptr(r.top), uintptr(r.right), uintptr(r.bottom))
}
