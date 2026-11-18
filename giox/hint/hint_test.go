//go:build linux && webkit

package hint

import (
	"os"
	"testing"
)

// The stems of an "l" at the interface's size on a 1.25 screen (14 × 1.25)
// must be one solid pixel, not two half-lit ones.
func TestStemsOnWholePixels(t *testing.T) {
	data, err := os.ReadFile("../../assets/fonts/Nunito-Regular.ttf")
	if err != nil {
		t.Skip(err)
	}
	f := Open(data)
	if f == nil {
		t.Fatal("FreeType could not open Nunito")
	}
	g := f.Glyph('l', 17*64+32)
	if g == nil || g.W == 0 {
		t.Fatal("no l")
	}
	row := g.A[(g.H/2)*g.W : (g.H/2+1)*g.W]
	mx := byte(0)
	for _, v := range row {
		mx = max(mx, v)
	}
	if mx < 240 {
		t.Errorf("the stem is not on a whole pixel: %v", row)
	}
	if f.Glyph(0x4E2D, 17*64) != nil { // 中: not in Nunito
		t.Error("a glyph the face does not have")
	}
	if g.Adv <= 0 {
		t.Error("no advance")
	}
}
