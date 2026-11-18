//go:build linux && webkit

package giox

import (
	"image"
	"image/color"
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

// Text on Linux: the glyphs as FreeType's autohinter draws them (stems on
// whole pixels, as in GTK and in the pages), at the places Gio's shaping
// gives them. Each line becomes one picture, drawn pixel for pixel.

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

type lineKey struct {
	s    string
	f    ui.Font
	ppem int32
	c    color.NRGBA
}

type lineImg struct {
	op         paint.ImageOp
	x, y, w, h int // the picture's corner from the line's dot, and its size (pixels)
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
	nc := nrgba(c)
	k := lineKey{s, f, int32(math.Round(float64(ppem) * 64)), nc}
	li, ok := g.lines[k]
	if !ok {
		var built bool
		li, built = g.buildLine(face, s, k.ppem, nc)
		if !built {
			g.lines[k] = nil
			g.linesUsed[k] = true
			return false
		}
		g.lines[k] = li
	}
	g.linesUsed[k] = true
	if li == nil {
		return false
	}
	if li.w == 0 || li.h == 0 {
		return true // only spaces
	}
	// one picture pixel on one screen pixel: back from device pixels to the
	// current (logical) units
	k1 := 1 / g.scale
	lx, ly := (dx+float32(li.x)-g.tx)*k1, (dy+float32(li.y)-g.ty)*k1
	defer op.Affine(f32.Affine2D{}.Scale(f32.Point{}, f32.Pt(k1, k1)).Offset(f32.Pt(lx, ly))).Push(g.ops).Pop()
	defer clip.Rect{Max: image.Pt(li.w, li.h)}.Push(g.ops).Pop()
	li.op.Add(g.ops)
	paint.PaintOp{}.Add(g.ops)
	return true
}

// buildLine renders the shaped line into one picture; built is false when a
// glyph cannot be drawn here.
func (g *Gfx) buildLine(face *hint.Face, s string, ppem64 int32, c color.NRGBA) (*lineImg, bool) {
	type placed struct {
		gl *hint.Glyph
		x  int
	}
	var ps []placed
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
			ps = append(ps, placed{hg, int(math.Round(float64(pen) / 64))})
			if len(cl) != int(gl.Runes) {
				pen += fixed.Int26_6(hg.Adv)
			}
		}
		cl = cl[:0]
	}
	if len(cl) > 0 || rest != "" {
		return nil, false // the clusters did not account for every character
	}
	minX, minY, maxX, maxY := 1<<30, 1<<30, -(1 << 30), -(1 << 30)
	for _, p := range ps {
		if p.gl.W == 0 || p.gl.H == 0 {
			continue
		}
		minX, maxX = min(minX, p.x+p.gl.Left), max(maxX, p.x+p.gl.Left+p.gl.W)
		minY, maxY = min(minY, -p.gl.Top), max(maxY, -p.gl.Top+p.gl.H)
	}
	if maxX <= minX || maxY <= minY {
		return &lineImg{}, true
	}
	w, h := maxX-minX, maxY-minY
	cov := make([]uint16, w*h)
	for _, p := range ps {
		ox, oy := p.x+p.gl.Left-minX, -p.gl.Top-minY
		for y := 0; y < p.gl.H; y++ {
			row := cov[(oy+y)*w+ox:]
			src := p.gl.A[y*p.gl.W : (y+1)*p.gl.W]
			for x, v := range src {
				row[x] += uint16(v)
			}
		}
	}
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for i, v := range cov {
		if v == 0 {
			continue
		}
		v = min(v, 255)
		img.Pix[i*4], img.Pix[i*4+1], img.Pix[i*4+2] = c.R, c.G, c.B
		img.Pix[i*4+3] = uint8(uint32(v) * uint32(c.A) / 255)
	}
	io := paint.NewImageOp(img)
	io.Filter = paint.FilterNearest
	return &lineImg{op: io, x: minX, y: minY, w: w, h: h}, true
}

// endLines lets go of the lines not drawn this frame.
func (g *Gfx) endLines() {
	if len(g.lines) > len(g.linesUsed) || len(g.lines) > 3000 {
		for k := range g.lines {
			if !g.linesUsed[k] {
				delete(g.lines, k)
			}
		}
	}
	clear(g.linesUsed)
}
