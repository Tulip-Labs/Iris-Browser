// What niri says about windows and workspaces, kept as a small model: only
// what the shell draws from (id, app id, title, workspace, where the window
// is). Strings are owned by the model (cloned in model_apply).
package logic

import "core:strings"

Rect :: struct {
	x, y, w, h: f32,
}

Rgb :: [3]f32

Window :: struct {
	id:          u64,
	title:       string,
	app_id:      string,
	ws_id:       u64,
	focused:     bool,
	floating:    bool,
	has_rect:    bool,
	/// the window in its workspace view, logical pixels
	rect:        Rect,
	/// a colour read from the window's own pixels (capture), when there is one
	has_sampled: bool,
	sampled:     Rgb,
}

Workspace :: struct {
	id:     u64,
	output: string,
	active: bool,
}

Layout_Change :: struct {
	id:       u64,
	has_rect: bool,
	rect:     Rect,
}

Ev_Windows :: struct { windows: []Window }
Ev_Window :: struct { window: Window }
Ev_Closed :: struct { id: u64 }
Ev_Focus :: struct { id: u64, any: bool }
Ev_Workspaces :: struct { workspaces: []Workspace }
Ev_Ws_Active :: struct { id: u64 }
Ev_Layouts :: struct { changes: []Layout_Change }
Ev_Overview :: struct { open: bool }

Event :: union {
	Ev_Windows,
	Ev_Window,
	Ev_Closed,
	Ev_Focus,
	Ev_Workspaces,
	Ev_Ws_Active,
	Ev_Layouts,
	Ev_Overview,
}

Model :: struct {
	windows:    [dynamic]Window,
	workspaces: [dynamic]Workspace,
	overview:   bool,
}

@(private) own_window :: proc(w: Window) -> Window {
	c := w
	c.title = strings.clone(w.title)
	c.app_id = strings.clone(w.app_id)
	return c
}

@(private) free_window :: proc(w: Window) {
	delete(w.title)
	delete(w.app_id)
}

model_destroy :: proc(m: ^Model) {
	for w in m.windows do free_window(w)
	for w in m.workspaces do delete(w.output)
	delete(m.windows)
	delete(m.workspaces)
	m^ = {}
}

model_find :: proc(m: ^Model, id: u64) -> int {
	for w, i in m.windows do if w.id == id do return i
	return -1
}

/// applies one event. It reports whether the model changed in a way the
/// picture can depend on (the caller still compares scenes: this is only a
/// cheap first filter).
model_apply :: proc(m: ^Model, ev: Event) -> bool {
	switch e in ev {
	case Ev_Windows:
		// the whole list: windows that stay keep what capture learned
		old := m.windows
		m.windows = make([dynamic]Window, 0, len(e.windows))
		for w in e.windows {
			n := own_window(w)
			for o in old {
				if o.id == w.id {
					n.has_sampled, n.sampled = o.has_sampled, o.sampled
					if !w.has_rect do n.has_rect, n.rect = o.has_rect, o.rect
					break
				}
			}
			append(&m.windows, n)
		}
		for o in old do free_window(o)
		delete(old)
	case Ev_Window:
		n := own_window(e.window)
		if i := model_find(m, e.window.id); i >= 0 {
			o := m.windows[i]
			n.has_sampled, n.sampled = o.has_sampled, o.sampled
			if !n.has_rect do n.has_rect, n.rect = o.has_rect, o.rect
			// another title: what it showed is not what it shows
			if o.title != n.title do n.has_sampled = false
			free_window(o)
			m.windows[i] = n
		} else {
			append(&m.windows, n)
		}
		if e.window.focused do for &w in m.windows do w.focused = w.id == e.window.id
	case Ev_Closed:
		if i := model_find(m, e.id); i >= 0 {
			free_window(m.windows[i])
			ordered_remove(&m.windows, i)
		}
	case Ev_Focus:
		for &w in m.windows do w.focused = e.any && w.id == e.id
	case Ev_Workspaces:
		for w in m.workspaces do delete(w.output)
		clear(&m.workspaces)
		for w in e.workspaces do append(&m.workspaces, Workspace{w.id, strings.clone(w.output), w.active})
	case Ev_Ws_Active:
		out := ""
		for w in m.workspaces do if w.id == e.id do out = w.output
		for &w in m.workspaces {
			if w.output == out do w.active = w.id == e.id
		}
	case Ev_Layouts:
		for c in e.changes {
			if i := model_find(m, c.id); i >= 0 {
				m.windows[i].has_rect, m.windows[i].rect = c.has_rect, c.rect
			}
		}
	case Ev_Overview:
		m.overview = e.open
	}
	return true
}

/// the colour capture read from this window's pixels
model_set_sampled :: proc(m: ^Model, id: u64, c: Rgb) {
	if i := model_find(m, id); i >= 0 do m.windows[i].has_sampled, m.windows[i].sampled = true, c
}

/// the workspace of this output that is on screen (id 0: none known)
active_workspace :: proc(m: ^Model, output: string) -> u64 {
	for w in m.workspaces do if w.output == output && w.active do return w.id
	return 0
}
