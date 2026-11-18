package ui

// Material 3 components, blended with Flowcode's palettes and glass.

// stateLayer paints M3's hover/press overlay in the content color; hot and
// down are how far the pointer is over it and pressing it (0 to 1).
func stateLayer(g Gfx, r Rect, rad float32, on Color, hot, down float32) {
	if a := 0.08*hot + 0.06*down; a > 0.003 {
		FillRound(g, r, rad, on.Alpha(a))
	}
}

func b2f(b bool) float32 {
	if b {
		return 1
	}
	return 0
}

// Button: Primary is an M3 filled button (with a soft accent gradient), the default
// is a tonal button, Danger a filled error button.
func (u *Ui) Button(id ID, r Rect, label string, o ButtonOpt) bool {
	g, th := u.G, u.Th
	enabled := !o.Disabled
	hot, down := u.Hot(id, r, enabled), u.Press(id, enabled)
	hit := r
	r = Squeeze(r, down)
	rad := r.H / 2
	var bg, fg Color
	switch {
	case !enabled:
		bg, fg = th.OnSurface.Alpha(0.10), th.OnSurface.Alpha(0.38)
	case o.Danger:
		bg, fg = th.Danger, White
	case o.Primary:
		bg, fg = th.Primary, th.OnPrimary
	default:
		bg, fg = th.SecondaryContainer, th.OnSecondaryContainer
	}
	if enabled && (o.Primary || o.Danger) {
		Shadow(g, r, rad, th.Shadow, 0.5+0.3*hot-0.3*down, 2)
		FillRoundAccent(g, r, rad, bg)
	} else {
		FillRound(g, r, rad, bg)
	}
	stateLayer(g, r, rad, fg, hot, down)
	f := FBodyBold
	var iw, gap float32
	if o.HasIcon {
		iw = 18
		if label != "" {
			gap = 8
		}
	}
	tw := g.Measure(label, f)
	x := r.CX() - (iw+gap+tw)/2
	if o.HasIcon {
		DrawIcon(g, o.Icon, x, r.CY()-9, 18, fg)
		x += iw + gap
	}
	if label != "" {
		g.Text(label, x, Mid(g, r.Y, r.H, f), f, fg)
	}
	u.Tooltip(o.Tip, hit)
	return enabled && u.Clickable(id, hit)
}

// IconButton is an M3 standard icon button; Toggled shows the tonal selected state.
func (u *Ui) IconButton(id ID, r Rect, icon Icon, tip string, o IconOpt) bool {
	g, th := u.G, u.Th
	enabled := !o.Disabled
	hot, down := u.Hot(id, r, enabled), u.Press(id, enabled)
	d := min(r.W, r.H)
	c := RectAround(r.CX(), r.CY(), d, d)
	col := th.OnSurfaceVariant
	// the selected state grows out of the middle
	on := u.Ease(id.Sub("on"), b2f(enabled && o.Toggled), RateQuick)
	if on > 0.01 {
		FillOval(g, RectAround(c.CX(), c.CY(), d*(0.6+0.4*on), d*(0.6+0.4*on)), th.SecondaryContainer.Fade(on))
	}
	switch {
	case !enabled:
		col = th.OnSurface.Alpha(0.38)
	case o.Toggled:
		col = th.OnSecondaryContainer
	case o.Accent != 0:
		col = o.Accent
	}
	stateLayer(g, c, d/2, col, hot, down)
	s := min(20, d-12) * (1 - 0.08*down)
	DrawIcon(g, icon, r.CX()-s/2, r.CY()-s/2, s, col)
	u.Tooltip(tip, r)
	return enabled && u.Clickable(id, r)
}

// Fab is an M3 floating action button (extended when label is set).
func (u *Ui) Fab(id ID, r Rect, icon Icon, label, tip string) bool {
	g, th := u.G, u.Th
	hot, down := u.Hot(id, r, true), u.Press(id, true)
	hit := r
	r = Squeeze(r, down)
	rad := min(16, r.H/2)
	Shadow(g, r, rad, th.Shadow, 0.9+0.3*hot, 3)
	FillRoundAccent(g, r, rad, th.Primary)
	stateLayer(g, r, rad, th.OnPrimary, hot, down)
	if label == "" {
		DrawIcon(g, icon, r.CX()-10, r.CY()-10, 20, th.OnPrimary)
	} else {
		tw := g.Measure(label, FBodyBold)
		x := r.CX() - (20+8+tw)/2
		DrawIcon(g, icon, x, r.CY()-10, 20, th.OnPrimary)
		g.Text(label, x+28, Mid(g, r.Y, r.H, FBodyBold), FBodyBold, th.OnPrimary)
	}
	u.Tooltip(tip, hit)
	return u.Clickable(id, hit)
}

// Segmented is an M3 segmented button: an outlined pill group, the selected
// segment tonal with a check mark. It returns the chosen index.
func (u *Ui) Segmented(id ID, r Rect, options []string, selected int) int {
	g, th := u.G, u.Th
	rad := r.H / 2
	w := r.W / float32(len(options))
	out := selected
	g.Save()
	g.Clip(r)
	// the selected fill glides to the chosen segment, clipped to the pill
	at := u.Ease(id.Sub("sel"), float32(selected), RateQuick)
	FillPathClip(g, NewPath().RoundRect(r, rad), Rect{r.X + at*w, r.Y, w, r.H}, th.SecondaryContainer)
	for i, o := range options {
		cr := Rect{r.X + float32(i)*w, r.Y, w, r.H}
		sel := i == selected
		fg := th.OnSurface
		if sel {
			fg = th.OnSecondaryContainer
		}
		stateLayer(g, cr, 0, fg, u.Hot(id.N(i), cr, true), u.Press(id.N(i), true))
		f := FSmallBold
		tw := g.Measure(o, f)
		cw := float32(0)
		if sel && w > tw+40 {
			cw = 20
		}
		x := cr.CX() - (tw+cw)/2
		if cw > 0 {
			DrawIcon(g, ICheck, x, cr.CY()-8, 16, fg)
			x += cw
		}
		g.Text(Fit(g, o, f, w-12), x, Mid(g, cr.Y, cr.H, f), f, fg)
		if i > 0 {
			g.FillRect(Rect{cr.X - 0.5, r.Y, 1, r.H}, th.Outline)
		}
		if u.Clickable(id.N(i), cr) {
			out = i
		}
	}
	g.Restore()
	StrokeRound(g, r.Inset(0.5), rad, 1, th.Outline)
	return out
}

// FillPathClip fills the part of path p inside rect r.
func FillPathClip(g Gfx, p *Path, r Rect, c Color) {
	g.Save()
	g.Clip(r)
	g.FillPath(p, c)
	g.Restore()
}

// Tabs are M3 primary tabs: icon and label, with an indicator bar under the selected one.
func (u *Ui) Tabs(id ID, r Rect, items []TabItem, selected int, compact bool) int {
	g, th := u.G, u.Th
	out := selected
	w := r.W / float32(len(items))
	iconsOnly := compact
	for _, it := range items {
		if g.Measure(it.Label, FSmallBold)+30 > w-4 {
			iconsOnly = true
		}
	}
	g.FillRect(Rect{r.X, r.B() - 1, r.W, 1}, th.OutlineVariant)
	for i, it := range items {
		cr := Rect{r.X + float32(i)*w, r.Y, w, r.H}
		sel := i == selected
		c := th.OnSurfaceVariant
		if sel {
			c = th.Primary
		}
		stateLayer(g, cr.Inset2(2, 2), 10, c, u.Hot(id.N(i), cr, true), u.Press(id.N(i), true))
		cw := float32(24)
		if iconsOnly {
			DrawIcon(g, it.Icon, cr.CX()-9, cr.CY()-10, 18, c)
			u.Tooltip(it.Label, cr)
		} else {
			tw := g.Measure(it.Label, FSmallBold)
			x0 := cr.CX() - (tw+22)/2
			DrawIcon(g, it.Icon, x0, cr.CY()-9, 16, c)
			g.Text(it.Label, x0+22, Mid(g, cr.Y, cr.H-2, FSmallBold), FSmallBold, c)
			cw = tw + 22
		}
		if sel {
			// the indicator glides from the last tab to this one
			cx := u.Ease(id.Sub("ind-x"), cr.CX(), RateQuick)
			iw := u.Ease(id.Sub("ind-w"), cw, RateQuick)
			FillRound(g, Rect{cx - iw/2, r.B() - 3, iw, 6}, 3, th.Primary)
		}
		if u.Clickable(id.N(i), cr) {
			out = i
		}
	}
	return out
}

func (u *Ui) Checkbox(id ID, r Rect, label string, value bool) bool {
	g, th := u.G, u.Th
	b := Rect{r.X + 2, r.CY() - 9, 18, 18}
	stateLayer(g, RectAround(b.CX(), b.CY(), 36, 36), 18, th.Primary, u.Hot(id, r, true), u.Press(id, true))
	// the box fills from the middle and the check pops in
	on := u.Ease(id.Sub("on"), b2f(value), RateQuick)
	if on < 0.99 {
		StrokeRound(g, b.Inset(1), 3, 2, th.OnSurfaceVariant.Fade(1-on))
	}
	if on > 0.01 {
		k := 0.5 + 0.5*on
		FillRound(g, RectAround(b.CX(), b.CY(), b.W*k, b.H*k), 4*k, th.Primary.Fade(on))
		s := 14 * (0.6 + 0.4*on)
		DrawIcon(g, ICheck, b.CX()-s/2, b.CY()-s/2, s, th.OnPrimary.Fade(on))
	}
	g.Text(label, r.X+32, Mid(g, r.Y, r.H, FBody), FBody, th.OnSurface)
	if u.Clickable(id, r) {
		return !value
	}
	return value
}

// Slider is an M3 slider: a thick active track, a gap, and a bar-shaped handle.
func (u *Ui) Slider(id ID, r Rect, value float32) float32 {
	g, th := u.G, u.Th
	v := value
	if u.Live() && u.In.Pressed && r.Inset2(-4, -8).Contains(u.In.MX, u.In.MY) {
		u.St.SliderDrag = id
	}
	if u.St.SliderDrag == id {
		if u.In.Down {
			v = clampf((u.In.MX-r.X)/r.W, 0, 1)
			u.In.Dragging = true
		} else {
			u.St.SliderDrag = ID{}
		}
	}
	ty := r.CY()
	const th2, gap = 6, 5
	kx := r.X + r.W*v
	if kx-gap > r.X {
		FillRound(g, Rect{r.X, ty - th2/2, kx - gap - r.X, th2}, th2/2, th.Primary)
	}
	if kx+gap < r.R() {
		FillRound(g, Rect{kx + gap, ty - th2/2, r.R() - kx - gap, th2}, th2/2, th.SecondaryContainer)
	}
	hot := u.Hover(r.Inset2(-4, -8)) || u.St.SliderDrag == id
	hw := float32(4)
	if u.St.SliderDrag == id {
		hw = 3
	}
	if hot {
		FillOval(g, RectAround(kx, ty, 30, 30), th.Primary.Alpha(0.10))
	}
	FillRound(g, RectAround(kx, ty, hw, 22), hw/2, th.Primary)
	return v
}

// DrawTooltip paints this frame's tooltip as an M3 plain tooltip (call last).
func (u *Ui) DrawTooltip() {
	s := u.St.Tooltip
	if s == "" {
		return
	}
	g, th, f := u.G, u.Th, FSmall
	// a new tooltip fades in and rises into place
	if s != u.St.tipLast {
		u.St.tipLast = s
		delete(u.St.anims, Id("tooltip"))
	}
	k := u.EaseFrom(Id("tooltip"), 1, RateQuick, 0)
	tw := g.Measure(s, f) + 16
	x := clampf(u.St.TooltipAt.CX()-tw/2, 4, u.W-tw-4)
	y := u.St.TooltipAt.B() + 6
	if y+26 > u.H-4 {
		y = u.St.TooltipAt.Y - 32
	}
	y += (1 - k) * 4
	FillRound(g, Rect{x, y, tw, 26}, 6, th.InverseSurface.Fade(k))
	g.Text(s, x+8, Mid(g, y, 26, f), f, th.InverseOnSurface.Fade(k))
	u.St.Tooltip = ""
}
