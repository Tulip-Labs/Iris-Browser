//go:build !(linux && webkit)

package giox

import "iris/ui"

// Elsewhere Gio draws the text itself (see hinted_linux.go).
func (g *Gfx) hinted(s string, f ui.Font, ppem float32, dx, dy float32, c ui.Color) bool {
	return false
}
