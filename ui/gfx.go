// Package ui is the whole Flowcode interface, drawn immediate-mode on a small
// Gfx interface. The desktop shell implements Gfx with Gio; the raster
// package implements it in software for tests and screenshots.
package ui

import (
	"image"
	"math"
)

// Color is 0xAARRGGBB (straight alpha).
type Color uint32

func ARGB(a, r, g, b int) Color {
	return Color(uint32(clamp8(a))<<24 | uint32(clamp8(r))<<16 | uint32(clamp8(g))<<8 | uint32(clamp8(b)))
}

func clamp8(v int) int { return max(0, min(255, v)) }

// Hex parses #rrggbb or #aarrggbb.
func Hex(s string) Color {
	if len(s) > 0 && s[0] == '#' {
		s = s[1:]
	}
	var v uint32
	for _, c := range s {
		v <<= 4
		switch {
		case c >= '0' && c <= '9':
			v |= uint32(c - '0')
		case c >= 'a' && c <= 'f':
			v |= uint32(c-'a') + 10
		case c >= 'A' && c <= 'F':
			v |= uint32(c-'A') + 10
		}
	}
	if len(s) <= 6 {
		v |= 0xff000000
	}
	return Color(v)
}

func (c Color) A() int { return int(c >> 24) }
func (c Color) R() int { return int(c>>16) & 0xff }
func (c Color) G() int { return int(c>>8) & 0xff }
func (c Color) B() int { return int(c) & 0xff }

// Alpha returns c with opacity f (0..1), replacing its alpha.
func (c Color) Alpha(f float32) Color {
	return Color(uint32(int(clampf(f, 0, 1)*255))<<24 | uint32(c)&0xffffff)
}

// Fade multiplies c's alpha by f.
func (c Color) Fade(f float32) Color {
	return Color(uint32(int(float32(c.A())*clampf(f, 0, 1)))<<24 | uint32(c)&0xffffff)
}

// Mix blends c toward d by t.
func Mix(c, d Color, t float32) Color {
	ch := func(p, q int) int { return int(float32(p) + float32(q-p)*t) }
	return ARGB(ch(c.A(), d.A()), ch(c.R(), d.R()), ch(c.G(), d.G()), ch(c.B(), d.B()))
}

const (
	White Color = 0xffffffff
	Black Color = 0xff000000
	Clear Color = 0
)

func clampf(v, lo, hi float32) float32 { return max(lo, min(hi, v)) }

// Font is Nunito (or the monospace face) at a size in logical pixels.
type Font struct {
	Size       float32
	Bold, Mono bool
}

var (
	FBody      = Font{Size: 14}
	FBodyBold  = Font{Size: 14, Bold: true}
	FSmall     = Font{Size: 12}
	FSmallBold = Font{Size: 12, Bold: true}
	FTitle     = Font{Size: 18, Bold: true}
	FBig       = Font{Size: 24, Bold: true}
	FCode      = Font{Size: 13, Mono: true}
	FCodeSmall = Font{Size: 12, Mono: true}
)

// Gfx is the drawing surface. Units are logical pixels; the backend maps them to the screen.
type Gfx interface {
	Save()
	Restore()
	Translate(x, y float32)
	Scale(s float32)
	// Clip intersects the clip with r (in current coordinates).
	Clip(r Rect)

	FillRect(r Rect, c Color)
	FillPath(p *Path, c Color)
	// StrokePath strokes with round joins and flat ends (use Pen for round ends).
	StrokePath(p *Path, width float32, c Color)
	// Radial paints a soft elliptical glow of c fading to clear at the edge.
	Radial(cx, cy, rx, ry float32, c Color)
	// Gradient paints r with a vertical gradient.
	Gradient(r Rect, top, bottom Color)
	// FillPathGradient fills p with a vertical gradient from top (at y0) to bottom (at y1).
	FillPathGradient(p *Path, top, bottom Color, y0, y1 float32)

	// Image draws img to cover r (cropped to keep its shape), with rounded corners.
	Image(img image.Image, r Rect, radius float32)

	Text(s string, x, baseline float32, f Font, c Color)
	Measure(s string, f Font) float32
	Ascent(f Font) float32
	Descent(f Font) float32
}

// ---- paths ----

type PathOp uint8

const (
	PMove PathOp = iota
	PLine
	PQuad
	PCube
	PClose
)

// Path is a device-independent outline: ops plus their points (1 for move/line, 2 quad, 3 cube).
type Path struct {
	Ops []PathOp
	Pts []float32
}

func NewPath() *Path { return &Path{} }

func (p *Path) MoveTo(x, y float32) *Path {
	p.Ops = append(p.Ops, PMove)
	p.Pts = append(p.Pts, x, y)
	return p
}
func (p *Path) LineTo(x, y float32) *Path {
	p.Ops = append(p.Ops, PLine)
	p.Pts = append(p.Pts, x, y)
	return p
}
func (p *Path) QuadTo(cx, cy, x, y float32) *Path {
	p.Ops = append(p.Ops, PQuad)
	p.Pts = append(p.Pts, cx, cy, x, y)
	return p
}
func (p *Path) CubeTo(c1x, c1y, c2x, c2y, x, y float32) *Path {
	p.Ops = append(p.Ops, PCube)
	p.Pts = append(p.Pts, c1x, c1y, c2x, c2y, x, y)
	return p
}
func (p *Path) Close() *Path { p.Ops = append(p.Ops, PClose); return p }
func (p *Path) Empty() bool  { return len(p.Ops) == 0 }

// Poly adds a closed polygon.
func (p *Path) Poly(xy ...float32) *Path {
	p.MoveTo(xy[0], xy[1])
	for i := 2; i+1 < len(xy); i += 2 {
		p.LineTo(xy[i], xy[i+1])
	}
	return p.Close()
}

// Polyline adds an open polyline.
func (p *Path) Polyline(xy ...float32) *Path {
	p.MoveTo(xy[0], xy[1])
	for i := 2; i+1 < len(xy); i += 2 {
		p.LineTo(xy[i], xy[i+1])
	}
	return p
}

const kappa = 0.5522847498

// RoundRect adds a rounded rectangle (r is clamped to half the shorter side).
func (p *Path) RoundRect(rc Rect, r float32) *Path {
	r = max(0, min(r, rc.W/2, rc.H/2))
	x, y, w, h := rc.X, rc.Y, rc.W, rc.H
	if r == 0 {
		return p.Poly(x, y, x+w, y, x+w, y+h, x, y+h)
	}
	k := r * (1 - kappa)
	p.MoveTo(x+r, y).LineTo(x+w-r, y).CubeTo(x+w-k, y, x+w, y+k, x+w, y+r)
	p.LineTo(x+w, y+h-r).CubeTo(x+w, y+h-k, x+w-k, y+h, x+w-r, y+h)
	p.LineTo(x+r, y+h).CubeTo(x+k, y+h, x, y+h-k, x, y+h-r)
	p.LineTo(x, y+r).CubeTo(x, y+k, x+k, y, x+r, y)
	return p.Close()
}

// Ellipse adds an ellipse inscribed in rc.
func (p *Path) Ellipse(rc Rect) *Path {
	cx, cy, rx, ry := rc.CX(), rc.CY(), rc.W/2, rc.H/2
	kx, ky := rx*kappa, ry*kappa
	p.MoveTo(cx+rx, cy)
	p.CubeTo(cx+rx, cy+ky, cx+kx, cy+ry, cx, cy+ry)
	p.CubeTo(cx-kx, cy+ry, cx-rx, cy+ky, cx-rx, cy)
	p.CubeTo(cx-rx, cy-ky, cx-kx, cy-ry, cx, cy-ry)
	p.CubeTo(cx+kx, cy-ry, cx+rx, cy-ky, cx+rx, cy)
	return p.Close()
}

// Arc adds a circular arc from angle a0 to a1 (degrees, clockwise on screen since y points down),
// as cubic segments. With move it starts a new subpath, otherwise it lines to the start.
func (p *Path) Arc(cx, cy, r, a0, a1 float32, move bool) *Path {
	rad := func(d float32) float64 { return float64(d) * math.Pi / 180 }
	n := int(math.Ceil(math.Abs(float64(a1-a0)) / 90))
	n = max(n, 1)
	step := (a1 - a0) / float32(n)
	pt := func(a float32) (float32, float32) {
		return cx + r*float32(math.Cos(rad(a))), cy + r*float32(math.Sin(rad(a)))
	}
	x0, y0 := pt(a0)
	if move {
		p.MoveTo(x0, y0)
	} else {
		p.LineTo(x0, y0)
	}
	k := float32(4.0/3.0*math.Tan(rad(step)/4)) * r
	for i := 0; i < n; i++ {
		s, e := a0+step*float32(i), a0+step*float32(i+1)
		sx, sy := pt(s)
		ex, ey := pt(e)
		ts, te := rad(s), rad(e)
		p.CubeTo(sx-k*float32(math.Sin(ts)), sy+k*float32(math.Cos(ts)),
			ex+k*float32(math.Sin(te)), ey-k*float32(math.Cos(te)), ex, ey)
	}
	return p
}

// Endpoints returns the start and end point of every open subpath (for round pen caps).
func (p *Path) Endpoints() []float32 {
	var out []float32
	var sx, sy, lx, ly float32
	open, i := false, 0
	flush := func() {
		if open {
			out = append(out, sx, sy, lx, ly)
		}
	}
	for _, op := range p.Ops {
		switch op {
		case PMove:
			flush()
			sx, sy, lx, ly = p.Pts[i], p.Pts[i+1], p.Pts[i], p.Pts[i+1]
			open, i = true, i+2
		case PLine:
			lx, ly, i = p.Pts[i], p.Pts[i+1], i+2
		case PQuad:
			lx, ly, i = p.Pts[i+2], p.Pts[i+3], i+4
		case PCube:
			lx, ly, i = p.Pts[i+4], p.Pts[i+5], i+6
		case PClose:
			open = false
		}
	}
	flush()
	return out
}

// Flatten converts the path to polylines (each subpath; closed reports whether it was closed),
// with curves split so no segment deviates more than tol.
func (p *Path) Flatten(tol float32, emit func(pts []float32, closed bool)) {
	var cur []float32
	i := 0
	var lx, ly float32
	done := func(closed bool) {
		if len(cur) >= 4 {
			emit(cur, closed)
		}
		cur = nil
	}
	for _, op := range p.Ops {
		switch op {
		case PMove:
			done(false)
			lx, ly = p.Pts[i], p.Pts[i+1]
			cur = append(cur, lx, ly)
			i += 2
		case PLine:
			lx, ly = p.Pts[i], p.Pts[i+1]
			cur = append(cur, lx, ly)
			i += 2
		case PQuad:
			cx, cy, x, y := p.Pts[i], p.Pts[i+1], p.Pts[i+2], p.Pts[i+3]
			d := float32(math.Hypot(float64(cx-(lx+x)/2), float64(cy-(ly+y)/2)))
			n := max(1, min(64, int(math.Ceil(math.Sqrt(float64(d/tol))))))
			for k := 1; k <= n; k++ {
				t := float32(k) / float32(n)
				u := 1 - t
				cur = append(cur, u*u*lx+2*u*t*cx+t*t*x, u*u*ly+2*u*t*cy+t*t*y)
			}
			lx, ly = x, y
			i += 4
		case PCube:
			c1x, c1y, c2x, c2y, x, y := p.Pts[i], p.Pts[i+1], p.Pts[i+2], p.Pts[i+3], p.Pts[i+4], p.Pts[i+5]
			d := float32(math.Hypot(float64(c1x-lx), float64(c1y-ly)) + math.Hypot(float64(c2x-c1x), float64(c2y-c1y)) + math.Hypot(float64(x-c2x), float64(y-c2y)))
			n := max(2, min(96, int(math.Ceil(math.Sqrt(float64(d/tol))*1.2))))
			for k := 1; k <= n; k++ {
				t := float32(k) / float32(n)
				u := 1 - t
				cur = append(cur, u*u*u*lx+3*u*u*t*c1x+3*u*t*t*c2x+t*t*t*x, u*u*u*ly+3*u*u*t*c1y+3*u*t*t*c2y+t*t*t*y)
			}
			lx, ly = x, y
			i += 6
		case PClose:
			if len(cur) >= 2 {
				lx, ly = cur[0], cur[1]
				if n := len(cur); cur[n-2] != lx || cur[n-1] != ly {
					cur = append(cur, lx, ly)
				}
			}
			done(true)
			cur = append(cur, lx, ly)
		}
	}
	done(false)
}

// ---- drawing helpers on any Gfx ----

func FillRound(g Gfx, r Rect, rad float32, c Color) { g.FillPath(NewPath().RoundRect(r, rad), c) }
func StrokeRound(g Gfx, r Rect, rad, w float32, c Color) {
	g.StrokePath(NewPath().RoundRect(r, rad), w, c)
}
func FillOval(g Gfx, r Rect, c Color)              { g.FillPath(NewPath().Ellipse(r), c) }
func StrokeOval(g Gfx, r Rect, w float32, c Color) { g.StrokePath(NewPath().Ellipse(r), w, c) }

// Pen strokes p with round ends (icons, connectors).
func Pen(g Gfx, p *Path, w float32, c Color) {
	g.StrokePath(p, w, c)
	e := p.Endpoints()
	for i := 0; i+1 < len(e); i += 2 {
		FillOval(g, Rect{e[i] - w/2, e[i+1] - w/2, w, w}, c)
	}
}

// Line draws a straight segment with round ends.
func Line(g Gfx, x1, y1, x2, y2, w float32, c Color) {
	Pen(g, NewPath().MoveTo(x1, y1).LineTo(x2, y2), w, c)
}

// Dashed strokes p as dashes of length on, gap off.
func Dashed(g Gfx, p *Path, w float32, c Color, on, off float32) {
	p.Flatten(0.3, func(pts []float32, closed bool) {
		q := NewPath()
		draw, left := true, on
		x, y := pts[0], pts[1]
		q.MoveTo(x, y)
		for i := 2; i+1 < len(pts); i += 2 {
			nx, ny := pts[i], pts[i+1]
			seg := float32(math.Hypot(float64(nx-x), float64(ny-y)))
			for seg > 0 {
				step := min(seg, left)
				t := step / seg
				x, y = x+(nx-x)*t, y+(ny-y)*t
				seg -= step
				left -= step
				if draw {
					q.LineTo(x, y)
				} else {
					q.MoveTo(x, y)
				}
				if left <= 0 {
					draw = !draw
					if draw {
						left = on
					} else {
						left = off
					}
				}
			}
		}
		g.StrokePath(q, w, c)
	})
}

// Shadow is a soft drop shadow drawn as stacked translucent round rects (looks like a blur).
func Shadow(g Gfx, r Rect, rad float32, tint Color, strength, dy float32) {
	for i := 5; i >= 1; i-- {
		s := float32(i) * 2.4
		FillRound(g, Rect{r.X - s*0.6, r.Y - s*0.3 + dy, r.W + s*1.2, r.H + s*1.2}, rad+s, tint.Alpha(0.022*strength))
	}
}

// Glass draws a liquid frosted-glass surface: a translucent tonal body, a soft
// shadow, a specular sheen across the top and a bright inner rim, so cards read
// as glass over the solid background.
func Glass(g Gfx, r Rect, rad float32, th *Theme, strong, shadow bool) {
	if shadow {
		s := float32(0.8)
		if strong {
			s = 1.1
		}
		Shadow(g, r, rad, th.Shadow, s, 5)
	}
	body := NewPath().RoundRect(r, rad)
	base := th.Card
	if strong {
		base = th.CardStrong
	}
	g.FillPath(body, base)
	// sheen: light pooled at the top, fading down (liquid highlight)
	top := White.Alpha(0.36)
	if th.Dark {
		top = White.Alpha(0.10)
	}
	g.FillPathGradient(body, top, top.Alpha(0), r.Y, r.Y+min(r.H, 160)*0.6) // fade to clear white, not black
	// inner rim: brighter along the top edge, like light caught in the glass
	rim := NewPath().RoundRect(r.Inset(0.75), rad-0.75)
	rimTop := White.Alpha(0.9)
	rimBottom := White.Alpha(0.25)
	if th.Dark {
		rimTop, rimBottom = White.Alpha(0.30), White.Alpha(0.06)
	}
	strokeGradient(g, rim, 1.2, rimTop, rimBottom, r.Y, r.B())
	// hairline outside, so glass stays visible on light backgrounds
	g.StrokePath(NewPath().RoundRect(r, rad), 0.8, th.Ink.Alpha(0.07))
}

// Liquid draws a glossy "liquid glass" tile for an icon: the color as a
// soft vertical gradient, a highlight pooled at the top like light on a
// drop, a bright rim along the top edge and a faint shade at the bottom.
// Draw the icon over it in white.
func Liquid(g Gfx, r Rect, rad float32, base Color) {
	body := NewPath().RoundRect(r, rad)
	g.FillPathGradient(body, Mix(base, White, 0.22), Mix(base, Black, 0.12), r.Y, r.B())
	hl := Rect{X: r.X + r.W*0.08, Y: r.Y + r.H*0.04, W: r.W * 0.84, H: r.H * 0.5}
	g.FillPathGradient(NewPath().RoundRect(hl, min(rad, hl.H/2)), White.Alpha(0.42), White.Alpha(0), hl.Y, hl.B())
	strokeGradient(g, NewPath().RoundRect(r.Inset(0.6), rad-0.6), 1.1, White.Alpha(0.75), White.Alpha(0.10), r.Y, r.B())
	g.FillPathGradient(body, Black.Alpha(0), Black.Alpha(0.10), r.CY(), r.B())
}

// strokeGradient approximates a vertically graded stroke with two passes.
func strokeGradient(g Gfx, p *Path, w float32, top, bottom Color, y0, y1 float32) {
	g.StrokePath(p, w, bottom)
	g.Save()
	g.Clip(Rect{-1e6, y0 - w, 2e6, (y1 - y0) * 0.45})
	g.StrokePath(p, w, top)
	g.Restore()
}

// Fit trims s with an ellipsis so it measures at most maxW.
func Fit(g Gfx, s string, f Font, maxW float32) string {
	if g.Measure(s, f) <= maxW {
		return s
	}
	rs := []rune(s)
	lo, hi := 0, len(rs)
	for lo < hi {
		m := (lo + hi + 1) / 2
		if g.Measure(string(rs[:m])+"...", f) <= maxW {
			lo = m
		} else {
			hi = m - 1
		}
	}
	return string(rs[:lo]) + "..."
}

// TextFit draws s trimmed to maxW.
func TextFit(g Gfx, s string, x, baseline float32, f Font, c Color, maxW float32) {
	g.Text(Fit(g, s, f, maxW), x, baseline, f, c)
}

// TextCenter centers one line of text in r.
func TextCenter(g Gfx, s string, r Rect, f Font, c Color) {
	g.Text(s, r.CX()-g.Measure(s, f)/2, Mid(g, r.Y, r.H, f), f, c)
}

// Mid is the baseline that centers one line of f in a box at y of height h.
func Mid(g Gfx, y, h float32, f Font) float32 { return y + h/2 + (g.Ascent(f)-g.Descent(f))/2 }

// ---- rectangles ----

type Rect struct{ X, Y, W, H float32 }

func (r Rect) R() float32                 { return r.X + r.W }
func (r Rect) B() float32                 { return r.Y + r.H }
func (r Rect) CX() float32                { return r.X + r.W/2 }
func (r Rect) CY() float32                { return r.Y + r.H/2 }
func (r Rect) Contains(x, y float32) bool { return x >= r.X && x < r.X+r.W && y >= r.Y && y < r.Y+r.H }
func (r Rect) Inset(d float32) Rect       { return Rect{r.X + d, r.Y + d, r.W - 2*d, r.H - 2*d} }
func (r Rect) Inset2(dx, dy float32) Rect { return Rect{r.X + dx, r.Y + dy, r.W - 2*dx, r.H - 2*dy} }
func (r Rect) Left(w float32) Rect        { return Rect{r.X, r.Y, w, r.H} }
func (r Rect) Right(w float32) Rect       { return Rect{r.R() - w, r.Y, w, r.H} }
func (r Rect) Top(h float32) Rect         { return Rect{r.X, r.Y, r.W, h} }
func (r Rect) Bottom(h float32) Rect      { return Rect{r.X, r.B() - h, r.W, h} }
func (r Rect) CutTop(h float32) Rect      { return Rect{r.X, r.Y + h, r.W, r.H - h} }
func (r Rect) CutLeft(w float32) Rect     { return Rect{r.X + w, r.Y, r.W - w, r.H} }
func (r Rect) CutRight(w float32) Rect    { return Rect{r.X, r.Y, r.W - w, r.H} }
func (r Rect) CutBottom(h float32) Rect   { return Rect{r.X, r.Y, r.W, r.H - h} }
func (r Rect) Move(dx, dy float32) Rect   { return Rect{r.X + dx, r.Y + dy, r.W, r.H} }
func (r Rect) Intersects(o Rect) bool {
	return r.X < o.R() && o.X < r.R() && r.Y < o.B() && o.Y < r.B()
}
func (r Rect) Empty() bool                 { return r.W <= 0 || r.H <= 0 }
func RectAround(cx, cy, w, h float32) Rect { return Rect{cx - w/2, cy - h/2, w, h} }

// CoverRect returns the part of an image of size (iw, ih) that fills a box of
// shape (w, h) without stretching (centered crop), in image pixels.
func CoverRect(iw, ih int, w, h float32) image.Rectangle {
	if iw <= 0 || ih <= 0 || w <= 0 || h <= 0 {
		return image.Rect(0, 0, iw, ih)
	}
	ar := w / h
	if float32(iw)/float32(ih) > ar {
		cw := int(float32(ih) * ar)
		x := (iw - cw) / 2
		return image.Rect(x, 0, x+cw, ih)
	}
	ch := int(float32(iw) / ar)
	y := (ih - ch) / 2
	return image.Rect(0, y, iw, y+ch)
}
