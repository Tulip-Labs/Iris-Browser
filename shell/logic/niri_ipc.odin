// niri's IPC, as the shell reads it: one JSON value per line from the
// event stream (the reply to "EventStream" is {"Ok":"Handled"}, then one
// event per line, each an object with one key: the event's name).
package logic

import "core:encoding/json"

EVENT_STREAM_REQUEST :: "\"EventStream\"\n"

@(private) get :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	o, ok := v.(json.Object)
	if !ok do return nil, false
	r, has := o[key]
	return r, has
}

@(private) num :: proc(v: json.Value) -> (f32, bool) {
	#partial switch x in v {
	case json.Integer: return f32(x), true
	case json.Float: return f32(x), true
	}
	return 0, false
}

@(private) uint_of :: proc(v: json.Value) -> (u64, bool) {
	#partial switch x in v {
	case json.Integer: return u64(x), x >= 0
	}
	return 0, false
}

@(private) pair :: proc(v: json.Value) -> (a, b: f32, ok: bool) {
	arr, is_arr := v.(json.Array)
	if !is_arr || len(arr) != 2 do return
	x, ok1 := num(arr[0])
	y, ok2 := num(arr[1])
	return x, y, ok1 && ok2
}

@(private) str :: proc(v: json.Value) -> string {
	if s, ok := v.(json.String); ok do return string(s)
	return ""
}

@(private) bool_of :: proc(v: json.Value) -> bool {
	b, _ := v.(json.Boolean)
	return bool(b)
}

/// the window's rectangle in its workspace view, from a "layout" object
/// (niri 25.11 and newer): the tile's position plus the window's offset in
/// the tile, and the window's size. A floating window has no tile position.
@(private) layout_rect :: proc(layout: json.Value) -> (r: Rect, ok: bool) {
	pos, has_pos := get(layout, "tile_pos_in_workspace_view")
	if !has_pos do return
	px, py, pok := pair(pos)
	if !pok do return
	size, has_size := get(layout, "window_size")
	if !has_size do return
	w, h, sok := pair(size)
	if !sok do return
	ox, oy: f32
	if off, has_off := get(layout, "window_offset_in_tile"); has_off {
		ox, oy, _ = pair(off)
	}
	return Rect{px + ox, py + oy, w, h}, true
}

/// a window as the IPC lists it (strings point into the parsed JSON)
parse_window :: proc(v: json.Value) -> (w: Window, ok: bool) {
	idv, has_id := get(v, "id")
	if !has_id do return {}, false
	if w.id, ok = uint_of(idv); !ok do return {}, false
	if t, has := get(v, "title"); has do w.title = str(t)
	if t, has := get(v, "app_id"); has do w.app_id = str(t)
	if t, has := get(v, "workspace_id"); has do w.ws_id, _ = uint_of(t)
	if t, has := get(v, "is_focused"); has do w.focused = bool_of(t)
	if t, has := get(v, "is_floating"); has do w.floating = bool_of(t)
	if l, has := get(v, "layout"); has {
		w.rect, w.has_rect = layout_rect(l)
	}
	return w, true
}

/// one line of the event stream; false for an event the shell does not use
/// (and for a reply line). Everything it returns lives in `allocator`.
parse_event :: proc(line: string, allocator := context.temp_allocator) -> (ev: Event, ok: bool) {
	root, err := json.parse(transmute([]byte)line, .JSON, true, allocator)
	if err != .None do return nil, false
	o, is_obj := root.(json.Object)
	if !is_obj || len(o) != 1 do return nil, false
	for name, body in o {
		switch name {
		case "WindowsChanged":
			list, _ := get(body, "windows")
			arr, _ := list.(json.Array)
			ws := make([]Window, len(arr), allocator)
			n := 0
			for item in arr {
				if w, good := parse_window(item); good {
					ws[n] = w
					n += 1
				}
			}
			return Ev_Windows{ws[:n]}, true
		case "WindowOpenedOrChanged":
			item, _ := get(body, "window")
			w, good := parse_window(item)
			return Ev_Window{w}, good
		case "WindowClosed":
			idv, _ := get(body, "id")
			id, good := uint_of(idv)
			return Ev_Closed{id}, good
		case "WindowFocusChanged":
			idv, _ := get(body, "id")
			id, good := uint_of(idv)
			return Ev_Focus{id, good}, true
		case "WorkspacesChanged":
			list, _ := get(body, "workspaces")
			arr, _ := list.(json.Array)
			ws := make([]Workspace, len(arr), allocator)
			n := 0
			for item in arr {
				idv, _ := get(item, "id")
				id, good := uint_of(idv)
				if !good do continue
				out, _ := get(item, "output")
				act, _ := get(item, "is_active")
				ws[n] = Workspace{id, str(out), bool_of(act)}
				n += 1
			}
			return Ev_Workspaces{ws[:n]}, true
		case "WorkspaceActivated":
			idv, _ := get(body, "id")
			id, good := uint_of(idv)
			return Ev_Ws_Active{id}, good
		case "WindowLayoutsChanged":
			list, _ := get(body, "changes")
			arr, _ := list.(json.Array)
			cs := make([]Layout_Change, len(arr), allocator)
			n := 0
			for item in arr {
				pr, is_arr := item.(json.Array)
				if !is_arr || len(pr) != 2 do continue
				id, good := uint_of(pr[0])
				if !good do continue
				r, has := layout_rect(pr[1])
				cs[n] = Layout_Change{id, has, r}
				n += 1
			}
			return Ev_Layouts{cs[:n]}, true
		case "OverviewOpenedOrClosed":
			open, _ := get(body, "is_open")
			return Ev_Overview{bool_of(open)}, true
		}
	}
	return nil, false
}
