//go:build android

package main

import (
	"gioui.org/app"

	"litego/webview"
)

const mobile = true

// The Gio view: the system WebView goes over it, in the same activity.
func nativeWindow(e app.ViewEvent) (uintptr, bool) {
	if v, ok := e.(app.AndroidViewEvent); ok && v.View != 0 {
		return v.View, true
	}
	return 0, false
}

func engineOS() bool { return true }

func onView(app.ViewEvent) { webview.SetJVM(app.JavaVM(), app.AppContext()) }

func onBack(f func() bool) { webview.OnBack = f }

func toBack() { webview.ToBack() }

func focusApp() { webview.FocusApp() }

func exitFullscreen() { webview.ExitFullscreen() }

// appDirs: the app's private storage (Android has no config or cache folders
// for programs).
func appDirs() (conf, web string, ok bool) {
	d, err := app.DataDir()
	if err != nil {
		return "", "", false
	}
	return d + "/config", d + "/web", true
}
