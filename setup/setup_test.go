package setup

import (
	"os"
	"path/filepath"
	"testing"

	"iris/raster"
)

type nopHost struct{}

func (nopHost) Invalidate() {}
func (nopHost) Minimize()   {}
func (nopHost) Close()      {}

func shot(t *testing.T, s *Setup, name string) {
	c := raster.New(600, 480, 2, raster.NewFonts())
	s.In.Now = 0.4
	s.Frame(c, 600, 480)
	if dir := os.Getenv("SHOTS"); dir != "" {
		if err := c.SavePNG(filepath.Join(dir, name+".png")); err != nil {
			t.Fatal(err)
		}
	}
}

func TestScreens(t *testing.T) {
	s := New(nopHost{}, false)
	s.existing = ""
	shot(t, s, "setup-welcome")
	s.stage = stWorking
	s.steps = []step{{"Checking the web engine", 2}, {"Copying Iris", 2}, {"Adding shortcuts", 1}, {"Registering Iris as a browser", 0}}
	s.progress = 0.8
	shot(t, s, "setup-working")
	s.stage = stDone
	shot(t, s, "setup-done")
	u := New(nopHost{}, true)
	shot(t, u, "setup-uninstall")
}
