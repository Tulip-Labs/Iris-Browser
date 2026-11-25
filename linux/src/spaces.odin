// Workspaces, as in Zen: named sets of tabs. The strip shows the tabs of
// the one you are in; Alt+1…9 or the workspace chip switch. Home is the
// first and is always there; the others are kept in settings, and each
// tab remembers its own in the session. Nothing runs for them: a switch
// only changes which tabs are drawn and which one is on screen.
package iris

import "core:strings"
import "core:testing"

/// every workspace, Home first (temporary)
space_list :: proc() -> []Space {
	s := settings()
	out := make([]Space, len(s.spaces) + 1, context.temp_allocator)
	out[0] = {id = "", name = "Home"}
	for x, i in s.spaces do out[i + 1] = x
	return out
}

space_exists :: proc(id: string) -> bool {
	if id == "" do return true
	for x in settings().spaces do if x.id == id do return true
	return false
}

space_name :: proc(id: string) -> string {
	for x in space_list() do if x.id == id do return x.name
	return "Home"
}

/// the tabs of a workspace, in strip order (temporary)
space_tabs :: proc(id: string) -> []^Tab {
	out := make([dynamic]^Tab, context.temp_allocator)
	for t in b.tabs do if t.space == id do append(&out, t)
	return out[:]
}

/// the tabs the strip shows
visible_tabs :: proc() -> []^Tab { return space_tabs(b.space) }

/// to another workspace: the tab you had there comes back (or a new one)
space_switch :: proc(id: string) {
	if id == b.space || !space_exists(id) do return
	if b.current != nil do b.space_last[b.space] = b.current.id
	split_end()
	peek_close()
	set_str(&b.space, id)
	set_str(&settings().space, id)
	want := b.space_last[id] or_else 0
	tabs := space_tabs(id)
	pick: ^Tab
	for t in tabs do if t.id == want do pick = t
	if pick == nil && len(tabs) > 0 do pick = tabs[len(tabs) - 1]
	if pick == nil {
		browser_new_tab({select = true})
	} else {
		browser_select(pick)
	}
	browser_session_changed()
	chrome_push()
}

/// the next or previous workspace, round
space_cycle :: proc(d: int) {
	l := space_list()
	if len(l) < 2 do return
	for x, i in l do if x.id == b.space {
		space_switch(l[(i + d + len(l)) % len(l)].id)
		return
	}
}

space_add :: proc(name: string) -> string {
	s := settings()
	id := new_id()
	append(&s.spaces, Space{id = id, name = strings.clone(name)})
	settings_save()
	return id
}

/// a workspace goes; its tabs move to Home (nothing closes)
space_remove :: proc(id0: string) {
	if id0 == "" do return
	id := strings.clone(id0, context.temp_allocator)
	s := settings()
	stored := ""
	for x, i in s.spaces do if x.id == id {
		delete(x.name)
		stored = x.id
		ordered_remove(&s.spaces, i)
		break
	}
	defer delete(stored)
	for t in b.tabs do if t.space == id do set_str(&t.space, "")
	if b.space == id {
		set_str(&b.space, "")
		set_str(&s.space, "")
	}
	settings_save()
	chrome_push()
}

/// a tab to another workspace; the one you are in keeps a tab on screen
tab_move_to_space :: proc(t: ^Tab, id: string) {
	if t == nil || t.space == id || !space_exists(id) do return
	leaving := t == b.current
	if split_has(t) do split_end()
	set_str(&t.space, id)
	b.space_last[id] = t.id
	browser_session_changed()
	if leaving {
		rest := visible_tabs()
		if len(rest) > 0 {
			b.current = nil
			if t.page != nil do page_set_visible(t.page, false)
			browser_select(rest[len(rest) - 1])
		} else {
			if t.page != nil do page_set_visible(t.page, false)
			b.current = nil
			browser_new_tab({select = true})
		}
	}
	browser_toast(strings.concatenate({"Moved to ", space_name(id)}, context.temp_allocator))
	chrome_push()
}

/// the workspace a tab from the session goes back to (a removed one: Home)
space_for_saved :: proc(id: string) -> string {
	return space_exists(id) ? id : ""
}

@(test) test_spaces_list :: proc(t: ^testing.T) {
	l := space_list()
	testing.expect(t, len(l) >= 1)
	testing.expect_value(t, l[0].id, "")
	testing.expect_value(t, l[0].name, "Home")
	testing.expect(t, space_exists(""))
	testing.expect(t, !space_exists("no-such-space"))
}
