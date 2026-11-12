//go:build linux && !webkit && !android

package main

import "gioui.org/app"

// Without WebKitGTK the Gio window runs natively (Wayland or X11) and shows
// that the web engine is missing.
func nativeWindow(app.ViewEvent) (uintptr, bool) { return 0, false }

func engineOS() bool { return false }
