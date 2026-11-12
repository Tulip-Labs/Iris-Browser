package main

import "gioui.org/app"

func nativeWindow(e app.ViewEvent) (uintptr, bool) {
	if v, ok := e.(app.AppKitViewEvent); ok && v.Valid() {
		return v.View, true
	}
	return 0, false
}

func engineOS() bool { return true }
