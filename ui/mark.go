package ui

// Iris's mark: an iris of light in a drop of clear glass, under an arc like
// a rainbow seen through glass. It has no color of its own: the app icon is
// smoked glass with white light, and inside the browser the mark is drawn in
// the theme's ink on clear glass.

// IrisMark draws the iris and its arc in ink inside r (a square).
func IrisMark(g Gfx, r Rect, ink Color) {
	s := r.W / 24
	cx, cy := r.CX(), r.CY()+0.6*s
	// the arc above, light passing through glass
	g.StrokePath(NewPath().Arc(cx, cy, 9*s, 205, 335, true), 0.9*s, ink.Fade(0.5))
	// the iris: a bright ring, a finer ring inside it and a clear pupil
	g.StrokePath(NewPath().Ellipse(RectAround(cx, cy, 12*s, 12*s)), 1.15*s, ink.Fade(0.95))
	g.StrokePath(NewPath().Ellipse(RectAround(cx, cy, 7.6*s, 7.6*s)), 0.5*s, ink.Fade(0.5))
	FillOval(g, RectAround(cx, cy, 3.2*s, 3.2*s), ink.Fade(0.92))
	// a glint where the light catches
	FillOval(g, RectAround(cx+2.9*s, cy-3*s, 1.3*s, 1.3*s), ink.Fade(0.8))
}

// IrisIcon draws the app icon in r: a tile of smoked glass with a highlight
// pooled at the top, a bright rim and the mark in white.
func IrisIcon(g Gfx, r Rect) {
	rad := r.W * 0.28
	body := NewPath().RoundRect(r, rad)
	g.FillPathGradient(body, Hex("#3c3c42"), Hex("#0b0b0e"), r.Y, r.B())
	// light pooled at the top, fading down like light on a drop
	hl := Rect{X: r.X + r.W*0.06, Y: r.Y + r.H*0.03, W: r.W * 0.88, H: r.H * 0.42}
	g.FillPathGradient(NewPath().RoundRect(hl, min(rad*0.85, hl.H/2)), White.Alpha(0.26), White.Alpha(0), hl.Y, hl.B())
	// the rim: a fine edge of light, brightest along the top
	g.StrokePath(NewPath().RoundRect(r.Inset(r.W*0.01), rad-r.W*0.01), r.W*0.012, White.Alpha(0.14))
	top := NewPath().Arc(r.X+rad, r.Y+rad, rad-r.W*0.01, 200, 270, true).LineTo(r.R()-rad, r.Y+r.W*0.01).Arc(r.R()-rad, r.Y+rad, rad-r.W*0.01, 270, 340, false)
	g.StrokePath(top, r.W*0.016, White.Alpha(0.55))
	IrisMark(g, r, White)
}

// IrisLogo draws the mark as it appears inside the browser: a drop of the
// theme's clear glass with the mark in its ink.
func IrisLogo(g Gfx, r Rect, th *Theme) {
	Shadow(g, r, r.W*0.28, th.Shadow, 0.5, 1.5)
	Liquid(g, r, r.W*0.28, th.Ink)
	IrisMark(g, r, th.Ink)
}
