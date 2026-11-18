//go:build !(linux && webkit)

package giox

import "iris/ui"

// Elsewhere Gio draws the text itself (see hinted_linux.go).

type lineKey struct{}
type lineImg struct{}

func (g *Gfx) hinted(s string, f ui.Font, ppem float32, dx, dy float32, c ui.Color) bool {
	return false
}

func (g *Gfx) endLines() {}
