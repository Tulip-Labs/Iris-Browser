//go:build !linux

package update

// Detect: other systems run builds from source.
func Detect() Kind { return KindDev }
