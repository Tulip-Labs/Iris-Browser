//go:build !windows && !(linux && webkit)

package webview

type popupImpl struct{}

func (popupImpl) kitPage() bool { return false }
