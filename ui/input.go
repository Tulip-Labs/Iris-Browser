package ui

import "math"

// Key is a key the interface reacts to; letters arrive with Ctrl for shortcuts.
type Key uint8

const (
	KNone Key = iota
	KLeft
	KRight
	KUp
	KDown
	KHome
	KEnd
	KPageUp
	KPageDown
	KBackspace
	KDelete
	KEnter
	KTab
	KEscape
	KSpace
	KSlash
	KPeriod
	KPlus
	KMinus
	KZero
	KF5
	KF6
	KF7
	KF8
	KF9
	KF10
	KF11
	KA
	KB
	KC
	KD
	KE
	KF
	KN
	KO
	KS
	KV
	KX
	KY
	KZ
	KT
	KW
	KL
	KR
	KH
	KK
	KM
	KJ
	KP
	KF12
	K1
	K2
	K3
	K4
	K5
	K6
	K7
	K8
	K9
	KComma
)

// Edit replaces runes [Start, End) of the focused field with Text.
type Edit struct {
	Start, End int
	Text       string
}

// KeyPress is one key event with its modifiers.
type KeyPress struct {
	Key              Key
	Ctrl, Shift, Alt bool
}

// Input is the pointer and keyboard state of one frame, filled by the host.
type Input struct {
	MX, MY            float32
	Down              bool
	Pressed, Released bool
	RightPressed      bool
	DoubleClick       bool
	WheelX, WheelY    float32 // positive WheelY scrolls content up (wheel away from the user)
	Pinch             float32 // zoom factor this frame (1 = none)
	PinchX, PinchY    float32
	PressX, PressY    float32
	Touch             bool
	Dragging          bool // a press became a drag (pan or scroll), so it is no longer a click
	Keys              []KeyPress
	Typed             string
	Paste             string // clipboard text that arrived this frame (after Ctrl+V)
	// Edits are what an input method changed in the focused field this frame
	// (Android keyboards rewrite words as they compose them), in runes of the
	// field's text as it was published to the input method.
	Edits            []Edit
	Ctrl, Shift, Alt bool
	Now              float64 // seconds, monotonic
}

func NewInput() *Input { return &Input{MX: -1, MY: -1, Pinch: 1} }

// EndFrame clears the one-frame events.
func (in *Input) EndFrame() {
	in.Pressed, in.Released, in.RightPressed, in.DoubleClick = false, false, false, false
	in.WheelX, in.WheelY, in.Pinch = 0, 0, 1
	in.Keys, in.Typed, in.Paste, in.Edits = in.Keys[:0], "", "", in.Edits[:0]
	if !in.Down {
		in.Dragging = false
	}
}

func (in *Input) DragDistance() float32 {
	return float32(math.Hypot(float64(in.MX-in.PressX), float64(in.MY-in.PressY)))
}

// Has reports (and consumes) a key press matching k and the Ctrl state.
func (in *Input) Has(k Key, ctrl bool) bool {
	for i, p := range in.Keys {
		if p.Key == k && p.Ctrl == ctrl {
			in.Keys = append(in.Keys[:i], in.Keys[i+1:]...)
			return true
		}
	}
	return false
}

// Peek reports a key press without consuming it.
func (in *Input) Peek(k Key, ctrl bool) bool {
	for _, p := range in.Keys {
		if p.Key == k && p.Ctrl == ctrl {
			return true
		}
	}
	return false
}
