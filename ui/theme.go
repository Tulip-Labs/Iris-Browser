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

// Themes lists the palettes, in the spirit of Apple's Liquid Glass: frosted
// panes over a deep or airy backdrop, one clear accent each. Liquid (black,
// with glass and glossy icons) is the default.
var Themes = []*Theme{
	// dark: a black or deep base with soft fields of colored light behind the glass
	dark("liquid", "Liquid", "#f5f5f7", "#e5e5ea", "#aeaeb2", "#6e6e73", "#0a84ff", "#5e5ce6", "#ff9f0a", "#ff453a",
		[]string{"#071a3a", "#170d33", "#04201f", "#1b0f2c", "#000000", "#0d0f1c"},
		[]string{"#132a4d", "#12332c", "#3a2e12", "#3a1726", "#251c46"}),
	dark("graphite", "Graphite", "#f2f2f7", "#d8d8de", "#a1a1a8", "#68686e", "#bf5af2", "#8e8aff", "#ffd60a", "#ff453a",
		[]string{"#2a1838", "#1b1f2e", "#22252b", "#2a1d33", "#141416", "#1f1d26"},
		[]string{"#2b2d3d", "#24332c", "#3b3420", "#3b2232", "#33284a"}),
	dark("deepsea", "Deep Sea", "#e6f7ff", "#c2e3f2", "#8fb6c9", "#567a8c", "#64d2ff", "#30b0c7", "#ffd60a", "#ff6961",
		[]string{"#06324a", "#0b1d45", "#03302c", "#16153f", "#020a12", "#05243a"},
		[]string{"#123049", "#0f3a35", "#3a3418", "#3a1d2c", "#211f4a"}),
	dark("ember", "Ember", "#fff1e8", "#f0d2c2", "#c09a87", "#7f6253", "#ff9f0a", "#ff6b3d", "#ffd60a", "#ff453a",
		[]string{"#3d1806", "#3a0f1c", "#2b230b", "#36130e", "#0a0503", "#2e1208"},
		[]string{"#3f2a20", "#2f3320", "#47371a", "#47211f", "#3a2530"}),
	dark("aurora", "Aurora", "#ecfff7", "#c8f0e0", "#90c4b0", "#577f70", "#30d158", "#66d4cf", "#bf5af2", "#ff6b7a",
		[]string{"#0b3a2a", "#1a1f4a", "#0d3a36", "#2a1648", "#030b08", "#0b2a33"},
		[]string{"#17323f", "#183a2c", "#3a3622", "#3c2335", "#2b2648"}),
	// light: white glass over an airy wash of color
	pastel(spring("daylight", "Daylight", "#1d1d1f", "#3a3a3c", "#6e6e73", "#a1a1a6", "#007aff", "#5856d6", "#ff9500", "#ff3b30",
		[]string{"#e8f1ff", "#f1ecff", "#e9f7f1", "#f6eefe", "#f5f5f7", "#eef2fb"},
		[]string{"#e5efff", "#e3f5ea", "#fff3d6", "#ffe5ec", "#efe8ff"}, "#1c2a44",
		[]string{"#f5f5f7", "#d6e6ff", "#007aff", "#5856d6", "#ff9500"}), "#eaf2ff", "#f6f3ff", "#f5f5f7"),
	pastel(spring("mist", "Mist", "#1c1c2e", "#3b3b55", "#6b6b85", "#a3a3bd", "#5856d6", "#7d7aff", "#ff9f0a", "#ff3b30",
		[]string{"#dfe8ff", "#eadfff", "#e1f3f7", "#efe2ff", "#f3f4fb", "#e6eaff"},
		[]string{"#e0e8ff", "#dff3ef", "#fff2d4", "#fde3ef", "#ebe3ff"}, "#22224a",
		[]string{"#dfe8ff", "#eadfff", "#5856d6", "#7d7aff", "#ff9f0a"}), "#dbe6ff", "#ece2ff", "#f6f0fb"),
	pastel(spring("rose", "Rose", "#2d1520", "#55323f", "#86606f", "#c4a2af", "#ff2d55", "#ff6482", "#ff9f0a", "#d70015",
		[]string{"#ffe0e9", "#ffeadf", "#f2e3ff", "#ffd9e4", "#fff6f8", "#ffe6ee"},
		[]string{"#f3e3f7", "#e6f2e3", "#fff0d4", "#ffe0e8", "#f1e1fb"}, "#5a1830",
		[]string{"#ffe0e9", "#ffeadf", "#f2e3ff", "#ff2d55", "#ff9f0a"}), "#ffe2ea", "#fff0e8", "#f4e9ff"),
	pastel(spring("sunrise", "Sunrise", "#2b1a0c", "#553c26", "#86684f", "#c4a68c", "#ff9500", "#ff6b3d", "#ffcc00", "#ff3b30",
		[]string{"#ffe7c7", "#ffdcd6", "#fff2d2", "#ffe0cc", "#fff9f2", "#ffebd9"},
		[]string{"#f3e6f2", "#e8f2e0", "#fff0c9", "#ffe2dc", "#f1e3f3"}, "#5a3110",
		[]string{"#ffe7c7", "#ffdcd6", "#fff2d2", "#ff9500", "#ff6b3d"}), "#ffe8cc", "#ffdfd9", "#fff6e6"),
	pastel(spring("mint", "Mint", "#0f2a26", "#2f514b", "#5f7f79", "#9dbdb6", "#00a99d", "#30b0c7", "#ff9f0a", "#ff3b30",
		[]string{"#d9f8ef", "#dfefff", "#e8fbe4", "#d9f2f8", "#f4fbf9", "#e3f5ff"},
		[]string{"#ddedfb", "#d9f5ea", "#fff2d1", "#fde4ec", "#e6e4fb"}, "#123c36",
		[]string{"#d9f8ef", "#dfefff", "#00a99d", "#30b0c7", "#ff9f0a"}), "#d8f7ee", "#e2efff", "#f4fbf9"),
}

// dark makes a night palette: light ink on a deep base with soft color
// fields, like Night.
func dark(id, label, ink, body, ink2, ink3, deep, deep2, hl, danger string, g, tint []string) *Theme {
	gs, ts := hexes(g...), hexes(tint...)
	return (&Theme{ID: id, Label: label, Dark: true, Ink: Hex(ink), Body: Hex(body), Ink2: Hex(ink2), Ink3: Hex(ink3),
		Deep: Hex(deep), Deep2: Hex(deep2), Hl: Hex(hl), Danger: Hex(danger),
		G1: gs[0], G2: gs[1], G3: gs[2], G4: gs[3], G5: gs[4], G6: gs[5],
		TBlue: ts[0], TGreen: ts[1], THoney: ts[2], TPink: ts[3], TLav: ts[4],
		Shadow: Black, Swatch: []Color{gs[4], Hex(deep), Hex(deep2), Hex(hl), Hex(danger)}, Fields: true}).derive()
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

// ThemeByID returns the palette with id, or Liquid (themes that no longer
// exist fall back to it).
func ThemeByID(id string) *Theme {
	for _, t := range Themes {
		if t.ID == id {
			return t
		}
	}
	return Themes[0]
}

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
