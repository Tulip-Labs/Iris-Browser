// Shields for an engine without WebKit's content rules (CEF): the very
// rules rules.odin makes for WebKit (converter_finish's JSON, with the
// lists' "||host^" rules and Iris's own domains in it), read once and
// matched per request. Same order as WebKit: a block counts unless an
// "ignore-previous-rules" rule after it matches too. Rules are indexed so a
// request tries few of them: by the request's host (the host patterns, most
// of the rules), by the page's domain ("if-domain" rules on every URL), and
// by four bytes of literal text in their url-filter (the rest).
//
// A Matcher is built on a thread and only read afterwards, so any thread
// (CEF's IO thread) may match against it.
package iris

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:text/regex"

Req_Type :: enum u8 { document, image, style_sheet, script, font, raw, svg_document, media, popup, ping, fetch, websocket, other }
Req_Types :: bit_set[Req_Type; u16]

Rule_Action :: enum u8 { block, ignore, hide }

Net_Rule :: struct {
	index:       i32,
	action:      Rule_Action,
	types:       Req_Types, // empty: every type
	party:       u8, // 0 any, 1 first-party, 2 third-party
	child_frame: bool, // only loads in a child frame
	if_dom:      []string, // "*a.com" is a.com and under it, "a.com" only it
	unless_dom:  []string,
	host:        string, // the url-filter was host_pattern(host)
	re:          regex.Regular_Expression,
	has_re:      bool,
	/// four bytes every URL it matches contains (literal_gram)
	gram:        u32,
	has_gram:    bool,
	runs:        []string, // (while building: the literal text to pick it from)
	selector:    string,
}

Matcher :: struct {
	arena:      virtual.Arena,
	by_host:    map[string][dynamic]^Net_Rule,
	by_page:    map[string][dynamic]^Net_Rule,
	by_gram:    map[u32][dynamic]^Net_Rule,
	every:      [dynamic]^Net_Rule,
	/// hiding rules for every page (generic, or "unless-domain")
	hides:      [dynamic]^Net_Rule,
	rules:      int,
}

/// a matcher from converter_finish's parts (one part, or many: rules are
/// numbered across them); nil when nothing could be read
matcher_from_rules :: proc(parts: []string) -> ^Matcher {
	m := new(Matcher)
	if virtual.arena_init_growing(&m.arena) != nil {
		free(m)
		return nil
	}
	context.allocator = virtual.arena_allocator(&m.arena)
	index: i32 = 0
	read: [dynamic]^Net_Rule
	defer delete(read)
	for part in parts {
		v, err := json.parse_string(part, parse_integers = false, allocator = context.temp_allocator)
		if err != nil do continue
		arr, ok := v.(json.Array)
		if !ok do continue
		for item in arr {
			if r, rok := read_rule(item, index); rok do append(&read, r)
			index += 1
		}
		free_all(context.temp_allocator)
	}
	// each regex rule is filed under the four bytes of its literal text
	// that the fewest rules share, so a URL tries few regexes
	seen := make(map[u32]int, 1 << 16, context.temp_allocator)
	for r in read do for run in r.runs do for k in 0 ..= len(run) - 4 do seen[gram(transmute([]u8)run[k:k + 4])] += 1
	for r in read {
		best := max(int)
		for run in r.runs do for k in 0 ..= len(run) - 4 {
			g := gram(transmute([]u8)run[k:k + 4])
			if n := seen[g]; n < best do r.gram, r.has_gram, best = g, true, n
		}
		r.runs = nil
		add_rule(m, r)
		m.rules += 1
	}
	free_all(context.temp_allocator)
	if m.rules == 0 {
		matcher_free(m)
		return nil
	}
	return m
}

matcher_free :: proc(m: ^Matcher) {
	if m == nil do return
	virtual.arena_destroy(&m.arena)
	free(m)
}

@(private="file") str_list :: proc(v: json.Value) -> []string {
	arr, ok := v.(json.Array)
	if !ok do return nil
	out := make([]string, len(arr))
	n := 0
	for x in arr do if s, sok := x.(json.String); sok {
		out[n] = strings.to_lower(s)
		n += 1
	}
	return out[:n]
}

@(private="file") read_rule :: proc(item: json.Value, index: i32) -> (r: ^Net_Rule, ok: bool) {
	obj := item.(json.Object) or_return
	trig := obj["trigger"].(json.Object) or_return
	act := obj["action"].(json.Object) or_return
	kind := act["type"].(json.String) or_return
	filter := trig["url-filter"].(json.String) or_return
	r = new(Net_Rule)
	r.index = index
	switch kind {
	case "block": r.action = .block
	case "ignore-previous-rules": r.action = .ignore
	case "css-display-none":
		r.action = .hide
		r.selector = strings.clone(act["selector"].(json.String) or_return)
	case: return nil, false
	}
	for t in str_list(trig["resource-type"]) {
		switch t {
		case "document": r.types += {.document}
		case "image": r.types += {.image}
		case "style-sheet": r.types += {.style_sheet}
		case "script": r.types += {.script}
		case "font": r.types += {.font}
		case "raw": r.types += {.raw}
		case "svg-document": r.types += {.svg_document}
		case "media": r.types += {.media}
		case "popup": r.types += {.popup}
		case "ping": r.types += {.ping}
		case "fetch": r.types += {.fetch}
		case "websocket": r.types += {.websocket}
		case "other": r.types += {.other}
		}
	}
	for t in str_list(trig["load-type"]) {
		if t == "first-party" do r.party = 1
		if t == "third-party" do r.party = 2
	}
	for t in str_list(trig["load-context"]) do if t == "child-frame" do r.child_frame = true
	r.if_dom = str_list(trig["if-domain"])
	r.unless_dom = str_list(trig["unless-domain"])
	if filter != ".*" {
		if h, hok := host_of_pattern(filter); hok {
			r.host = h
		} else {
			re, err := regex.create(filter, {.Case_Insensitive, .No_Capture}, context.allocator, context.temp_allocator)
			if err != nil do return nil, false
			r.re, r.has_re = re, true
			r.runs = literal_runs(filter)
		}
	}
	return r, true
}

/// host_pattern(d) read back: d
@(private="file") host_of_pattern :: proc(f: string) -> (string, bool) {
	PRE :: "^[^:]+://+([^:/]+\\.)?"
	SUF :: "[:/]"
	if !strings.has_prefix(f, PRE) || !strings.has_suffix(f, SUF) do return "", false
	body := f[len(PRE):len(f) - len(SUF)]
	b := strings.builder_make()
	for i := 0; i < len(body); i += 1 {
		c := body[i]
		if c == '\\' && i + 1 < len(body) {
			i += 1
			strings.write_byte(&b, body[i])
			continue
		}
		// anything but an escaped literal: not a plain host
		if strings.index_byte(".*+?()[]{}|^$", c) >= 0 do return "", false
		strings.write_byte(&b, c)
	}
	return strings.to_lower(strings.to_string(b)), true
}

/// the runs of literal text (lower-cased) every match of the url-filter
/// contains, those of 4 bytes or more
@(private="file") literal_runs :: proc(f: string) -> []string {
	runs: [dynamic]string
	cur: [dynamic]u8
	flush :: proc(runs: ^[dynamic]string, cur: ^[dynamic]u8) {
		if len(cur) >= 4 do append(runs, string(cur[:]))
		cur^ = {}
	}
	for i := 0; i < len(f); i += 1 {
		c := f[i]
		switch c {
		case '\\':
			if i + 1 < len(f) {
				i += 1
				x := f[i]
				if (x >= 'a' && x <= 'z') || (x >= 'A' && x <= 'Z') || (x >= '0' && x <= '9') {
					flush(&runs, &cur) // \d, \w...: a class
				} else {
					append(&cur, x)
				}
			}
		case '[':
			flush(&runs, &cur)
			for i < len(f) && f[i] != ']' do i += 1
		case '?', '*':
			// the character before is optional: not part of the run
			if len(cur) > 0 do pop(&cur)
			flush(&runs, &cur)
		case '+':
			flush(&runs, &cur) // one or more: what came before stays
		case '.', '(', ')', '|', '^', '$', '{', '}':
			flush(&runs, &cur)
		case:
			append(&cur, c >= 'A' && c <= 'Z' ? c + 32 : c)
		}
	}
	flush(&runs, &cur)
	return runs[:]
}

@(private="file") gram :: #force_inline proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private="file") add_rule :: proc(m: ^Matcher, r: ^Net_Rule) {
	put :: proc(mp: ^map[$K][dynamic]^Net_Rule, k: K, r: ^Net_Rule) {
		if k not_in mp do mp[k] = make([dynamic]^Net_Rule)
		append(&mp[k], r)
	}
	if r.action == .hide && len(r.if_dom) == 0 {
		append(&m.hides, r)
		return
	}
	switch {
	case len(r.host) > 0:
		put(&m.by_host, r.host, r)
	case !r.has_re && len(r.if_dom) > 0:
		for d in r.if_dom do put(&m.by_page, strings.trim_prefix(d, "*"), r)
	case r.has_re:
		// a regex rule with a gram is tried only when the URL has it
		if r.has_gram {
			put(&m.by_gram, r.gram, r)
		} else {
			append(&m.every, r)
		}
	case:
		append(&m.every, r)
	}
}

/// d (a rule's domain, "*a.com" or "a.com") covers host
@(private="file") dom_match :: proc(d, host: string) -> bool {
	if strings.has_prefix(d, "*") {
		base := d[1:]
		return host == base || (len(host) > len(base) && strings.has_suffix(host, base) && host[len(host) - len(base) - 1] == '.')
	}
	return host == d
}

@(private="file") applies :: proc(r: ^Net_Rule, url, page_host: string, t: Req_Type, third, child: bool) -> bool {
	if r.types != {} && t not_in r.types do return false
	if r.party == 1 && third do return false
	if r.party == 2 && !third do return false
	if r.child_frame && !child do return false
	if len(r.if_dom) > 0 {
		hit := false
		for d in r.if_dom do if dom_match(d, page_host) {
			hit = true
			break
		}
		if !hit do return false
	}
	for d in r.unless_dom do if dom_match(d, page_host) do return false
	if r.has_re {
		_, ok := regex.match_and_allocate_capture(r.re, url, context.temp_allocator, context.temp_allocator)
		return ok
	}
	return true
}

@(private="file") Hits :: struct {
	block, ignore: i32,
}

@(private="file") consider :: proc(h: ^Hits, r: ^Net_Rule, url, page_host: string, t: Req_Type, third, child: bool) {
	// only a later rule than the one already found can change the answer
	switch r.action {
	case .block: if r.index <= h.block do return
	case .ignore: if r.index <= h.ignore do return
	case .hide: return
	}
	if !applies(r, url, page_host, t, third, child) do return
	if r.action == .block do h.block = r.index
	else do h.ignore = r.index
}

@(private="file") hits :: proc(m: ^Matcher, url0, host, page_host: string, t: Req_Type, child: bool) -> Hits {
	h := Hits{-1, -1}
	url := strings.to_lower(url0, context.temp_allocator)
	third := site_of(host) != site_of(page_host)
	for x := host; len(x) > 0; {
		if rs, ok := m.by_host[x]; ok do for r in rs do consider(&h, r, url, page_host, t, third, child)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	for x := page_host; len(x) > 0; {
		if rs, ok := m.by_page[x]; ok do for r in rs do consider(&h, r, url, page_host, t, third, child)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	if len(m.by_gram) > 0 do for i := 0; i + 4 <= len(url); i += 1 {
		if rs, ok := m.by_gram[gram(transmute([]u8)url[i:i + 4])]; ok do for r in rs do consider(&h, r, url, page_host, t, third, child)
	}
	for r in m.every do consider(&h, r, url, page_host, t, third, child)
	return h
}

/// the page's own exception ("@@...$document": its document matches an
/// ignore rule for documents): every request on the page counts it, as
/// WebKit does. Worked out once a page (matcher_blocks' page_ignore); -1
/// for none.
matcher_page_ignore :: proc(m: ^Matcher, page_url, page_host: string) -> i32 {
	if m == nil do return -1
	defer free_all(context.temp_allocator)
	h := Hits{-1, -1}
	url := strings.to_lower(page_url, context.temp_allocator)
	check :: proc(h: ^Hits, rs: [dynamic]^Net_Rule, url, page_host: string) {
		for r in rs do if r.action == .ignore && .document in r.types do consider(h, r, url, page_host, .document, false, false)
	}
	for x := page_host; len(x) > 0; {
		if rs, ok := m.by_host[x]; ok do check(&h, rs, url, page_host)
		if rs, ok := m.by_page[x]; ok do check(&h, rs, url, page_host)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	if len(m.by_gram) > 0 do for i := 0; i + 4 <= len(url); i += 1 {
		if rs, ok := m.by_gram[gram(transmute([]u8)url[i:i + 4])]; ok do check(&h, rs, url, page_host)
	}
	check(&h, m.every, url, page_host)
	return h.ignore
}

/// whether a request is blocked: url and its host, the top page's host and
/// its matcher_page_ignore, the request's type, and whether it loads in a
/// child frame
matcher_blocks :: proc(m: ^Matcher, url, host, page_host: string, page_ignore: i32, t: Req_Type, child := false) -> bool {
	if m == nil || len(host) == 0 do return false
	defer free_all(context.temp_allocator)
	h := hits(m, url, host, page_host, t, child)
	return h.block >= 0 && h.block > max(h.ignore, page_ignore)
}

/// the style that hides what the rules hide on this page ("" for nothing)
matcher_css :: proc(m: ^Matcher, page_url, page_host: string, allocator := context.allocator) -> string {
	if m == nil || len(page_host) == 0 do return ""
	h := hits(m, page_url, page_host, page_host, .document, false)
	b := strings.builder_make(allocator)
	add :: proc(b: ^strings.Builder, r: ^Net_Rule, page_host: string, after: i32) {
		if r.action != .hide || r.index <= after do return
		for d in r.unless_dom do if dom_match(d, page_host) do return
		if len(r.if_dom) > 0 {
			hit := false
			for d in r.if_dom do if dom_match(d, page_host) do hit = true
			if !hit do return
		}
		// one rule a selector list: a selector the engine cannot read
		// loses only its own list
		strings.write_string(b, r.selector)
		strings.write_string(b, "{display:none!important}\n")
	}
	for r in m.hides do add(&b, r, page_host, h.ignore)
	for x := page_host; len(x) > 0; {
		if rs, ok := m.by_page[x]; ok do for r in rs do add(&b, r, page_host, h.ignore)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	free_all(context.temp_allocator)
	return strings.to_string(b)
}

// ---------------------------------------------------------------- tests

@(test) test_matcher :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .aggressive}
	converter_add_list(&c, "||ads.example.com^\n/banner/*$image\nnews.example##.promo\n##.ad-slot\n@@||good.example^$document\n||tracker.example^$third-party\n")
	converter_add_domains(&c, {"builtin-ads.example"})
	m := matcher_from_rules(converter_finish(&c, 1 << 30))
	testing.expect(t, m != nil)
	defer matcher_free(m)
	no := i32(-1)
	testing.expect(t, matcher_blocks(m, "https://x.ads.example.com/a.js", "x.ads.example.com", "site.example", no, .script))
	testing.expect(t, matcher_blocks(m, "https://builtin-ads.example/p", "builtin-ads.example", "site.example", no, .image))
	testing.expect(t, matcher_blocks(m, "https://cdn.site.example/banner/1.png", "cdn.site.example", "site.example", no, .image))
	testing.expect(t, !matcher_blocks(m, "https://cdn.site.example/banner/1.js", "cdn.site.example", "site.example", no, .script))
	testing.expect(t, !matcher_blocks(m, "https://site.example/app.js", "site.example", "site.example", no, .script))
	// third-party only
	testing.expect(t, !matcher_blocks(m, "https://tracker.example/t", "tracker.example", "tracker.example", no, .script))
	testing.expect(t, matcher_blocks(m, "https://tracker.example/t", "tracker.example", "site.example", no, .script))
	// a page's own exception covers everything on it
	good := matcher_page_ignore(m, "https://good.example/", "good.example")
	testing.expect(t, good >= 0)
	testing.expect(t, !matcher_blocks(m, "https://x.ads.example.com/a.js", "x.ads.example.com", "good.example", good, .script))
	testing.expect_value(t, matcher_page_ignore(m, "https://news.example/", "news.example"), no)
	// sign-in pages, and requests to them, are left alone
	testing.expect(t, !matcher_blocks(m, "https://x.ads.example.com/a.js", "x.ads.example.com", "accounts.google.com", no, .script))
	// YouTube's ad breaks go, the rest of YouTube stays
	testing.expect(t, matcher_blocks(m, "https://www.youtube.com/pagead/x", "www.youtube.com", "www.youtube.com", no, .fetch))
	testing.expect(t, !matcher_blocks(m, "https://www.youtube.com/watch?v=1", "www.youtube.com", "www.youtube.com", no, .fetch))
	css := matcher_css(m, "https://news.example/", "news.example")
	testing.expect(t, strings.contains(css, ".promo{"))
	testing.expect(t, strings.contains(css, ".ad-slot{"))
	testing.expect(t, !strings.contains(matcher_css(m, "https://other.example/", "other.example"), ".promo"))
}
