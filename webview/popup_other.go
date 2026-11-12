//go:build !windows && !darwin && !android && !(linux && webkit)

package webview

type popupImpl struct{}
