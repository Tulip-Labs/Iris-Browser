package ui

// Sym colors one family of chart symbols.
type SymStyle struct{ Fill, Stroke, Text Color }

// Theme is one palette.
// Every color the interface uses is derived here.
type Theme struct {
	ID, Label string
	Dark      bool
	Ink, Body, Ink2, Ink3,
	Deep, Deep2, Hl, Danger Color
	G1, G2, G3, G4, G5, G6             Color // backdrop color fields; G5 is the base
	TBlue, TGreen, THoney, TPink, TLav Color
	Shadow                             Color
	Swatch                             []Color
	Fields                             bool
	// Focus is the ring around the control that has the keyboard (Apple's
	// system blue: the one color Liquid Glass keeps besides the content)
	Focus Color
	// Wall is the window's background picture (nil: the theme's wash); glass
	// panes show it frosted.
	Wall *Wall
	// Grad, when set, is the window's backdrop: three pastel colors that
	// merge from top to bottom (the page surfaces take a paler version).
	Grad []Color

	Card, CardStrong, Rim, Hover, Pressed, Divider, OnDeep, Field, FieldRim, Selection, OK Color

	SymTerminal, SymProcess, SymData, SymDecision, SymLoop, SymCall, SymStore, SymNote SymStyle
	Edge, Current, Breakpoint                                                          Color

	CodeKeyword, CodeString, CodeNumber, CodeComment, CodeType, CodeFn Color

	// Material 3 color roles, derived from the palette.
	Primary, OnPrimary, PrimaryContainer, OnPrimaryContainer    Color
	SecondaryContainer, OnSecondaryContainer                    Color
	Surface, SurfaceLow, SurfaceHigh, SurfaceHighest, OnSurface Color
	OnSurfaceVariant, Outline, OutlineVariant, InverseSurface   Color
	InverseOnSurface, ErrorContainer, OnErrorContainer, Scrim   Color
}

// clear turns a palette into colorless liquid glass: only the backdrop keeps
// its color. Text is neutral and slightly see-through, accents are clear glass
// (white light on dark themes, smoked glass on light ones), and the pastel
// tints become frosted panes.
func (t *Theme) clear() *Theme {
	if t.Dark {
		t.Ink, t.Body = Hex("#f5f5f7").Alpha(0.96), Hex("#f5f5f7").Alpha(0.86)
		t.Ink2, t.Ink3 = Hex("#f5f5f7").Alpha(0.62), Hex("#f5f5f7").Alpha(0.40)
		t.Deep, t.Deep2, t.Hl = White.Alpha(0.30), White.Alpha(0.20), White.Alpha(0.85)
		glass := White.Alpha(0.10)
		t.TBlue, t.TGreen, t.THoney, t.TPink, t.TLav = glass, glass, glass, glass, glass
	} else {
		t.Ink, t.Body = Hex("#1d1d1f").Alpha(0.94), Hex("#1d1d1f").Alpha(0.84)
		t.Ink2, t.Ink3 = Hex("#1d1d1f").Alpha(0.60), Hex("#1d1d1f").Alpha(0.38)
		t.Deep, t.Deep2, t.Hl = Hex("#1d1d1f").Alpha(0.72), Hex("#1d1d1f").Alpha(0.50), Hex("#1d1d1f").Alpha(0.80)
		glass := White.Alpha(0.50)
		t.TBlue, t.TGreen, t.THoney, t.TPink, t.TLav = glass, glass, glass, glass, glass
		t.Shadow = Hex("#1d1d1f")
	}
	return t
}

func (t *Theme) derive() *Theme {
	t.clear()
	d := t.Dark
	pick := func(dark, light Color) Color {
		if d {
			return dark
		}
		return light
	}
	pf := func(dark, light float32) float32 {
		if d {
			return dark
		}
		return light
	}
	// glass: clear and bright-rimmed over the backdrop (Liquid Glass)
	t.Card = pick(Mix(t.G5, White, 0.08).Alpha(0.55), White.Alpha(0.52))
	t.CardStrong = pick(Mix(t.G5, White, 0.11).Alpha(0.86), White.Alpha(0.76))
	t.Rim = pick(White.Alpha(0.16), White.Alpha(0.8))
	t.Hover = t.Deep.Alpha(pf(0.18, 0.08))
	t.Pressed = t.Deep.Alpha(pf(0.28, 0.16))
	t.Divider = t.Ink.Alpha(pf(0.14, 0.08))
	t.OnDeep = White
	t.Field = pick(White.Alpha(0.06), White.Alpha(0.82))
	t.FieldRim = t.Ink.Alpha(pf(0.22, 0.14))
	t.Selection = t.Deep.Alpha(0.25)
	t.OK = pick(Hex("#7fd18b"), Hex("#2f7d4f"))
	sym := func(tint, s Color) SymStyle {
		if d {
			return SymStyle{Mix(tint, t.G5, 0.78), Mix(s, White, 0.25), t.Ink}
		}
		return SymStyle{tint, Mix(s, t.Ink, 0.15), t.Ink}
	}
	if d {
		t.SymTerminal = SymStyle{Mix(t.Deep, t.G5, 0.35), t.Deep2, White}
	} else {
		t.SymTerminal = SymStyle{t.Deep, Mix(t.Deep, t.Ink, 0.3), White}
	}
	t.SymProcess = sym(t.TBlue, Mix(t.Deep2, t.TBlue, 0.25))
	t.SymData = sym(t.TGreen, Mix(Hex("#4f8a4c"), t.TGreen, 0.2))
	t.SymDecision = sym(t.THoney, Mix(Hex("#d08f00"), t.THoney, 0.2))
	t.SymLoop = sym(t.TLav, Mix(t.Deep, t.TLav, 0.2))
	t.SymCall = sym(t.TPink, Mix(Hex("#b8407e"), t.TPink, 0.2))
	t.SymStore = sym(Mix(t.TBlue, t.TGreen, 0.5), Mix(t.Deep2, Hex("#2a8f86"), 0.5))
	t.SymNote = SymStyle{White.Alpha(pf(0.04, 0.5)), t.Ink3, t.Ink2}
	t.Edge = pick(White.Alpha(0.55), Mix(t.Ink2, t.Ink, 0.3))
	t.Current, t.Breakpoint = t.Hl, t.Danger
	t.CodeKeyword = t.Deep
	t.CodeString = pick(Hex("#9ed79a"), Hex("#3f7f3c"))
	t.CodeNumber = pick(Hex("#ffc66d"), Hex("#b06a00"))
	t.CodeComment = t.Ink3
	t.CodeType = t.Deep2
	t.CodeFn = pick(Hex("#8fb8ff"), Hex("#3b5fbf"))
	// Material 3 roles: tonal steps of the primary over the palette's base
	t.Primary, t.OnPrimary = t.Deep, White
	t.OnSurface, t.OnSurfaceVariant = t.Ink, t.Ink2
	t.Outline, t.OutlineVariant = t.Ink.Alpha(pf(0.36, 0.28)), t.Ink.Alpha(pf(0.16, 0.10))
	t.Scrim = Black.Alpha(pf(0.55, 0.32))
	if d {
		t.PrimaryContainer = Mix(t.Deep, t.G5, 0.55)
		t.OnPrimaryContainer = Mix(t.Deep, White, 0.8)
		t.SecondaryContainer = Mix(t.Deep2, t.G5, 0.65)
		t.OnSecondaryContainer = Mix(t.Deep2, White, 0.85)
		t.Surface = t.G5
		t.SurfaceLow = Mix(t.G5, White, 0.04)
		t.SurfaceHigh = Mix(t.G5, White, 0.09)
		t.SurfaceHighest = Mix(t.G5, White, 0.14)
		t.InverseSurface, t.InverseOnSurface = Mix(t.Ink, t.G5, 0.05), t.G5
		t.ErrorContainer, t.OnErrorContainer = Mix(t.Danger, t.G5, 0.6), Mix(t.Danger, White, 0.8)
	} else {
		t.PrimaryContainer = Mix(t.Deep, White, 0.82)
		t.OnPrimaryContainer = Mix(t.Deep, Black, 0.45)
		t.SecondaryContainer = Mix(t.Deep2, White, 0.80)
		t.OnSecondaryContainer = Mix(t.Deep2, Black, 0.5)
		t.Surface = t.G5
		t.SurfaceLow = Mix(t.G5, t.Deep, 0.03)
		t.SurfaceHigh = Mix(t.G5, t.Deep, 0.06)
		t.SurfaceHighest = Mix(t.G5, t.Deep, 0.09)
		t.InverseSurface, t.InverseOnSurface = Mix(t.Ink, Black, 0.1), t.G5
		t.ErrorContainer, t.OnErrorContainer = Mix(t.Danger, White, 0.82), Mix(t.Danger, Black, 0.45)
	}
	t.Hover, t.Pressed = t.Ink.Alpha(0.08), t.Ink.Alpha(0.12) // M3 state layers
	// clear glass roles: accents read as the ink itself, filled buttons are
	// the ink with the backdrop's color on top, containers are frosted panes
	t.Primary = t.Ink
	t.OnPrimary = pick(Hex("#1d1d1f"), White)
	t.PrimaryContainer, t.OnPrimaryContainer = pick(White.Alpha(0.12), White.Alpha(0.62)), t.Ink
	t.SecondaryContainer, t.OnSecondaryContainer = pick(White.Alpha(0.08), White.Alpha(0.48)), t.Ink
	t.Selection = t.Ink.Alpha(0.22)
	t.CodeKeyword, t.CodeType = t.Ink, t.Body
	t.Focus = Hex("#007aff")
	return t
}

func hexes(s ...string) []Color {
	out := make([]Color, len(s))
	for i, x := range s {
		out[i] = Hex(x)
	}
	return out
}

func spring(id, label, ink, body, ink2, ink3, deep, deep2, hl, danger string, g, tint []string, shc string, sw []string) *Theme {
	gs, ts := hexes(g...), hexes(tint...)
	return (&Theme{ID: id, Label: label, Ink: Hex(ink), Body: Hex(body), Ink2: Hex(ink2), Ink3: Hex(ink3),
		Deep: Hex(deep), Deep2: Hex(deep2), Hl: Hex(hl), Danger: Hex(danger),
		G1: gs[0], G2: gs[1], G3: gs[2], G4: gs[3], G5: gs[4], G6: gs[5],
		TBlue: ts[0], TGreen: ts[1], THoney: ts[2], TPink: ts[3], TLav: ts[4], Shadow: Hex(shc), Swatch: hexes(sw...), Fields: true}).derive()
}

// Themes is Iris's one look: Apple's Liquid Glass in its light form. Clear,
// frosted white panes with bright rims float over an airy, almost white
// backdrop; text is near-black and every control is colorless glass, with
// the system blue kept for focus and links. There are no other palettes.
var Themes = []*Theme{
	pastel(spring("glass", "Liquid Glass", "#1d1d1f", "#3a3a3c", "#6e6e73", "#a1a1a6", "#007aff", "#5856d6", "#ff9500", "#ff3b30",
		[]string{"#e9f1ff", "#f1eefc", "#eaf6f2", "#f5effb", "#f5f5f7", "#eef2f9"},
		[]string{"#e6effd", "#e5f4ec", "#fff3d9", "#fde8ee", "#efeafd"}, "#1c2433",
		[]string{"#f5f5f7", "#e9f1ff", "#007aff", "#5856d6", "#ff9500"}), "#edf3fc", "#f6f6f9", "#f2f2f7"),
}

// pastel gives a palette a backdrop of three colors merging top to bottom.
func pastel(t *Theme, top, mid, bottom string) *Theme {
	t.Grad = hexes(top, mid, bottom)
	return t
}

// FillGradient3 fills the rounded rectangle r with three colors merging
// from top to bottom.
func FillGradient3(g Gfx, r Rect, rad float32, c []Color) {
	p := NewPath().RoundRect(r, rad)
	g.FillPathGradient(p, c[0], c[1], r.Y, r.CY())
	g.Save()
	g.Clip(Rect{r.X, r.CY(), r.W, r.H/2 + 1})
	g.FillPathGradient(p, c[1], c[2], r.CY(), r.B())
	g.Restore()
}

// ThemeByID returns Iris's look. Every saved choice (the dark and pastel
// palettes of earlier versions included) now opens in light Liquid Glass.
func ThemeByID(id string) *Theme { return Themes[0] }

// Backdrop paints the solid base color. Backgrounds stay flat; gradients are kept
// for small accents inside elements (primary buttons, terminals, the logo).
func Backdrop(g Gfx, w, h float32, th *Theme) {
	g.FillRect(Rect{0, 0, w, h}, th.G5)
}

// Accent returns the top and bottom colors of an element's accent gradient.
func Accent(base Color) (Color, Color) {
	return Mix(base, White, 0.14), Mix(base, Black, 0.08)
}

// FillRoundAccent fills a rounded rectangle with base as a soft vertical gradient.
func FillRoundAccent(g Gfx, r Rect, rad float32, base Color) {
	t, b := Accent(base)
	g.FillPathGradient(NewPath().RoundRect(r, rad), t, b, r.Y, r.B())
}
