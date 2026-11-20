//go:build linux && webkit && !servo

package main

import "iris/webview"

// newEngine is Electron alone (a build without Servo).
func newEngine(conf string) webview.Engine { return webview.New() }
