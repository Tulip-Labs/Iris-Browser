// A small SVG reader for Iris's own icons (resources/ui-icons): the
// viewBox, and each <path>, <circle> and <rect> as path data with its fill
// and stroke (inherited from <svg>). The paths (M, L, H, V, C, S, Q, T, A,
// Z) go to raster.odin, which fills and strokes them with round caps.
// Nothing more of SVG: no transforms, groups, styles or text.
package iris

import "core:fmt"
import "core:strconv"
import "core:strings"

Svg_Shape :: struct {
	d:            string,
	fill, stroke: bool,
	width:        f32,
}

Svg :: struct {
	view:   [4]f32,
	shapes: [dynamic]Svg_Shape,
}

/// an attribute's value in a tag's text ("" and false when it has none)
@(private="file") attr :: proc(tag, name: string) -> (string, bool) {
	rest := tag
	for {
		i := strings.index(rest, name)
		if i < 0 do return "", false
		before := i > 0 ? rest[i - 1] : ' '
		after := rest[i + len(name):]
		if (before == ' ' || before == '\n' || before == '\t') && strings.has_prefix(after, "=\"") {
			v := after[2:]
			e := strings.index_byte(v, '"')
			if e < 0 do return "", false
			return v[:e], true
		}
		rest = rest[i + len(name):]
	}
}

@(private="file") num_attr :: proc(tag, name: string, def: f32 = 0) -> f32 {
	v, ok := attr(tag, name)
	if !ok do return def
	f, fok := strconv.parse_f32(strings.trim_space(v))
	return fok ? f : def
}

/// paint: "none" is none; anything else (a colour, currentColor) paints,
/// in the colour the icon is drawn in
@(private="file") paints :: proc(tag: string, name: string, inherited: bool) -> bool {
	v, ok := attr(tag, name)
	if !ok do return inherited
	return v != "none"
}

svg_parse :: proc(src: string, allocator := context.temp_allocator) -> (s: Svg) {
	s.shapes = make([dynamic]Svg_Shape, allocator)
	s.view = {0, 0, 24, 24}
	fill, stroke := true, false // SVG's own defaults
	width: f32 = 1
	rest := src
	for {
		i := strings.index_byte(rest, '<')
		if i < 0 do break
		rest = rest[i + 1:]
		e := strings.index_byte(rest, '>')
		if e < 0 do break
		tag := rest[:e]
		rest = rest[e + 1:]
		name_end := strings.index_any(tag, " \n\t/")
		name := name_end < 0 ? tag : tag[:name_end]
		switch name {
		case "svg":
			if vb, ok := attr(tag, "viewBox"); ok {
				parts := strings.fields(vb, context.temp_allocator)
				if len(parts) == 4 do for p, k in parts {
					f, _ := strconv.parse_f32(p)
					s.view[k] = f
				}
			}
			fill = paints(tag, "fill", fill)
			stroke = paints(tag, "stroke", stroke)
			width = num_attr(tag, "stroke-width", width)
		case "path", "circle", "rect":
			d: string
			switch name {
			case "path":
				d, _ = attr(tag, "d")
			case "circle":
				cx, cy, r := num_attr(tag, "cx"), num_attr(tag, "cy"), num_attr(tag, "r")
				d = fmt.aprintf("M%v %vA%v %v 0 1 0 %v %vA%v %v 0 1 0 %v %vZ", cx - r, cy, r, r, cx + r, cy, r, r, cx - r, cy, allocator = allocator)
			case "rect":
				x, y := num_attr(tag, "x"), num_attr(tag, "y")
				w, h := num_attr(tag, "width"), num_attr(tag, "height")
				rx := min(num_attr(tag, "rx"), w / 2, h / 2)
				if rx <= 0 {
					d = fmt.aprintf("M%v %vH%vV%vH%vZ", x, y, x + w, y + h, x, allocator = allocator)
				} else {
					d = fmt.aprintf("M%v %vH%vA%v %v 0 0 1 %v %vV%vA%v %v 0 0 1 %v %vH%vA%v %v 0 0 1 %v %vV%vA%v %v 0 0 1 %v %vZ",
						x + rx, y, x + w - rx, rx, rx, x + w, y + rx, y + h - rx, rx, rx, x + w - rx, y + h,
						x + rx, rx, rx, x, y + h - rx, y + rx, rx, rx, x + rx, y, allocator = allocator)
				}
			}
			if len(d) == 0 do continue
			append(&s.shapes, Svg_Shape{d = d, fill = paints(tag, "fill", fill), stroke = paints(tag, "stroke", stroke), width = num_attr(tag, "stroke-width", width)})
		}
	}
	return
}
