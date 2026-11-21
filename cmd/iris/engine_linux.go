//go:build linux && webkit

package main

import "iris/webview"

// newEngine is WebKitGTK, for every page (docs/engines.md).
func newEngine(conf string) webview.Engine { return webview.NewWebKit() }
