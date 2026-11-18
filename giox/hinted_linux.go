//go:build linux && webkit

package giox

import (
	"math"
	"sync"
	"unicode/utf8"

	"gioui.org/f32"
	"gioui.org/op"
	"gioui.org/op/clip"
	"gioui.org/op/paint"
	"gioui.org/text"
	"golang.org/x/image/math/fixed"

	"iris/assets"
	"iris/giox/hint"
	"iris/ui"
)

// Text on Linux: each glyph's outline as FreeType's autohinter shapes it
// (stems and edges on whole pixels, as in GTK and in the pages), at the place
// Gio's shaping gives it, its dot on a whole pixel. Gio fills the outlines
// like any other shape, so colors and fades work as before.

var (
	hintOnce  sync.Once
	hintFaces [3]*hint.Face // regular, bold, mono
)

func hintFace(f ui.Font) *hint.Face {
	hintOnce.Do(func() {
		hintFaces = [3]*hint.Face{hint.Open(assets.NunitoRegular), hint.Open(assets.NunitoBold), hint.Open(assets.Mono)}
	})
	switch {
	case f.Mono:
		return hintFaces[2]
	case f.Bold:
		return hintFaces[1]
	}
	return hintFaces[0]
}

type placed struct {
	gl *hint.Glyph
	x  float32 // the dot, in whole pixels from the line's
}

// hinted draws the line g.glyphs (shaped from s at ppem device pixels) with
// its dot at device pixel (dx, dy), which lie on whole pixels. It reports
// false, drawing nothing, where it cannot: a zoom in progress, text running
// right to left, or a character the font lacks (Gio's fallback draws those).
func (g *Gfx) hinted(s string, f ui.Font, ppem float32, dx, dy float32, c ui.Color) bool {
	if math.Abs(float64(g.scale-g.base)) > 1e-4 || len(g.glyphs) == 0 {
		return false
	}
	face := hintFace(f)
	if face == nil {
		return false
	}
	ps, ok := g.placeLine(face, s, int32(math.Round(float64(ppem)*64)))
	if !ok {
		return false
	}
	// device pixels from here: one unit is one screen pixel
	k1 := 1 / g.scale
	defer op.Affine(f32.Affine2D{}.Scale(f32.Point{}, f32.Pt(k1, k1)).Offset(f32.Pt((dx-g.tx)*k1, (dy-g.ty)*k1))).Push(g.ops).Pop()
	var p clip.Path
	p.Begin(g.ops)
	open := false // a contour is being drawn
	for _, pl := range ps {
		for _, sg := range pl.gl.Segs {
			at := func(i int) f32.Point { return f32.Pt(pl.x+sg.P[i][0], sg.P[i][1]) }
			switch sg.Op {
			case hint.Move:
				if open {
					p.Close() // each contour is a closed shape
				}
				p.MoveTo(at(0))
				open = true
			case hint.Line:
				p.LineTo(at(0))
			case hint.Quad:
				p.QuadTo(at(0), at(1))
			case hint.Cubic:
				p.CubeTo(at(0), at(1), at(2))
			}
		}
	}
	if open {
		p.Close()
	}
	spec := p.End()
	if open {
		paint.FillShape(g.ops, nrgba(c), clip.Outline{Path: spec}.Op())
	}
	return true
}

// placeLine finds each character's hinted glyph and its place; ok is false
// when one cannot be drawn here.
func (g *Gfx) placeLine(face *hint.Face, s string, ppem64 int32) (ps []placed, ok bool) {
	x0 := g.glyphs[0].X
	rest := s
	var cl []text.Glyph // the glyphs of the cluster being read
	for _, gl := range g.glyphs {
		if gl.Flags&text.FlagTowardOrigin != 0 {
			return nil, false // right to left: Gio's own order and shaping
		}
		cl = append(cl, gl)
		if gl.Flags&text.FlagClusterBreak == 0 {
			continue
		}
		// the cluster's characters, from its first glyph's place on (one
		// glyph for one character nearly always; a ligature draws its letters)
		pen := cl[0].X - x0
		for i := 0; i < int(gl.Runes); i++ {
			r, n := utf8.DecodeRuneInString(rest)
			if n == 0 {
				return nil, false
			}
			rest = rest[n:]
			if i > 0 && len(cl) == int(gl.Runes) {
				pen = cl[i].X - x0 // one glyph each: Gio's place for each
			}
			if r == '\t' || r == '\n' || r == '\r' {
				continue
			}
			hg := face.Glyph(r, ppem64)
			if hg == nil {
				if r == ' ' || r == ' ' {
					continue
				}
				return nil, false
			}
			ps = append(ps, placed{hg, float32(math.Round(float64(pen) / 64))})
			if len(cl) != int(gl.Runes) {
				pen += fixed.Int26_6(hg.Adv)
			}
		}
		cl = cl[:0]
	}
	if len(cl) > 0 || rest != "" {
		return nil, false // the clusters did not account for every character
	}
	return ps, true
}
