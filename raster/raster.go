// Package raster draws the Flowcode interface in software (pure Go): used by
// tests, headless checks and screenshots. It matches the Gio shell's output
// closely: same fonts, same paths, same colors.
package raster

import (
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"math"
	"os"

	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
	"golang.org/x/image/vector"

	"litego/assets"
	"litego/ui"
)

type state struct {
	s, tx, ty float32
	clip      image.Rectangle
}

// Canvas is a ui.Gfx over an RGBA image. Scale is the device pixel ratio.
type Canvas struct {
	Img   *image.RGBA
	st    state
	stack []state
	z     vector.Rasterizer
	fonts *Fonts
}

// Fonts parses the embedded faces once and caches sized faces.
type Fonts struct {
	reg, bold, mono *opentype.Font
	faces           map[faceKey]font.Face
}

type faceKey struct {
	f  ui.Font
	px float32
}

func NewFonts() *Fonts {
	must := func(b []byte) *opentype.Font {
		f, err := opentype.Parse(b)
		if err != nil {
			panic(err)
		}
		return f
	}
	return &Fonts{must(assets.NunitoRegular), must(assets.NunitoBold), must(assets.Mono), map[faceKey]font.Face{}}
}

func (fs *Fonts) face(f ui.Font, scale float32) font.Face {
	px := float32(math.Round(float64(f.Size*scale*4))) / 4
	k := faceKey{f, px}
	if fc, ok := fs.faces[k]; ok {
		return fc
	}
	src := fs.reg
	switch {
	case f.Mono:
		src = fs.mono
	case f.Bold:
		src = fs.bold
	}
	fc, err := opentype.NewFace(src, &opentype.FaceOptions{Size: float64(px), DPI: 72, Hinting: font.HintingNone})
	if err != nil {
		panic(err)
	}
	fs.faces[k] = fc
	return fc
}

// New makes a canvas of w x h logical pixels at the given scale.
func New(w, h int, scale float32, fs *Fonts) *Canvas {
	if fs == nil {
		fs = NewFonts()
	}
	img := image.NewRGBA(image.Rect(0, 0, int(float32(w)*scale), int(float32(h)*scale)))
	return &Canvas{Img: img, st: state{s: scale, clip: img.Bounds()}, fonts: fs}
}

func (c *Canvas) Save()    { c.stack = append(c.stack, c.st) }
func (c *Canvas) Restore() { c.st = c.stack[len(c.stack)-1]; c.stack = c.stack[:len(c.stack)-1] }
func (c *Canvas) Translate(x, y float32) {
	c.st.tx += x * c.st.s
	c.st.ty += y * c.st.s
}
func (c *Canvas) Scale(s float32) { c.st.s *= s }

func (c *Canvas) dev(x, y float32) (float32, float32) { return x*c.st.s + c.st.tx, y*c.st.s + c.st.ty }

func (c *Canvas) devRect(r ui.Rect) image.Rectangle {
	x0, y0 := c.dev(r.X, r.Y)
	x1, y1 := c.dev(r.R(), r.B())
	return image.Rect(int(math.Floor(float64(x0))), int(math.Floor(float64(y0))), int(math.Ceil(float64(x1))), int(math.Ceil(float64(y1))))
}

func (c *Canvas) Clip(r ui.Rect) { c.st.clip = c.st.clip.Intersect(c.devRect(r)) }

func premul(col ui.Color) color.RGBA {
	a := uint32(col.A())
	return color.RGBA{uint8(uint32(col.R()) * a / 255), uint8(uint32(col.G()) * a / 255), uint8(uint32(col.B()) * a / 255), uint8(a)}
}

// polys rasterizes device-space polygons (already oriented) clipped to the current clip.
func (c *Canvas) polys(ps [][]float32, col ui.Color) {
	cl := c.st.clip
	if cl.Empty() || col.A() == 0 || len(ps) == 0 {
		return
	}
	// bounding box to keep the rasterizer small
	minX, minY, maxX, maxY := float32(math.MaxFloat32), float32(math.MaxFloat32), float32(-math.MaxFloat32), float32(-math.MaxFloat32)
	for _, p := range ps {
		for i := 0; i+1 < len(p); i += 2 {
			minX, maxX = min(minX, p[i]), max(maxX, p[i])
			minY, maxY = min(minY, p[i+1]), max(maxY, p[i+1])
		}
	}
	bb := image.Rect(int(math.Floor(float64(minX)))-1, int(math.Floor(float64(minY)))-1, int(math.Ceil(float64(maxX)))+1, int(math.Ceil(float64(maxY)))+1).Intersect(cl)
	if bb.Empty() {
		return
	}
	c.z.Reset(bb.Dx(), bb.Dy())
	ox, oy := float32(bb.Min.X), float32(bb.Min.Y)
	for _, p := range ps {
		if len(p) < 6 {
			continue
		}
		c.z.MoveTo(p[0]-ox, p[1]-oy)
		for i := 2; i+1 < len(p); i += 2 {
			c.z.LineTo(p[i]-ox, p[i+1]-oy)
		}
		c.z.ClosePath()
	}
	c.z.Draw(c.Img, bb, image.NewUniform(premul(col)), image.Point{})
}

// polysSrc is polys with an image source aligned to the canvas.
func (c *Canvas) polysSrc(ps [][]float32, src image.Image) {
	cl := c.st.clip
	minX, minY, maxX, maxY := float32(math.MaxFloat32), float32(math.MaxFloat32), float32(-math.MaxFloat32), float32(-math.MaxFloat32)
	for _, p := range ps {
		for i := 0; i+1 < len(p); i += 2 {
			minX, maxX = min(minX, p[i]), max(maxX, p[i])
			minY, maxY = min(minY, p[i+1]), max(maxY, p[i+1])
		}
	}
	bb := image.Rect(int(math.Floor(float64(minX)))-1, int(math.Floor(float64(minY)))-1, int(math.Ceil(float64(maxX)))+1, int(math.Ceil(float64(maxY)))+1).Intersect(cl)
	if bb.Empty() {
		return
	}
	c.z.Reset(bb.Dx(), bb.Dy())
	ox, oy := float32(bb.Min.X), float32(bb.Min.Y)
	for _, p := range ps {
		if len(p) < 6 {
			continue
		}
		c.z.MoveTo(p[0]-ox, p[1]-oy)
		for i := 2; i+1 < len(p); i += 2 {
			c.z.LineTo(p[i]-ox, p[i+1]-oy)
		}
		c.z.ClosePath()
	}
	c.z.Draw(c.Img, bb, src, bb.Min)
}

func (c *Canvas) devPath(p *ui.Path) *ui.Path {
	q := &ui.Path{Ops: p.Ops, Pts: make([]float32, len(p.Pts))}
	for i := 0; i+1 < len(p.Pts); i += 2 {
		q.Pts[i], q.Pts[i+1] = c.dev(p.Pts[i], p.Pts[i+1])
	}
	return q
}

func (c *Canvas) FillRect(r ui.Rect, col ui.Color) {
	x0, y0 := c.dev(r.X, r.Y)
	x1, y1 := c.dev(r.R(), r.B())
	c.polys([][]float32{{x0, y0, x1, y0, x1, y1, x0, y1}}, col)
}

func (c *Canvas) FillPath(p *ui.Path, col ui.Color) {
	var ps [][]float32
	c.devPath(p).Flatten(0.2, func(pts []float32, _ bool) { ps = append(ps, append([]float32(nil), pts...)) })
	c.polys(ps, col)
}

func area(p []float32) float32 {
	var a float32
	n := len(p)
	for i := 0; i+1 < n; i += 2 {
		j := (i + 2) % n
		a += p[i]*p[j+1] - p[j]*p[i+1]
	}
	return a
}

func orient(p []float32) []float32 {
	if area(p) < 0 {
		for i, j := 0, len(p)-2; i < j; i, j = i+2, j-2 {
			p[i], p[j] = p[j], p[i]
			p[i+1], p[j+1] = p[j+1], p[i+1]
		}
	}
	return p
}

func disc(x, y, r float32) []float32 {
	n := max(8, min(48, int(r*3)))
	out := make([]float32, 0, n*2)
	for k := 0; k < n; k++ {
		a := float64(k) / float64(n) * 2 * math.Pi
		out = append(out, x+r*float32(math.Cos(a)), y+r*float32(math.Sin(a)))
	}
	return orient(out)
}

// StrokePath strokes with round joins and flat ends, as the Gio shell does.
func (c *Canvas) StrokePath(p *ui.Path, width float32, col ui.Color) {
	hw := width * c.st.s / 2
	if hw <= 0 {
		return
	}
	var ps [][]float32
	c.devPath(p).Flatten(0.2, func(pts []float32, closed bool) {
		n := len(pts) / 2
		for i := 0; i+1 < n; i++ {
			x0, y0, x1, y1 := pts[i*2], pts[i*2+1], pts[i*2+2], pts[i*2+3]
			dx, dy := x1-x0, y1-y0
			l := float32(math.Hypot(float64(dx), float64(dy)))
			if l < 1e-4 {
				continue
			}
			nx, ny := -dy/l*hw, dx/l*hw
			ps = append(ps, orient([]float32{x0 + nx, y0 + ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny, x0 - nx, y0 - ny}))
			if i+2 < n || closed {
				if hw > 0.6 {
					ps = append(ps, disc(x1, y1, hw))
				}
			}
		}
	})
	c.polys(ps, col)
}

// blend paints one device pixel with straight-alpha color col at coverage a (0..1).
func (c *Canvas) blend(x, y int, col ui.Color, a float32) {
	i := c.Img.PixOffset(x, y)
	p := c.Img.Pix[i : i+4 : i+4]
	sa := float32(col.A()) / 255 * a
	inv := 1 - sa
	p[0] = uint8(float32(col.R())*sa + float32(p[0])*inv)
	p[1] = uint8(float32(col.G())*sa + float32(p[1])*inv)
	p[2] = uint8(float32(col.B())*sa + float32(p[2])*inv)
	p[3] = uint8(255*sa + float32(p[3])*inv)
}

func (c *Canvas) Radial(cx, cy, rx, ry float32, col ui.Color) {
	r := c.devRect(ui.Rect{X: cx - rx, Y: cy - ry, W: 2 * rx, H: 2 * ry}).Intersect(c.st.clip)
	dcx, dcy := c.dev(cx, cy)
	drx, dry := rx*c.st.s, ry*c.st.s
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			u, v := (float32(x)+0.5-dcx)/drx, (float32(y)+0.5-dcy)/dry
			d := u*u + v*v
			if d < 1 {
				t := 1 - float32(math.Sqrt(float64(d)))
				c.blend(x, y, col, t*t*(3-2*t))
			}
		}
	}
}

func (c *Canvas) FillPathGradient(p *ui.Path, top, bottom ui.Color, y0, y1 float32) {
	var ps [][]float32
	c.devPath(p).Flatten(0.2, func(pts []float32, _ bool) { ps = append(ps, append([]float32(nil), pts...)) })
	if len(ps) == 0 || c.st.clip.Empty() {
		return
	}
	_, dy0 := c.dev(0, y0)
	_, dy1 := c.dev(0, y1)
	b := c.Img.Bounds()
	src := image.NewRGBA(b)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		t := clamp01((float32(y) + 0.5 - dy0) / max(1, dy1-dy0))
		col := premul(ui.Mix(top, bottom, t))
		for x := b.Min.X; x < b.Max.X; x++ {
			i := src.PixOffset(x, y)
			src.Pix[i], src.Pix[i+1], src.Pix[i+2], src.Pix[i+3] = col.R, col.G, col.B, col.A
		}
	}
	c.polysSrc(ps, src)
}

func clamp01(v float32) float32 { return max(0, min(1, v)) }

func (c *Canvas) Gradient(rc ui.Rect, top, bottom ui.Color) {
	r := c.devRect(rc).Intersect(c.st.clip)
	h := float32(c.devRect(rc).Dy())
	y0 := c.devRect(rc).Min.Y
	for y := r.Min.Y; y < r.Max.Y; y++ {
		col := ui.Mix(top, bottom, float32(y-y0)/max(1, h))
		for x := r.Min.X; x < r.Max.X; x++ {
			c.blend(x, y, col, 1)
		}
	}
}

func (c *Canvas) Text(s string, x, baseline float32, f ui.Font, col ui.Color) {
	if s == "" || c.st.clip.Empty() {
		return
	}
	dx, dy := c.dev(x, baseline)
	d := font.Drawer{Dst: c.Img.SubImage(c.st.clip).(*image.RGBA), Src: image.NewUniform(premul(col)), Face: c.fonts.face(f, c.st.s),
		Dot: fixed.Point26_6{X: fixed.Int26_6(dx * 64), Y: fixed.Int26_6(dy * 64)}}
	d.DrawString(s)
}

func (c *Canvas) Measure(s string, f ui.Font) float32 { return c.fonts.Measure(s, f) }
func (c *Canvas) Ascent(f ui.Font) float32            { return c.fonts.Ascent(f) }
func (c *Canvas) Descent(f ui.Font) float32           { return c.fonts.Descent(f) }

// Measure gives the advance of s in logical pixels (scale independent).
func (fs *Fonts) Measure(s string, f ui.Font) float32 {
	return float32(font.MeasureString(fs.face(f, 4), s)) / 64 / 4
}
func (fs *Fonts) Ascent(f ui.Font) float32 {
	return float32(fs.face(f, 4).Metrics().Ascent) / 64 / 4
}
func (fs *Fonts) Descent(f ui.Font) float32 {
	return float32(fs.face(f, 4).Metrics().Descent) / 64 / 4
}

// SavePNG writes the canvas to a file.
func (c *Canvas) SavePNG(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return png.Encode(f, c.Img)
}

var _ ui.Gfx = (*Canvas)(nil)
var _ = draw.Over
