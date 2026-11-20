//go:build !windows && !(linux && webkit)

package webview

// SetColorScheme makes the pages light or dark; this engine follows the
// system instead.
func SetColorScheme(dark bool) {}
