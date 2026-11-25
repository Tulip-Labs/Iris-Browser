// Shields for an engine without WebKit's content rules (CEF): the very
// rules rules.odin makes for WebKit (converter_rules), kept in a compact
// file (matcher_bytes: what starts take, without the lists read again) and
// matched per request. Same order as WebKit: a block counts unless an
// "ignore-previous-rules" rule after it matches too. The whole-host blocks
// are no rules here but host sets (rules.odin), looked up label by label;
// the other rules are indexed so a request tries few of them: by the
// request's host, by the page's domain ("if-domain" rules on every URL),
// and by four bytes of literal text in their url-filter (the rest), whose
// regular expression is compiled the first time a URL gets that far.
//
// A Matcher is only read once made, so any thread (CEF's IO thread) may
// match against it (a regex compiled late is made under a lock). Matching
// uses the calling thread's temporary allocator inside a guard: what the
// caller has there stays.
package iris

import "base:intrinsics"
import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
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
	has_re:      bool,
	/// 0 not compiled yet, 1 compiled, 2 cannot be (atomic)
	re_state:    i32,
	/// four bytes every URL it matches contains (literal_gram)
	gram:        u32,
	has_gram:    bool,
	if_dom:      []string, // "*a.com" is a.com and under it, "a.com" only it
	unless_dom:  []string,
	host:        string, // the url-filter is host_pattern(host)
	filter:      string, // else this regular expression
	selector:    string,
	re:          regex.Regular_Expression,
}

Matcher :: struct {
	arena:         virtual.Arena,
	/// the file it was read from: every string points into it
	data:          []u8,
	by_host:       map[string][dynamic]^Net_Rule,
	by_page:       map[string][dynamic]^Net_Rule,
	by_gram:       map[u32][dynamic]^Net_Rule,
	every:         [dynamic]^Net_Rule,
	/// hiding rules for every page (generic, or "unless-domain")
	hides:         [dynamic]^Net_Rule,
	rules:         int,
	/// where the whole-host blocks stand among the rules (Rules.block_at)
	block_at:      i32,
	hosts_any:     string,
	hosts_third:   string,
	builtin:       bool,
	builtin_third: bool,
	level:         Level,
	re_lock:       sync.Mutex,
	re_arena:      virtual.Arena,
}

// ---------------------------------------------------------------- the file

MATCHER_MAGIC :: "IRIS-SHIELD-MATCHER-1\n"

@(private="file") put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private="file") put_str :: proc(b: ^[dynamic]u8, s: string) {
	put_u32(b, u32(len(s)))
	append(b, s)
}

@(private="file") put_list :: proc(b: ^[dynamic]u8, l: []string) {
	put_u32(b, u32(len(l)))
	for s in l do put_str(b, s)
}

/// the rules as the matcher's file, key first (what they were made from:
/// a file with another key is never read as this one). From the heap: it
/// outlives the conversion's arena.
matcher_bytes :: proc(r: ^Rules, key: string) -> []u8 {
	// each regex rule is filed under the four bytes of its literal text
	// that the fewest rules share, so a URL tries few regexes
	grams := make([]u32, len(r.list))
	has := make([]bool, len(r.list))
	{
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		runs := make([][]string, len(r.list), context.temp_allocator)
		seen := make(map[u32]int, 1 << 16, context.temp_allocator)
		for x, i in r.list do if rule_has_re(x) {
			runs[i] = literal_runs(x.filter, context.temp_allocator)
			for run in runs[i] do for k in 0 ..= len(run) - 4 do seen[gram(transmute([]u8)run[k:k + 4])] += 1
		}
		for x, i in r.list do if rule_has_re(x) {
			best := max(int)
			for run in runs[i] do for k in 0 ..= len(run) - 4 {
				g := gram(transmute([]u8)run[k:k + 4])
				if n := seen[g]; n < best do grams[i], has[i], best = g, true, n
			}
		}
	}
	defer delete(grams)
	defer delete(has)
	size := len(MATCHER_MAGIC) + len(key) + len(r.hosts_any) + len(r.hosts_third) + 64
	for x in r.list do size += 40 + len(x.host) + len(x.filter) + len(x.selector) + (len(x.if_dom) + len(x.unless_dom)) * 24
	b := make([dynamic]u8, 0, size, runtime.heap_allocator())
	append(&b, MATCHER_MAGIC)
	put_str(&b, key)
	append(&b, u8(r.builtin), u8(r.builtin_third), u8(r.level))
	put_u32(&b, u32(r.block_at))
	put_str(&b, r.hosts_any)
	put_str(&b, r.hosts_third)
	put_u32(&b, u32(len(r.list)))
	for x, i in r.list {
		types := transmute(u16)x.types
		append(&b, u8(x.action), u8(types), u8(types >> 8), x.party, u8(x.frames), u8(has[i]))
		put_u32(&b, grams[i])
		put_str(&b, x.host)
		put_str(&b, x.filter)
		put_str(&b, x.selector)
		put_list(&b, x.if_dom)
		put_list(&b, x.unless_dom)
	}
	return b[:]
}

@(private="file") rule_has_re :: proc(x: Rule) -> bool {
	return len(x.host) == 0 && len(x.filter) > 0 && x.filter != ".*"
}

@(private="file") Reader :: struct {
	d:  []u8,
	at: int,
	ok: bool,
}

@(private="file") get_u8 :: proc(r: ^Reader) -> u8 {
	if r.at + 1 > len(r.d) {
		r.ok = false
		return 0
	}
	r.at += 1
	return r.d[r.at - 1]
}

@(private="file") get_u32 :: proc(r: ^Reader) -> u32 {
	if r.at + 4 > len(r.d) {
		r.ok = false
		return 0
	}
	v := u32(r.d[r.at]) | u32(r.d[r.at + 1]) << 8 | u32(r.d[r.at + 2]) << 16 | u32(r.d[r.at + 3]) << 24
	r.at += 4
	return v
}

@(private="file") get_str :: proc(r: ^Reader) -> string {
	n := int(get_u32(r))
	if !r.ok || n > len(r.d) - r.at {
		r.ok = false
		return ""
	}
	r.at += n
	return string(r.d[r.at - n:r.at])
}

@(private="file") get_list :: proc(r: ^Reader) -> []string {
	n := int(get_u32(r))
	if !r.ok || n > (len(r.d) - r.at) / 4 {
		r.ok = false
		return nil
	}
	if n == 0 do return nil
	out := make([]string, n)
	for i in 0 ..< n do out[i] = get_str(r)
	return out
}

/// the matcher in a file of matcher_bytes (which it then owns, and frees),
/// or nil (and the bytes freed) when the file is not one, or not this key's
matcher_load :: proc(data: []u8, key: string) -> ^Matcher {
	rd := Reader{d = data, at = len(MATCHER_MAGIC), ok = true}
	if len(data) < len(MATCHER_MAGIC) || string(data[:len(MATCHER_MAGIC)]) != MATCHER_MAGIC || get_str(&rd) != key || !rd.ok {
		delete(data, runtime.heap_allocator())
		return nil
	}
	m := new(Matcher, runtime.heap_allocator())
	m.data = data
	if virtual.arena_init_growing(&m.arena) != nil {
		matcher_free(m)
		return nil
	}
	context.allocator = virtual.arena_allocator(&m.arena)
	m.builtin = get_u8(&rd) != 0
	m.builtin_third = get_u8(&rd) != 0
	m.level = Level(clamp(int(get_u8(&rd)), 0, len(Level) - 1))
	m.block_at = i32(get_u32(&rd))
	m.hosts_any = get_str(&rd)
	m.hosts_third = get_str(&rd)
	n := int(get_u32(&rd))
	if !rd.ok || n > len(data) / 8 {
		matcher_free(m)
		return nil
	}
	rules := make([]Net_Rule, n)
	for i in 0 ..< n {
		r := &rules[i]
		r.index = i32(i)
		r.action = Rule_Action(min(get_u8(&rd), 2))
		lo := get_u8(&rd)
		hi := get_u8(&rd)
		r.types = transmute(Req_Types)(u16(lo) | u16(hi) << 8)
		r.party = get_u8(&rd)
		r.child_frame = get_u8(&rd) != 0
		r.has_gram = get_u8(&rd) != 0
		r.gram = get_u32(&rd)
		r.host = get_str(&rd)
		r.filter = get_str(&rd)
		r.selector = get_str(&rd)
		r.if_dom = get_list(&rd)
		r.unless_dom = get_list(&rd)
		if !rd.ok {
			matcher_free(m)
			return nil
		}
		r.has_re = len(r.host) == 0 && len(r.filter) > 0 && r.filter != ".*"
		add_rule(m, r)
	}
	m.rules = n
	return m
}

/// a matcher straight from rules (no file kept)
matcher_from :: proc(r: ^Rules) -> ^Matcher {
	return matcher_load(matcher_bytes(r, ""), "")
}

matcher_free :: proc(m: ^Matcher) {
	if m == nil do return
	virtual.arena_destroy(&m.arena)
	virtual.arena_destroy(&m.re_arena)
	delete(m.data, runtime.heap_allocator())
	free(m, runtime.heap_allocator())
}

/// the runs of literal text (lower-cased) every match of the url-filter
/// contains, those of 4 bytes or more
@(private="file") literal_runs :: proc(f: string, allocator := context.allocator) -> []string {
	context.allocator = allocator
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
		if k not_in mp do mp[k] = make([dynamic]^Net_Rule, 0, 1)
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

/// the rule's regular expression, compiled the first time it is needed
@(private="file") rule_regex :: proc(m: ^Matcher, r: ^Net_Rule) -> (regex.Regular_Expression, bool) {
	switch intrinsics.atomic_load(&r.re_state) {
	case 1: return r.re, true
	case 2: return {}, false
	}
	sync.mutex_lock(&m.re_lock)
	defer sync.mutex_unlock(&m.re_lock)
	if s := intrinsics.atomic_load(&r.re_state); s != 0 do return r.re, s == 1
	re, err := regex.create(r.filter, {.Case_Insensitive, .No_Capture}, virtual.arena_allocator(&m.re_arena), context.temp_allocator)
	if err != nil {
		intrinsics.atomic_store(&r.re_state, 2)
		return {}, false
	}
	r.re = re
	intrinsics.atomic_store(&r.re_state, 1)
	return re, true
}

/// d (a rule's domain, "*a.com" or "a.com") covers host
@(private="file") dom_match :: proc(d, host: string) -> bool {
	if strings.has_prefix(d, "*") {
		base := d[1:]
		return host == base || (len(host) > len(base) && strings.has_suffix(host, base) && host[len(host) - len(base) - 1] == '.')
	}
	return host == d
}

@(private="file") Ask :: struct {
	m:         ^Matcher,
	url:       string,
	page_host: string,
	t:         Req_Type,
	third:     bool,
	child:     bool,
}

@(private="file") applies :: proc(a: ^Ask, r: ^Net_Rule) -> bool {
	if r.types != {} && a.t not_in r.types do return false
	if r.party == 1 && a.third do return false
	if r.party == 2 && !a.third do return false
	if r.child_frame && !a.child do return false
	if len(r.if_dom) > 0 {
		hit := false
		for d in r.if_dom do if dom_match(d, a.page_host) {
			hit = true
			break
		}
		if !hit do return false
	}
	for d in r.unless_dom do if dom_match(d, a.page_host) do return false
	if r.has_re {
		re := rule_regex(a.m, r) or_return
		_, ok := regex.match_and_allocate_capture(re, a.url, context.temp_allocator, context.temp_allocator)
		return ok
	}
	return true
}

@(private="file") Hits :: struct {
	block, ignore: i32,
}

@(private="file") consider :: proc(h: ^Hits, a: ^Ask, r: ^Net_Rule) {
	// only a later rule than the one already found can change the answer
	switch r.action {
	case .block: if r.index <= h.block do return
	case .ignore: if r.index <= h.ignore do return
	case .hide: return
	}
	if !applies(a, r) do return
	if r.action == .block do h.block = r.index
	else do h.ignore = r.index
}

@(private="file") hits :: proc(a: ^Ask, host: string) -> Hits {
	m := a.m
	h := Hits{-1, -1}
	for x := host; len(x) > 0; {
		if rs, ok := m.by_host[x]; ok do for r in rs do consider(&h, a, r)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	for x := a.page_host; len(x) > 0; {
		if rs, ok := m.by_page[x]; ok do for r in rs do consider(&h, a, r)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	url := a.url
	if len(m.by_gram) > 0 do for i := 0; i + 4 <= len(url); i += 1 {
		if rs, ok := m.by_gram[gram(transmute([]u8)url[i:i + 4])]; ok do for r in rs do consider(&h, a, r)
	}
	for r in m.every do consider(&h, a, r)
	return h
}

/// the host sets block this request: a whole host blocked, for any type a
/// whole-host rule covers, and (unlike WebKit's rules) child frames too
@(private="file") set_blocks :: proc(m: ^Matcher, host: string, t: Req_Type, third, child: bool) -> bool {
	if t == .document && !child do return false
	if t != .document && t not_in ALL_TYPES do return false
	if _, ok := set_find(m.hosts_any, host); ok do return true
	if third {
		if _, ok := set_find(m.hosts_third, host); ok do return true
	}
	if m.builtin && (third || !m.builtin_third) {
		if e, ok := set_find(builtin_hosts(), host); ok && usable(e) do return true
	}
	return false
}

/// the page's own exception ("@@...$document": its document matches an
/// ignore rule for documents): every request on the page counts it, as
/// WebKit does. Worked out once a page (matcher_blocks' page_ignore); -1
/// for none.
matcher_page_ignore :: proc(m: ^Matcher, page_url, page_host: string) -> i32 {
	if m == nil do return -1
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	h := Hits{-1, -1}
	a := Ask{m = m, url = strings.to_lower(page_url, context.temp_allocator), page_host = page_host, t = .document}
	check :: proc(h: ^Hits, a: ^Ask, rs: [dynamic]^Net_Rule) {
		for r in rs do if r.action == .ignore && .document in r.types do consider(h, a, r)
	}
	for x := page_host; len(x) > 0; {
		if rs, ok := m.by_host[x]; ok do check(&h, &a, rs)
		if rs, ok := m.by_page[x]; ok do check(&h, &a, rs)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	url := a.url
	if len(m.by_gram) > 0 do for i := 0; i + 4 <= len(url); i += 1 {
		if rs, ok := m.by_gram[gram(transmute([]u8)url[i:i + 4])]; ok do check(&h, &a, rs)
	}
	check(&h, &a, m.every)
	return h.ignore
}

/// whether a request is blocked: url and its host, the top page's host and
/// its matcher_page_ignore, the request's type, and whether it loads in a
/// child frame
matcher_blocks :: proc(m: ^Matcher, url, host, page_host: string, page_ignore: i32, t: Req_Type, child := false) -> bool {
	if m == nil || len(host) == 0 do return false
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	a := Ask{m = m, url = strings.to_lower(url, context.temp_allocator), page_host = page_host, t = t, third = site_of(host) != site_of(page_host), child = child}
	h := hits(&a, host)
	block := h.block
	// a whole host blocked stands where the blocks begin: every exception
	// after it still lets the request through
	if block < m.block_at && set_blocks(m, host, t, a.third, child) do block = m.block_at
	return block >= 0 && block > max(h.ignore, page_ignore)
}

/// the style that hides what the rules hide on this page ("" for nothing)
matcher_css :: proc(m: ^Matcher, page_url, page_host: string, allocator := context.allocator) -> string {
	if m == nil || len(page_host) == 0 do return ""
	ignore: i32
	{
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		a := Ask{m = m, url = strings.to_lower(page_url, context.temp_allocator), page_host = page_host, t = .document}
		ignore = hits(&a, page_host).ignore
	}
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
	for r in m.hides do add(&b, r, page_host, ignore)
	for x := page_host; len(x) > 0; {
		if rs, ok := m.by_page[x]; ok do for r in rs do add(&b, r, page_host, ignore)
		dot := strings.index_byte(x, '.')
		if dot < 0 do break
		x = x[dot + 1:]
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------- tests

@(test) test_matcher :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .aggressive}
	converter_add_list(&c, "||ads.example.com^\n/banner/*$image\nnews.example##.promo\n##.ad-slot\n@@||good.example^$document\n||tracker.example^$third-party\n||cdn.cookielaw.org^\n||consent.example^$script\n")
	converter_add_domains(&c, {"builtin-ads.example"})
	rules := converter_rules(&c)
	m := matcher_from(&rules)
	testing.expect(t, m != nil)
	defer matcher_free(m)
	no := i32(-1)
	// what the caller keeps in its temporary allocator stays (the main
	// thread's turn of the loop is not over)
	keep := strings.clone("keep", context.temp_allocator)
	_ = matcher_blocks(m, "https://x.ads.example.com/a.js", "x.ads.example.com", "site.example", no, .script)
	_ = matcher_blocks(m, "https://cdn.site.example/banner/1.png", "cdn.site.example", "site.example", no, .image)
	_ = matcher_page_ignore(m, "https://site.example/", "site.example")
	_ = strings.repeat("x", 1 << 16, context.temp_allocator)
	testing.expect_value(t, keep, "keep")
	testing.expect(t, matcher_blocks(m, "https://x.ads.example.com/a.js", "x.ads.example.com", "site.example", no, .script))
	testing.expect(t, matcher_blocks(m, "https://builtin-ads.example/p", "builtin-ads.example", "site.example", no, .image))
	testing.expect(t, matcher_blocks(m, "https://cdn.site.example/banner/1.png", "cdn.site.example", "site.example", no, .image))
	testing.expect(t, !matcher_blocks(m, "https://cdn.site.example/banner/1.js", "cdn.site.example", "site.example", no, .script))
	testing.expect(t, !matcher_blocks(m, "https://site.example/app.js", "site.example", "site.example", no, .script))
	// a whole host: its frames go, its style sheets stay, the page itself is never stopped
	testing.expect(t, matcher_blocks(m, "https://ads.example.com/f", "ads.example.com", "site.example", no, .document, true))
	testing.expect(t, !matcher_blocks(m, "https://ads.example.com/f", "ads.example.com", "site.example", no, .document, false))
	testing.expect(t, !matcher_blocks(m, "https://ads.example.com/s.css", "ads.example.com", "site.example", no, .style_sheet))
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
	// consent managers load (their banners are hidden instead)
	testing.expect(t, !matcher_blocks(m, "https://cdn.cookielaw.org/scripttemplates/otSDKStub.js", "cdn.cookielaw.org", "site.example", no, .script))
	// YouTube's ad breaks go, the rest of YouTube stays
	testing.expect(t, matcher_blocks(m, "https://www.youtube.com/pagead/x", "www.youtube.com", "www.youtube.com", no, .fetch))
	testing.expect(t, !matcher_blocks(m, "https://www.youtube.com/watch?v=1", "www.youtube.com", "www.youtube.com", no, .fetch))
	css := matcher_css(m, "https://news.example/", "news.example")
	testing.expect(t, strings.contains(css, ".promo{"))
	testing.expect(t, strings.contains(css, ".ad-slot{"))
	testing.expect(t, !strings.contains(matcher_css(m, "https://other.example/", "other.example"), ".promo"))
}

@(test) test_matcher_file :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .ultra, builtin = true}
	converter_add_list(&c, "||ads.example.com^\n/banner/*$image\n")
	rules := converter_rules(&c)
	data := matcher_bytes(&rules, "key-1")
	copy := make([]u8, len(data), runtime.heap_allocator())
	for b, i in data do copy[i] = b
	// another key's file is not read
	testing.expect(t, matcher_load(copy, "key-2") == nil)
	m := matcher_load(data, "key-1")
	testing.expect(t, m != nil)
	defer matcher_free(m)
	testing.expect(t, m.builtin && !m.builtin_third)
	testing.expect(t, matcher_blocks(m, "https://ads.example.com/a.js", "ads.example.com", "site.example", -1, .script))
	testing.expect(t, matcher_blocks(m, "https://cdn.site.example/banner/1.png", "cdn.site.example", "site.example", -1, .image))
	// Iris's own domains, at the ultra level
	testing.expect(t, matcher_blocks(m, "https://doubleclick.net/x", "ad.doubleclick.net", "site.example", -1, .script))
	// a file cut short is no matcher
	short := make([]u8, len(MATCHER_MAGIC) + 20, runtime.heap_allocator())
	for i in 0 ..< len(short) do short[i] = m.data[i]
	testing.expect(t, matcher_load(short, "key-1") == nil)
}
