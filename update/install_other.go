//go:build !linux && !windows

package update

import (
	"context"
	"errors"
)

// Detect: other systems run builds from source.
func Detect() Kind { return KindDev }

// Install is not available here.
func Install(context.Context, Kind, string) (Result, error) {
	return Result{}, errors.New("updates are not available on this system")
}

// Restart does nothing here.
func Restart() error { return nil }

// MigrateUserInstall has nothing to move here.
func MigrateUserInstall() {}
