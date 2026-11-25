// Iris's line icons (24 × 24, stroked) and the container icons (16 × 16,
// filled), rasterised by Iris at the screen's own pixels into the glyph
// atlas and drawn in any colour.
package iris

import "core:math"
import gl "vendor:OpenGL"

Icon :: enum u8 {
	Back, Forward, Reload, Stop, Plus, Close, Shield, Shield_On, Shield_Off, Download,
	Layers, Search, Sparkle, Globe, Warn, Mask, History, Link, Tab, Copy, Image, Cut,
	Paste, Select_All, Check, Folder, Trash, Up, Down, Min, Max, Restore, Open,
	// 2.3
	Pin, Speaker, Speaker_Off, Reader, Split, Compact, Expand, Command, Eye, Grid, Lock,
	// container icons (filled)
	K_Person, K_Briefcase, K_Cart, K_Bank, K_Home, K_Heart, K_Game, K_Book, K_Plane, K_Code, K_Music, K_Star,
}

@(rodata) ICON_PATHS := [Icon]string{
	.Back = "M15 5l-7 7 7 7",
	.Forward = "M9 5l7 7-7 7",
	.Reload = "M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v4.5H15",
	.Stop = "M6.5 6.5l11 11M17.5 6.5l-11 11",
	.Plus = "M12 5v14M5 12h14",
	.Close = "M7 7l10 10M17 7L7 17",
	.Shield = "M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6z",
	.Shield_On = "M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6zM8.8 12.2l2.2 2.2 4.4-4.6",
	.Shield_Off = "M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6zM4 4l16 16",
	.Download = "M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14",
	.Layers = "M12 3.5l8.5 4.5-8.5 4.5L3.5 8zM3.5 12.5l8.5 4.5 8.5-4.5M3.5 16.5l8.5 4.5 8.5-4.5",
	.Search = "M11 4a7 7 0 1 0 0 14 7 7 0 1 0 0-14M16.2 16.2l4.3 4.3",
	.Sparkle = "M12 3c.6 4.6 2.4 6.4 7 7-4.6.6-6.4 2.4-7 7-.6-4.6-2.4-6.4-7-7 4.6-.6 6.4-2.4 7-7zM19 16c.2 1.6.9 2.3 2.5 2.5-1.6.2-2.3.9-2.5 2.5-.2-1.6-.9-2.3-2.5-2.5 1.6-.2 2.3-.9 2.5-2.5z",
	.Globe = "M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18M3 12h18M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9c-2.5-2.6-3.7-5.6-3.7-9S9.5 5.6 12 3",
	.Warn = "M12 4l9 16H3zM12 10v4.5M12 17.2v.3",
	.Mask = "M3 9c3-2 15-2 18 0 0 5-2.5 7-5 7-2 0-2.5-2-4-2s-2 2-4 2c-2.5 0-5-2-5-7zM8 11.2h.01M16 11.2h.01",
	.History = "M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4v4.5H9M12 8v4.3l3 1.8",
	.Link = "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
	.Tab = "M3.5 6.5h17v13h-17zM3.5 10h17M8 6.5v3.5",
	.Copy = "M8 8h11v12H8zM5 16V4h11",
	.Image = "M3.5 5h17v14h-17zM3.5 16l5-5 4 4 3-3 5 5M15.5 9v.2",
	.Cut = "M6 7a2.5 2.5 0 1 0 0 .1M6 17a2.5 2.5 0 1 0 0 .1M8 8.5L19 18M8 15.5L19 6",
	.Paste = "M9 4h6v3H9zM7 5.5H5.5v15h13v-15H17",
	.Select_All = "M4 4h16v16H4zM8 12l3 3 5-6",
	.Check = "M5 12.5l4.5 4.5L19 7.5",
	.Folder = "M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2h8.5A1.5 1.5 0 0 1 21 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z",
	.Trash = "M5 7h14M10 7V4.5h4V7M7 7l1 13h8l1-13",
	.Up = "M6 15l6-6 6 6",
	.Down = "M6 9l6 6 6-6",
	.Min = "M6 12h12",
	.Max = "M6.5 6.5h11v11h-11z",
	.Restore = "M8.5 8.5h9v9h-9zM6 15V6h9",
	.Open = "M7 17L17 7M9 7h8v8",
	.Pin = "M9 4h6M10 4v5.5L7 13h10l-3-3.5V4M12 13v7",
	.Speaker = "M4 9.5h3.5L12 6v12l-4.5-3.5H4zM15.5 9.2a4 4 0 0 1 0 5.6M18.2 6.5a7.6 7.6 0 0 1 0 11",
	.Speaker_Off = "M4 9.5h3.5L12 6v12l-4.5-3.5H4zM16 9.5l5 5M21 9.5l-5 5",
	.Reader = "M4.5 5.5h15M4.5 9.5h15M4.5 13.5h15M4.5 17.5h9",
	.Split = "M3.5 5h17v14h-17zM12 5v14",
	.Compact = "M4 9l8-5 8 5M4 15l8 5 8-5",
	.Expand = "M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7",
	.Command = "M9 9V6.5A2.5 2.5 0 1 0 6.5 9H9zm0 0h6m-6 0v6m6-6V6.5A2.5 2.5 0 1 1 17.5 9H15zm0 0v6m0 0h2.5A2.5 2.5 0 1 1 15 17.5V15zm0 0H9m0 0v2.5A2.5 2.5 0 1 1 6.5 15H9z",
	.Eye = "M2.5 12c2.5-4.5 6-7 9.5-7s7 2.5 9.5 7c-2.5 4.5-6 7-9.5 7s-7-2.5-9.5-7zM12 9a3 3 0 1 0 0 6 3 3 0 1 0 0-6",
	.Grid = "M4.5 4.5h6v6h-6zM13.5 4.5h6v6h-6zM4.5 13.5h6v6h-6zM13.5 13.5h6v6h-6z",
	.Lock = "M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3",
	.K_Person = "M8 1.5a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM2 15c0-3.6 2.7-6 6-6s6 2.4 6 6z",
	.K_Briefcase = "M6 1.5h4a1.5 1.5 0 0 1 1.5 1.5V4H14a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 14 15H2a1.5 1.5 0 0 1-1.5-1.5v-8A1.5 1.5 0 0 1 2 4h2.5V3A1.5 1.5 0 0 1 6 1.5zM6 3v1h4V3z",
	.K_Cart = "M0.5 1.5h2.3l.5 2H15l-1.6 6.5H4.6l.3 1.5H13v1.5H3.7L1.6 3H.5z",
	.K_Bank = "M8 .5l7.5 4V6H.5V4.5zM2 7h2.5v5H2zm4.75 0h2.5v5h-2.5zM11.5 7H14v5h-2.5zM.5 13h15v2.5H.5z",
	.K_Home = "M8 1l7.5 6.5H13V15H9.5v-4.5h-3V15H3V7.5H.5z",
	.K_Heart = "M8 14.5S1 10.3 1 5.6A3.6 3.6 0 0 1 8 4a3.6 3.6 0 0 1 7 1.6c0 4.7-7 8.9-7 8.9z",
	.K_Game = "M4.5 4h7A4.5 4.5 0 0 1 16 8.5v1A2.5 2.5 0 0 1 11.6 11L10.5 10h-5l-1.1 1A2.5 2.5 0 0 1 0 9.5v-1A4.5 4.5 0 0 1 4.5 4zM3.5 6v1.25H2.25v1.5H3.5V10H5V8.75h1.25v-1.5H5V6zm8 0a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8zm-1.6 1.7a.9.9 0 1 0 0 1.8.9.9 0 0 0 0-1.8z",
	.K_Book = "M1 2.5c2.4-.8 4.8-.6 6.25.6V15c-1.6-1.1-3.9-1.2-6.25-.5zm14 0c-2.4-.8-4.8-.6-6.25.6V15c1.6-1.1 3.9-1.2 6.25-.5z",
	.K_Plane = "M15 6.8c.6 0 1 .5 1 1.2s-.4 1.2-1 1.2H10.3L7 15H5.2L7 9.2H3.6L2.2 11H.8l.8-3-.8-3h1.4l1.4 1.8H7L5.2 1H7l3.3 5.8z",
	.K_Code = "M5.3 3.3l1.1 1.1L2.8 8l3.6 3.6-1.1 1.1L.6 8zm5.4 0L15.4 8l-4.7 4.7-1.1-1.1L13.2 8 9.6 4.4z",
	.K_Music = "M15 1v10.5a2.5 2.5 0 1 1-1.5-2.3V4.6L6.5 6v7.5A2.5 2.5 0 1 1 5 11.2V3z",
	.K_Star = "M8 .8l2.2 4.6 5 .7-3.6 3.5.9 5L8 12.2l-4.5 2.4.9-5L.8 6.1l5-.7z",
}

/// a container's icon by the name Iris keeps ("person"…); Mask for private
container_icon :: proc(name: string) -> Icon {
	switch name {
	case "person": return .K_Person
	case "briefcase": return .K_Briefcase
	case "cart": return .K_Cart
	case "bank": return .K_Bank
	case "home": return .K_Home
	case "heart": return .K_Heart
	case "game": return .K_Game
	case "book": return .K_Book
	case "plane": return .K_Plane
	case "code": return .K_Code
	case "music": return .K_Music
	case "star": return .K_Star
	case "private": return .Mask
	}
	return .Globe
}

Icon_Key :: struct {
	icon: Icon,
	px:   u16, // device pixels × 4
}

@(private="file") icon_slot :: proc(ic: Icon, px: f32) -> (Atlas_Slot, bool) {
	key := Icon_Key{ic, u16(px * 4)}
	if s, ok := atlas.icons[key]; ok do return s, true
	filled := ic >= .K_Person
	box: f32 = filled ? 16 : 24
	n := i32(math.ceil(px)) + 2
	r := raster_make(int(n), int(n))
	k := px / box
	p := path_parse(ICON_PATHS[ic], k)
	if filled {
		raster_fill(&r, p, k, {1, 1})
	} else {
		// a 1.8-unit line in a 24-unit box, never thinner than a pixel
		raster_stroke(&r, p, k, {1, 1}, max(1.8 * k, 1.1))
	}
	cov := make([]u8, int(n * n), context.temp_allocator)
	raster_coverage(&r, cov)
	x, y, ok := atlas_place(n, n)
	if !ok {
		atlas_clear()
		x, y, ok = atlas_place(n, n)
		if !ok do return {}, false
	}
	atlas_upload(x, y, n, n, cov)
	s := Atlas_Slot{x = x, y = y, w = n, h = n, ox = -1, oy = -1}
	atlas.icons[key] = s
	return s, true
}

/// an icon in a size × size square at (x, y), logical pixels
draw_icon :: proc(ic: Icon, x, y, size: f32, color: [4]f32) {
	sc := rnd.scale
	px := math.round(size * sc)
	slot, ok := icon_slot(ic, px)
	if !ok do return
	x0 := math.round(x * sc) + slot.ox
	y0 := math.round(y * sc) + slot.oy
	inv := 1 / f32(atlas.size)
	verts := [24]f32{}
	x1, y1 := x0 + f32(slot.w), y0 + f32(slot.h)
	u0, v0 := f32(slot.x) * inv, f32(slot.y) * inv
	u1, v1 := f32(slot.x + slot.w) * inv, f32(slot.y + slot.h) * inv
	verts = {x0, y0, u0, v0, x1, y0, u1, v0, x0, y1, u0, v1, x1, y0, u1, v0, x1, y1, u1, v1, x0, y1, u0, v1}
	p := &atlas.prog
	gl.UseProgram(p.id)
	gl.BindVertexArray(atlas.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, atlas.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(verts), &verts[0], gl.STREAM_DRAW)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, atlas.tex)
	gl.Uniform1i(loc(p, "u_atlas"), 0)
	gl.Uniform2f(loc(p, "u_screen"), f32(rnd.sw), f32(rnd.sh))
	c := premul(color)
	gl.Uniform4f(loc(p, "u_color"), c.r, c.g, c.b, c.a)
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
	gl.BindVertexArray(rnd.vao)
}
