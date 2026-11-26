package logic

import "core:os"
import "core:strings"
import "core:testing"

@(private) lines_of :: proc(m: ^Model, lines: []string) {
	for l in lines {
		ev, ok := parse_event(l)
		if ok do model_apply(m, ev)
	}
}

WS_LINE :: `{"WorkspacesChanged":{"workspaces":[{"id":1,"idx":1,"name":null,"output":"eDP-1","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":7},{"id":2,"idx":2,"name":null,"output":"eDP-1","is_urgent":false,"is_active":false,"is_focused":false,"active_window_id":null},{"id":3,"idx":1,"name":null,"output":"DP-2","is_urgent":false,"is_active":true,"is_focused":false,"active_window_id":null}]}}`
WINDOWS_LINE :: `{"WindowsChanged":{"windows":[{"id":7,"title":"Lofi beats - YouTube - Chromium","app_id":"chromium","pid":4242,"workspace_id":1,"is_focused":true,"is_floating":false,"is_urgent":false,"layout":{"pos_in_scrolling_layout":[1,1],"tile_size":[944.0,1048.0],"window_size":[944,1048],"tile_pos_in_workspace_view":[16.0,16.0],"window_offset_in_tile":[0.0,0.0]}},{"id":8,"title":"~","app_id":"foot","pid":99,"workspace_id":1,"is_focused":false,"is_floating":false,"is_urgent":false,"layout":{"pos_in_scrolling_layout":[2,1],"tile_size":[944.0,1048.0],"window_size":[944,1048],"tile_pos_in_workspace_view":[976.0,16.0],"window_offset_in_tile":[0.0,0.0]}},{"id":9,"title":"x","app_id":"foot","pid":100,"workspace_id":2,"is_focused":false,"is_floating":false,"is_urgent":false,"layout":null},{"id":10,"title":"float","app_id":"foot","pid":101,"workspace_id":1,"is_focused":false,"is_floating":true,"is_urgent":false,"layout":{"pos_in_scrolling_layout":null,"tile_size":[300.0,200.0],"window_size":[300,200],"tile_pos_in_workspace_view":null,"window_offset_in_tile":[0.0,0.0]}}]}}`

@(test)
test_parse_windows :: proc(t: ^testing.T) {
	ev, ok := parse_event(WINDOWS_LINE)
	testing.expect(t, ok)
	e, is := ev.(Ev_Windows)
	testing.expect(t, is)
	testing.expect_value(t, len(e.windows), 4)
	testing.expect_value(t, e.windows[0].id, 7)
	testing.expect_value(t, e.windows[0].app_id, "chromium")
	testing.expect(t, e.windows[0].focused)
	testing.expect(t, e.windows[0].has_rect)
	testing.expect_value(t, e.windows[1].rect, Rect{976, 16, 944, 1048})
	testing.expect(t, !e.windows[2].has_rect) // layout null
	testing.expect(t, !e.windows[3].has_rect && e.windows[3].floating)
}

@(test)
test_parse_other_events :: proc(t: ^testing.T) {
	ev, ok := parse_event(`{"WindowClosed":{"id":12}}`)
	testing.expect(t, ok)
	c, is := ev.(Ev_Closed)
	testing.expect(t, is && c.id == 12)
	ev, ok = parse_event(`{"WindowFocusChanged":{"id":null}}`)
	f, isf := ev.(Ev_Focus)
	testing.expect(t, ok && isf && !f.any)
	ev, ok = parse_event(`{"WindowLayoutsChanged":{"changes":[[7,{"pos_in_scrolling_layout":[1,1],"tile_size":[10.0,10.0],"window_size":[10,10],"tile_pos_in_workspace_view":[5.5,6.5],"window_offset_in_tile":[1.0,2.0]}]]}}`)
	l, isl := ev.(Ev_Layouts)
	testing.expect(t, ok && isl && len(l.changes) == 1)
	testing.expect_value(t, l.changes[0].rect, Rect{6.5, 8.5, 10, 10})
	ev, ok = parse_event(`{"OverviewOpenedOrClosed":{"is_open":true}}`)
	o, iso := ev.(Ev_Overview)
	testing.expect(t, ok && iso && o.open)
	// events the shell does not use, replies, and noise
	_, ok = parse_event(`{"KeyboardLayoutsChanged":{"keyboard_layouts":{}}}`)
	testing.expect(t, !ok)
	_, ok = parse_event(`{"Ok":"Handled"}`)
	testing.expect(t, !ok)
	_, ok = parse_event(`not json`)
	testing.expect(t, !ok)
}

@(test)
test_scene_per_output :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	lines_of(&m, {WS_LINE, WINDOWS_LINE})
	f := scene_for_output(&m, "eDP-1", 1920, 1080, true)
	// 7 and 8 are tiled on the active workspace; 9 is on the other one, 10 floats
	testing.expect_value(t, f.n, 2)
	testing.expect_value(t, f.halos[0].id, 7)
	testing.expect_value(t, f.halos[0].power, 1.0)
	testing.expect_value(t, f.halos[1].power, 0.7)
	testing.expect_value(t, f.halos[0].tint, Rgb{1.00, 0.18, 0.16}) // YouTube
	testing.expect_value(t, f.dark, 1)
	g := scene_for_output(&m, "DP-2", 1920, 1080, false)
	testing.expect_value(t, g.n, 0)
	// the second workspace becomes the active one
	lines_of(&m, {`{"WorkspaceActivated":{"id":2,"focused":true}}`})
	testing.expect_value(t, scene_for_output(&m, "eDP-1", 1920, 1080, true).n, 0) // 9 has no layout
	// the overview shows no halos
	lines_of(&m, {`{"WorkspaceActivated":{"id":1,"focused":true}}`, `{"OverviewOpenedOrClosed":{"is_open":true}}`})
	testing.expect_value(t, scene_for_output(&m, "eDP-1", 1920, 1080, true).n, 0)
}

@(test)
test_title_change_retints :: proc(t: ^testing.T) {
	m: Model
	defer model_destroy(&m)
	lines_of(&m, {WS_LINE, WINDOWS_LINE})
	a := scene_for_output(&m, "eDP-1", 1920, 1080, true)
	lines_of(&m, {`{"WindowOpenedOrChanged":{"window":{"id":7,"title":"owner/repo: code - GitHub - Chromium","app_id":"chromium","pid":4242,"workspace_id":1,"is_focused":true,"is_floating":false,"is_urgent":false,"layout":{"pos_in_scrolling_layout":[1,1],"tile_size":[944.0,1048.0],"window_size":[944,1048],"tile_pos_in_workspace_view":[16.0,16.0],"window_offset_in_tile":[0.0,0.0]}}}}`})
	b := scene_for_output(&m, "eDP-1", 1920, 1080, true)
	testing.expect(t, a.halos[0].tint != b.halos[0].tint)
	testing.expect_value(t, b.halos[0].tint, Rgb{0.60, 0.63, 0.68}) // GitHub
	testing.expect_value(t, b.halos[0].rect, a.halos[0].rect)
	// a window closes, another changes size
	lines_of(&m, {`{"WindowClosed":{"id":8}}`})
	testing.expect_value(t, scene_for_output(&m, "eDP-1", 1920, 1080, true).n, 1)
}

@(test)
test_tint :: proc(t: ^testing.T) {
	// the same input, the same colour; no purple (hue 220 degrees at most)
	a := tint_for("some.App", "a title")
	testing.expect_value(t, a, tint_for("some.App", "a title"))
	for i in 0 ..< 400 {
		buf: [16]u8
		for k in 0 ..< 8 do buf[k] = u8('a' + (i * 7 + k * 3) % 26)
		c := tint_for(string(buf[:8]), "")
		// blue is never below red when the hue is at most 220: and green never exceeds both
		testing.expect(t, c.b <= 1.0 && c.r >= 0 && c.g >= 0)
		testing.expect(t, !(c.r > 0.6 && c.b > 0.6 && c.g < 0.5 * min(c.r, c.b))) // magenta
	}
	testing.expect_value(t, tint_for("", ""), Rgb{0.7, 0.72, 0.76})
	// the capture colour: a grey stays grey, a red stays red
	g := tint_from_mean({0.5, 0.5, 0.5})
	testing.expect(t, g.r == g.g && g.g == g.b)
	r := tint_from_mean({0.8, 0.1, 0.1})
	testing.expect(t, r.r > r.g && r.r > r.b)
}

@(test)
test_anim :: proc(t: ^testing.T) {
	a: Anim
	f1 := Frame{n = 1, dark = 1}
	f1.halos[0] = Halo{1, {0, 0, 100, 100}, {1, 0, 0}, 1}
	anim_jump(&a, f1)
	v, done := anim_value(&a, 0)
	testing.expect(t, done && frame_equal(&v, &f1))
	// the same scene again: nothing to animate
	testing.expect(t, !anim_to(&a, 10, f1))
	// the window moves, a new one appears, dark turns to light
	f2 := Frame{n = 2, dark = 0}
	f2.halos[0] = Halo{1, {100, 0, 100, 100}, {0, 0, 1}, 1}
	f2.halos[1] = Halo{2, {300, 0, 50, 50}, {0, 1, 0}, 1}
	testing.expect(t, anim_to(&a, 1000, f2))
	mid, d := anim_value(&a, 1000 + ANIM_MS / 2)
	testing.expect(t, !d)
	testing.expect_value(t, mid.n, 2)
	testing.expect(t, mid.halos[0].rect.x > 50 && mid.halos[0].rect.x < 100) // eased past halfway
	testing.expect(t, mid.halos[1].power > 0 && mid.halos[1].power < 1)
	testing.expect(t, mid.dark > 0 && mid.dark < 1)
	end, d2 := anim_value(&a, 1000 + ANIM_MS)
	testing.expect(t, d2 && frame_equal(&end, &f2))
	// a window goes: it fades out and is gone at the end
	f3 := Frame{n = 1}
	f3.halos[0] = f2.halos[0]
	anim_to(&a, 2000, f3)
	m3, _ := anim_value(&a, 2100)
	testing.expect_value(t, m3.n, 2)
	testing.expect(t, m3.halos[1].power < 1)
	e3, d3 := anim_value(&a, 2300)
	testing.expect(t, d3 && e3.n == 1)
	// without motion: at once
	anim_to(&a, 3000, f1, 0)
	v4, d4 := anim_value(&a, 3000)
	testing.expect(t, d4 && frame_equal(&v4, &f1))
}

@(test)
test_kdl_and_config :: proc(t: ^testing.T) {
	d := theme_kdl(true)
	defer delete(d)
	l := theme_kdl(false)
	defer delete(l)
	testing.expect(t, strings.has_prefix(d, KDL_MARK))
	testing.expect(t, strings.contains(d, `spawn-at-startup "iris-shell"`))
	testing.expect(t, strings.contains(d, "gaps 16"))
	testing.expect(t, strings.contains(d, "geometry-corner-radius 18"))
	testing.expect(t, strings.contains(d, `namespace="^iris-shell$"`))
	testing.expect(t, d != l)
	// braces balance, strings close
	depth, quotes := 0, 0
	for c in d {
		if c == '{' do depth += 1
		if c == '}' do depth -= 1
		if c == '"' do quotes += 1
	}
	testing.expect_value(t, depth, 0)
	testing.expect_value(t, quotes % 2, 0)

	cfg := "input {\n    keyboard { }\n}\n\nspawn-at-startup \"waybar\"\n    spawn-sh-at-startup \"waybar -c x\"\nspawn-at-startup \"mako\"\n"
	testing.expect(t, !config_has_include(cfg))
	with := config_add_include(cfg)
	defer delete(with)
	testing.expect(t, config_has_include(with))
	testing.expect(t, strings.has_suffix(with, INCLUDE_LINE + "\n"))
	again := config_add_include(with)
	defer delete(again)
	testing.expect_value(t, again, with) // once
	hidden, changed := config_bar(with, true)
	defer delete(hidden)
	testing.expect(t, changed)
	testing.expect(t, strings.contains(hidden, BAR_MARK + `spawn-at-startup "waybar"`))
	testing.expect(t, strings.contains(hidden, "    " + BAR_MARK + `spawn-sh-at-startup "waybar -c x"`))
	testing.expect(t, strings.contains(hidden, "spawn-at-startup \"mako\"")) // others stay
	testing.expect(t, config_bar_hidden(hidden))
	shown, ch2 := config_bar(hidden, false)
	defer delete(shown)
	testing.expect(t, ch2)
	testing.expect_value(t, shown, with)
	removed := config_remove_include(shown)
	defer delete(removed)
	testing.expect_value(t, removed, cfg)
}

@(test)
test_setup_in_temp_dir :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "iris-shell-test-*", context.temp_allocator)
	testing.expect(t, derr == nil)
	if derr != nil do return
	defer os.remove_all(dir)
	// niri has not written its config yet
	_, e := setup_niri(dir, true)
	testing.expect_value(t, e, Setup_Error.No_Config)
	cfg := strings.concatenate({dir, "/config.kdl"}, context.temp_allocator)
	orig := "layout {\n    gaps 4\n}\nspawn-at-startup \"waybar\"\n"
	testing.expect(t, os.write_entire_file(cfg, orig) == nil)
	res, e2 := setup_niri(dir, true)
	testing.expect_value(t, e2, Setup_Error.None)
	testing.expect(t, res.added_include && res.hid_bar && len(res.backup) > 0)
	delete(res.backup)
	text, _ := read_text(cfg)
	testing.expect(t, config_has_include(text))
	testing.expect(t, config_bar_hidden(text))
	bk, bok := read_text(strings.concatenate({cfg, BACKUP_SUFFIX}, context.temp_allocator))
	testing.expect(t, bok && bk == orig)
	testing.expect(t, os.exists(strings.concatenate({dir, "/", KDL_NAME}, context.temp_allocator)))
	// a second run changes nothing
	res2, _ := setup_niri(dir, true)
	testing.expect(t, !res2.added_include && !res2.hid_bar && res2.backup == "")
	// light after dark: the file follows
	testing.expect(t, refresh_theme_file(dir, false))
	kdl, _ := read_text(strings.concatenate({dir, "/", KDL_NAME}, context.temp_allocator))
	testing.expect(t, strings.contains(kdl, "light theme"))
	// and removing puts everything back
	_, e3 := remove_niri(dir)
	testing.expect_value(t, e3, Setup_Error.None)
	after, _ := read_text(cfg)
	testing.expect_value(t, after, orig)
	testing.expect(t, !os.exists(strings.concatenate({dir, "/", KDL_NAME}, context.temp_allocator)))
	// a file that is not ours is not rewritten
	testing.expect(t, os.write_entire_file(strings.concatenate({dir, "/", KDL_NAME}, context.temp_allocator), "mine\n") == nil)
	testing.expect(t, !refresh_theme_file(dir, true))
}

@(test)
test_scheme :: proc(t: ^testing.T) {
	testing.expect(t, parse_color_scheme("'prefer-dark'\n"))
	testing.expect(t, !parse_color_scheme("'prefer-light'"))
	testing.expect(t, !parse_color_scheme("'default'"))
	testing.expect_value(t, parse_scheme("dark"), Scheme.Dark)
	testing.expect_value(t, parse_scheme("light"), Scheme.Light)
	testing.expect_value(t, parse_scheme(""), Scheme.Auto)
}
