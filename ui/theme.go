package ui

// Sym colors one family of chart symbols.
type SymStyle struct{ Fill, Stroke, Text Color }

// Theme is one palette: the five spring palettes of Lite, Classic (paper) and Night.
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

func (t *Theme) derive() *Theme {
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
	t.Card = pick(Mix(t.G5, Black, 0.1).Alpha(0.72), White.Alpha(0.58))
	t.CardStrong = pick(Mix(t.G5, White, 0.06).Alpha(0.9), White.Alpha(0.78))
	t.Rim = pick(White.Alpha(0.10), White.Alpha(0.75))
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

// Themes lists the palettes; Crocus is the default.
var Themes = []*Theme{
	spring("crocus", "Crocus", "#2a1433", "#5a3d66", "#7d6487", "#b9a3c6", "#923993", "#9d60ab", "#ffae00", "#ca3404",
		[]string{"#ffe2a0", "#ecc8f0", "#d9edd5", "#cca2e2", "#fffaf7", "#f4d6e6"},
		[]string{"#ece5f9", "#e2f1df", "#fff0c6", "#f6e0f2", "#ecdcf6"}, "#4a1e50",
		[]string{"#923993", "#9d60ab", "#cca2e2", "#ffae00", "#ca3404"}),
	spring("tulip", "Tulip", "#2b0f2e", "#5b3560", "#85628a", "#c4a6c8", "#922b99", "#bb38bd", "#f69a2f", "#d2264f",
		[]string{"#fed272", "#ffc4df", "#d6ecd3", "#f0b3ea", "#fff9f4", "#ffd2a8"},
		[]string{"#f1e3f7", "#e0f0dc", "#fff1c9", "#fde0ee", "#f3dcf3"}, "#5a1950",
		[]string{"#922b99", "#bb38bd", "#f04599", "#fed272", "#f69a2f"}),
	spring("spring", "Spring Mix", "#241f4e", "#4c4674", "#78739e", "#a9a4cf", "#5145c9", "#8f7fe0", "#f7b2d5", "#c8424f",
		[]string{"#fce38a", "#f8bbd9", "#d8f3dc", "#a9def9", "#fffdf5", "#cdb4f0"},
		[]string{"#dce9fd", "#d9f6e5", "#fdf0c9", "#fbe3f1", "#e7e0fd"}, "#2b2054",
		[]string{"#5145c9", "#f8bbd9", "#fce38a", "#d8f3dc", "#a9def9"}),
	spring("sakura", "Sakura", "#33171f", "#63404b", "#8c6a74", "#d0aab6", "#c2457a", "#e48aae", "#8fbf6a", "#c0392b",
		[]string{"#ffe1ea", "#ffd1df", "#e3f2d9", "#f6c4d6", "#fffafa", "#fbe7ef"},
		[]string{"#f3e6f0", "#e5f2dc", "#fff0d8", "#fde2ea", "#f2e2ef"}, "#6e283c",
		[]string{"#c2457a", "#e48aae", "#ffd1df", "#fffafa", "#8fbf6a"}),
	spring("meadow", "Meadow", "#12291c", "#3b5745", "#66806f", "#a7c0ae", "#2f7d4f", "#5aa86f", "#f5c518", "#c43d2f",
		[]string{"#fff1a8", "#d4f0ff", "#d5efc9", "#bfe6d0", "#fbfdf6", "#e8f6c8"},
		[]string{"#e2f1fb", "#def2e2", "#fff3c4", "#fbe6ea", "#e9e8f8"}, "#1e462d",
		[]string{"#2f7d4f", "#5aa86f", "#f5c518", "#d4f0ff", "#bfe6d0"}),
	pastel(spring("peach", "Peach Sky", "#33172b", "#5f3d55", "#8a6880", "#cbaec2", "#a8487f", "#d47fae", "#f2a65a", "#c63d3d",
		[]string{"#ffe9c9", "#fbd5e6", "#dcefe0", "#e3d3f5", "#fdf3f4", "#ffe0d2"},
		[]string{"#e4e6fb", "#e0f2e2", "#fff0cf", "#fde1ec", "#efe0f7"}, "#5a2447",
		[]string{"#ffe3d3", "#fbdcec", "#dfe3fb", "#a8487f", "#f2a65a"}), "#ffe3d3", "#fbdcec", "#dfe3fb"),
	pastel(spring("mint", "Mint Lilac", "#1c2340", "#424a6b", "#6c7494", "#aab1cc", "#5a63b8", "#8b93dc", "#f0b35a", "#c8424f",
		[]string{"#fff1c4", "#e6dcf8", "#d5f1e2", "#cfe4f8", "#f4f8fc", "#e9defa"},
		[]string{"#dde8fc", "#d9f3e6", "#fdf1cd", "#f6e2f1", "#e9e0fb"}, "#27305c",
		[]string{"#d9f3e6", "#dcecf9", "#e9defa", "#5a63b8", "#f0b35a"}), "#d9f3e6", "#dcecf9", "#e9defa"),
	pastel(spring("sorbet", "Sorbet", "#33161f", "#623f49", "#8d6a74", "#d1b0b8", "#c4517a", "#e68aa6", "#f09a3e", "#c0392b",
		[]string{"#fff0c9", "#fbd3e4", "#e2f1d6", "#f7cfdc", "#fff6f1", "#ffdcd2"},
		[]string{"#ece4f7", "#e3f2dc", "#fff0cc", "#fde0e8", "#f5e0ee"}, "#6a2a40",
		[]string{"#fff0c9", "#ffdcd2", "#f9d3e6", "#c4517a", "#f09a3e"}), "#fff0c9", "#ffdcd2", "#f9d3e6"),
	pastel(spring("lagoon", "Lagoon", "#10283a", "#38566a", "#647f90", "#a6bdc9", "#2f7f97", "#63aebf", "#f3b24c", "#c4453a",
		[]string{"#fff2c2", "#f2e3f5", "#d2f0e4", "#cfe9f3", "#f3f9fb", "#dfeaf9"},
		[]string{"#dbeafb", "#d6f2e6", "#fdf1cb", "#f8e3ee", "#e8e3f8"}, "#17405a",
		[]string{"#d6f1f5", "#dfeaf9", "#f2e3f5", "#2f7f97", "#f3b24c"}), "#d6f1f5", "#dfeaf9", "#f2e3f5"),
	// warm and strong
	pastel(spring("glow", "Ember Glow", "#3a1608", "#6b3a22", "#946450", "#d0a995", "#d9480f", "#f27a3a", "#ffc233", "#b3261e",
		[]string{"#ffd59e", "#ffb59e", "#ffe7b3", "#ffc7a8", "#fff6ee", "#ffd9c2"},
		[]string{"#ffe5d6", "#fdf0d0", "#ffe9c2", "#fde0e4", "#f6e1d6"}, "#5c2410",
		[]string{"#ffd8a8", "#ffbfa0", "#ffb3b8", "#d9480f", "#ffc233"}), "#ffd8a8", "#ffbfa0", "#ffb3b8"),
	pastel(spring("sunset", "Sunset", "#2e0f1e", "#5c2c42", "#86566c", "#c79fb2", "#c2185b", "#e64a6f", "#ff9f1c", "#b71c1c",
		[]string{"#ffc98c", "#ff9fb2", "#ffd6a5", "#d7a8f2", "#fff2ef", "#ffb4a2"},
		[]string{"#f3dcf2", "#ffe3d3", "#ffedc7", "#ffd9e2", "#ead8f8"}, "#5a1030",
		[]string{"#ffb88c", "#ff8fa3", "#c79bf2", "#c2185b", "#ff9f1c"}), "#ffb88c", "#ff8fa3", "#c79bf2"),
	pastel(spring("terracotta", "Terracotta", "#2f1a12", "#5e3e30", "#86685a", "#c4a99b", "#b5532a", "#d77a4c", "#e9b44c", "#a83224",
		[]string{"#f6d5b8", "#efc0a0", "#e6dcc2", "#e8b4a6", "#fbf4ec", "#f3cdb0"},
		[]string{"#efe2d6", "#e6ecd6", "#f8ebcc", "#f6dcd4", "#ece0dc"}, "#4e2516",
		[]string{"#f6d5b8", "#efc0a0", "#e8b4a6", "#b5532a", "#e9b44c"}), "#f6d5b8", "#efc0a0", "#e8b4a6"),
	(&Theme{ID: "classic", Label: "Classic", Ink: Hex("#1d1d24"), Body: Hex("#3c3c48"), Ink2: Hex("#6b6b78"), Ink3: Hex("#a8a8b4"),
		Deep: Hex("#3a5bc7"), Deep2: Hex("#6f86d6"), Hl: Hex("#f0a500"), Danger: Hex("#c62828"),
		G1: White, G2: White, G3: White, G4: White, G5: Hex("#f7f7f9"), G6: White,
		TBlue: Hex("#e8eefc"), TGreen: Hex("#e3f4e1"), THoney: Hex("#fff3cf"), TPink: Hex("#fbe4ef"), TLav: Hex("#efe7fb"),
		Shadow: Hex("#20203a"), Swatch: hexes("#3a5bc7", "#e8eefc", "#e3f4e1", "#fff3cf", "#f0a500")}).derive(),
	(&Theme{ID: "night", Label: "Night", Dark: true, Ink: Hex("#f3e9f7"), Body: Hex("#d9c8e1"), Ink2: Hex("#b29fbd"), Ink3: Hex("#7c6a87"),
		Deep: Hex("#c07ad0"), Deep2: Hex("#9d60ab"), Hl: Hex("#ffae00"), Danger: Hex("#ff6b4a"),
		G1: Hex("#3a2a14"), G2: Hex("#3d1f44"), G3: Hex("#1f3324"), G4: Hex("#2f2140"), G5: Hex("#17111c"), G6: Hex("#2e1b2a"),
		TBlue: Hex("#3a3357"), TGreen: Hex("#2b4430"), THoney: Hex("#4a3d17"), TPink: Hex("#4a2a43"), TLav: Hex("#3c2c4f"),
		Shadow: Black, Swatch: hexes("#17111c", "#c07ad0", "#9d60ab", "#ffae00", "#ff6b4a"), Fields: true}).derive(),
	// more nights
	dark("midnight", "Midnight", "#e6ecff", "#c4cdec", "#97a3c9", "#5e6990", "#6b93ff", "#4a6fd6", "#ffc857", "#ff6b6b",
		[]string{"#1b2747", "#21234a", "#16303a", "#262049", "#0b1120", "#1a1d3d"},
		[]string{"#24305a", "#1f3a3a", "#3b3420", "#3a2440", "#2d2852"}),
	dark("embernight", "Ember Night", "#fbe9df", "#e8cbbb", "#bf9886", "#7d5f52", "#ff7a3d", "#e0592a", "#ffc233", "#ff5a5a",
		[]string{"#3a1d10", "#3b1622", "#2a2414", "#3a2016", "#140c09", "#33130f"},
		[]string{"#3d2a22", "#2e3322", "#45351a", "#46231f", "#3a2630"}),
	dark("aurora", "Aurora", "#e3fbf2", "#bfe6d8", "#8fbfae", "#58806f", "#3ddc97", "#22b07a", "#b388ff", "#ff6b7a",
		[]string{"#0f3329", "#1c2448", "#133a33", "#26204a", "#08130f", "#0e2a33"},
		[]string{"#17323f", "#183a2c", "#3a3622", "#3c2335", "#2b2648"}),
	dark("abyss", "Abyss", "#e2f6fb", "#bcdde6", "#8bb3bf", "#55788a", "#22d3ee", "#0ea5c4", "#fbbf24", "#f87171",
		[]string{"#0c2a38", "#10193a", "#0b302f", "#1a1840", "#050b12", "#0a2236"},
		[]string{"#13304a", "#123a33", "#3a3418", "#3a1d2c", "#221e45"}),
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

// ThemeByID returns the palette with id, or Crocus.
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
