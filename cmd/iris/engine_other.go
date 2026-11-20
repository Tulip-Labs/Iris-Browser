//go:build !(linux && webkit) && !windows

package main

import "iris/webview"

// newEngine is the engine stand-in of a build with no page engine.
func newEngine(conf string) webview.Engine { return webview.New() }
