package ui

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

// The reader's own picture: loaded, frosted, and judged busy (so the glass
// over it gets milkier); Iris's own backgrounds are calm.
func TestWalls(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 400, 300))
	for y := 0; y < 300; y++ {
		for x := 0; x < 400; x++ {
			v := uint8(0)
			if (x/20+y/20)%2 == 0 {
				v = 255
			}
			img.SetRGBA(x, y, color.RGBA{v, v / 2, 255 - v, 255})
		}
	}
	p := filepath.Join(t.TempDir(), "busy.png")
	f, _ := os.Create(p)
	png.Encode(f, img)
	f.Close()
	w, err := LoadWall(p)
	if err != nil || w.Sharp == nil || w.Frost == nil {
		t.Fatalf("picture not loaded: %v", err)
	}
	if w.Busy < 0.6 {
		t.Errorf("a checkerboard is busy: %.2f", w.Busy)
	}
	for _, s := range Walls {
		if b := MakeWall(s.ID).Busy; b > 0.5 {
			t.Errorf("%s should be calm: %.2f", s.ID, b)
		}
	}
	if _, err := LoadWall(filepath.Join(t.TempDir(), "missing.jpg")); err == nil {
		t.Error("a missing picture is an error")
	}
}
