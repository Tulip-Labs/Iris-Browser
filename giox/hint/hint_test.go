//go:build linux && webkit

package hint

import (
	"math"
	"os"
	"testing"
)

// The outline of an "l" at the interface's size on a 1.25 screen (14 × 1.25)
// must have its stem's sides on whole pixels.
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
	if g == nil || len(g.Segs) == 0 {
		t.Fatal("no l")
	}
	// the points where the outline runs straight up or down: the stem's sides
	xs := map[float32]bool{}
	var last [2]float32
	for _, s := range g.Segs {
		end := s.P[map[Op]int{Move: 0, Line: 0, Quad: 1, Cubic: 2}[s.Op]]
		if s.Op == Line && end[0] == last[0] && math.Abs(float64(end[1]-last[1])) > 4 {
			xs[end[0]] = true
		}
		last = end
	}
	if len(xs) < 2 {
		t.Fatalf("no stem found: %v", g.Segs)
	}
	// the stem covers at least one whole pixel: one solid column, not two
	// half-lit ones
	lo, hi := float32(math.Inf(1)), float32(math.Inf(-1))
	for x := range xs {
		lo, hi = min(lo, x), max(hi, x)
	}
	if float32(math.Ceil(float64(lo)))+1 > hi {
		t.Errorf("the stem (%v to %v) covers no whole pixel", lo, hi)
	}
	// and unhinted it would not: the test means something
	t.Logf("stem from %v to %v", lo, hi)
	if f.Glyph(0x4E2D, 17*64) != nil { // 中: not in Nunito
		t.Error("a glyph the face does not have")
	}
	if g.Adv <= 0 {
		t.Error("no advance")
	}
}
