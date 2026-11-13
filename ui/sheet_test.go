package ui_test

import (
	"os"
	"testing"

	"litego/raster"
	"litego/ui"
)

func TestIconSheet(t *testing.T) {
	dir := os.Getenv("SHOTS")
	if dir == "" {
		t.Skip()
	}
	n := int(ui.IGrid) + 1
	c := raster.New(16*44, ((n+15)/16)*44*2, 2, raster.NewFonts())
	c.FillRect(ui.Rect{W: 16 * 44, H: 2000}, ui.White)
	for i := 0; i < n; i++ {
		x, y := float32(i%16)*44, float32(i/16)*88
		ui.DrawIcon(c, ui.Icon(i), x+10, y+10, 24, ui.Hex("#2a1433"))
		ui.DrawIcon(c, ui.Icon(i), x+14, y+50, 16, ui.Hex("#2a1433"))
	}
	c.SavePNG(dir + "/icons.png")
}
