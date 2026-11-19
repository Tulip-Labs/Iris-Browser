//go:build !(linux && webkit) && !windows

package main

import "iris/webview"

// newEngine is the engine alone (a build without a system web view).
func newEngine(conf string) webview.Engine { return webview.New() }
