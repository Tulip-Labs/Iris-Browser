//go:build ignore

// iconpng draws Iris's app icon into assets/icon.png (256 by 256), the icon
// the Linux packages install:
//
//	go run tools/iconpng.go [size out.png]
package main

import (
	"image/png"
	"log"
	"os"
	"strconv"

	"iris/raster"
	"iris/ui"
)

func main() {
	size, out := 256, "assets/icon.png"
	if len(os.Args) == 3 {
		size, _ = strconv.Atoi(os.Args[1])
		out = os.Args[2]
	}
	c := raster.New(24, 24, float32(size)/24, raster.NewFonts())
	ui.IrisIcon(c, ui.Rect{X: 1, Y: 1, W: 22, H: 22})
	f, err := os.Create(out)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, c.Img); err != nil {
		log.Fatal(err)
	}
}
