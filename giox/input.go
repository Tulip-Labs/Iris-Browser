package giox

import (
	"io"
	"runtime"
	"time"

	"gioui.org/f32"
	"gioui.org/io/clipboard"
	"gioui.org/io/event"
	"gioui.org/io/key"
	"gioui.org/io/pointer"
	"gioui.org/io/transfer"
	"gioui.org/layout"

	"litego/ui"
)

var keyNames = map[key.Name]ui.Key{
	key.NameLeftArrow: ui.KLeft, key.NameRightArrow: ui.KRight, key.NameUpArrow: ui.KUp, key.NameDownArrow: ui.KDown,
	key.NameHome: ui.KHome, key.NameEnd: ui.KEnd, key.NamePageUp: ui.KPageUp, key.NamePageDown: ui.KPageDown,
	key.NameDeleteBackward: ui.KBackspace, key.NameDeleteForward: ui.KDelete, key.NameReturn: ui.KEnter, key.NameEnter: ui.KEnter,
	key.NameTab: ui.KTab, key.NameEscape: ui.KEscape, key.NameSpace: ui.KSpace,
	key.NameF5: ui.KF5, key.NameF6: ui.KF6, key.NameF11: ui.KF11, key.NameF12: ui.KF12,
	"A": ui.KA, "C": ui.KC, "D": ui.KD, "K": ui.KK, "L": ui.KL, "M": ui.KM, "N": ui.KN, "R": ui.KR, "T": ui.KT, "V": ui.KV, "W": ui.KW, "X": ui.KX, "Z": ui.KZ, "Y": ui.KY, "J": ui.KJ,
	"1": ui.K1, "2": ui.K2, "3": ui.K3, "4": ui.K4, "5": ui.K5, "6": ui.K6, "7": ui.K7, "8": ui.K8, "9": ui.K9, ",": ui.KComma,
}

func keyFilters(tag event.Tag) []event.Filter {
	all := key.ModShift | key.ModAlt | key.ModCtrl | key.ModShortcut
	fs := []event.Filter{
		key.FocusFilter{Target: tag},
		transfer.TargetFilter{Target: tag, Type: "application/text"},
		pointer.Filter{Target: tag, Kinds: pointer.Press | pointer.Release | pointer.Move | pointer.Drag | pointer.Scroll | pointer.Leave | pointer.Cancel,
			ScrollX: pointer.ScrollRange{Min: -1 << 20, Max: 1 << 20}, ScrollY: pointer.ScrollRange{Min: -1 << 20, Max: 1 << 20}},
	}
	for name := range keyNames {
		switch {
		case len(name) == 1:
			// letters, digits and symbols only as shortcuts: plain typing arrives as text
			fs = append(fs, key.Filter{Focus: tag, Name: name, Required: key.ModShortcut, Optional: key.ModShift | key.ModAlt})
			if name == "D" {
				fs = append(fs, key.Filter{Focus: tag, Name: name, Required: key.ModAlt})
			}
		case name == key.NameSpace:
			fs = append(fs, key.Filter{Focus: tag, Name: name, Required: key.ModShortcut})
		default:
			fs = append(fs, key.Filter{Focus: tag, Name: name, Optional: all})
		}
	}
	return fs
}

// Reader turns a window's Gio events into ui.Input. Tag must be the target of
// an event.Op covering the window.
type Reader struct {
	Tag       event.Tag
	filters   []event.Filter
	lastClick time.Time
	lastPos   f32.Point
}

// Read collects this frame's events.
func (rd *Reader) Read(gtx layout.Context, in *ui.Input, scale float32) {
	if rd.filters == nil {
		rd.filters = keyFilters(rd.Tag)
	}
	tag := rd.Tag
	lastClick, lastPos := &rd.lastClick, &rd.lastPos
	for {
		ev, ok := gtx.Event(rd.filters...)
		if !ok {
			break
		}
		switch e := ev.(type) {
		case pointer.Event:
			p := e.Position.Div(scale)
			in.MX, in.MY = p.X, p.Y
			in.Ctrl = e.Modifiers.Contain(key.ModShortcut)
			in.Shift = e.Modifiers.Contain(key.ModShift)
			in.Alt = e.Modifiers.Contain(key.ModAlt)
			in.Touch = e.Source == pointer.Touch
			switch e.Kind {
			case pointer.Press:
				if e.Buttons.Contain(pointer.ButtonSecondary) {
					in.RightPressed = true
					continue
				}
				now := time.Now()
				d := e.Position.Sub(*lastPos).Div(scale)
				if now.Sub(*lastClick) < 450*time.Millisecond && d.X*d.X+d.Y*d.Y < 36 {
					in.DoubleClick = true
				}
				*lastClick, *lastPos = now, e.Position
				in.Down, in.Pressed, in.PressX, in.PressY = true, true, p.X, p.Y
				gtx.Execute(key.FocusCmd{Tag: tag})
			case pointer.Release, pointer.Cancel:
				if in.Down {
					in.Down, in.Released = false, true
				}
			case pointer.Scroll:
				div := float32(40)
				if runtime.GOOS == "windows" {
					div = 120
				}
				if e.Source == pointer.Touch || runtime.GOOS == "darwin" {
					div = 30
				}
				in.WheelY += -e.Scroll.Y / div
				in.WheelX += -e.Scroll.X / div
			case pointer.Leave:
				if !in.Down {
					in.MX, in.MY = -1, -1
				}
			}
		case key.Event:
			if e.State != key.Press {
				continue
			}
			k, ok := keyNames[e.Name]
			if !ok {
				continue
			}
			ctrl := e.Modifiers.Contain(key.ModShortcut)
			if ctrl && k == ui.KV {
				gtx.Execute(clipboard.ReadCmd{Tag: tag})
				continue
			}
			in.Keys = append(in.Keys, ui.KeyPress{Key: k, Ctrl: ctrl, Shift: e.Modifiers.Contain(key.ModShift), Alt: e.Modifiers.Contain(key.ModAlt)})
		case key.EditEvent:
			in.Typed += e.Text
		case transfer.DataEvent:
			if r := e.Open(); r != nil {
				b, _ := io.ReadAll(io.LimitReader(r, 4<<20))
				r.Close()
				in.Paste += string(b)
			}
		}
	}
}
