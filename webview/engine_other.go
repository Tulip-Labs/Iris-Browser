//go:build !windows && !(linux && webkit)

package webview

type unsupported struct{}

// New returns an engine that reports it is unavailable (Linux needs the webkit build tag).
func New() Engine { return unsupported{} }

func (unsupported) Start(_ uintptr, _ string, _ bool, ready func(error)) { ready(ErrUnavailable) }
func (unsupported) NewView(_ Options, _ Events, done func(View, error)) {
	done(nil, ErrUnavailable)
}
func (unsupported) SetPolicy(Policy)  {}
func (unsupported) MemoryMB() float64 { return 0 }
func (unsupported) Version() string   { return "" }
func Installed() bool                 { return false }
func SelfMB() float64                 { return 0 }
