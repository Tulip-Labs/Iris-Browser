// Package giox draws the shared interface (package ui) with Gio and reads Gio input into ui.Input.
package giox

import (
	"image"
	"image/color"
	"math"

	"gioui.org/f32"
	giofont "gioui.org/font"
	"gioui.org/font/opentype"
	"gioui.org/op"
	"gioui.org/op/clip"
	"gioui.org/op/paint"
	"gioui.org/text"
	"golang.org/x/image/math/fixed"

	"iris/assets"
	"iris/ui"
)

// Gfx implements ui.Gfx on Gio operations. Logical pixels are mapped to
// device pixels by a base scale; text is shaped at device size so it stays crisp.
type Gfx struct {
	ops    *op.Ops
	shaper *text.Shaper
	base   float32 // device pixels per logical pixel
	scale  float32 // current total scale (base * zooms)
	tx, ty float32 // where the current origin is, in device pixels
	marks  []mark
	stack  []func()
	glyphs []text.Glyph
	meas   map[measKey]float32
	metric map[ui.Font][2]float32
	images map[image.Image]paint.ImageOp
	used   map[image.Image]bool
	// lines of hinted text (Linux), kept while drawn
	lines     map[lineKey]*lineImg
	linesUsed map[lineKey]bool
}

type mark struct {
	n      int
	scale  float32
	tx, ty float32
}

type measKey struct {
	s string
	f ui.Font
}

var (
	faceRegular = giofont.Font{Typeface: "Nunito"}
	faceBold    = giofont.Font{Typeface: "Nunito", Weight: giofont.Bold}
	faceMono    = giofont.Font{Typeface: "DejaVu Sans Mono"}
)

func newShaper() *text.Shaper {
	var faces []giofont.FontFace
	for _, b := range [][]byte{assets.NunitoRegular, assets.NunitoBold, assets.Mono} {
		fs, err := opentype.ParseCollection(b)
		if err != nil {
			panic(err)
		}
		faces = append(faces, fs...)
	}
	return text.NewShaper(text.NoSystemFonts(), text.WithCollection(faces))
}

// NewGfx makes the Gio drawing surface.
func NewGfx() *Gfx {
	return &Gfx{shaper: newShaper(), meas: map[measKey]float32{}, metric: map[ui.Font][2]float32{}, images: map[image.Image]paint.ImageOp{}, used: map[image.Image]bool{},
		lines: map[lineKey]*lineImg{}, linesUsed: map[lineKey]bool{}}
}

// Begin starts a frame on ops with the device scale.
func (g *Gfx) Begin(ops *op.Ops, base float32) {
	g.ops, g.base, g.scale = ops, base, base
	g.tx, g.ty = 0, 0
	g.marks, g.stack = g.marks[:0], g.stack[:0]
	g.push(op.Affine(f32.Affine2D{}.Scale(f32.Point{}, f32.Pt(base, base))).Push(ops).Pop)
	if len(g.meas) > 20000 {
		g.meas = map[measKey]float32{}
	}
}

// Image draws img covering r with rounded corners. Each image is uploaded once
// and kept while it is drawn; images not drawn for a frame are let go.
func (g *Gfx) Image(img image.Image, r ui.Rect, radius float32) {
	if img == nil || r.Empty() {
		return
	}
	io, ok := g.images[img]
	if !ok {
		io = paint.NewImageOp(img)
		io.Filter = paint.FilterLinear
		g.images[img] = io
	}
	g.used[img] = true
	b := img.Bounds()
	src := ui.CoverRect(b.Dx(), b.Dy(), r.W, r.H)
	defer clip.Outline{Path: g.spec(ui.NewPath().RoundRect(r, radius), true)}.Op().Push(g.ops).Pop()
	sx, sy := r.W/float32(src.Dx()), r.H/float32(src.Dy())
	tr := f32.Affine2D{}.Offset(f32.Pt(-float32(src.Min.X-b.Min.X), -float32(src.Min.Y-b.Min.Y))).Scale(f32.Point{}, f32.Pt(sx, sy)).Offset(f32.Pt(r.X, r.Y))
	defer op.Affine(tr).Push(g.ops).Pop()
	io.Add(g.ops)
	paint.PaintOp{}.Add(g.ops)
}

func (g *Gfx) End() {
	g.endLines()
	if len(g.images) > len(g.used) {
		for k := range g.images {
			if !g.used[k] {
				delete(g.images, k)
			}
		}
	}
	clear(g.used)
	for len(g.stack) > 0 {
		g.stack[len(g.stack)-1]()
		g.stack = g.stack[:len(g.stack)-1]
	}
}

func (g *Gfx) push(pop func()) { g.stack = append(g.stack, pop) }

func (g *Gfx) Save() { g.marks = append(g.marks, mark{len(g.stack), g.scale, g.tx, g.ty}) }

func (g *Gfx) Restore() {
	m := g.marks[len(g.marks)-1]
	g.marks = g.marks[:len(g.marks)-1]
	for len(g.stack) > m.n {
		g.stack[len(g.stack)-1]()
		g.stack = g.stack[:len(g.stack)-1]
	}
	g.scale, g.tx, g.ty = m.scale, m.tx, m.ty
}

func (g *Gfx) Translate(x, y float32) {
	g.push(op.Affine(f32.Affine2D{}.Offset(f32.Pt(x, y))).Push(g.ops).Pop)
	g.tx += x * g.scale
	g.ty += y * g.scale
}

func (g *Gfx) Scale(s float32) {
	g.push(op.Affine(f32.Affine2D{}.Scale(f32.Point{}, f32.Pt(s, s))).Push(g.ops).Pop)
	g.scale *= s
}

func (g *Gfx) Clip(r ui.Rect) {
	g.push(clip.Outline{Path: g.rectPath(r)}.Op().Push(g.ops).Pop)
}

func nrgba(c ui.Color) color.NRGBA {
	return color.NRGBA{R: uint8(c.R()), G: uint8(c.G()), B: uint8(c.B()), A: uint8(c.A())}
}

func (g *Gfx) rectPath(r ui.Rect) clip.PathSpec {
	var p clip.Path
	p.Begin(g.ops)
	p.MoveTo(f32.Pt(r.X, r.Y))
	p.LineTo(f32.Pt(r.R(), r.Y))
	p.LineTo(f32.Pt(r.R(), r.B()))
	p.LineTo(f32.Pt(r.X, r.B()))
	p.Close()
	return p.End()
}

func (g *Gfx) spec(pa *ui.Path, closeAll bool) clip.PathSpec {
	var p clip.Path
	p.Begin(g.ops)
	i := 0
	open := false
	for _, o := range pa.Ops {
		switch o {
		case ui.PMove:
			if open && closeAll {
				p.Close()
			}
			p.MoveTo(f32.Pt(pa.Pts[i], pa.Pts[i+1]))
			open, i = true, i+2
		case ui.PLine:
			p.LineTo(f32.Pt(pa.Pts[i], pa.Pts[i+1]))
			i += 2
		case ui.PQuad:
			p.QuadTo(f32.Pt(pa.Pts[i], pa.Pts[i+1]), f32.Pt(pa.Pts[i+2], pa.Pts[i+3]))
			i += 4
		case ui.PCube:
			p.CubeTo(f32.Pt(pa.Pts[i], pa.Pts[i+1]), f32.Pt(pa.Pts[i+2], pa.Pts[i+3]), f32.Pt(pa.Pts[i+4], pa.Pts[i+5]))
			i += 6
		case ui.PClose:
			p.Close()
			open = false
		}
	}
	if open && closeAll {
		p.Close()
	}
	return p.End()
}

func (g *Gfx) FillRect(r ui.Rect, c ui.Color) {
	if c.A() == 0 {
		return
	}
	paint.FillShape(g.ops, nrgba(c), clip.Outline{Path: g.rectPath(r)}.Op())
}

func (g *Gfx) FillPath(p *ui.Path, c ui.Color) {
	if c.A() == 0 || p.Empty() {
		return
	}
	paint.FillShape(g.ops, nrgba(c), clip.Outline{Path: g.spec(p, true)}.Op())
}

func (g *Gfx) StrokePath(p *ui.Path, w float32, c ui.Color) {
	if c.A() == 0 || p.Empty() || w <= 0 {
		return
	}
	paint.FillShape(g.ops, nrgba(c), clip.Stroke{Path: g.spec(p, false), Width: w}.Op())
}

func (g *Gfx) FillPathGradient(p *ui.Path, top, bottom ui.Color, y0, y1 float32) {
	if p.Empty() {
		return
	}
	defer clip.Outline{Path: g.spec(p, true)}.Op().Push(g.ops).Pop()
	paint.LinearGradientOp{Stop1: f32.Pt(0, y0), Color1: nrgba(top), Stop2: f32.Pt(0, y1), Color2: nrgba(bottom)}.Add(g.ops)
	paint.PaintOp{}.Add(g.ops)
}

func (g *Gfx) Gradient(r ui.Rect, top, bottom ui.Color) {
	g.FillPathGradient(ui.NewPath().Poly(r.X, r.Y, r.R(), r.Y, r.R(), r.B(), r.X, r.B()), top, bottom, r.Y, r.B())
}

// Radial approximates a soft glow with stacked translucent ellipses (only small accents use it).
func (g *Gfx) Radial(cx, cy, rx, ry float32, c ui.Color) {
	const n = 10
	for i := n; i >= 1; i-- {
		k := float32(i) / n
		ui.FillOval(g, ui.Rect{X: cx - rx*k, Y: cy - ry*k, W: 2 * rx * k, H: 2 * ry * k}, c.Fade(1.0/n*1.4))
	}
}

func gioFont(f ui.Font) giofont.Font {
	switch {
	case f.Mono:
		return faceMono
	case f.Bold:
		return faceBold
	}
	return faceRegular
}

// shape lays out one line of s at ppem device pixels into g.glyphs.
func (g *Gfx) shape(s string, f ui.Font, ppem float32) {
	g.shaper.LayoutString(text.Parameters{Font: gioFont(f), PxPerEm: fixed.Int26_6(ppem * 64), MaxLines: 1, MaxWidth: 1 << 24}, s)
	g.glyphs = g.glyphs[:0]
	for {
		gl, ok := g.shaper.NextGlyph()
		if !ok {
			break
		}
		g.glyphs = append(g.glyphs, gl)
	}
}

func (g *Gfx) Text(s string, x, baseline float32, f ui.Font, c ui.Color) {
	if s == "" || c.A() == 0 {
		return
	}
	k := g.scale
	ppem := float32(math.Round(float64(f.Size*k*4))) / 4
	if ppem < 1 {
		return
	}
	g.shape(s, f, ppem)
	if len(g.glyphs) == 0 {
		return
	}
	// Shape's outlines are relative to the first glyph's dot (its baseline point),
	// so the dot goes exactly on (x, baseline).
	inv := f.Size / ppem // device glyph space back to logical units
	x0 := float32(g.glyphs[0].X) / 64 * inv
	// the line starts on a whole screen pixel and its baseline lies on one:
	// at fractional scales (1.25, 1.5) a baseline between two pixel rows
	// smears every horizontal stroke over both, and the text looks soft
	if k > 0 {
		dx, dy := g.tx+(x+x0)*k, g.ty+baseline*k
		x += (float32(math.Round(float64(dx))) - dx) / k
		baseline += (float32(math.Round(float64(dy))) - dy) / k
		// hinted, where the system has the rasterizer (Linux): stems on whole pixels
		if g.hinted(s, f, ppem, float32(math.Round(float64(dx))), float32(math.Round(float64(dy))), c) {
			return
		}
	}
	t := op.Affine(f32.Affine2D{}.Scale(f32.Point{}, f32.Pt(inv, inv)).Offset(f32.Pt(x+x0, baseline))).Push(g.ops)
	spec := g.shaper.Shape(g.glyphs)
	paint.FillShape(g.ops, nrgba(c), clip.Outline{Path: spec}.Op())
	t.Pop()
}

const refPx = 64 // size used for measuring, so measures do not depend on zoom

func (g *Gfx) Measure(s string, f ui.Font) float32 {
	if s == "" {
		return 0
	}
	k := measKey{s, f}
	if v, ok := g.meas[k]; ok {
		return v
	}
	g.shape(s, f, refPx)
	var adv fixed.Int26_6
	for _, gl := range g.glyphs {
		adv += gl.Advance
	}
	v := float32(adv) / 64 / refPx * f.Size
	g.meas[k] = v
	return v
}

func (g *Gfx) metrics(f ui.Font) [2]float32 {
	if m, ok := g.metric[f]; ok {
		return m
	}
	g.shape("Mg", f, refPx)
	m := [2]float32{f.Size * 0.95, f.Size * 0.3}
	if len(g.glyphs) > 0 {
		m = [2]float32{float32(g.glyphs[0].Ascent) / 64 / refPx * f.Size, float32(g.glyphs[0].Descent) / 64 / refPx * f.Size}
	}
	g.metric[f] = m
	return m
}

func (g *Gfx) Ascent(f ui.Font) float32  { return g.metrics(f)[0] }
func (g *Gfx) Descent(f ui.Font) float32 { return g.metrics(f)[1] }

var _ ui.Gfx = (*Gfx)(nil)
