//go:build !windows

package webview

type unsupported struct{}

// New returns an engine that reports it is unavailable (macOS and Linux come next).
func New() Engine { return unsupported{} }

func (unsupported) Start(uintptr, string, bool, func(error)) {}
func (unsupported) NewView(_ Options, _ Events, done func(View, error)) {
	done(nil, ErrUnavailable)
}
func (unsupported) SetPolicy(Policy)  {}
func (unsupported) MemoryMB() float64 { return 0 }
func (unsupported) Version() string   { return "" }
func Installed() bool                 { return false }
func SelfMB() float64                 { return 0 }
