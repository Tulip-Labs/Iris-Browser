// The CEF engine's hidden tabs: frozen at once, put to
// sleep only much later.
//
// Freezing: a tab you leave is hidden (was_hidden) and frozen at once
// (DevTools' Page.setWebLifecycleState "frozen": its timers, animation
// frames, workers and network work stop; CPU goes to about nothing) and
// unfrozen ("active") the moment it shows again. Nothing is lost: the
// page, its state and its history stay as they were. Never frozen: a page
// with sound or video, a live connection (WebSocket, WebRTC, EventSource),
// one that asks before you leave it (beforeunload), one with a download
// going, a pop-up or a page with a pop-up open (they talk to each other),
// the peek. IRIS_CEF_FREEZE=0 turns it off.
//
// Sleeping (discarding): a tab hidden for SLEEP_AFTER_S that passes the
// light test (an article, a blog, documentation) gives its browser back
// (its renderer with it: cef_engine.odin's reaper); what stays is its last
// frame (the Page with no view), its address and where it was scrolled.
// Coming back to it makes the browser again, loads the address, shows the
// last frame meanwhile (input waits) and scrolls back when it has loaded.
// What sleeping costs: the tab's back and forward history, and whatever
// the page kept in memory only; so not light is also: anything in
// sessionStorage, a focused field or frame, something typed, a live
// connection, beforeunload, a service worker in control, more than a few
// frames, a big script heap, media, fullscreen; and never a pinned tab, a
// sandboxed one (its world would be gone), a page from a form (waking
// would send it again), the reader, a pop-up pair, a tab downloading.
// IRIS_CEF_SLEEP=0 turns sleeping off.
package iris

import "core:fmt"
import "core:strconv"
import "core:strings"

// (not indented: the whole file is this engine's)

/// a woken tab's last frame stays at most this long while it loads again
SLEEP_HOLD_S :: 4.0
/// hidden this long (and light): the tab sleeps
SLEEP_AFTER_S :: 600
/// a page whose scripts hold more than this is not light (bytes)
SLEEP_HEAP_MAX :: 64 << 20
SLEEP_FRAMES_MAX :: 3

/// at the document's start (main frame): live connections counted, whether
/// you typed in it, and whether it asks before you leave (beforeunload);
/// read by the probes below. The wrappers are Proxies of the originals
/// (instanceof, toString and the rest behave as before).
SLEEP_WATCH_JS :: `(() => {
  if (window.__irisLive) return;
  let live = 0, typed = false, unload = false;
  for (const name of ['WebSocket', 'RTCPeerConnection', 'EventSource']) {
    const C = window[name];
    if (typeof C !== 'function') continue;
    try {
      window[name] = new Proxy(C, { construct(target, args, nt) {
        const o = Reflect.construct(target, args, nt);
        live++;
        let done = false;
        const end = () => { if (!done) { done = true; live = Math.max(0, live - 1); } };
        try {
          if (name === 'RTCPeerConnection') o.addEventListener('connectionstatechange', () => { if (o.connectionState === 'closed' || o.connectionState === 'failed') end(); });
          else { o.addEventListener('close', end); o.addEventListener('error', () => { if (o.readyState === 2) end(); }); }
        } catch (e) {}
        return o;
      } });
    } catch (e) {}
  }
  try {
    const add = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = new Proxy(add, { apply(target, self, args) { if (self === window && args[0] === 'beforeunload') unload = true; return Reflect.apply(target, self, args); } });
  } catch (e) {}
  addEventListener('input', e => { if (e.isTrusted) typed = true; }, true);
  Object.defineProperty(window, '__irisLive', { value: () => ({ live, typed, unload: unload || !!window.onbeforeunload }) });
})();`

/// may the page be frozen? "ok", or why not
@(private="file") FREEZE_PROBE_JS :: `(() => {
  const w = window.__irisLive;
  if (typeof w !== 'function') return window.onbeforeunload ? 'unload' : 'ok';
  const s = w();
  return s.live > 0 ? 'live' : s.unload ? 'unload' : 'ok';
})()`

/// is the page light? "1,<scrollX>,<scrollY>" if so, else "0"
@(private="file") SLEEP_PROBE_JS :: `(() => {
  const d = document;
  if (d.querySelector('video,audio')) return '0';
  if (navigator.serviceWorker && navigator.serviceWorker.controller) return '0';
  const w = window.__irisLive;
  if (typeof w !== 'function') return '0';
  const s = w();
  if (s.live > 0 || s.typed || s.unload) return '0';
  try { if (sessionStorage.length > 0) return '0'; } catch (e) {}
  const a = d.activeElement;
  if (a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT|IFRAME|FRAME|OBJECT|EMBED)$/.test(a.tagName))) return '0';
  if (d.designMode === 'on' || d.fullscreenElement || d.pictureInPictureElement) return '0';
  if (d.querySelectorAll('iframe').length > ` + SLEEP_FRAMES_MAX_JS + `) return '0';
  const m = performance.memory;
  if (m && m.usedJSHeapSize > ` + SLEEP_HEAP_MAX_JS + `) return '0';
  return '1,' + Math.round(scrollX) + ',' + Math.round(scrollY);
})()`

@(private="file") SLEEP_FRAMES_MAX_JS :: "3"
@(private="file") SLEEP_HEAP_MAX_JS :: "67108864"
#assert(SLEEP_FRAMES_MAX == 3 && SLEEP_HEAP_MAX == 67108864, "keep the probe's numbers in step")

@(private="file") switch_on :: proc(cache: ^int, name: string) -> bool {
	if cache^ == 0 do cache^ = env(name) == "0" ? 2 : 1
	return cache^ == 1
}
@(private="file") freeze_cache, sleep_cache: int

/// the tab downloads something now
@(private="file") downloading :: proc(t: ^Tab) -> bool {
	for d in downloads do if d.tab_id == t.id && !d.done && !d.failed && !d.cancelled do return true
	return false
}

/// a pop-up, or a page with a pop-up of its own still open (they talk
/// through window.opener and postMessage)
@(private="file") in_popup_pair :: proc(v: ^View) -> bool {
	if v.popup_opener != 0 do return true
	return views_opened_by(v.id)
}

/// what Iris itself knows says the hidden tab may be frozen
@(private="file") may_freeze :: proc(t: ^Tab) -> bool {
	if t == nil || !browser_has_tab(t) || t == b.current || t == b.peek do return false
	v := t.cv
	p := t.page
	if v == nil || p == nil || p.visible || v.host == nil || v.browser == nil do return false
	if t.held || t.audio || p.media || t.cert_error != nil || b.dialog_tab == t do return false
	if in_popup_pair(v) || downloading(t) do return false
	return strings.has_prefix(t.url, "http")
}

/// what Iris itself knows says the tab may sleep (before asking the page)
@(private="file") may_sleep :: proc(t: ^Tab) -> bool {
	if !may_freeze(t) do return false
	v := t.cv
	if t.pinned || t.sandboxed || t.reader || t.reader_pending || t.loading || v.posted do return false
	h, _ := host_of(t.url, context.temp_allocator)
	return !keep_awake_host(h)
}

/// a DevTools method on the page (fire and forget: no answer is read)
@(private="file") devtools_seq: i32
@(private="file") devtools :: proc(v: ^View, method, params: string) -> bool {
	if v == nil || v.host == nil do return false
	devtools_seq += 1
	msg := fmt.tprintf(`{{"id":%d,"method":"%s","params":%s}}`, devtools_seq, method, params)
	return v.host.send_dev_tools_message(v.host, raw_data(msg), uint(len(msg))) != 0
}

/// a tab left the screen: frozen now if it may be, and looked at again
/// later for sleep
cef_sleep_consider :: proc(t: ^Tab) {
	if t == nil || t.page == nil do return
	p := t.page
	p.hidden_seq += 1
	p.hidden_since = now_s()
	if !switch_on(&freeze_cache, "IRIS_CEF_FREEZE") || !may_freeze(t) do return
	run_job(t, main_frame(t.cv), FREEZE_PROBE_JS, proc(t: ^Tab, result: string, data: rawptr) {
		seq := int(uintptr(data))
		if result != "ok" || !may_freeze(t) || t.page.hidden_seq != seq do return
		freeze(t)
	}, rawptr(uintptr(p.hidden_seq)))
	if switch_on(&sleep_cache, "IRIS_CEF_SLEEP") do sleep_later(t)
}

@(private="file") freeze :: proc(t: ^Tab) {
	p := t.page
	if p.frozen do return
	page_apply_hidden(p) // hidden first: Chromium freezes only a hidden page
	if devtools(t.cv, "Page.setWebLifecycleState", `{"state":"frozen"}`) do p.frozen = true
}

@(private="file") unfreeze :: proc(t: ^Tab) {
	p := t.page
	if p == nil || !p.frozen do return
	p.frozen = false
	devtools(t.cv, "Page.setWebLifecycleState", `{"state":"active"}`)
}

/// the tab shows again: back to life at once
cef_sleep_shown :: proc(t: ^Tab) {
	if t == nil || t.page == nil do return
	t.page.hidden_seq += 1 // the sleep looked for is off
	unfreeze(t)
}

@(private="file") Later :: struct {
	t:   ^Tab,
	id:  int,
	seq: int,
}

@(private="file") sleep_later :: proc(t: ^Tab) {
	l := new(Later)
	l^ = {t, t.id, t.page.hidden_seq}
	after(SLEEP_AFTER_S * 1000, proc(d: rawptr) {
		l := cast(^Later)d
		defer free(l)
		t := l.t
		if !browser_has_tab(t) || t.id != l.id || t.page == nil || t.page.hidden_seq != l.seq do return
		if !may_sleep(t) do return
		// a frozen page answers no script: awake for the question, frozen
		// again if it stays
		was := t.page.frozen
		unfreeze(t)
		run_job(t, main_frame(t.cv), SLEEP_PROBE_JS, proc(t: ^Tab, result: string, data: rawptr) {
			seq := int(uintptr(data) >> 1)
			was := uintptr(data) & 1 != 0
			if t.page == nil || t.page.hidden_seq != seq do return
			x, y, light := parse_sleep_probe(result)
			if light && may_sleep(t) {
				tab_sleep(t, x, y)
			} else if was && may_freeze(t) {
				freeze(t)
			}
		}, rawptr(uintptr(l.seq) << 1 | uintptr(was ? 1 : 0)))
	}, l)
}

/// the browser goes; the last frame, the address and the scroll stay
@(private="file") tab_sleep :: proc(t: ^Tab, x, y: f64) {
	p := t.page
	set_str(&p.restore_url, t.url)
	p.restore_scroll = {x, y}
	p.hold, p.frozen = false, false
	fling_stop(p)
	t.page = nil // kept out of tab_release_web
	tab_release_web(t) // the browser closes: its renderer is ended with it
	p.view = nil
	p.media, p.popup_on = false, false
	t.page = p
	// a new browser will know only the address
	t.loading, t.progress, t.can_back, t.can_forward = false, 1, false, false
	browser_tab_changed(t)
}

/// a sleeping tab (no browser, its last frame kept)
cef_tab_asleep :: proc(t: ^Tab) -> bool {
	return t != nil && t.cv == nil && t.page != nil && t.page.view == nil && len(t.url) > 0
}

/// the main frame of a woken tab loaded: back where it was, and its frames
/// show again
cef_sleep_woke :: proc(t: ^Tab, frame: ^cef_frame_t) {
	p := t.page
	if p == nil do return
	if len(p.restore_url) > 0 {
		if from_userfree(frame.get_url(frame)) == p.restore_url && (p.restore_scroll.x != 0 || p.restore_scroll.y != 0) {
			run_in(frame, fmt.tprintf("scrollTo(%d, %d)", int(p.restore_scroll.x), int(p.restore_scroll.y)))
		}
		delete(p.restore_url)
		p.restore_url = ""
	}
	if p.hold {
		p.hold = false
		if v := p.view; v != nil && v.host != nil do v.host.invalidate(v.host, PET_VIEW)
	}
}

// ---- pure logic, no CEF in it (scratch tests copy it from between the
// markers) ---- BEGIN CEF_LOGIC_SLEEP

/// sites never put to sleep, whatever they look like (media, by the user's
/// rule: YouTube and its kin)
keep_awake_host :: proc(h: string) -> bool {
	KEEP :: [?]string{"youtube.com", "youtube-nocookie.com", "youtu.be", "music.youtube.com", "twitch.tv", "spotify.com", "soundcloud.com", "netflix.com", "vimeo.com", "meet.google.com", "teams.microsoft.com", "zoom.us", "discord.com", "web.whatsapp.com", "web.telegram.org"}
	for k in KEEP do if h == k || strings.has_suffix(h, k) && len(h) > len(k) && h[len(h) - len(k) - 1] == '.' do return true
	return false
}

/// the probe's answer: "1,x,y" when light
parse_sleep_probe :: proc(r: string) -> (x, y: f64, light: bool) {
	if !strings.has_prefix(r, "1,") do return
	rest := r[2:]
	i := strings.index_byte(rest, ',')
	if i < 0 do return
	xv, ok1 := strconv.parse_f64(rest[:i])
	yv, ok2 := strconv.parse_f64(rest[i + 1:])
	if !ok1 || !ok2 do return
	return max(xv, 0), max(yv, 0), true
}

/// Chromium's own pages and tools: chrome://, chrome-untrusted://,
/// devtools://, view-source:, and every about: page but about:blank and
/// about:srcdoc (about:flags, about:labs... are chrome:// ones)
internal_url :: proc(u: string) -> bool {
	i := strings.index_byte(u, ':')
	if i <= 0 do return false
	scheme := strings.to_lower(strings.trim_space(u[:i]), context.temp_allocator)
	switch scheme {
	case "chrome", "chrome-untrusted", "chrome-extension", "chrome-search", "chrome-native", "devtools", "view-source", "chrome-devtools":
		return true
	case "about":
		rest := u[i + 1:]
		if j := strings.index_any(rest, "?#"); j >= 0 do rest = rest[:j]
		rest = strings.to_lower(rest, context.temp_allocator)
		return rest != "blank" && rest != "srcdoc"
	}
	return false
}

/// Chromium's PDF viewer (an extension of Chromium's own, in a frame of
/// the page that shows the PDF)
PDF_EXTENSION :: "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/"

/// what a frame may not load: in the main frame (and the address bar),
/// every internal page; in a page's frames, the same but for what
/// Chromium itself puts there: the PDF viewer, its error pages, print
/// preview
internal_url_in_frame :: proc(u: string, main: bool) -> bool {
	if !internal_url(u) do return false
	if main do return true
	lower := strings.to_lower(u[:min(len(u), 64)], context.temp_allocator)
	for ok in ([?]string{PDF_EXTENSION, "chrome://print/", "chrome-untrusted://print/", "chrome://pdf-viewer/"}) do if strings.has_prefix(lower, ok) do return false
	return true
}

/// an address a new tab may be opened with from page_url: printable text
/// with a scheme of the web's (never a drag's data, a script, or a
/// garbled string); file: only from a file: page (local documentation)
url_plausible_from :: proc(u, page_url: string) -> bool {
	if url_plausible(u) do return true
	return has_prefix_fold(u, "file:") && has_prefix_fold(page_url, "file:") && printable(u)
}

@(private="file") has_prefix_fold :: proc(s, p: string) -> bool {
	return len(s) >= len(p) && strings.equal_fold(s[:len(p)], p)
}

@(private="file") printable :: proc(u: string) -> bool {
	if len(u) == 0 || len(u) > 1 << 16 do return false
	for r in u do if r < 0x20 || r == 0x7f || r == 0xfffd do return false
	return true
}

/// an address a tab may be opened with: printable text with a scheme of
/// the web's (never a drag's data, a script, or a garbled string)
url_plausible :: proc(u: string) -> bool {
	if len(u) == 0 || len(u) > 1 << 16 do return false
	for r in u {
		if r < 0x20 || r == 0x7f || r == 0xfffd do return false
	}
	lower := strings.to_lower(u[:min(len(u), 12)], context.temp_allocator)
	for p in ([?]string{"http://", "https://", "about:blank", "mailto:"}) do if strings.has_prefix(lower, p) do return true
	return false
}

// ---- END CEF_LOGIC_SLEEP

