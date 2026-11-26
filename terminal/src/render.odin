// One frame: the glass, then the cells (backgrounds, selection, search
// matches, text, lines), the cursor with its glow, and the little chrome
// (container name, scroll position, search bar). All in device pixels, so
// everything lands on whole pixels and stays sharp at any scale.
package main

import "core:math"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import plat "../plat"
import term "../term"

FADE_MS :: 180
FLASH_MS :: 220

rgba :: #force_inline proc(c: term.RGB, a: u8 = 255) -> [4]u8 { return {c.r, c.g, c.b, a} }

@(private="file") cell_colors :: proc(a: ^App, c: term.Cell) -> (fg, bg: term.RGB, solid: bool) {
	t := &a.t
	fgc, bgc := c.fg, c.bg
	if a.cfg.bold_is_bright && term.has_attr(c, .Bold) && term.color_kind(fgc) == 1 && u32(fgc) & 0xff < 8 {
		fgc = term.Color(u32(fgc) + 8)
	}
	fg = term.resolve(t, fgc, true)
	bg = term.resolve(t, bgc, false)
	solid = !term.color_is_default(bgc)
	if (c.attr & term.A_REVERSE != 0) != t.modes.reverse {
		fg, bg = bg, fg
		solid = true
	}
	return
}

@(private="file") ui_glyph :: proc(r: rune, x, y: f32, col: [4]u8) -> f32 {
	fi := font_for_rune(r)
	if fi < 0 do return f32(fonts.cell_w)
	gid, ok := plain_glyph(fi, .Regular, r)
	if !ok do return f32(fonts.cell_w)
	if slot, _, ok2 := atlas_glyph(fi, .Regular, gid); ok2 && slot.w > 0 {
		push_quad(math.round(x + slot.ox), math.round(y + f32(fonts.baseline) + slot.oy), f32(slot.w), f32(slot.h), slot, col)
	}
	return f32(fonts.cell_w)
}

/// a line of interface text in the main font; returns its width
@(private="file") ui_text :: proc(s: string, x, y: f32, col: [4]u8, max_w: f32 = 1e9) -> f32 {
	cx := x
	for r in s {
		if cx + f32(fonts.cell_w) > x + max_w do break
		cx += ui_glyph(r, cx, y, col)
	}
	return cx - x
}

@(private="file") text_cells :: proc(s: string) -> int {
	n := 0
	for _ in s do n += 1
	return n
}

draw_frame :: proc(w: ^plat.Window) {
	a := cast(^App)w.user
	t := &a.t
	if !gfx.ready {
		if !gfx_init() {
			logf("could not set up drawing")
			a.quit = true
			return
		}
	}
	if a.atlas_stale || atlas.full {
		atlas_clear()
		a.atlas_stale = false
	}
	now := now_ms()
	// the animations: the fade-in, the bell
	fade := f32(1)
	if a.cfg.animations {
		fade = clamp(f32(now - a.start_ms) / FADE_MS, 0, 1)
		fade = 1 - (1 - fade) * (1 - fade)
	}
	flash := f32(0)
	if a.bell_ms != 0 && a.cfg.animations {
		f := 1 - f32(now - a.bell_ms) / FLASH_MS
		if f > 0 { flash = f * f }
	}
	animating := fade < 1 || flash > 0

	gl.ClearColor(0, 0, 0, 0)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	th := a.theme
	alpha := a.cfg.opacity
	if alpha < 0 do alpha = a.has_blur ? th.alpha_blur : th.alpha_plain
	radius := f32(a.cfg.radius) * f32(w.scale)
	if w.maximized || w.fullscreen || w.tiled do radius = 0
	pw, ph := f32(w.pixel_w), f32(w.pixel_h)
	draw_glass({
		w = pw, h = ph, tint = {f32(th.bg.r) / 255, f32(th.bg.g) / 255, f32(th.bg.b) / 255}, alpha = clamp(alpha, 0, 1),
		dark = th.dark, radius = radius, scale = f32(w.scale), rim = th.rim, flash = flash, fade = fade, focus = a.focused,
	})

	cw, ch := f32(fonts.cell_w), f32(fonts.cell_h)
	ox, oy := f32(a.ox), f32(a.oy)
	S := f32(w.scale)
	top_line := term.view_top_line(t)
	sel_a, sel_b, sel_ok := term.sel_range(t, a.sel, a.cfg.word_chars)
	if !term.sel_active(a.sel) do sel_ok = false
	cur_x, cur_y := t.cursor.x, t.cursor.y
	cursor_on := t.modes.cursor_visible && t.view == 0 && !a.exited && !a.offer
	style := t.cursor_style_set ? t.cursor_style : a.cfg.cursor

	// the cursor's glow, under everything
	if cursor_on && a.cfg.cursor_glow && a.focused {
		g := ch * 3.2
		push_quad(ox + (f32(cur_x) + 0.5) * cw - g / 2, oy + (f32(cur_y) + 0.5) * ch - g / 2, g, g, atlas.glow, rgba(t.cursor_color, 70))
	}

	run_cells := make([dynamic]term.Cell, 0, 256, context.temp_allocator)
	run_x := make([dynamic]int, 0, 256, context.temp_allocator)
	placed := make([dynamic]Placed, 0, 256, context.temp_allocator)
	sel_col := th.selection
	sel_rgba := [4]u8{u8(sel_col[0] * 255), u8(sel_col[1] * 255), u8(sel_col[2] * 255), u8(sel_col[3] * 255)}

	for y in 0 ..< t.rows {
		row := term.view_row(t, y)
		line := top_line + y
		py := oy + f32(y) * ch
		// ---- grounds, selection, lines
		x := 0
		for x < t.cols {
			c := term.cell_at(row, x)
			_, bg, solid := cell_colors(a, c)
			x0 := x
			x += 1
			for x < t.cols {
				c2 := term.cell_at(row, x)
				_, bg2, solid2 := cell_colors(a, c2)
				if solid2 != solid || (solid && bg2 != bg) do break
				x += 1
			}
			if solid do push_rect(ox + f32(x0) * cw, py, f32(x - x0) * cw, ch, rgba(bg))
		}
		if sel_ok {
			x = 0
			for x < t.cols {
				if !term.sel_contains(t, a.sel, sel_a, sel_b, line, x) {
					x += 1
					continue
				}
				x0 := x
				for x < t.cols && term.sel_contains(t, a.sel, sel_a, sel_b, line, x) do x += 1
				push_rect(ox + f32(x0) * cw, py, f32(x - x0) * cw, ch, sel_rgba)
			}
		}
		if a.searching && len(a.matches) > 0 {
			id := term.line_id(t, line)
			for m, i in a.matches {
				if m.line != id do continue
				col := i == a.cur_match ? [4]u8{255, 196, 70, 140} : [4]u8{255, 196, 70, 70}
				push_rect(ox + f32(m.col0) * cw, py, f32(m.col1 - m.col0 + 1) * cw, ch, col)
			}
		}
		// the cursor block sits under the text
		if cursor_on && y == cur_y && style == .Block && a.focused {
			push_rect(ox + f32(cur_x) * cw, py, cw * (term.has_attr(term.cell_at(row, cur_x), .Wide) ? 2 : 1), ch, rgba(t.cursor_color))
		}
		// ---- text
		x = 0
		for x < t.cols {
			c := term.cell_at(row, x)
			if c.attr & term.A_WIDE_CONT != 0 {
				x += 1
				continue
			}
			base := rune(c.ch & ~term.CLUSTER_BIT)
			if c.ch & term.CLUSTER_BIT != 0 {
				buf: [7]rune
				rs := term.cell_runes(t, c, &buf)
				base = len(rs) > 0 ? rs[0] : ' '
			}
			hidden := term.has_attr(c, .Hidden)
			if base == ' ' || base == 0 || hidden {
				x += 1
				continue
			}
			fg, _, _ := cell_colors(a, c)
			on_cursor := cursor_on && a.focused && style == .Block && y == cur_y && x == cur_x
			if on_cursor do fg = th.bg
			alpha_fg := term.has_attr(c, .Dim) ? u8(150) : u8(255)
			if c.ch & term.CLUSTER_BIT == 0 && term.is_special_glyph(base) {
				wcells := term.has_attr(c, .Wide) ? 2 : 1
				if s, ok := atlas_special(base, int(cw) * wcells, int(ch)); ok {
					push_quad(ox + f32(x) * cw, py, f32(s.w), f32(s.h), s, rgba(fg, alpha_fg))
				}
				x += 1
				continue
			}
			st: Style = .Regular
			bold, ital := term.has_attr(c, .Bold), term.has_attr(c, .Italic)
			if bold && ital { st = .Bold_Italic } else if bold { st = .Bold } else if ital { st = .Italic }
			fi := font_for_rune(base)
			if fi < 0 {
				x += 1
				continue
			}
			// a run of the same font and style
			clear(&run_cells)
			clear(&run_x)
			clear(&placed)
			for x < t.cols {
				c2 := term.cell_at(row, x)
				if c2.attr & term.A_WIDE_CONT != 0 {
					x += 1
					continue
				}
				b2 := rune(c2.ch & ~term.CLUSTER_BIT)
				if c2.ch & term.CLUSTER_BIT != 0 {
					buf: [7]rune
					rs := term.cell_runes(t, c2, &buf)
					b2 = len(rs) > 0 ? rs[0] : ' '
				}
				if b2 == ' ' || b2 == 0 || term.has_attr(c2, .Hidden) do break
				if c2.ch & term.CLUSTER_BIT == 0 && term.is_special_glyph(b2) do break
				b, i := term.has_attr(c2, .Bold), term.has_attr(c2, .Italic)
				st2: Style = .Regular
				if b && i { st2 = .Bold_Italic } else if b { st2 = .Bold } else if i { st2 = .Italic }
				if st2 != st || font_for_rune(b2) != fi do break
				append(&run_cells, c2)
				append(&run_x, x)
				x += 1
			}
			if len(run_cells) == 0 {
				x += 1
				continue
			}
			shape_run(fi, st, run_cells[:], t, &placed)
			for p in placed {
				if p.col >= len(run_x) do continue
				cx := run_x[p.col]
				cc := run_cells[p.col]
				gfg, _, _ := cell_colors(a, cc)
				if cursor_on && a.focused && style == .Block && y == cur_y && cx == cur_x do gfg = th.bg
				slot, _, ok := atlas_glyph(p.fi, p.style, p.gid)
				if !ok || slot.w == 0 do continue
				gx := math.round(ox + f32(cx) * cw + p.dx + slot.ox)
				gy := math.round(py + f32(fonts.baseline) + p.dy + slot.oy)
				push_quad(gx, gy, f32(slot.w), f32(slot.h), slot, rgba(gfg, term.has_attr(cc, .Dim) ? 150 : 255))
			}
		}
		// ---- underlines, strikes, the link under the pointer
		for cx in 0 ..< t.cols {
			c := term.cell_at(row, cx)
			ul := term.cell_underline(c)
			strike := term.has_attr(c, .Strike)
			over := term.has_attr(c, .Overline)
			hov := a.hover_ok && link_contains(a, line, cx)
			if ul == .None && !strike && !over && !hov do continue
			fg, _, _ := cell_colors(a, c)
			col := rgba(fg, term.has_attr(c, .Dim) ? 150 : 255)
			x0, wd := ox + f32(cx) * cw, cw
			uy := py + f32(fonts.ul_pos)
			th_px := f32(fonts.ul_th)
			if hov && ul == .None do ul = .Single
			switch ul {
			case .None:
			case .Single: push_rect(x0, uy, wd, th_px, col)
			case .Double:
				push_rect(x0, uy - th_px, wd, th_px, col)
				push_rect(x0, uy + th_px, wd, th_px, col)
			case .Curly:
				for i in 0 ..< int(wd) {
					off := math.round(math.sin((f32(cx * int(wd) + i) / cw) * 2 * math.PI) * f32(fonts.ul_th) * 1.2)
					push_rect(x0 + f32(i), uy + off, 1, th_px, col)
				}
			case .Dotted:
				for i := 0; i < int(wd); i += max(2 * fonts.ul_th, 2) do push_rect(x0 + f32(i), uy, th_px, th_px, col)
			case .Dashed:
				push_rect(x0, uy, wd * 0.6, th_px, col)
			}
			if strike do push_rect(x0, py + f32(fonts.strike_pos), wd, th_px, col)
			if over do push_rect(x0, py, wd, th_px, col)
		}
	}

	// ---- the cursor, when it is not a block over text
	if cursor_on {
		cx, cy := ox + f32(cur_x) * cw, oy + f32(cur_y) * ch
		cc := rgba(t.cursor_color)
		thick := max(f32(math.round(S * 1.5)), 1)
		if !a.focused {
			// an outline, whatever the style
			push_rect(cx, cy, cw, thick, cc)
			push_rect(cx, cy + ch - thick, cw, thick, cc)
			push_rect(cx, cy, thick, ch, cc)
			push_rect(cx + cw - thick, cy, thick, ch, cc)
		} else {
			switch style {
			case .Block:
			case .Bar: push_rect(cx, cy, thick, ch, cc)
			case .Underline: push_rect(cx, cy + ch - thick, cw, thick, cc)
			}
		}
	}

	draw_chrome(a, pw, ph)
	gamma := th.dark ? f32(0.82) : f32(1.0)
	draw_quads(pw, ph, gamma, fade)

	if a.finishing && a.opt.dump_frame != "" && !a.frame_dumped && !animating && finish_ready(a) {
		dump_frame(a, w.pixel_w, w.pixel_h)
		a.frame_dumped = true
	}
	if a.finishing && !animating && (a.opt.dump_frame == "" || a.frame_dumped) do a.quit = true
	if animating do w.dirty = true
	if atlas.full do w.dirty = true
}

/// the app is ready for the frame that is dumped (the last output is in)
finish_ready :: proc(a: ^App) -> bool { return a.exited }

@(private="file") link_contains :: proc(a: ^App, line, col: int) -> bool {
	h := a.hover
	if line < h[0] || line > h[2] do return false
	if line == h[0] && col < h[1] do return false
	if line == h[2] && col > h[3] do return false
	return true
}

// ---------------------------------------------------------------- the chrome

@(private="file") draw_chrome :: proc(a: ^App, pw, ph: f32) {
	t := &a.t
	th := a.theme
	S := f32(a.win.scale)
	cw, ch := f32(fonts.cell_w), f32(fonts.cell_h)
	ink := th.fg
	// the container, in the top bar
	if a.container != "" {
		y := f32(a.pad) * 0.5
		isz := int(ch * 0.8)
		if s, ok := atlas_icon(.Container, isz); ok do push_quad(f32(a.pad), y + (ch - f32(isz)) / 2, f32(s.w), f32(s.h), s, rgba(ink, 230))
		x := f32(a.pad) + f32(isz) + cw * 0.6
		nw := ui_text(a.container, x, y, rgba(ink, 235))
		title := t.title
		if title != "" {
			tx := x + nw + cw * 1.5
			avail := pw - tx - f32(a.pad)
			if avail > cw * 4 {
				n := min(text_cells(title), int(avail / cw))
				// right-aligned, dim
				tw := f32(n) * cw
				_ = ui_text(title, pw - f32(a.pad) - tw, y, rgba(ink, 110), tw)
			}
		}
	}
	// where we are in the history
	if t.view > 0 && t.sb.count > 0 && !t.modes.alt_screen {
		total := f32(t.sb.count + t.rows)
		bh := max(f32(t.rows) / total * (ph - f32(a.oy) - f32(a.pad)), 18 * S)
		track := ph - f32(a.oy) - f32(a.pad) - bh
		frac := 1 - f32(t.view) / f32(t.sb.count)
		bw := max(f32(math.round(3 * S)), 2)
		if s, ok := atlas_pill(int(bw), int(bh), int(bw / 2)); ok {
			push_quad(pw - bw - max(S * 4, 3), f32(a.oy) + track * frac, f32(s.w), f32(s.h), s, rgba(ink, 90))
		}
	}
	// the search bar
	if a.searching {
		bh := ch + 12 * S
		bw := min(cw * 38, pw - f32(a.pad) * 2)
		bx := pw - f32(a.pad) - bw
		by := f32(a.oy) + 4 * S
		rad := int(bh / 2)
		if s, ok := atlas_pill(int(bw) + int(2 * S), int(bh) + int(2 * S), rad + 1); ok do push_quad(bx - S, by - S, f32(s.w), f32(s.h), s, rgba(ink, 46))
		if s, ok := atlas_pill(int(bw), int(bh), rad); ok do push_quad(bx, by, f32(s.w), f32(s.h), s, rgba(th.bg, 236))
		isz := int(ch * 0.78)
		ix := bx + bh * 0.5
		if s, ok := atlas_icon(.Search, isz); ok do push_quad(ix, by + (bh - f32(isz)) / 2, f32(s.w), f32(s.h), s, rgba(ink, 170))
		tx := ix + f32(isz) + cw * 0.6
		count := ""
		if len(a.query) > 0 {
			count = len(a.matches) == 0 ? "0" : strings.concatenate({itoa(a.cur_match + 1), "/", itoa(len(a.matches))}, context.temp_allocator)
		}
		cwid := f32(text_cells(count)) * cw
		avail := bx + bw - bh * 0.5 - cwid - cw - tx
		qw := ui_text(string(a.query[:]), tx, by + 6 * S, rgba(ink), avail)
		push_rect(tx + qw + 1, by + 6 * S + 2 * S, max(f32(math.round(S)), 1), ch - 4 * S, rgba(ink, 200))
		if count != "" do ui_text(count, bx + bw - bh * 0.5 - cwid, by + 6 * S, rgba(ink, 130))
	}
}

// ---------------------------------------------------------------- test: the frame as a picture

@(private="file") dump_frame :: proc(a: ^App, w, h: i32) {
	px := make([]u8, int(w) * int(h) * 4, context.temp_allocator)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(px))
	// the rows come bottom up
	flipped := make([]u8, len(px), context.temp_allocator)
	for y in 0 ..< int(h) do copy(flipped[y * int(w) * 4:][:int(w) * 4], px[(int(h) - 1 - y) * int(w) * 4:][:int(w) * 4])
	hdr := strings.concatenate({"P7\nWIDTH ", itoa(int(w)), "\nHEIGHT ", itoa(int(h)), "\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"}, context.temp_allocator)
	all := make([]u8, len(hdr) + len(flipped), context.temp_allocator)
	copy(all, transmute([]u8)hdr)
	copy(all[len(hdr):], flipped)
	if err := os.write_entire_file(a.opt.dump_frame, all); err != nil do logf("could not write the frame")
}
