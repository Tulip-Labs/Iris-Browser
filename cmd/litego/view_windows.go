package main

import "gioui.org/app"

func nativeWindow(e app.ViewEvent) (uintptr, bool) {
	if v, ok := e.(app.Win32ViewEvent); ok && v.Valid() {
		return v.HWND, true
	}
	return 0, false
}

func engineOS() bool { return true }
