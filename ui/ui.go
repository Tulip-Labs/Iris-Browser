package ui

import (
	"strconv"
	"strings"
	"unicode"
)

// ID names a widget across frames.
type ID struct {
	S string
	I int
}

func Id(s string) ID          { return ID{S: s} }
func IdN(s string, i int) ID  { return ID{S: s, I: i + 1} }
func (id ID) Sub(s string) ID { return ID{S: id.S + "/" + s, I: id.I} }
func (id ID) N(i int) ID      { return ID{S: id.S, I: id.I*1000 + i + 1} }
func (id ID) String() string  { return id.S + "#" + strconv.Itoa(id.I) }
func (id ID) Zero() bool      { return id == ID{} }

// State is widget state that lives across frames.
type State struct {
	Active, Focus, LastFocus ID
	Tooltip                  string
	TooltipAt                Rect
	DragScroll               ID
	DragStartScroll          float32
	SliderDrag               ID
	CaretBlink               float64
	// Editing is the focused field's text (set by TextField each frame), for
	// hosts that tell the input method what is being edited.
	Editing *TextEdit
	// motion (anim.go)
	anims   map[ID]*animVal
	animNow float64
	animDt  float32
	tipLast string
}

// Clipboard writes text to the system clipboard; pasted text arrives in Input.Paste.
type Clipboard interface{ Set(s string) }

// Ui draws immediate-mode widgets: each call draws a control and reports what the
// pointer or keyboard did to it this frame. Only InputLayer (the top popup or dialog,
// or the base) receives input.
type Ui struct {
	G          Gfx
	In         *Input
	Th         *Theme
	St         *State
	Clip       Clipboard
	Layer      int
	InputLayer int
	W, H       float32
	Redraw     bool // something animates: ask for another frame
	NoMotion   bool // the reader asked for less motion: values jump to where they go
	hit        []Rect
}

// PushHit limits the pointer to r (and to the limits already in place) until
// PopHit: what a scrolled list draws outside its clip must not take clicks.
func (u *Ui) PushHit(r Rect) {
	if n := len(u.hit); n > 0 {
		o := u.hit[n-1]
		x, y := max(r.X, o.X), max(r.Y, o.Y)
		r = Rect{x, y, max(0, min(r.R(), o.R())-x), max(0, min(r.B(), o.B())-y)}
	}
	u.hit = append(u.hit, r)
}

func (u *Ui) PopHit() {
	if n := len(u.hit); n > 0 {
		u.hit = u.hit[:n-1]
	}
}

// ResetHit drops every limit (call at the start of a frame).
func (u *Ui) ResetHit() { u.hit = u.hit[:0] }

// Over says whether the pointer is in r and inside the current limits.
func (u *Ui) Over(r Rect) bool { return u.at(r, u.In.MX, u.In.MY) }

func (u *Ui) at(r Rect, x, y float32) bool {
	if n := len(u.hit); n > 0 && !u.hit[n-1].Contains(x, y) {
		return false
	}
	return r.Contains(x, y)
}

func (u *Ui) Live() bool  { return u.Layer == u.InputLayer }
func (u *Ui) Touch() bool { return u.In.Touch }

// RowH is the minimum height of a tappable row.
func (u *Ui) RowH() float32 {
	if u.In.Touch {
		return 44
	}
	return 32
}

func (u *Ui) Hover(r Rect) bool {
	return u.Live() && u.Over(r) && !(u.In.Touch && !u.In.Down && !u.In.Released)
}
func (u *Ui) PressedIn(r Rect) bool { return u.Live() && u.In.Pressed && u.Over(r) }

// Clickable arms on press and fires on release over the same target.
func (u *Ui) Clickable(id ID, r Rect) bool {
	if !u.Live() {
		return false
	}
	if u.In.Pressed && u.Over(r) {
		u.St.Active = id
	}
	if u.In.Released && u.St.Active == id {
		u.St.Active = ID{}
		return u.Over(r) && !u.In.Dragging
	}
	return false
}

func (u *Ui) IsActive(id ID) bool { return u.St.Active == id && u.In.Down && !u.In.Dragging }

func (u *Ui) Tooltip(text string, r Rect) {
	if !u.In.Touch && u.Hover(r) && text != "" {
		u.St.Tooltip, u.St.TooltipAt = text, r
	}
}

// ---- buttons ----

type ButtonOpt struct {
	Icon            Icon
	HasIcon         bool
	Primary, Danger bool
	Disabled        bool
	Tip             string
}

type IconOpt struct {
	Toggled, Disabled bool
	Accent            Color
}

// TabItem is one tab: an icon and a label.
type TabItem struct {
	Icon  Icon
	Label string
}

// ---- scrolling ----

type Scroll struct{ Y, Content, X, ContentW float32 }

// Scroll handles the wheel and touch drags over r; draw the content offset by -s.Y.
func (u *Ui) Scroll(id ID, r Rect, s *Scroll) {
	maxY := max(0, s.Content-r.H)
	if u.Live() && r.Contains(u.In.MX, u.In.MY) {
		s.Y -= u.In.WheelY * 48
	}
	if u.Live() && u.In.Touch {
		if u.In.Pressed && r.Contains(u.In.MX, u.In.MY) {
			u.St.DragScroll, u.St.DragStartScroll = id, s.Y
		}
		if u.St.DragScroll == id && u.In.Down && abs32(u.In.MY-u.In.PressY) > 8 && maxY > 0 {
			u.In.Dragging = true
			s.Y = u.St.DragStartScroll - (u.In.MY - u.In.PressY)
		}
		if !u.In.Down && u.St.DragScroll == id {
			u.St.DragScroll = ID{}
		}
	}
	s.Y = clampf(s.Y, 0, maxY)
}

func (u *Ui) Scrollbar(r Rect, s *Scroll) {
	if s.Content <= r.H+1 {
		return
	}
	h := max(24, r.H*r.H/s.Content)
	y := r.Y + (r.H-h)*(s.Y/(s.Content-r.H))
	FillRound(u.G, Rect{r.R() - 5, y, 3.5, h}, 2, u.Th.Ink.Alpha(0.22))
}

func abs32(v float32) float32 {
	if v < 0 {
		return -v
	}
	return v
}

// ---- text fields ----

// TextEdit is text being edited in a field (runes, so accents and other scripts edit correctly).
type TextEdit struct {
	R             []rune
	Caret, Anchor int
	Multiline     bool
	ScrollX       float32
	ScrollY       float32
}

func NewTextEdit(s string, multiline bool) *TextEdit {
	r := []rune(s)
	return &TextEdit{R: r, Caret: len(r), Anchor: len(r), Multiline: multiline}
}
func (t *TextEdit) Text() string     { return string(t.R) }
func (t *TextEdit) HasSel() bool     { return t.Caret != t.Anchor }
func (t *TextEdit) SelStart() int    { return min(t.Caret, t.Anchor) }
func (t *TextEdit) SelEnd() int      { return max(t.Caret, t.Anchor) }
func (t *TextEdit) SelectAll()       { t.Anchor, t.Caret = 0, len(t.R) }
func (t *TextEdit) Set(s string)     { t.R = []rune(s); t.Caret, t.Anchor = len(t.R), len(t.R) }
func (t *TextEdit) Selected() string { return string(t.R[t.SelStart():t.SelEnd()]) }
func (t *TextEdit) ReplaceSel(s string) {
	a, b := t.SelStart(), t.SelEnd()
	ins := []rune(s)
	out := make([]rune, 0, len(t.R)-(b-a)+len(ins))
	out = append(append(append(out, t.R[:a]...), ins...), t.R[b:]...)
	t.R = out
	t.Caret = a + len(ins)
	t.Anchor = t.Caret
}

type FieldOpt struct {
	Placeholder string
	Mono, Error bool
	Autofocus   bool
	OnEnter     func()
	// Bare draws only the text (the caller draws the field), in Font if set.
	Bare bool
	Font Font
}

// TextField draws a text field; it returns true when the text changed this frame.
func (u *Ui) TextField(id ID, r Rect, t *TextEdit, o FieldOpt) bool {
	g, th, in := u.G, u.Th, u.In
	f := FBody
	if o.Mono {
		f = FCode
	}
	if o.Font.Size > 0 {
		f = o.Font
	}
	if o.Autofocus && u.St.Focus.Zero() && u.St.LastFocus != id {
		u.St.Focus, u.St.LastFocus = id, id
		t.SelectAll()
	}
	focused := u.St.Focus == id
	if !o.Bare {
		// M3 outlined text field, rounded to match the glass cards; focus
		// glows in around it, so it is plain where typing goes
		fo := u.Ease(id.Sub("focus"), b2f(focused), RateQuick)
		hot := u.Hot(id, r, !focused)
		FillRound(g, r, 12, th.Field)
		if fo > 0.01 && !o.Error {
			StrokeRound(g, r.Inset(-2.5), 14.5, 3, th.Primary.Fade(0.22*fo))
		}
		rim, rw := Mix(th.Outline, th.OnSurface.Alpha(0.6), hot), float32(1)
		switch {
		case o.Error:
			rim, rw = th.Danger, 2
		case fo > 0.01:
			rim, rw = Mix(rim, th.Primary, fo), 1+fo
		}
		StrokeRound(g, r.Inset(rw/2), 12, rw, rim)
	}
	lineH := g.Ascent(f) + g.Descent(f) + 4
	padY := float32(0)
	if t.Multiline {
		padY = 8
	}
	inner := r.Inset2(10, padY)
	if u.Live() && in.Pressed && u.Over(r) {
		u.St.Focus, u.St.LastFocus = id, id
		pos := u.hitText(t, inner, f, lineH, in.MX, in.MY)
		t.Caret = pos
		if !in.Shift {
			t.Anchor = pos
		}
		if in.DoubleClick {
			t.Anchor, t.Caret = wordBounds(t.R, pos)
		}
		u.St.Active = id
	} else if u.Live() && u.St.Active == id && in.Down && !in.Touch {
		t.Caret = u.hitText(t, inner, f, lineH, in.MX, in.MY)
	} else if u.Live() && in.Pressed && focused && !r.Contains(in.MX, in.MY) {
		u.St.Focus = ID{}
	}
	changed := false
	if focused && u.Live() {
		u.St.Editing = t
		for _, e := range in.Edits {
			a, b := max(0, min(e.Start, len(t.R))), max(0, min(e.End, len(t.R)))
			if a > b {
				a, b = b, a
			}
			t.Anchor, t.Caret = a, b
			t.ReplaceSel(e.Text)
			changed = true
		}
		in.Edits = in.Edits[:0]
		changed = u.editKeys(t, o.OnEnter) || changed
	}
	g.Save()
	g.Clip(r.Inset(2))
	if !t.Multiline {
		cx := g.Measure(string(t.R[:t.Caret]), f)
		if cx-t.ScrollX > inner.W-4 {
			t.ScrollX = cx - inner.W + 4
		}
		if cx-t.ScrollX < 0 {
			t.ScrollX = max(0, cx-20)
		}
		base := Mid(g, r.Y, r.H, f)
		x0 := inner.X - t.ScrollX
		if t.HasSel() && focused {
			a := g.Measure(string(t.R[:t.SelStart()]), f)
			b := g.Measure(string(t.R[:t.SelEnd()]), f)
			g.FillRect(Rect{x0 + a, r.CY() - lineH/2, b - a, lineH}, th.Selection)
		}
		if len(t.R) == 0 && o.Placeholder != "" {
			g.Text(o.Placeholder, inner.X, base, f, th.Ink3)
		} else {
			g.Text(string(t.R), x0, base, f, th.Ink)
		}
		if focused {
			g.FillRect(Rect{x0 + cx, r.CY() - lineH/2 + 1, 1.6, lineH - 2}, th.Deep)
		}
	} else {
		lines := strings.Split(string(t.R), "\n")
		cl, _ := lineCol(t.R, t.Caret)
		if float32(cl+1)*lineH-t.ScrollY > inner.H {
			t.ScrollY = float32(cl+1)*lineH - inner.H
		}
		if float32(cl)*lineH-t.ScrollY < 0 {
			t.ScrollY = float32(cl) * lineH
		}
		if u.Hover(r) {
			t.ScrollY = clampf(t.ScrollY-in.WheelY*40, 0, max(0, float32(len(lines))*lineH-inner.H))
		}
		start := 0
		for i, ln := range lines {
			lr := []rune(ln)
			y := inner.Y + float32(i)*lineH - t.ScrollY
			if y > r.B() {
				break
			}
			end := start + len(lr)
			if y+lineH >= r.Y {
				if t.HasSel() && focused && t.SelEnd() > start && t.SelStart() <= end {
					a, b := max(t.SelStart(), start)-start, min(t.SelEnd(), end)-start
					ax, bx := g.Measure(string(lr[:a]), f), g.Measure(string(lr[:b]), f)
					if t.SelEnd() > end {
						bx += 6
					}
					g.FillRect(Rect{inner.X + ax, y, bx - ax, lineH}, th.Selection)
				}
				g.Text(ln, inner.X, y+2+g.Ascent(f), f, th.Ink)
				if focused && cl == i {
					g.FillRect(Rect{inner.X + g.Measure(string(lr[:t.Caret-start]), f), y + 1, 1.6, lineH - 2}, th.Deep)
				}
			}
			start = end + 1
		}
		if len(t.R) == 0 && o.Placeholder != "" {
			g.Text(o.Placeholder, inner.X, inner.Y+2+g.Ascent(f), f, th.Ink3)
		}
	}
	g.Restore()
	return changed
}

func lineCol(r []rune, pos int) (int, int) {
	line, col := 0, 0
	for i := 0; i < pos && i < len(r); i++ {
		if r[i] == '\n' {
			line, col = line+1, 0
		} else {
			col++
		}
	}
	return line, col
}

func lineStartOf(r []rune, line int) int {
	l, i := 0, 0
	for l < line && i < len(r) {
		if r[i] == '\n' {
			l++
		}
		i++
	}
	return i
}

func (u *Ui) hitText(t *TextEdit, inner Rect, f Font, lineH, px, py float32) int {
	if !t.Multiline {
		return u.colAt(t.R, px-inner.X+t.ScrollX, f)
	}
	lines := strings.Split(string(t.R), "\n")
	li := int((py - inner.Y + t.ScrollY) / lineH)
	li = max(0, min(len(lines)-1, li))
	return lineStartOf(t.R, li) + u.colAt([]rune(lines[li]), px-inner.X, f)
}

func (u *Ui) colAt(s []rune, x float32, f Font) int {
	if x <= 0 {
		return 0
	}
	prev := float32(0)
	for i := 1; i <= len(s); i++ {
		w := u.G.Measure(string(s[:i]), f)
		if w >= x {
			if x-prev < w-x {
				return i - 1
			}
			return i
		}
		prev = w
	}
	return len(s)
}

func isWordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }

func wordBounds(r []rune, p int) (int, int) {
	a, b := p, p
	for a > 0 && isWordRune(r[a-1]) {
		a--
	}
	for b < len(r) && isWordRune(r[b]) {
		b++
	}
	return a, b
}

func wordLeft(s []rune, i int) int {
	j := i - 1
	for j > 0 && !isWordRune(s[j-1]) {
		j--
	}
	for j > 0 && isWordRune(s[j-1]) {
		j--
	}
	return max(0, j)
}

func wordRight(s []rune, i int) int {
	j := i
	for j < len(s) && !isWordRune(s[j]) {
		j++
	}
	for j < len(s) && isWordRune(s[j]) {
		j++
	}
	return j
}

// globalKey reports keys a text field leaves for the app (shortcuts, Escape, Tab).
func globalKey(k KeyPress) bool {
	if k.Key == KEscape || k.Key == KTab || k.Key >= KF5 && k.Key <= KF11 || k.Key == KF12 {
		return true
	}
	return k.Ctrl && (k.Key == KS || k.Key == KZ || k.Key == KY || k.Key == KO || k.Key == KN || k.Key == KE || k.Key == KB)
}

func (u *Ui) editKeys(t *TextEdit, onEnter func()) bool {
	in := u.In
	changed := false
	var rest []KeyPress
	for _, k := range in.Keys {
		move := func(to int) {
			t.Caret = max(0, min(len(t.R), to))
			if !k.Shift {
				t.Anchor = t.Caret
			}
		}
		switch k.Key {
		case KLeft:
			if k.Alt {
				rest = append(rest, k)
			} else if t.HasSel() && !k.Shift {
				move(t.SelStart())
			} else if k.Ctrl {
				move(wordLeft(t.R, t.Caret))
			} else {
				move(t.Caret - 1)
			}
		case KRight:
			if k.Alt {
				rest = append(rest, k)
			} else if t.HasSel() && !k.Shift {
				move(t.SelEnd())
			} else if k.Ctrl {
				move(wordRight(t.R, t.Caret))
			} else {
				move(t.Caret + 1)
			}
		case KHome:
			if t.Multiline {
				l, _ := lineCol(t.R, t.Caret)
				move(lineStartOf(t.R, l))
			} else {
				move(0)
			}
		case KEnd:
			if t.Multiline {
				j := t.Caret
				for j < len(t.R) && t.R[j] != '\n' {
					j++
				}
				move(j)
			} else {
				move(len(t.R))
			}
		case KUp, KDown:
			if t.Multiline {
				l, c := lineCol(t.R, t.Caret)
				nl := l + 1
				if k.Key == KUp {
					nl = l - 1
				}
				lines := strings.Split(string(t.R), "\n")
				if nl >= 0 && nl < len(lines) {
					move(lineStartOf(t.R, nl) + min(c, len([]rune(lines[nl]))))
				}
			} else {
				rest = append(rest, k)
			}
		case KBackspace:
			if !t.HasSel() && t.Caret > 0 {
				if k.Ctrl {
					t.Anchor = wordLeft(t.R, t.Caret)
				} else {
					t.Anchor = t.Caret - 1
				}
			}
			t.ReplaceSel("")
			changed = true
		case KDelete:
			if !t.HasSel() && t.Caret < len(t.R) {
				t.Anchor = t.Caret + 1
			}
			t.ReplaceSel("")
			changed = true
		case KEnter:
			if t.Multiline && !k.Ctrl {
				t.ReplaceSel("\n")
				changed = true
			} else if onEnter != nil {
				onEnter()
			} else {
				rest = append(rest, k)
			}
		case KA:
			if k.Ctrl {
				t.SelectAll()
			}
		case KC:
			if k.Ctrl && t.HasSel() && u.Clip != nil {
				u.Clip.Set(t.Selected())
			}
		case KX:
			if k.Ctrl && t.HasSel() {
				if u.Clip != nil {
					u.Clip.Set(t.Selected())
				}
				t.ReplaceSel("")
				changed = true
			}
		default:
			if globalKey(k) || k.Ctrl || k.Alt {
				rest = append(rest, k)
			}
		}
	}
	in.Keys = rest
	if in.Paste != "" {
		s := strings.ReplaceAll(in.Paste, "\r\n", "\n")
		if !t.Multiline {
			s = strings.ReplaceAll(strings.ReplaceAll(s, "\r", ""), "\n", " ")
		}
		t.ReplaceSel(s)
		in.Paste = ""
		changed = true
	}
	if in.Typed != "" {
		var sb strings.Builder
		for _, r := range in.Typed {
			switch {
			case r == '\t':
				sb.WriteString("  ")
			case r >= ' ' || r == '\n' && t.Multiline:
				sb.WriteRune(r)
			}
		}
		if sb.Len() > 0 {
			t.ReplaceSel(sb.String())
			changed = true
		}
		in.Typed = ""
	}
	return changed
}

// ---- small helpers ----

func (u *Ui) Label(s string, x, y float32, f Font, c Color) { u.G.Text(s, x, y, f, c) }
func (u *Ui) Heading(s string, r Rect) {
	u.G.Text(s, r.X, Mid(u.G, r.Y, r.H, FSmallBold), FSmallBold, u.Th.Ink2)
}
