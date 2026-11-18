//go:build linux && webkit

// Package hint draws text the way the rest of the Linux desktop does: each
// glyph through FreeType's autohinter, which moves its stems onto whole
// pixels. Gio draws glyphs exactly where their outlines fall (no hinting), so
// a 1-pixel stem at 1.25 often lands between two pixels at half strength:
// the interface's text looked soft beside GTK's and the pages' own.
//
// Only the glyph pictures come from here; where each glyph goes stays Gio's
// (its shaping, kerning and measures), so the layout does not move.
package hint

/*
#cgo pkg-config: freetype2
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdlib.h>

static FT_Library lib;

static FT_Face hintOpen(const unsigned char *data, long n) {
	if (!lib && FT_Init_FreeType(&lib)) return NULL;
	FT_Face f = NULL;
	if (FT_New_Memory_Face(lib, data, n, 0, &f)) return NULL;
	return f;
}

// hintGlyph renders rune r at ppem64 (26.6 pixels per em), hinted; 0 when the
// face has no glyph for it.
static int hintGlyph(FT_Face f, unsigned long r, long ppem64, int *left, int *top, int *w, int *h, int *pitch, unsigned char **buf, long *adv) {
	FT_UInt gi = FT_Get_Char_Index(f, r);
	if (!gi) return 0;
	if (FT_Set_Char_Size(f, 0, ppem64, 72, 72)) return 0;
	if (FT_Load_Glyph(f, gi, FT_LOAD_FORCE_AUTOHINT | FT_LOAD_TARGET_NORMAL)) return 0;
	if (FT_Render_Glyph(f->glyph, FT_RENDER_MODE_NORMAL)) return 0;
	FT_Bitmap *b = &f->glyph->bitmap;
	*left = f->glyph->bitmap_left;
	*top = f->glyph->bitmap_top;
	*w = (int)b->width;
	*h = (int)b->rows;
	*pitch = b->pitch;
	*buf = b->buffer;
	*adv = f->glyph->linearHoriAdvance; // unhinted, 16.16
	return 1;
}
*/
import "C"

import (
	"sync"
	"unsafe"
)

// Face is one font file.
type Face struct {
	f     C.FT_Face
	mu    sync.Mutex
	cache map[key]*Glyph
}

type key struct {
	r    rune
	ppem int32 // 26.6
}

// Glyph is one rendered glyph: A is its coverage (W×H, row by row), placed
// Left pixels right of the pen and Top pixels above the baseline. Adv is the
// unhinted advance in pixels (26.6).
type Glyph struct {
	Left, Top, W, H int
	A               []byte
	Adv             int32
}

// Open reads a font file; nil when FreeType cannot.
func Open(data []byte) *Face {
	if len(data) == 0 {
		return nil
	}
	p := C.CBytes(data) // FreeType reads from it for the program's life
	f := C.hintOpen((*C.uchar)(p), C.long(len(data)))
	if f == nil {
		C.free(p)
		return nil
	}
	return &Face{f: f, cache: map[key]*Glyph{}}
}

// Glyph returns rune r at ppem64 (26.6), or nil when the face lacks it.
func (fc *Face) Glyph(r rune, ppem64 int32) *Glyph {
	if fc == nil {
		return nil
	}
	fc.mu.Lock()
	defer fc.mu.Unlock()
	k := key{r, ppem64}
	if g, ok := fc.cache[k]; ok {
		return g
	}
	if len(fc.cache) > 8000 {
		clear(fc.cache)
	}
	var left, top, w, h, pitch C.int
	var buf *C.uchar
	var adv C.long
	if C.hintGlyph(fc.f, C.ulong(r), C.long(ppem64), &left, &top, &w, &h, &pitch, &buf, &adv) == 0 {
		fc.cache[k] = nil
		return nil
	}
	g := &Glyph{Left: int(left), Top: int(top), W: int(w), H: int(h), Adv: int32(int64(adv) * 64 / 65536)}
	if g.W > 0 && g.H > 0 {
		g.A = make([]byte, g.W*g.H)
		p := int(pitch)
		src := unsafe.Slice((*byte)(unsafe.Pointer(buf)), p*g.H)
		for y := 0; y < g.H; y++ {
			copy(g.A[y*g.W:(y+1)*g.W], src[y*p:y*p+g.W])
		}
	}
	fc.cache[k] = g
	return g
}
