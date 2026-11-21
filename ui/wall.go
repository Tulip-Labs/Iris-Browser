package ui

// The window's backdrop: the theme's own wash of pale colors, with no
// picture behind the glass.

// GlassBand is a full-width band of glass (the window's top, under the tabs
// and the bar): a veil of white over the wash and a hairline.
func GlassBand(g Gfx, r Rect, th *Theme) {
	g.FillRect(r, White.Alpha(0.35))
	g.FillRect(Rect{X: r.X, Y: r.Y, W: r.W, H: 1}, White.Alpha(0.7))
	g.FillRect(Rect{X: r.X, Y: r.B() - 1, W: r.W, H: 1}, th.Ink.Alpha(0.06))
}

// DrawWall paints the window's backdrop: the theme's wash.
func DrawWall(g Gfx, r Rect, th *Theme) {
	if th.Grad != nil {
		FillGradient3(g, r, 0, th.Grad)
		return
	}
	g.FillRect(r, th.SurfaceHigh)
}
