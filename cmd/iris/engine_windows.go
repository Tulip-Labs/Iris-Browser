//go:build windows && !servo

package main

import "iris/webview"

// newEngine is Chromium alone (a build without Servo).
func newEngine(conf string) webview.Engine { return webview.New() }
