package shell

import (
	"context"
	"image"
	"strings"
	"testing"
)

func TestNowPlayingPill(t *testing.T) {
	d := newDriver(t, 1440, 900, true)
	d.a.fetchImage = func(ctx context.Context, src string, maxW int) (image.Image, error) {
		img := image.NewRGBA(image.Rect(0, 0, 64, 36))
		for i := range img.Pix {
			if i%4 == 0 {
				img.Pix[i] = 200 // red-orange artwork
			} else if i%4 == 1 {
				img.Pix[i] = 90
			} else if i%4 == 3 {
				img.Pix[i] = 255
			}
		}
		return img, nil
	}
	d.eng.run = func(js string) string {
		if strings.Contains(js, "mediaSession") {
			return `{"title":"Lofi beats to study to","artist":"Chill Radio","art":"https://i.ytimg.com/vi/x/mqdefault.jpg","paused":false}`
		}
		return "null"
	}
	d.frames(2)
	d.a.newTab(KNormal, "", "https://www.youtube.com/watch?v=x", true)
	d.frame()
	music := d.a.tab()
	d.a.newTab(KNormal, "", "https://en.wikipedia.org/wiki/Iris", true)
	d.frame()
	if d.a.playingTab() != nil {
		t.Fatal("nothing plays yet")
	}
	music.Audio = true
	d.settle(8)
	if d.a.playingTab() != music || d.a.np.title != "Lofi beats to study to" || d.a.np.artist != "Chill Radio" {
		t.Fatalf("pill: %+v", d.a.np)
	}
	if c := d.a.np.tint; c == 0 || c.R() <= c.G() || c.R() <= c.B() {
		t.Fatalf("the tint should be the artwork's warm colour: %08x", uint32(c))
	}
	d.shot("now-playing")
	// paused: it stays a while, then goes
	music.Audio, music.audioEnd = false, d.a.now()
	d.frame()
	if d.a.playingTab() != music {
		t.Fatal("a paused tab keeps its pill for a while")
	}
	d.advance(61)
	if d.a.playingTab() != nil {
		t.Fatal("the pill should go a minute after a pause")
	}
}
