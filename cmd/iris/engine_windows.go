//go:build windows

package main

import "iris/webview"

// newEngine is Electron: Iris's one page engine on Windows (docs/engines.md).
func newEngine(conf string) webview.Engine { return webview.New() }
