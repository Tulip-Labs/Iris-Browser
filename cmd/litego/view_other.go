//go:build !windows && !linux

package main

import "gioui.org/app"

func nativeWindow(app.ViewEvent) (uintptr, bool) { return 0, false }

func engineOS() bool { return false }
