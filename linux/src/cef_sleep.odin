// The CEF engine's sleeping tabs (IRIS_ENGINE=cef): a light page you leave
// (an article, a blog, documentation) goes to sleep at once. Its browser
// closes (its renderer with it: cef_engine.odin's reaper), and what stays
// is its last frame (the Page with no view), its address and where it was
// scrolled. Coming back to it makes the browser again, loads the address,
// shows the last frame meanwhile and scrolls back when it has loaded.
//
// What is never put to sleep: a page with sound or video (YouTube above
// all), a live connection (WebSocket, WebRTC, EventSource), a service
// worker in control (a web app), something typed into it, a focused field,
// more than a few frames, a big script heap, fullscreen or picture in
// picture; also a pinned tab, the peek, a pop-up, a tab in the sandbox (its
// world would be gone), a page that came from a form (waking would send it
// again), the reader, a page still loading or with a dialog open.
// IRIS_CEF_SLEEP=0 turns it off.
//
// What sleeping costs: the tab's back and forward history (a new browser
// knows only the address), and anything the page kept in memory only.
package iris

import "core:strconv"
import "core:strings"

// (not indented: the whole file is this engine's)
when ENGINE_CEF {

/// a woken tab's last frame stays at most this long while it loads again
SLEEP_HOLD_S :: 4.0
/// a page whose scripts hold more than this is not light (bytes)
SLEEP_HEAP_MAX :: 64 << 20
SLEEP_FRAMES_MAX :: 3

/// at the document's start (main frame): live connections counted, and
/// whether you typed in it (read by SLEEP_PROBE_JS)
SLEEP_WATCH_JS :: `(() => {
  if (window.__irisLive) return;
  let live = 0, typed = false;
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
  addEventListener('input', e => { if (e.isTrusted) typed = true; }, true);
  Object.defineProperty(window, '__irisLive', { value: () => live + (typed ? 1000 : 0) });
})();`

/// is the page light? "1,<scrollX>,<scrollY>" if so, else "0"
@(private="file") SLEEP_PROBE_JS :: `(() => {
  const d = document;
  if (d.querySelector('video,audio')) return '0';
  if (navigator.serviceWorker && navigator.serviceWorker.controller) return '0';
  const live = window.__irisLive;
  if (typeof live !== 'function' || live() > 0) return '0';
  const a = d.activeElement;
  if (a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName))) return '0';
  if (d.designMode === 'on' || d.fullscreenElement || d.pictureInPictureElement) return '0';
  if (d.querySelectorAll('iframe').length > ` + SLEEP_FRAMES_MAX_JS + `) return '0';
  const m = performance.memory;
  if (m && m.usedJSHeapSize > ` + SLEEP_HEAP_MAX_JS + `) return '0';
  return '1,' + Math.round(scrollX) + ',' + Math.round(scrollY);
})()`

@(private="file") SLEEP_FRAMES_MAX_JS :: "3"
@(private="file") SLEEP_HEAP_MAX_JS :: "67108864"
#assert(SLEEP_FRAMES_MAX == 3 && SLEEP_HEAP_MAX == 67108864, "keep the probe's numbers in step")

@(private="file") sleep_off: int // 0 not read yet, 1 on, 2 off

@(private="file") sleep_enabled :: proc() -> bool {
	if sleep_off == 0 do sleep_off = env("IRIS_CEF_SLEEP") == "0" ? 2 : 1
	return sleep_off == 1
}

/// what Iris itself knows says the tab may sleep (before asking the page)
@(private="file") may_sleep :: proc(t: ^Tab) -> bool {
	if t == nil || !browser_has_tab(t) || t == b.current || t == b.peek do return false
	v := t.cv
	p := t.page
	if v == nil || p == nil || p.visible || v.browser == nil do return false
	if t.pinned || t.held || t.sandboxed || t.reader || t.reader_pending || t.loading do return false
	if t.audio || p.media || v.posted || t.cert_error != nil || b.dialog_tab == t do return false
	if !strings.has_prefix(t.url, "http") do return false
	h, _ := host_of(t.url, context.temp_allocator)
	return !keep_awake_host(h)
}

/// a tab left the screen: if its page is light, it sleeps now
cef_sleep_consider :: proc(t: ^Tab) {
	if !sleep_enabled() || !may_sleep(t) do return
	run_job(t, main_frame(t.cv), SLEEP_PROBE_JS, proc(t: ^Tab, result: string, data: rawptr) {
		x, y, light := parse_sleep_probe(result)
		// still out of sight, still light by what Iris knows
		if !light || !may_sleep(t) do return
		tab_sleep(t, x, y)
	})
}

/// the browser goes; the last frame, the address and the scroll stay
@(private="file") tab_sleep :: proc(t: ^Tab, x, y: f64) {
	p := t.page
	set_str(&p.restore_url, t.url)
	p.restore_scroll = {x, y}
	p.hold = false
	fling_stop(p)
	t.page = nil // kept out of tab_release_web
	tab_release_web(t) // the browser closes: its renderer is ended with it
	p.view = nil
	p.media, p.popup_on = false, false
	t.page = p
	t.loading, t.progress = false, 1
	browser_tab_changed(t)
}

/// the main frame of a woken tab loaded: back where it was, and its frames
/// show again
cef_sleep_woke :: proc(t: ^Tab, frame: ^cef_frame_t) {
	p := t.page
	if p == nil do return
	if len(p.restore_url) > 0 {
		if from_userfree(frame.get_url(frame)) == p.restore_url && (p.restore_scroll.x != 0 || p.restore_scroll.y != 0) {
			run_in(frame, fmt_scroll(p.restore_scroll))
		}
		delete(p.restore_url)
		p.restore_url = ""
	}
	if p.hold {
		p.hold = false
		if v := p.view; v != nil && v.host != nil do v.host.invalidate(v.host, PET_VIEW)
	}
}

@(private="file") fmt_scroll :: proc(s: [2]f64) -> string {
	buf: [64]u8
	b := strings.builder_from_bytes(buf[:])
	strings.write_string(&b, "scrollTo(")
	strings.write_int(&b, int(s.x))
	strings.write_string(&b, ", ")
	strings.write_int(&b, int(s.y))
	strings.write_string(&b, ")")
	return strings.clone(strings.to_string(b), context.temp_allocator)
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

} // when ENGINE_CEF
