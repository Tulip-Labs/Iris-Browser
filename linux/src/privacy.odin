// The privacy report, as in Safari: the trackers Shields stopped on this
// page, and today. Engines block inside themselves and tell nobody, so Iris
// looks once, when a page has finished loading (and again when you open the
// report): the hosts the page's elements point at, and the ones that did
// load. A known ad or tracker host (Iris's list) that the page asked for and
// that never loaded was stopped. Requests a script makes by itself may be
// missing; nothing is counted twice. Only tracker names and numbers are
// kept, never the sites you visit; private and sandboxed tabs add nothing.
package iris

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

/// one look at a page: is it an article (the reader), which hosts do its
/// elements ask for, which loaded (cheap: a few selectors, once)
SURVEY_JS :: `(() => {
  const d = new Set(), l = new Set(), me = location.hostname;
  const host = u => { try { return new URL(u, location.href).hostname; } catch (e) { return ''; } };
  for (const e of document.querySelectorAll('script[src],img[src],iframe[src],embed[src],source[src],video[src],audio[src],link[href]')) {
    const h = host(e.getAttribute('src') || e.getAttribute('href') || '');
    if (h && h !== me) d.add(h);
  }
  for (const r of performance.getEntriesByType('resource')) { const h = host(r.name); if (h) l.add(h); }
  let text = 0, paras = 0;
  const root = document.querySelector('article') || document.querySelector('main') || document.body;
  if (root) for (const p of root.querySelectorAll('p')) { const n = p.textContent.trim().length; if (n > 80) { text += n; paras++; } }
  return JSON.stringify({ a: paras >= 4 && text > 1500, d: [...d].slice(0, 400), l: [...l].slice(0, 800) });
})()`

@(private="file") Survey :: struct {
	a: bool,
	d: []string,
	l: []string,
}

Tracker_Count :: struct {
	host: string,
	n:    int,
}

/// today's numbers (kept in privacy.json, a day at a time)
Privacy_Day :: struct {
	day:      i64,
	blocked:  int,
	pages:    int,
	trackers: [dynamic]Tracker_Count,
}

@(private="file") today: Privacy_Day
@(private="file") today_loaded, today_dirty: bool

@(private="file") day_now :: proc() -> i64 { return i64(now_s() / 86400) }

@(private="file") today_ensure :: proc() {
	if !today_loaded {
		today_loaded = true
		if v, ok := load_json(Privacy_Day, "privacy.json"); ok do today = v
	}
	if d := day_now(); today.day != d {
		for x in today.trackers do delete(x.host)
		clear(&today.trackers)
		today.day, today.blocked, today.pages = d, 0, 0
	}
}

/// a page has loaded: one look at it (only where Shields are up, and never
/// at the reader's own page)
survey_page :: proc(t: ^Tab) {
	if t.reader || !strings.has_prefix(t.url, "http") do return
	tab_run_isolated(t, SURVEY_JS, proc(t: ^Tab, result: string) {
		s: Survey
		if json.unmarshal(transmute([]u8)result, &s, allocator = context.temp_allocator) != nil do return
		host, _ := host_of(t.url, context.temp_allocator)
		// the reader: an article, never Google's or YouTube's pages
		site := site_of(host)
		t.article = s.a && !is_ai_mode(t.url) && site != "google.com" && site != "youtube.com"
		if shields_on_for(host) {
			stopped := stopped_trackers(s.d, s.l, host, host_blocked)
			had := len(t.trackers)
			fresh := 0
			outer: for h in stopped {
				for x in t.trackers do if x == h do continue outer
				append(&t.trackers, strings.clone(h))
				fresh += 1
				if !tab_is_private(t) && !t.sandboxed do day_count(h)
			}
			if fresh > 0 && had == 0 && !tab_is_private(t) && !t.sandboxed {
				today.pages += 1
				privacy_later()
			}
		}
		browser_tab_changed(t)
	})
}

/// the trackers a page asked for (asked) that never loaded (loaded): known
/// ones (blocked), of other sites than the page's own, each once
stopped_trackers :: proc(asked, loaded: []string, page_host: string, blocked: proc(h: string) -> bool, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	own := site_of(page_host)
	outer: for h0 in asked {
		h := strings.to_lower(h0, context.temp_allocator)
		if site_of(h) == own || !blocked(h) do continue
		for x in loaded do if strings.equal_fold(x, h) do continue outer
		for x in out do if x == h do continue outer
		append(&out, h)
	}
	return out[:]
}

@(private="file") day_count :: proc(h: string) {
	today_ensure()
	today.blocked += 1
	for &x in today.trackers do if x.host == h {
		x.n += 1
		privacy_later()
		return
	}
	if len(today.trackers) < 500 do append(&today.trackers, Tracker_Count{strings.clone(h), 1})
	privacy_later()
}

@(private="file") privacy_later :: proc() {
	if today_dirty do return
	today_dirty = true
	after(5000, proc(_: rawptr) { privacy_flush() }, nil)
}

privacy_flush :: proc() {
	if !today_dirty do return
	today_dirty = false
	save_json("privacy.json", today)
}

/// the day's numbers forgotten (clear on exit)
privacy_forget :: proc() {
	for x in today.trackers do delete(x.host)
	clear(&today.trackers)
	today.blocked, today.pages = 0, 0
	today_dirty = false
	today_loaded = true
	os.remove(data_path("privacy.json"))
}

/// the report opens: the page is looked at again (what came since loading)
privacy_open :: proc(anchor: [4]f32) {
	if t := b.current; t != nil && tab_has_view(t) do survey_page(t)
	open_panel(.Report, anchor, true)
}

/// the report's rows (chrome.odin draws them)
privacy_items :: proc(items: ^[dynamic]Item) {
	today_ensure()
	t := b.current
	append(items, Item{kind = .Title, text = "Privacy Report"})
	host := ""
	if t != nil do host, _ = host_of(t.url, context.temp_allocator)
	n := t != nil ? len(t.trackers) : 0
	switch {
	case t == nil || !strings.has_prefix(t.url, "http"):
		append(items, Item{kind = .Note, text = "Open a site to see what Shields stop on it."})
	case !shields_on_for(host):
		append(items, Item{kind = .Note, text = fmt.tprintf("Shields are off for %s.", site_of(host))})
	case n == 0:
		append(items, Item{kind = .Note, text = fmt.tprintf("No known trackers tried to reach you on %s.", site_of(host))})
	case:
		append(items, Item{kind = .Head, text = fmt.tprintf("%d stopped on %s", n, site_of(host))})
		for h, i in t.trackers {
			if i == 8 {
				append(items, Item{kind = .Note, text = fmt.tprintf("and %d more", n - 8)})
				break
			}
			row(items, .Shield_On, h, {}, disabled = false)
		}
	}
	append(items, Item{kind = .Sep}, Item{kind = .Head, text = "Today"})
	if today.blocked == 0 {
		append(items, Item{kind = .Note, text = "Nothing stopped yet today."})
	} else {
		append(items, Item{kind = .Note, text = fmt.tprintf("%d trackers stopped on %d %s.", today.blocked, today.pages, today.pages == 1 ? "page" : "pages")})
		top := slice.clone(today.trackers[:], context.temp_allocator)
		slice.sort_by(top, proc(a, z: Tracker_Count) -> bool { return a.n > z.n })
		for x in top[:min(5, len(top))] do row(items, .Shield_On, x.host, {}, fmt.tprint(x.n))
	}
	append(items, Item{kind = .Note, text = "Known ad and tracker hosts this page asked for that never loaded. Only these names and numbers are kept, never the sites you visit."})
}

@(test) test_stopped_trackers :: proc(t: ^testing.T) {
	blocked :: proc(h: string) -> bool { return strings.has_suffix(h, "doubleclick.net") || strings.has_suffix(h, "tracker.example") || h == "ads.news.com" }
	asked := []string{"securepubads.g.doubleclick.net", "cdn.site.org", "a.tracker.example", "a.tracker.example", "ads.news.com", "Loaded.Tracker.Example"}
	loaded := []string{"cdn.site.org", "loaded.tracker.example"}
	got := stopped_trackers(asked, loaded, "www.news.com", blocked)
	// the page's own site and what loaded are never counted; each one once
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "securepubads.g.doubleclick.net")
	testing.expect_value(t, got[1], "a.tracker.example")
}
