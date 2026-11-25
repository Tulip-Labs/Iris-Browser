// Iris's icons: SVG files of its own (resources/ui-icons, 24 × 24, round
// 1.75 strokes), built into Iris and rasterised by Iris (svg.odin,
// raster.odin) at the screen's own pixels the first time each size is
// drawn, kept in the glyph atlas and drawn in any colour.
package iris

import "core:math"
import gl "vendor:OpenGL"

Icon :: enum u8 {
	Back, Forward, Reload, Stop, Plus, Close, Shield, Shield_On, Shield_Off, Download,
	Layers, Search, Sparkle, Globe, Warn, Mask, History, Link, Tab, Copy, Image, Cut,
	Paste, Select_All, Check, Folder, Trash, Up, Down, Min, Max, Restore, Open,
	Pin, Speaker, Speaker_Off, Reader, Split, Compact, Expand, Command, Eye, Grid, Lock,
	Dot, // a container: a dot in its colour
}

@(rodata) ICON_SVG := [Icon]string{
	.Back = #load("../resources/ui-icons/back.svg", string),
	.Forward = #load("../resources/ui-icons/forward.svg", string),
	.Reload = #load("../resources/ui-icons/reload.svg", string),
	.Stop = #load("../resources/ui-icons/stop.svg", string),
	.Plus = #load("../resources/ui-icons/plus.svg", string),
	.Close = #load("../resources/ui-icons/close.svg", string),
	.Shield = #load("../resources/ui-icons/shield.svg", string),
	.Shield_On = #load("../resources/ui-icons/shield_on.svg", string),
	.Shield_Off = #load("../resources/ui-icons/shield_off.svg", string),
	.Download = #load("../resources/ui-icons/download.svg", string),
	.Layers = #load("../resources/ui-icons/layers.svg", string),
	.Search = #load("../resources/ui-icons/search.svg", string),
	.Sparkle = #load("../resources/ui-icons/sparkle.svg", string),
	.Globe = #load("../resources/ui-icons/globe.svg", string),
	.Warn = #load("../resources/ui-icons/warn.svg", string),
	.Mask = #load("../resources/ui-icons/mask.svg", string),
	.History = #load("../resources/ui-icons/history.svg", string),
	.Link = #load("../resources/ui-icons/link.svg", string),
	.Tab = #load("../resources/ui-icons/tab.svg", string),
	.Copy = #load("../resources/ui-icons/copy.svg", string),
	.Image = #load("../resources/ui-icons/image.svg", string),
	.Cut = #load("../resources/ui-icons/cut.svg", string),
	.Paste = #load("../resources/ui-icons/paste.svg", string),
	.Select_All = #load("../resources/ui-icons/select_all.svg", string),
	.Check = #load("../resources/ui-icons/check.svg", string),
	.Folder = #load("../resources/ui-icons/folder.svg", string),
	.Trash = #load("../resources/ui-icons/trash.svg", string),
	.Up = #load("../resources/ui-icons/up.svg", string),
	.Down = #load("../resources/ui-icons/down.svg", string),
	.Min = #load("../resources/ui-icons/min.svg", string),
	.Max = #load("../resources/ui-icons/max.svg", string),
	.Restore = #load("../resources/ui-icons/restore.svg", string),
	.Open = #load("../resources/ui-icons/open.svg", string),
	.Pin = #load("../resources/ui-icons/pin.svg", string),
	.Speaker = #load("../resources/ui-icons/speaker.svg", string),
	.Speaker_Off = #load("../resources/ui-icons/speaker_off.svg", string),
	.Reader = #load("../resources/ui-icons/reader.svg", string),
	.Split = #load("../resources/ui-icons/split.svg", string),
	.Compact = #load("../resources/ui-icons/compact.svg", string),
	.Expand = #load("../resources/ui-icons/expand.svg", string),
	.Command = #load("../resources/ui-icons/command.svg", string),
	.Eye = #load("../resources/ui-icons/eye.svg", string),
	.Grid = #load("../resources/ui-icons/grid.svg", string),
	.Lock = #load("../resources/ui-icons/lock.svg", string),
	.Dot = #load("../resources/ui-icons/dot.svg", string),
}

/// a container's icon: a dot in its colour (Mask for private tabs)
container_icon :: proc(name: string) -> Icon {
	return name == "private" ? .Mask : .Dot
}

Icon_Key :: struct {
	icon: Icon,
	px:   u16, // device pixels × 4
}

@(private="file") icon_slot :: proc(ic: Icon, px: f32) -> (Atlas_Slot, bool) {
	key := Icon_Key{ic, u16(px * 4)}
	if s, ok := atlas.icons[key]; ok do return s, true
	sv := svg_parse(ICON_SVG[ic])
	n := i32(math.ceil(px)) + 2
	r := raster_make(int(n), int(n))
	k := px / max(sv.view.z, 1)
	off := [2]f32{1, 1} - sv.view.xy * k
	for sh in sv.shapes {
		p := path_parse(sh.d, k)
		if sh.fill do raster_fill(&r, p, k, off)
		// a stroke never thinner than a pixel
		if sh.stroke do raster_stroke(&r, p, k, off, max(sh.width * k, 1.1))
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
