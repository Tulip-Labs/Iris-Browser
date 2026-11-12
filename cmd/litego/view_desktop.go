//go:build !android && !(linux && webkit)

package main

import "gioui.org/app"

const mobile = false

func onView(app.ViewEvent)            {}
func onBack(func() bool)              {}
func focusApp()                       {}
func toBack()                         {}
func exitFullscreen()                 {}
func appDirs() (string, string, bool) { return "", "", false }
