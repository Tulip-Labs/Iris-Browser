// The CEF engine's page on screen (IRIS_ENGINE=cef, see engine_api.odin):
// CEF draws the page off-screen and hands Iris its pixels (OnPaint, BGRA,
// premultiplied, with the rectangles that changed) when it composites in
// software; only those rectangles go up into the page's texture, and the
// renderer's shader reads BGRA (Texture.bgra). On the GPU its frames come
// as DMA-BUFs instead (cef_osr.odin). A <select>'s list is a popup CEF
// paints apart: it is laid over the page in the same texture. Input is forwarded explicitly:
// pointer, wheel, keys (Windows key codes as CEF wants, the xkb keycode as
// the native one) and text.
package iris

import gl "vendor:OpenGL"
import "core:math"
import "core:strings"
import "core:unicode/utf16"
import plat "../plat"

// (not indented: the whole file is this engine's)
when ENGINE_CEF {

Page :: struct {
	view:          ^View,
	/// where it is in the window (logical pixels), and the window's scale
	x, y, w, h:    f64,
	scale:         f64,
	tex:           Texture,
	cursor:        plat.Cursor_Shape,
	user:          rawptr,
	on_frame:      proc(p: ^Page),
	on_cursor:     proc(p: ^Page),
	on_fullscreen: proc(p: ^Page, on: bool),
	buttons:       u32, // EVENTFLAG_*_MOUSE_BUTTON held
	pointer:       [2]f64,
	visible:       bool,
	/// sound or video playing: the page is never hidden (it keeps running)
	media:         bool,
	popup:         cef_rect_t, // view coordinates
	popup_on:      bool,
	popup_px:      []u8,
	popup_w, popup_h: i32,
	/// the popup's GPU frame (cef_osr.odin)
	popup_tex:     Texture,
	/// a tab put to sleep (cef_sleep.odin): its last frame, with no view
	/// behind it (view is nil); hold: that frame stays on screen while the
	/// page loads again, until it has loaded (or hold_until)
	hold:          bool,
	hold_until:    f64,
	/// where the page was scrolled when it went to sleep, for its address
	restore_url:   string,
	restore_scroll: [2]f64,
	/// hidden: since when, and which time (a later show or hide makes a
	/// timer of the time before do nothing); frozen by DevTools'
	/// Page.setWebLifecycleState (cef_sleep.odin)
	hidden_since:  f64,
	hidden_seq:    int,
	frozen:        bool,
	/// a touchpad's last moves (time ms, dx, dy), for its fling
	scroll_samples: [FLING_SAMPLES]Scroll_Sample,
	scroll_n:      int,
	fling:         ^Fling,
}

page_new :: proc(v: ^View) -> ^Page {
	p := new(Page)
	p^ = {view = v, w = 800, h = 600, scale = 1}
	return p
}

page_free :: proc(p: ^Page) {
	if p == nil do return
	fling_stop(p)
	if p.tex.owned do texture_free(&p.tex)
	page_free_gpu(p)
	delete(p.popup_px)
	delete(p.restore_url)
	free(p)
}

/// the browser behind the page (nil while it sleeps, or before CEF made it)
@(private="file") page_host :: proc(p: ^Page) -> ^cef_browser_host_t {
	if p == nil || p.view == nil do return nil
	return p.view.host
}

/// the size CEF lays the page out at (view coordinates)
page_view_rect :: proc(p: ^Page) -> cef_rect_t {
	return {0, 0, i32(max(1, math.round(p.w))), i32(max(1, math.round(p.h)))}
}

// ---------------------------------------------------------------- pixels

/// the rectangles that changed, into the texture (all of it when its size
/// changed); data is w*h BGRA
@(private="file") upload_rects :: proc(t: ^Texture, data: rawptr, w, h: i32, rects: []cef_rect_t) {
	// (a texture of GPU frames is RGBA: a software frame replaces it whole)
	if t.id == 0 || !t.owned || t.w != w || t.h != h || !t.bgra {
		texture_upload(t, data, w, h, w * 4)
		return
	}
	gl.BindTexture(gl.TEXTURE_2D, t.id)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, w)
	for r in rects {
		x0, y0 := clamp(r.x, 0, w), clamp(r.y, 0, h)
		x1, y1 := clamp(r.x + r.width, 0, w), clamp(r.y + r.height, 0, h)
		if x1 <= x0 || y1 <= y0 do continue
		gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, x0)
		gl.PixelStorei(gl.UNPACK_SKIP_ROWS, y0)
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, x0, y0, x1 - x0, y1 - y0, gl.RGBA, gl.UNSIGNED_BYTE, data)
	}
	gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, 0)
	gl.PixelStorei(gl.UNPACK_SKIP_ROWS, 0)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
}

/// the popup's pixels over the page, where CEF placed it
@(private="file") lay_popup :: proc(p: ^Page) {
	if !p.popup_on || len(p.popup_px) == 0 || p.tex.id == 0 do return
	x := i32(math.round(f64(p.popup.x) * p.scale))
	y := i32(math.round(f64(p.popup.y) * p.scale))
	// cut to the texture: a list that runs past the page's edge
	w := min(p.popup_w, p.tex.w - x)
	h := min(p.popup_h, p.tex.h - y)
	if x < 0 || y < 0 || w <= 0 || h <= 0 do return
	gl.BindTexture(gl.TEXTURE_2D, p.tex.id)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, p.popup_w)
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(p.popup_px))
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
}

/// OnPaint (the main thread, in CEF's turn of the loop: Iris's GL context
/// is current)
page_paint :: proc(p: ^Page, kind: i32, rects: []cef_rect_t, buffer: rawptr, w, h: i32) {
	if buffer == nil || w <= 0 || h <= 0 do return
	cef_software_frame_seen()
	// a woken tab shows its last frame until it has loaded again
	if p.hold && now_s() < p.hold_until do return
	if kind == PET_POPUP {
		n := int(w) * int(h) * 4
		if len(p.popup_px) != n {
			delete(p.popup_px)
			p.popup_px = make([]u8, n)
		}
		copy(p.popup_px, ([^]u8)(buffer)[:n])
		p.popup_w, p.popup_h = w, h
		lay_popup(p)
	} else {
		upload_rects(&p.tex, buffer, w, h, rects)
		lay_popup(p)
	}
	if p.on_frame != nil do p.on_frame(p)
}

page_popup_show :: proc(p: ^Page, on: bool) {
	p.popup_on = on
	if !on {
		delete(p.popup_px)
		p.popup_px = nil
		page_free_gpu(p)
		// the page under the list is drawn again
		if h := page_host(p); h != nil do h.invalidate(h, PET_VIEW)
	}
}

// the frame is uploaded as it comes: nothing to latch or give back
page_latch :: proc(p: ^Page) {}
flush_rendered :: proc(p: ^Page) {}

// ---------------------------------------------------------------- place, visibility, focus

page_place :: proc(p: ^Page, x, y, w, h: f64, scale: f64) {
	p.x, p.y = x, y
	resized := (w != p.w || h != p.h) && w > 0 && h > 0
	rescaled := scale != p.scale
	if resized do p.w, p.h = w, h
	p.scale = scale
	host := page_host(p)
	if host == nil do return
	if rescaled do host.notify_screen_info_changed(host)
	if resized || rescaled do host.was_resized(host)
}

/// a page out of sight is hidden (it stops painting and slows its timers),
/// unless it plays sound or video: those are never put to sleep
page_apply_hidden :: proc(p: ^Page) {
	host := page_host(p)
	if host == nil do return
	host.was_hidden(host, !p.visible && !p.media ? 1 : 0)
}

page_set_visible :: proc(p: ^Page, on: bool) {
	was := p.visible
	p.visible = on
	page_apply_hidden(p)
	if !on do fling_stop(p)
	// a tab you left is frozen at once, and may sleep much later; one you
	// come back to is alive at once (cef_sleep.odin)
	if was && !on do cef_sleep_consider(cast(^Tab)p.user)
	if on && !was do cef_sleep_shown(cast(^Tab)p.user)
}

page_set_active :: proc(p: ^Page, on: bool) {}

page_focus :: proc(p: ^Page, on: bool) {
	if host := page_host(p); host != nil do host.set_focus(host, on ? 1 : 0)
}

/// CEF reads keys by Windows key code and xkb keycode: no keymap needed
set_keymap :: proc(format: u32, fd: i32, size: u32) {}

/// the desktop copied something: kept, and put on Chromium's own clipboard
/// when a page pastes (cef_view.odin's clipboard_to_chromium; CEF's
/// clipboard has no desktop behind it: its ozone platform is headless)
clipboard_from_desktop :: proc(text: string) {
	delete(clipboard_text)
	clipboard_text = strings.clone(text)
}

cursor_of_cef :: proc(t: i32) -> plat.Cursor_Shape {
	switch t {
	case CT_HAND: return .Pointer
	case CT_IBEAM, CT_VERTICALTEXT: return .Text
	case CT_GRAB, CT_GRABBING, CT_MOVE: return .Grab
	case CT_EASTRESIZE, CT_WESTRESIZE, CT_EASTWESTRESIZE, CT_COLUMNRESIZE: return .Ew_Resize
	case CT_NORTHRESIZE, CT_SOUTHRESIZE, CT_NORTHSOUTHRESIZE, CT_ROWRESIZE: return .Ns_Resize
	}
	return .Default
}

// ---------------------------------------------------------------- input

@(private="file") flags :: proc(m: plat.Mods, buttons: u32) -> u32 {
	r := buttons
	if .Shift in m do r |= EVENTFLAG_SHIFT_DOWN
	if .Ctrl in m do r |= EVENTFLAG_CONTROL_DOWN
	if .Alt in m do r |= EVENTFLAG_ALT_DOWN
	if .Logo in m do r |= EVENTFLAG_COMMAND_DOWN
	return r
}

@(private="file") button_flag :: proc(b: u32) -> u32 {
	switch b {
	case 1: return EVENTFLAG_LEFT_MOUSE_BUTTON
	case 2: return EVENTFLAG_MIDDLE_MOUSE_BUTTON
	case 3: return EVENTFLAG_RIGHT_MOUSE_BUTTON
	}
	return 0
}

/// a pointer event in window coordinates, for this page
/// a woken tab still shows its last frame: what you do goes to nothing
/// (not to a page you cannot see yet)
@(private="file") holding :: proc(p: ^Page) -> bool {
	return p.hold && now_s() < p.hold_until
}

page_pointer :: proc(p: ^Page, e: plat.Pointer_Event) {
	host := page_host(p)
	if host == nil || holding(p) do return
	x, y := e.x - p.x, e.y - p.y
	ev := cef_mouse_event_t{x = i32(math.round(x)), y = i32(math.round(y)), modifiers = flags(e.mods, p.buttons)}
	switch e.kind {
	case .Enter, .Motion:
		p.pointer = {x, y}
		host.send_mouse_move_event(host, &ev, 0)
	case .Leave:
		ev.x, ev.y = i32(p.pointer.x), i32(p.pointer.y)
		host.send_mouse_move_event(host, &ev, 1)
	case .Button:
		// the side buttons go back and forward, as in every browser
		if e.button == 8 || e.button == 9 {
			if e.pressed {
				t := cast(^Tab)p.user
				if e.button == 8 { tab_back(t) } else { tab_forward(t) }
			}
			return
		}
		kind: i32
		switch e.button {
		case 1: kind = MBT_LEFT
		case 2: kind = MBT_MIDDLE
		case 3: kind = MBT_RIGHT
		case: return
		}
		fling_stop(p) // a click stops a fling, as a finger on the pad does
		if e.pressed { p.buttons |= button_flag(e.button) } else { p.buttons &= ~button_flag(e.button) }
		ev.modifiers = flags(e.mods, p.buttons)
		host.send_mouse_click_event(host, &ev, kind, e.pressed ? 0 : 1, i32(max(1, e.clicks)))
	case .Scroll:
		// sent as it comes (each Wayland pointer frame), never held for a
		// frame of Iris's: Chromium scrolls on its compositor at once.
		// Chromium's deltas point up; a wheel notch (15 from the
		// compositor, 3 lines) is Chromium's 120
		fling_stop(p)
		dx, dy := -e.dx, -e.dy
		if e.precise {
			ev.modifiers |= EVENTFLAG_PRECISION_SCROLLING_DELTA
			scroll_sample(p, now_s() * 1000, dx, dy) // (one clock for the samples and the stop: Iris's)
		} else {
			dx, dy = dx * 8, dy * 8
			p.scroll_n = 0
		}
		ev.x, ev.y = i32(p.pointer.x), i32(p.pointer.y)
		host.send_mouse_wheel_event(host, &ev, i32(math.round(dx)), i32(math.round(dy)))
	case .Scroll_Stop:
		// the fingers left the touchpad (wl_pointer.axis_stop): CEF's
		// windowless wheel events have no phases, so Iris flings itself,
		// as GTK does, from the last moves' speed
		fling_start(p, now_s() * 1000)
	}
}

page_key :: proc(p: ^Page, e: plat.Key_Event) {
	host := page_host(p)
	if host == nil || holding(p) do return
	ctrl := .Ctrl in e.mods
	// Ctrl+V: Chromium's clipboard gets the desktop's text first (it has no
	// desktop of its own), then the key goes to the page, whose paste event
	// fires as in any browser (cef_view.odin). Ctrl+C / X / A / Z go as
	// they are: the page's copy event fires, and what it copied comes back
	// to the desktop by the page's copy watcher.
	if ctrl && !(.Alt in e.mods) && e.pressed && keycode_us_letter(e.code, e.sym) == 'V' {
		cef_paste_key(cast(^Tab)p.user, i32(e.code), flags(e.mods, 0))
		return
	}
	// a copy you asked for: what the page copies may reach the desktop
	// (a page's own copy, without your key, never does: cef_view.odin)
	if e.pressed && !(.Alt in e.mods) {
		letter := keycode_us_letter(e.code, e.sym)
		ctrl_insert := ctrl && (e.keysym == 0xff63 || e.keysym == 0xff9e) // Ctrl+Insert
		shift_delete := .Shift in e.mods && !ctrl && (e.keysym == 0xffff || e.keysym == 0xff9f) // Shift+Delete
		if (ctrl && (letter == 'C' || letter == 'X')) || ctrl_insert || shift_delete do cef_copy_intent(cast(^Tab)p.user)
	}
	ev := cef_key_event_t{size = size_of(cef_key_event_t)}
	ev.modifiers = flags(e.mods, 0)
	if e.repeat do ev.modifiers |= EVENTFLAG_IS_REPEAT
	ev.windows_key_code = windows_key_code(e.keysym, e.sym)
	// a key of a layout that is not Latin (Cyrillic, Greek...): the key the
	// US layout has there, as Chromium does itself, so Ctrl+A, Ctrl+Z and
	// the rest work in every layout
	if ev.windows_key_code == 0 do ev.windows_key_code = us_layout_key_code(e.code)
	ev.native_key_code = i32(e.code)
	if !e.pressed {
		ev.type = KEYEVENT_KEYUP
		host.send_key_event(host, &ev)
		return
	}
	ev.type = KEYEVENT_RAWKEYDOWN
	host.send_key_event(host, &ev)
	if len(e.text) == 0 || ctrl do return
	units: [8]u16
	n := utf16.encode_string(units[:], e.text)
	if n == 1 {
		// one character: the char event the page's keypress and input read
		ev.type = KEYEVENT_CHAR
		ev.character, ev.unmodified_character = units[0], units[0]
		host.send_key_event(host, &ev)
	} else if n > 1 {
		page_commit_text(p, e.text) // an emoji, a composed sequence
	}
}

/// text typed into the page as one piece (an input method's commit, a paste)
page_commit_text :: proc(p: ^Page, text: string) {
	host := page_host(p)
	if host == nil || len(text) == 0 do return
	s := cef_str(text)
	none := cef_range_t{max(u32), max(u32)} // no range to replace: at the caret
	host.ime_commit_text(host, &s, &none, 0)
}

/// what an input method is composing, shown in the page (no Wayland text
/// input in Iris's platform yet: ready for it)
page_preedit :: proc(p: ^Page, text: string) {
	host := page_host(p)
	if host == nil do return
	if len(text) == 0 {
		host.ime_cancel_composition(host)
		return
	}
	s := cef_str(text)
	none := cef_range_t{max(u32), max(u32)}
	sel := cef_range_t{u32(len(text)), u32(len(text))}
	host.ime_set_composition(host, &s, 0, nil, &none, &sel)
}

// ---------------------------------------------------------------- touchpad fling

Fling :: struct {
	page:    ^Page,
	vx, vy:  f64, // px per ms, Chromium's direction
	last:    f64, // ms
	timer:   u32,
}

@(private="file") scroll_sample :: proc(p: ^Page, t, dx, dy: f64) {
	if p.scroll_n == FLING_SAMPLES {
		copy(p.scroll_samples[:], p.scroll_samples[1:])
		p.scroll_n -= 1
	}
	p.scroll_samples[p.scroll_n] = {t, dx, dy}
	p.scroll_n += 1
}

fling_stop :: proc(p: ^Page) {
	if p == nil do return
	if f := p.fling; f != nil {
		p.fling = nil
		g_source_remove(f.timer)
		free(f)
	}
}

@(private="file") fling_start :: proc(p: ^Page, t: f64) {
	// axis_stop comes once per axis: the first starts the fling, the next
	// (with no moves left) changes nothing
	if p.scroll_n == 0 do return
	fling_stop(p)
	vx, vy, ok := fling_velocity(p.scroll_samples[:p.scroll_n], t)
	p.scroll_n = 0
	if !ok do return
	f := new(Fling)
	f^ = {page = p, vx = vx, vy = vy, last = now_s() * 1000}
	p.fling = f
	// a timer only while the page flings (about 1 s at most)
	f.timer = g_timeout_add_full(G_PRIORITY_DEFAULT, FLING_TICK_MS, proc "c" (d: rawptr) -> gboolean {
		context = main_context
		f := cast(^Fling)d
		p := f.page
		host := page_host(p)
		now := now_s() * 1000
		dx, dy, more := fling_step(&f.vx, &f.vy, now - f.last)
		f.last = now
		if host != nil && (dx != 0 || dy != 0) {
			ev := cef_mouse_event_t{x = i32(p.pointer.x), y = i32(p.pointer.y), modifiers = EVENTFLAG_PRECISION_SCROLLING_DELTA}
			host.send_mouse_wheel_event(host, &ev, i32(math.round(dx)), i32(math.round(dy)))
		}
		if more && host != nil do return 1
		p.fling = nil
		free(f)
		return 0
	}, f, nil)
}

// ---- pure logic, no CEF in it (scratch tests copy it from between the
// markers) ---- BEGIN CEF_LOGIC_FLING

FLING_SAMPLES :: 8
FLING_TICK_MS :: 8
/// moves older than this before the fingers left do not count
FLING_WINDOW_MS :: 100.0
/// slower than this (px/ms) is not a fling
FLING_MIN_SPEED :: 0.25
FLING_MAX_SPEED :: 8.0
/// speed kept per millisecond (about GTK's deceleration)
FLING_FRICTION :: 0.9965
FLING_STOP_SPEED :: 0.03

Scroll_Sample :: struct {
	t, dx, dy: f64,
}

/// the speed the fingers left the pad at (px/ms), from its last moves
fling_velocity :: proc(samples: []Scroll_Sample, stop_t: f64) -> (vx, vy: f64, ok: bool) {
	sx, sy: f64
	first := -1.0
	n := 0
	for s in samples {
		if stop_t - s.t > FLING_WINDOW_MS || s.t > stop_t + 1 do continue
		if first < 0 do first = s.t
		sx += s.dx
		sy += s.dy
		n += 1
	}
	if n < 2 do return
	span := max(stop_t - first, 8.0)
	vx, vy = sx / span, sy / span
	speed := abs(vx) + abs(vy)
	if speed < FLING_MIN_SPEED do return 0, 0, false
	if speed > FLING_MAX_SPEED {
		k := FLING_MAX_SPEED / speed
		vx, vy = vx * k, vy * k
	}
	return vx, vy, true
}

/// one step of a fling dt ms long: the distance to scroll, and whether it
/// goes on (the speed decays exponentially)
fling_step :: proc(vx, vy: ^f64, dt: f64) -> (dx, dy: f64, more: bool) {
	d := clamp(dt, 1, 50)
	k := math.pow(FLING_FRICTION, d)
	// the distance under an exponentially decaying speed over d ms
	dist := (1 - k) / (1 - FLING_FRICTION)
	dx, dy = vx^ * dist, vy^ * dist
	vx^, vy^ = vx^ * k, vy^ * k
	return dx, dy, abs(vx^) + abs(vy^) >= FLING_STOP_SPEED
}

// ---- END CEF_LOGIC_FLING

// ---- pure logic, no CEF in it (scratch tests copy it from between the
// markers) ---- BEGIN CEF_LOGIC_KEYS

/// the Windows key code of the key at this place on a US keyboard (code:
/// the xkb keycode, evdev's + 8), for a layout whose keysyms are not Latin
us_layout_key_code :: proc(code: u32) -> i32 {
	if code < 8 do return 0
	ROW_Q := "QWERTYUIOP"
	ROW_A := "ASDFGHJKL"
	ROW_Z := "ZXCVBNM"
	switch k := code - 8; k {
	case 2 ..= 10: return i32('1' + k - 2) // KEY_1..KEY_9
	case 11: return '0'
	case 12: return 0xBD // minus
	case 13: return 0xBB // equal
	case 16 ..= 25: return i32(ROW_Q[k - 16])
	case 26: return 0xDB // [
	case 27: return 0xDD // ]
	case 30 ..= 38: return i32(ROW_A[k - 30])
	case 39: return 0xBA // ;
	case 40: return 0xDE // '
	case 41: return 0xC0 // `
	case 43: return 0xDC // backslash
	case 44 ..= 50: return i32(ROW_Z[k - 44])
	case 51: return 0xBC // ,
	case 52: return 0xBE // .
	case 53: return 0xBF // /
	case 57: return 0x20 // space
	case 86: return 0xE2 // the key left of Z on ISO keyboards
	}
	return 0
}

/// the letter a shortcut means: the keysym's, when it is Latin (Dvorak's V
/// is where Dvorak puts it), else the US layout's at that place
keycode_us_letter :: proc(code, sym: u32) -> i32 {
	if sym >= 'a' && sym <= 'z' do return i32(sym - 'a' + 'A')
	if sym >= 'A' && sym <= 'Z' do return i32(sym)
	if sym < 0x80 do return 0 // a Latin key that is not a letter
	k := us_layout_key_code(code)
	return k >= 'A' && k <= 'Z' ? k : 0
}

/// a keysym as the Windows virtual key code Chromium reads keys by
windows_key_code :: proc(keysym, sym: u32) -> i32 {
	switch sym {
	case 'a' ..= 'z': return i32(sym - 'a' + 'A')
	case '0' ..= '9': return i32(sym)
	case ' ': return 0x20
	case ';', ':': return 0xBA
	case '=', '+': return 0xBB
	case ',', '<': return 0xBC
	case '-', '_': return 0xBD
	case '.', '>': return 0xBE
	case '/', '?': return 0xBF
	case '`', '~': return 0xC0
	case '[', '{': return 0xDB
	case '\\', '|': return 0xDC
	case ']', '}': return 0xDD
	case '\'', '"': return 0xDE
	case '!': return '1'
	case '@': return '2'
	case '#': return '3'
	case '$': return '4'
	case '%': return '5'
	case '^': return '6'
	case '&': return '7'
	case '*': return '8'
	case '(': return '9'
	case ')': return '0'
	}
	switch keysym {
	case 0xff08: return 0x08 // BackSpace
	case 0xff09, 0xfe20: return 0x09 // Tab, ISO_Left_Tab
	case 0xff0d, 0xff8d: return 0x0D // Return, KP_Enter
	case 0xff13: return 0x13 // Pause
	case 0xff1b: return 0x1B // Escape
	case 0xff50, 0xff95: return 0x24 // Home
	case 0xff51, 0xff96: return 0x25 // Left
	case 0xff52, 0xff97: return 0x26 // Up
	case 0xff53, 0xff98: return 0x27 // Right
	case 0xff54, 0xff99: return 0x28 // Down
	case 0xff55, 0xff9a: return 0x21 // Prior
	case 0xff56, 0xff9b: return 0x22 // Next
	case 0xff57, 0xff9c: return 0x23 // End
	case 0xff63, 0xff9e: return 0x2D // Insert
	case 0xffff, 0xff9f: return 0x2E // Delete
	case 0xff67: return 0x5D // Menu
	case 0xffe1, 0xffe2: return 0x10 // Shift
	case 0xffe3, 0xffe4: return 0x11 // Control
	case 0xffe9, 0xffea, 0xfe03: return 0x12 // Alt, ISO_Level3_Shift
	case 0xffeb, 0xffec: return 0x5B // Super
	case 0xffe5: return 0x14 // Caps_Lock
	case 0xff7f: return 0x90 // Num_Lock
	case 0xffb0 ..= 0xffb9: return i32(0x60 + keysym - 0xffb0) // KP_0..9
	case 0xffaa: return 0x6A
	case 0xffab: return 0x6B
	case 0xffad: return 0x6D
	case 0xffae: return 0x6E
	case 0xffaf: return 0x6F
	case 0xffbe ..= 0xffd5: return i32(0x70 + keysym - 0xffbe) // F1..F24
	}
	return 0
}

// ---- END CEF_LOGIC_KEYS

} // when ENGINE_CEF
