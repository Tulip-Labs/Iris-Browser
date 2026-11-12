package ui

// Material 3 components, blended with Flowcode's palettes and glass.

// stateLayer paints M3's hover/press overlay in the content color.
func stateLayer(g Gfx, r Rect, rad float32, on Color, hot, down bool) {
	switch {
	case down:
		FillRound(g, r, rad, on.Alpha(0.12))
	case hot:
		FillRound(g, r, rad, on.Alpha(0.08))
	}
}

// Button: Primary is an M3 filled button (with a soft accent gradient), the default
// is a tonal button, Danger a filled error button.
func (u *Ui) Button(id ID, r Rect, label string, o ButtonOpt) bool {
	g, th := u.G, u.Th
	enabled := !o.Disabled
	hot := enabled && u.Hover(r)
	down := enabled && u.IsActive(id)
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
		Shadow(g, r, rad, th.Shadow, 0.5, 2)
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
	u.Tooltip(o.Tip, r)
	return enabled && u.Clickable(id, r)
}

// IconButton is an M3 standard icon button; Toggled shows the tonal selected state.
func (u *Ui) IconButton(id ID, r Rect, icon Icon, tip string, o IconOpt) bool {
	g, th := u.G, u.Th
	enabled := !o.Disabled
	hot := enabled && u.Hover(r)
	down := enabled && u.IsActive(id)
	d := min(r.W, r.H)
	c := RectAround(r.CX(), r.CY(), d, d)
	col := th.OnSurfaceVariant
	switch {
	case !enabled:
		col = th.OnSurface.Alpha(0.38)
	case o.Toggled:
		FillOval(g, c, th.SecondaryContainer)
		col = th.OnSecondaryContainer
	case o.Accent != 0:
		col = o.Accent
	}
	stateLayer(g, c, d/2, col, hot, down)
	s := min(20, d-12)
	DrawIcon(g, icon, r.CX()-s/2, r.CY()-s/2, s, col)
	u.Tooltip(tip, r)
	return enabled && u.Clickable(id, r)
}

// Fab is an M3 floating action button (extended when label is set).
func (u *Ui) Fab(id ID, r Rect, icon Icon, label, tip string) bool {
	g, th := u.G, u.Th
	hot, down := u.Hover(r), u.IsActive(id)
	rad := min(16, r.H/2)
	Shadow(g, r, rad, th.Shadow, 0.9, 3)
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
	u.Tooltip(tip, r)
	return u.Clickable(id, r)
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
	for i, o := range options {
		cr := Rect{r.X + float32(i)*w, r.Y, w, r.H}
		sel := i == selected
		if sel {
			// selected fill, clipped to the pill
			g.Save()
			FillPathClip(g, NewPath().RoundRect(r, rad), cr, th.SecondaryContainer)
			g.Restore()
		}
		fg := th.OnSurface
		if sel {
			fg = th.OnSecondaryContainer
		}
		stateLayer(g, cr, 0, fg, u.Hover(cr), u.IsActive(id.N(i)))
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
		stateLayer(g, cr.Inset2(2, 2), 10, c, u.Hover(cr), u.IsActive(id.N(i)))
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
			ind := Rect{cr.CX() - cw/2, r.B() - 3, cw, 3}
			FillRound(g, Rect{ind.X, ind.Y, ind.W, 6}, 3, th.Primary)
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
	stateLayer(g, RectAround(b.CX(), b.CY(), 36, 36), 18, th.Primary, u.Hover(r), u.IsActive(id))
	if value {
		FillRound(g, b, 4, th.Primary)
		DrawIcon(g, ICheck, b.X+2, b.Y+2, 14, th.OnPrimary)
	} else {
		StrokeRound(g, b.Inset(1), 3, 2, th.OnSurfaceVariant)
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
	tw := g.Measure(s, f) + 16
	x := clampf(u.St.TooltipAt.CX()-tw/2, 4, u.W-tw-4)
	y := u.St.TooltipAt.B() + 6
	if y+26 > u.H-4 {
		y = u.St.TooltipAt.Y - 32
	}
	FillRound(g, Rect{x, y, tw, 26}, 6, th.InverseSurface)
	g.Text(s, x+8, Mid(g, y, 26, f), f, th.InverseOnSurface)
	u.St.Tooltip = ""
}
