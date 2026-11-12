package main

import (
	"os"

	"gioui.org/app"
)

// Wayland does not let one program's view sit inside another's window (Gio
// and GTK each keep their own connection to the display), so the page cannot
// be placed in a native Wayland Gio window. Lite Go runs through XWayland,
// which GNOME, KDE and the other Wayland desktops provide: on a Wayland
// session it switches to it by itself.
func init() {
	if os.Getenv("WAYLAND_DISPLAY") != "" && os.Getenv("DISPLAY") != "" {
		os.Unsetenv("WAYLAND_DISPLAY")
		os.Setenv("GDK_BACKEND", "x11")
	}
}

func nativeWindow(e app.ViewEvent) (uintptr, bool) {
	if v, ok := e.(app.X11ViewEvent); ok && v.Valid() {
		return uintptr(v.Window), true
	}
	return 0, false
}

func engineOS() bool { return true }
