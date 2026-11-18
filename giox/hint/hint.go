//go:build linux && webkit

// Package hint gives glyph outlines the way the rest of the Linux desktop
// draws text: through FreeType's autohinter, which moves each glyph's stems
// and edges onto whole pixels. Gio draws glyphs exactly where their outlines
// fall (no hinting), so at 1.25 a one-pixel stem often lands between two
// pixels at half strength and the interface's text looked soft beside GTK's
// and the pages' own. These outlines are filled by Gio like any other shape.
//
// Only the glyph shapes come from here; where each glyph goes stays Gio's
// (its shaping, kerning and measures), so the layout does not move.
package hint

/*
#cgo pkg-config: freetype2
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include <stdlib.h>

static FT_Library lib;

static FT_Face hintOpen(const unsigned char *data, long n) {
	if (!lib && FT_Init_FreeType(&lib)) return NULL;
	FT_Face f = NULL;
	if (FT_New_Memory_Face(lib, data, n, 0, &f)) return NULL;
	return f;
}

// the outline as commands: 0 move (1 point), 1 line (1), 2 quad (2), 3 cubic (3)
typedef struct {
	int n, np, cap, capp;
	unsigned char *op;
	long *pt; // x, y pairs in 26.6, y up
} HintPath;

static void hpAdd(HintPath *p, unsigned char op, const FT_Vector **v, int k) {
	if (p->n == p->cap) {
		p->cap = p->cap ? p->cap * 2 : 64;
		p->op = realloc(p->op, p->cap);
	}
	if (p->np + 2 * k > p->capp) {
		p->capp = (p->capp ? p->capp * 2 : 256) + 2 * k;
		p->pt = realloc(p->pt, p->capp * sizeof(long));
	}
	p->op[p->n++] = op;
	for (int i = 0; i < k; i++) {
		p->pt[p->np++] = v[i]->x;
		p->pt[p->np++] = v[i]->y;
	}
}
static int hpMove(const FT_Vector *to, void *u) { hpAdd(u, 0, &to, 1); return 0; }
static int hpLine(const FT_Vector *to, void *u) { hpAdd(u, 1, &to, 1); return 0; }
static int hpQuad(const FT_Vector *c, const FT_Vector *to, void *u) {
	const FT_Vector *v[2] = {c, to};
	hpAdd(u, 2, v, 2);
	return 0;
}
static int hpCubic(const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *u) {
	const FT_Vector *v[3] = {c1, c2, to};
	hpAdd(u, 3, v, 3);
	return 0;
}

// hintOutline puts the hinted outline of rune r at ppem64 (26.6 pixels per
// em) in p; 0 when the face has no glyph for it.
static int hintOutline(FT_Face f, unsigned long r, long ppem64, HintPath *p, long *adv) {
	FT_UInt gi = FT_Get_Char_Index(f, r);
	if (!gi) return 0;
	if (FT_Set_Char_Size(f, 0, ppem64, 72, 72)) return 0;
	if (FT_Load_Glyph(f, gi, FT_LOAD_NO_BITMAP | FT_LOAD_FORCE_AUTOHINT | FT_LOAD_TARGET_NORMAL)) return 0;
	if (f->glyph->format != FT_GLYPH_FORMAT_OUTLINE) return 0;
	*adv = f->glyph->linearHoriAdvance; // unhinted, 16.16
	FT_Outline_Funcs fn = {hpMove, hpLine, hpQuad, hpCubic, 0, 0};
	return FT_Outline_Decompose(&f->glyph->outline, &fn, p) == 0;
}

static void hpFree(HintPath *p) {
	free(p->op);
	free(p->pt);
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

// Op is an outline command.
type Op uint8

const (
	Move  Op = iota // to P[0]
	Line            // to P[0]
	Quad            // through P[0] to P[1]
	Cubic           // through P[0], P[1] to P[2]
)

// Seg is one command of an outline: its points in pixels, y down, from the
// glyph's dot.
type Seg struct {
	Op Op
	P  [3][2]float32
}

// Glyph is a hinted glyph: its outline and its unhinted advance in pixels
// (26.6).
type Glyph struct {
	Segs []Seg
	Adv  int32
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
	var p C.HintPath
	var adv C.long
	ok := C.hintOutline(fc.f, C.ulong(r), C.long(ppem64), &p, &adv) != 0
	defer C.hpFree(&p)
	if !ok {
		fc.cache[k] = nil
		return nil
	}
	g := &Glyph{Adv: int32(int64(adv) * 64 / 65536)}
	ops := unsafe.Slice((*byte)(unsafe.Pointer(p.op)), int(p.n))
	pts := unsafe.Slice((*C.long)(unsafe.Pointer(p.pt)), int(p.np))
	n := map[Op]int{Move: 1, Line: 1, Quad: 2, Cubic: 3}
	j := 0
	for _, o := range ops {
		s := Seg{Op: Op(o)}
		for i := 0; i < n[s.Op]; i++ {
			s.P[i] = [2]float32{float32(pts[j]) / 64, -float32(pts[j+1]) / 64}
			j += 2
		}
		g.Segs = append(g.Segs, s)
	}
	fc.cache[k] = g
	return g
}
