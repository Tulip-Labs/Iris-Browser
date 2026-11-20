package ui

import (
	"image"
	"image/color"
	"image/draw"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"math"
	"os"

	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// The window's background, behind Liquid Glass: a picture the panes frost.
// Iris has a few of its own (soft fields of light, drawn here, so they cost
// nothing to ship); the reader may use a picture of their own, or none.

// Wall is a background ready to draw: the picture as it is (Sharp) and
// frosted (Frost, what a glass pane shows of it). Win is the window, in
// its own units, set each frame.
type Wall struct {
	ID           string
	Sharp, Frost image.Image
	Win          Rect
	// Busy is how much the picture varies under the panes (0 calm .. 1
	// busy); a busier picture gets more milk in the glass, so text stays
	// readable on it.
	Busy float32
}

// WallStyle is one of Iris's own backgrounds.
type WallStyle struct {
	ID, Label string
	base      string
	blobs     []blob
}

type blob struct {
	x, y, r float32 // in the picture's width and height
	c       string
	k       float32 // strength
}

// Walls are Iris's own backgrounds; the first is the default.
var Walls = []WallStyle{
	{"sky", "Sky", "#eef4ff", []blob{{0.12, 0.10, 0.55, "#8ab4ff", 0.75}, {0.88, 0.22, 0.50, "#c7b5ff", 0.65}, {0.55, 0.95, 0.60, "#9ee3ff", 0.60}}},
	{"dawn", "Dawn", "#fff4ee", []blob{{0.15, 0.15, 0.55, "#ffb199", 0.70}, {0.85, 0.20, 0.50, "#ffd59e", 0.70}, {0.50, 0.95, 0.60, "#f7a8cf", 0.60}}},
	{"meadow", "Meadow", "#effaf3", []blob{{0.10, 0.20, 0.55, "#97e0bd", 0.70}, {0.90, 0.15, 0.50, "#c9f0a5", 0.60}, {0.60, 0.95, 0.60, "#a3d6ff", 0.55}}},
	{"lilac", "Lilac", "#f5f0ff", []blob{{0.15, 0.10, 0.55, "#c9b3ff", 0.75}, {0.90, 0.30, 0.50, "#f6b6e2", 0.60}, {0.40, 0.95, 0.60, "#b5c6ff", 0.60}}},
	{"sand", "Sand", "#f8f4ec", []blob{{0.15, 0.15, 0.55, "#ead1a8", 0.70}, {0.85, 0.25, 0.50, "#f5c8a6", 0.55}, {0.55, 0.95, 0.60, "#d6e3c3", 0.55}}},
	{"mist", "Mist", "#f1f3f6", []blob{{0.15, 0.10, 0.55, "#cdd5e1", 0.70}, {0.85, 0.30, 0.50, "#e1e5ec", 0.60}, {0.50, 0.95, 0.60, "#bfcadb", 0.60}}},
}

// WallPlain and WallPicture are the reader's other two choices.
const (
	WallPlain   = "plain"
	WallPicture = "picture"
)

// WallStyleByID returns Iris's background id (the default for an unknown one).
func WallStyleByID(id string) WallStyle {
	for _, w := range Walls {
		if w.ID == id {
			return w
		}
	}
	return Walls[0]
}

// Render draws the background at w×h pixels: fields of light on a pale base.
// The fields are wide and soft, so a small picture scaled up is enough.
func (s WallStyle) Render(w, h int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	base := Hex(s.base)
	type bl struct {
		x, y, r2 float64
		cr, cg, cb, k float64
	}
	var bs []bl
	diag := math.Hypot(float64(w), float64(h))
	for _, b := range s.blobs {
		c := Hex(b.c)
		r := float64(b.r) * diag
		bs = append(bs, bl{float64(b.x) * float64(w), float64(b.y) * float64(h), r * r, float64(c.R()), float64(c.G()), float64(c.B()), float64(b.k)})
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, bb := float64(base.R()), float64(base.G()), float64(base.B())
			for _, b := range bs {
				dx, dy := float64(x)-b.x, float64(y)-b.y
				t := math.Exp(-(dx*dx + dy*dy) / (0.5 * b.r2)) * b.k
				r += (b.cr - r) * t
				g += (b.cg - g) * t
				bb += (b.cb - bb) * t
			}
			img.SetRGBA(x, y, color.RGBA{clampF8(r), clampF8(g), clampF8(bb), 255})
		}
	}
	return img
}

func clampF8(v float64) uint8 {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return uint8(v + 0.5)
}

// MakeWall prepares one of Iris's backgrounds.
func MakeWall(id string) *Wall {
	s := WallStyleByID(id)
	sharp := s.Render(640, 400)
	return &Wall{ID: s.ID, Sharp: sharp, Frost: frost(sharp, 96), Busy: busyness(sharp)}
}

// LoadWall prepares the reader's own picture (JPEG, PNG, WebP or GIF).
func LoadWall(path string) (*Wall, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	cfg, _, err := image.DecodeConfig(f)
	if err != nil {
		return nil, err
	}
	if cfg.Width*cfg.Height > 60_000_000 {
		return nil, errTooLarge
	}
	if _, err := f.Seek(0, 0); err != nil {
		return nil, err
	}
	img, _, err := image.Decode(f)
	if err != nil {
		return nil, err
	}
	sharp := fit(img, 2560)
	return &Wall{ID: WallPicture, Sharp: sharp, Frost: frost(sharp, 120), Busy: busyness(sharp)}, nil
}

type wallErr string

func (e wallErr) Error() string { return string(e) }

const errTooLarge = wallErr("the picture is too large")

// fit scales img down to at most w pixels wide.
func fit(img image.Image, w int) *image.RGBA {
	b := img.Bounds()
	if b.Dx() <= w {
		out := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
		draw.Draw(out, out.Bounds(), img, b.Min, draw.Src)
		return out
	}
	h := max(1, b.Dy()*w/b.Dx())
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	xdraw.CatmullRom.Scale(out, out.Bounds(), img, b, xdraw.Src, nil)
	return out
}

// frost is img as seen through frosted glass: small, blurred three times
// (close to a Gaussian), and a little brighter. It is drawn scaled up, which
// smooths it further.
func frost(img image.Image, w int) *image.RGBA {
	b := img.Bounds()
	h := max(1, b.Dy()*w/max(1, b.Dx()))
	small := image.NewRGBA(image.Rect(0, 0, w, h))
	xdraw.ApproxBiLinear.Scale(small, small.Bounds(), img, b, xdraw.Src, nil)
	r := max(2, w/40)
	for i := 0; i < 3; i++ {
		boxBlur(small, r)
	}
	for i := 0; i < len(small.Pix); i += 4 {
		for j := 0; j < 3; j++ {
			v := float64(small.Pix[i+j])
			small.Pix[i+j] = clampF8(v + (255-v)*0.12)
		}
	}
	return small
}

// boxBlur blurs img in place, r pixels each way, across then down.
func boxBlur(img *image.RGBA, r int) {
	w, h := img.Rect.Dx(), img.Rect.Dy()
	tmp := make([]uint8, len(img.Pix))
	pass := func(src, dst []uint8, n, m int, at func(i, j int) int) {
		for j := 0; j < m; j++ {
			var s [4]int
			cnt := 0
			for i := -r; i <= r; i++ {
				if i >= 0 && i < n {
					o := at(i, j)
					for c := 0; c < 4; c++ {
						s[c] += int(src[o+c])
					}
					cnt++
				}
			}
			for i := 0; i < n; i++ {
				o := at(i, j)
				for c := 0; c < 4; c++ {
					dst[o+c] = uint8(s[c] / cnt)
				}
				if a := i - r; a >= 0 {
					oa := at(a, j)
					for c := 0; c < 4; c++ {
						s[c] -= int(src[oa+c])
					}
					cnt--
				}
				if b := i + r + 1; b < n {
					ob := at(b, j)
					for c := 0; c < 4; c++ {
						s[c] += int(src[ob+c])
					}
					cnt++
				}
			}
		}
	}
	stride := img.Stride
	pass(img.Pix, tmp, w, h, func(i, j int) int { return j*stride + i*4 })
	pass(tmp, img.Pix, h, w, func(i, j int) int { return i*stride + j*4 })
}

// busyness measures how much a picture varies: the spread of its brightness.
func busyness(img image.Image) float32 {
	b := img.Bounds()
	var sum, sum2, n float64
	for y := b.Min.Y; y < b.Max.Y; y += max(1, b.Dy()/48) {
		for x := b.Min.X; x < b.Max.X; x += max(1, b.Dx()/48) {
			r, g, bb, _ := img.At(x, y).RGBA()
			l := (0.2126*float64(r) + 0.7152*float64(g) + 0.0722*float64(bb)) / 65535
			sum += l
			sum2 += l * l
			n++
		}
	}
	if n == 0 {
		return 0
	}
	mean := sum / n
	sd := math.Sqrt(max(0, sum2/n-mean*mean))
	dark := max(0, 0.75-mean) // a dark picture needs milk under dark text too
	return float32(min(1, sd*3+dark*1.5))
}

// GlassBand is a full-width band of glass (the window's top, under the tabs
// and the bar): the background frosted, a veil of white and a hairline.
func GlassBand(g Gfx, r Rect, th *Theme) {
	if w := th.Wall; w != nil && w.Frost != nil {
		g.Backdrop(w.Frost, w.Win, r, 0)
		g.FillRect(r, White.Alpha(min(0.85, 0.38+0.32*w.Busy)))
	} else {
		g.FillRect(r, White.Alpha(0.35))
	}
	g.FillRect(Rect{X: r.X, Y: r.Y, W: r.W, H: 1}, White.Alpha(0.7))
	g.FillRect(Rect{X: r.X, Y: r.B() - 1, W: r.W, H: 1}, th.Ink.Alpha(0.06))
}

// DrawWall paints the window's background: the picture when there is one,
// else the theme's own wash.
func DrawWall(g Gfx, r Rect, th *Theme) {
	if w := th.Wall; w != nil && w.Sharp != nil {
		g.Backdrop(w.Sharp, w.Win, r, 0)
		return
	}
	if th.Grad != nil {
		FillGradient3(g, r, 0, th.Grad)
		return
	}
	g.FillRect(r, th.SurfaceHigh)
}
