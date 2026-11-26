// A tab: one page view (the engine's: engine_api.odin) and what it is
// doing. Every tab stays awake (Iris has no sleeping tabs).
package iris

import "core:strings"
import "core:testing"

Tab :: struct {
	id:             int,
	container:      string, // "" none, PRIVATE_ID, or a container's id
	url:            string,
	title:          string,
	progress:       f64,
	loading:        bool,
	can_back:       bool,
	can_forward:    bool,
	zoom:           f64,
	/// the engine's view of the page (cef_view.odin)
	using view:     Tab_View,
	page:           ^Page,
	/// a site Iris does not trust: its own processes and a throwaway world
	sandboxed:      bool,
	/// hosts whose failing certificate the sandbox let through, once each
	allowed_certs:  map[string]bool,
	/// a pop-up waiting for its first address (the page wrote it into a
	/// blank window: Iris shows it only once it knows where it goes)
	held:           bool,
	/// the site's icon, premultiplied BGRA, uploaded when next drawn
	favicon_px:     []u8,
	favicon_w, favicon_h, favicon_stride: i32,
	favicon_tex:    Texture,
	favicon_dirty:  bool,
	/// script dialogs lately (alert, confirm, prompt): a page that keeps
	/// opening them is stopped, so it cannot hold Iris in a loop
	dialogs_since:  f64,
	dialogs_n:      int,
	dialogs_blocked: bool,
	// 2.3: what the tab strip, reader, peek and the privacy report know
	// (features.odin, reader.odin, peek.odin, privacy.odin)
	pinned:         bool,
	muted:          bool,
	/// the page is playing sound (the engine says so; nothing is polled)
	audio:          bool,
	/// the workspace the tab belongs to ("" the first one)
	space:          string,
	/// the page looks like an article: the reader can show it
	article:        bool,
	/// the tab shows the reader's page of its article; reader_pending until
	/// that page commits
	reader, reader_pending: bool,
	/// known tracker hosts the page tried to load, which Shields stopped
	trackers:       [dynamic]string,
	/// an http address tried over https first: the one it came from
	upgraded_from:  string,
	/// the view is a peek's: a process of its own, ended with it
	isolated:       bool,
	/// a certificate that failed: Iris's page over the tab says so, and
	/// nothing of the site shows until you choose (interstitial.odin)
	cert_error:     ^Cert_Error,
	/// the address of the page last committed in the tab (a failed load
	/// changes t.url, not this)
	committed_url:  string,
}

@(private="file") next_tab_id := 1

TITLE_MAX :: 1024

tab_new :: proc(container: string) -> ^Tab {
	t := new(Tab)
	t^ = {id = next_tab_id, container = strings.clone(container), zoom = 1}
	next_tab_id += 1
	return t
}

tab_is_private :: proc(t: ^Tab) -> bool {
	return t.container == PRIVATE_ID
}

forget_certs :: proc(t: ^Tab) {
	for h in t.allowed_certs do delete(h)
	clear(&t.allowed_certs)
}

tab_free :: proc(t: ^Tab) {
	cert_clear(t)
	tab_release_web(t)
	delete(t.container)
	delete(t.url)
	delete(t.title)
	delete(t.favicon_px)
	forget_certs(t)
	if t.favicon_tex.owned do texture_free(&t.favicon_tex)
	delete(t.allowed_certs)
	tab_free_extra(t)
	free(t)
}

set_str :: proc(s: ^string, v: string) {
	if s^ == v do return
	delete(s^)
	s^ = strings.clone(v)
}

// (browser_tab_alive, a tab in the strip or the peek: features.odin)

/// every tab with a page Iris has: the strip's and the peek
browser_all_tabs :: proc() -> []^Tab {
	out := make([dynamic]^Tab, 0, len(b.tabs) + 1, context.temp_allocator)
	append(&out, ..b.tabs[:])
	if b.peek != nil do append(&out, b.peek)
	return out[:]
}

/// opens an address after this turn of the loop (from inside an engine's
/// callback, where the view cannot be remade)
Later :: struct {
	t:   ^Tab,
	url: string,
}

tab_load_later :: proc(t: ^Tab, u: string) {
	l := new(Later)
	l^ = {t, u}
	idle(proc(d: rawptr) {
		l := cast(^Later)d
		if browser_tab_alive(l.t) do tab_load(l.t, l.url)
		delete(l.url)
		free(l)
	}, l)
}

// ---------------------------------------------------------------- the sandbox

Sandbox_Move :: enum u8 {
	/// the address loads again in a view made for it (in or out of the sandbox)
	Reload,
	/// it goes on where it is, in the sandbox
	Stay,
	/// it is not sent (a form into the sandbox: loading it again would make
	/// it a GET, without what it sends)
	Refuse,
}

/// a navigation that should cross the sandbox's edge: Iris loads it again
/// in a view of the other side, unless it sends a body (a form's POST),
/// which only a sandboxed page may send on from where it is
sandbox_move_for :: proc(sandboxed, body: bool) -> Sandbox_Move {
	if !body do return .Reload
	return sandboxed ? .Stay : .Refuse
}

@(test) test_sandbox_move :: proc(t: ^testing.T) {
	testing.expect_value(t, sandbox_move_for(false, false), Sandbox_Move.Reload)
	testing.expect_value(t, sandbox_move_for(true, false), Sandbox_Move.Reload)
	testing.expect_value(t, sandbox_move_for(true, true), Sandbox_Move.Stay)
	testing.expect_value(t, sandbox_move_for(false, true), Sandbox_Move.Refuse)
}

// ---------------------------------------------------------------- dialogs

DIALOGS_BURST :: 5
DIALOGS_WINDOW :: 15.0

/// whether a page may show one more dialog: past DIALOGS_BURST in
/// DIALOGS_WINDOW seconds (an alert in a loop) its dialogs stop, until you
/// open another address in the tab
dialog_allowed :: proc(t: ^Tab, now: f64) -> bool {
	if t.dialogs_blocked do return false
	if now - t.dialogs_since > DIALOGS_WINDOW || now < t.dialogs_since {
		t.dialogs_since, t.dialogs_n = now, 0
	}
	t.dialogs_n += 1
	if t.dialogs_n > DIALOGS_BURST {
		t.dialogs_blocked = true
		return false
	}
	return true
}

@(test) test_dialog_loop :: proc(t: ^testing.T) {
	tab: Tab
	now := 1000.0
	for _ in 0 ..< DIALOGS_BURST {
		testing.expect(t, dialog_allowed(&tab, now))
		now += 1
	}
	// one more in the same few seconds: the page is stopped
	testing.expect(t, !dialog_allowed(&tab, now))
	testing.expect(t, !dialog_allowed(&tab, now + 100))
	// a page that asks now and then is never stopped
	calm: Tab
	for i in 0 ..< 20 do testing.expect(t, dialog_allowed(&calm, 2000 + f64(i) * 20))
}

// ---------------------------------------------------------------- icons

FAVICON_MAX :: 64

/// a site's icon at most FAVICON_MAX pixels a side, rows packed (a larger
/// one is averaged down: the pixels are premultiplied, so a plain average
/// is right); false when the pixels do not cover the sizes given
favicon_fit :: proc(px: []u8, w, h, stride: int, allocator := context.allocator) -> (out: []u8, ow, oh: int, ok: bool) {
	if w <= 0 || h <= 0 || w > 4096 || h > 4096 || stride < w * 4 do return
	if len(px) < stride * (h - 1) + w * 4 do return
	f := max(1, (max(w, h) + FAVICON_MAX - 1) / FAVICON_MAX)
	ow, oh = max(1, w / f), max(1, h / f)
	out = make([]u8, ow * oh * 4, allocator)
	for y in 0 ..< oh do for x in 0 ..< ow {
		sum: [4]int
		for dy in 0 ..< f do for dx in 0 ..< f {
			sy, sx := y * f + dy, x * f + dx
			if sy >= h || sx >= w do continue
			q := sy * stride + sx * 4
			for c in 0 ..< 4 do sum[c] += int(px[q + c])
		}
		for c in 0 ..< 4 do out[(y * ow + x) * 4 + c] = u8(sum[c] / (f * f))
	}
	return out, ow, oh, true
}

@(test) test_favicon_fit :: proc(t: ^testing.T) {
	// a 32 px icon stays as it is, its rows packed
	src := make([]u8, 160 * 32, context.temp_allocator)
	for i in 0 ..< len(src) do src[i] = u8(i % 251)
	out, w, h, ok := favicon_fit(src, 32, 32, 160, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, w, 32)
	testing.expect_value(t, h, 32)
	testing.expect_value(t, len(out), 32 * 32 * 4)
	testing.expect_value(t, out[32 * 4], src[160])
	// a 512 px one comes down to 64, each pixel the average of 8x8
	big := make([]u8, 512 * 512 * 4, context.temp_allocator)
	for i in 0 ..< len(big) do big[i] = 200
	out, w, h, ok = favicon_fit(big, 512, 512, 512 * 4, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, w, 64)
	testing.expect_value(t, h, 64)
	testing.expect_value(t, len(out), 64 * 64 * 4)
	testing.expect_value(t, out[1000], 200)
	// sizes the pixels do not cover are refused
	_, _, _, ok = favicon_fit(src, 32, 64, 160, context.temp_allocator)
	testing.expect(t, !ok)
	_, _, _, ok = favicon_fit(src, 32, 32, 64, context.temp_allocator)
	testing.expect(t, !ok)
	_, _, _, ok = favicon_fit(nil, 0, 0, 0, context.temp_allocator)
	testing.expect(t, !ok)
}
