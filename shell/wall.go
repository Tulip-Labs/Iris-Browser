package shell

import (
	"io"
	"os"
	"path/filepath"
	"strings"

	"iris/ui"
)

// The window's background (ui.Wall): one of Iris's own, the reader's own
// picture or none, made off the window's thread when the choice changes.

// ensureWall starts making the background the settings ask for.
func (a *App) ensureWall() {
	key := a.set.Background + "\x00" + a.set.Picture
	if key == a.wallKey || a.wallBusy {
		return
	}
	a.wallBusy = true
	bg, pic := a.set.Background, a.set.Picture
	go func() {
		var w *ui.Wall
		switch bg {
		case ui.WallPlain:
		case ui.WallPicture:
			if wl, err := ui.LoadWall(pic); err == nil {
				w = wl
			} else {
				w = ui.MakeWall("") // the picture is gone: Iris's own
			}
		default:
			w = ui.MakeWall(bg)
		}
		a.post(func() {
			a.wall, a.wallKey, a.wallBusy = w, key, false
			a.h.Invalidate()
		})
	}()
}

// wallThumb is a small picture of one of Iris's backgrounds (for the menu).
func (a *App) wallThumb(id string) *ui.Wall {
	if w := a.wallThumbs[id]; w != nil {
		return w
	}
	if a.wallThumbs == nil {
		a.wallThumbs = map[string]*ui.Wall{}
	}
	s := ui.WallStyleByID(id)
	img := s.Render(160, 100)
	w := &ui.Wall{ID: id, Sharp: img}
	a.wallThumbs[id] = w
	return w
}

// setBackground chooses one of Iris's backgrounds, or none.
func (a *App) setBackground(id string) {
	a.set.Background = id
	a.set.Save()
}

// pickPicture asks for a picture of the reader's own; a copy goes into
// Iris's folder, so the background stays if the picture moves.
func (a *App) pickPicture() {
	pick := a.cfg.Sys.PickPicture
	if pick == nil {
		a.notify("Choosing a picture is not available here.")
		return
	}
	dir := a.cfg.DataDir
	go func() {
		src := pick()
		if src == "" {
			return
		}
		if _, err := ui.LoadWall(src); err != nil {
			a.post(func() { a.notify("That file is not a picture Iris can show (JPEG, PNG, WebP or GIF).") })
			return
		}
		dst := src
		if dir != "" {
			ext := strings.ToLower(filepath.Ext(src))
			dst = filepath.Join(dir, "background"+ext)
			if err := copyFile(src, dst); err != nil {
				dst = src
			}
		}
		a.post(func() {
			a.set.Background, a.set.Picture = ui.WallPicture, dst
			a.wallKey = "" // the same name may hold a new picture
			a.set.Save()
		})
	}()
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".new"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}
