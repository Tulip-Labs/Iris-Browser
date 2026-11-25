// Filter lists (EasyList and uBlock Origin's syntax) turned into rules: the
// lists' blocks, hiding and exceptions as Rule values, and their commonest
// kind, "||host^" (a whole host blocked), folded with Iris's own domains
// into sorted host sets instead. From there, WebKit gets JSON content rules
// in parts small enough for its compiler (rules_json, written part by part),
// and CEF a matcher (shield_match.odin) that looks hosts up in the sets.
// All the strings live in one arena: the caller makes it the context's
// allocator for the whole conversion.
package iris

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:mem/virtual"

Level :: enum { moderate, aggressive, ultra }

level_title :: proc(l: Level) -> string {
	switch l {
	case .moderate: return "Moderate"
	case .aggressive: return "Aggressive"
	case .ultra: return "Ultra aggressive"
	}
	return ""
}

level_hint :: proc(l: Level) -> string {
	switch l {
	case .moderate: return "Other sites' ads"
	case .aggressive: return "All ads, trackers"
	case .ultra: return "Also cookie notices, pop-ups, annoyances"
	}
	return ""
}

/// the lists, as uBlock's mirrors keep them. uBlock's own come in their
/// .min form: the plain filters.txt and privacy.txt only !#include the rest,
/// which a converter reading one file never sees.
List :: enum {
	easylist, easyprivacy, unbreak, ublock, ublock_privacy, quick_fixes, badware,
	cookies, ublock_cookies, annoyances, fanboy_annoyances, fanboy_social, fanboy_notifications, fanboy_newsletters,
}

level_lists :: proc(l: Level) -> []List {
	@(static) m := [?]List{.easylist, .easyprivacy, .unbreak}
	@(static) a := [?]List{.easylist, .easyprivacy, .unbreak, .ublock, .ublock_privacy, .quick_fixes, .badware}
	@(static) u := [?]List{
		.easylist, .easyprivacy, .unbreak, .ublock, .ublock_privacy, .quick_fixes, .badware,
		.cookies, .ublock_cookies, .annoyances, .fanboy_annoyances, .fanboy_social, .fanboy_notifications, .fanboy_newsletters,
	}
	switch l {
	case .moderate: return m[:]
	case .aggressive: return a[:]
	case .ultra: return u[:]
	}
	return nil
}

/// the list's file name in the cache (a new name when its source changes,
/// so the old copy is never read as the new one)
list_id :: proc(l: List) -> string {
	switch l {
	case .easylist: return "easylist"
	case .easyprivacy: return "easyprivacy"
	case .unbreak: return "unbreak-min"
	case .ublock: return "ublock-min"
	case .ublock_privacy: return "ublock-privacy-min"
	case .quick_fixes: return "quick-fixes-min"
	case .badware: return "badware-min"
	case .cookies: return "cookies"
	case .ublock_cookies: return "ublock-cookies"
	case .annoyances: return "annoyances"
	case .fanboy_annoyances: return "fanboy-annoyances"
	case .fanboy_social: return "fanboy-social"
	case .fanboy_notifications: return "fanboy-notifications"
	case .fanboy_newsletters: return "fanboy-newsletters"
	}
	return ""
}

list_path :: proc(l: List) -> string {
	switch l {
	case .easylist: return "thirdparties/easylist.txt"
	case .easyprivacy: return "thirdparties/easyprivacy.txt"
	case .unbreak: return "filters/unbreak.min.txt"
	case .ublock: return "filters/filters.min.txt"
	case .ublock_privacy: return "filters/privacy.min.txt" // with resource-abuse (in-page miners)
	case .quick_fixes: return "filters/quick-fixes.min.txt"
	case .badware: return "filters/badware.min.txt"
	case .cookies: return "thirdparties/easylist-cookies.txt"
	case .ublock_cookies: return "filters/annoyances-cookies.txt"
	case .annoyances: return "filters/annoyances-others.txt"
	// Fanboy's annoyance list, as EasyList now publishes it, in its parts
	case .fanboy_annoyances: return "thirdparties/easylist-annoyances.txt"
	case .fanboy_social: return "thirdparties/easylist-social.txt"
	case .fanboy_notifications: return "thirdparties/easylist-notifications.txt"
	case .fanboy_newsletters: return "thirdparties/easylist-newsletters.txt"
	}
	return ""
}

/// a list only the ultra level reads (cookie notices and annoyances): its
/// rules, Iris's own domains and the pings rule never apply on the video
/// sites (MEDIA_SITES), which get the aggressive level at most
list_ultra_only :: proc(l: List) -> bool {
	for x in level_lists(.aggressive) do if x == l do return false
	return true
}

/// a list whose hiding rules for every site Iris takes (the others' are
/// for named sites only: their generic ones hide real content too often)
list_generic_ok :: proc(l: List) -> bool {
	#partial switch l {
	case .fanboy_annoyances, .fanboy_social, .fanboy_notifications, .fanboy_newsletters, .annoyances: return false
	}
	return true
}

LIST_MIRRORS :: [?]string{
	"https://ublockorigin.github.io/uAssets/",
	"https://ublockorigin.github.io/uAssetsCDN/",
	"https://ublockorigin.pages.dev/",
	"https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/",
}

/// messaging and sign-in sites: never blocked, nor anything on them
/// (and Google's and YouTube's consent pages: they gate the page behind them,
/// and a hidden one leaves it locked)
NEVER :: [?]string{"whatsapp.com", "whatsapp.net", "accounts.google.com", "consent.google.com", "consent.youtube.com", "login.microsoftonline.com", "login.live.com", "teams.microsoft.com", "meet.google.com", "challenges.cloudflare.com", "hcaptcha.com", "recaptcha.net", "appleid.apple.com"}

/// consent managers: requests to them always go through (a page that waits
/// for one never plays its video or takes your payment otherwise); at the
/// ultra level their banners are hidden instead (CONSENT_HIDE)
CONSENT :: [?]string{"cookielaw.org", "onetrust.com", "consent.cookiebot.com", "consentcdn.cookiebot.com", "privacy-mgmt.com", "sourcepoint.com"}

CONSENT_HIDE :: [?]string{"#onetrust-consent-sdk", "#onetrust-banner-sdk", ".onetrust-pc-dark-filter", "#CybotCookiebotDialog", "#CybotCookiebotDialogBodyUnderlay", "div[id^=\"sp_message_container_\"]", ".sp_veil"}

/// sites whose pages play video: the ultra level's own rules (its lists,
/// Iris's own domains, the pings rule) stop at them, as the aggressive
/// level does, so a player never misses what it waits for (YouTube's
/// "your browser can't play this video", LinkedIn's videos that never start)
MEDIA_SITES :: [?]string{"youtube.com", "youtube-nocookie.com", "linkedin.com", "licdn.com", "vimeo.com", "twitch.tv", "dailymotion.com", "facebook.com", "instagram.com", "x.com", "twitter.com", "tiktok.com"}

/// what video players need wherever they are, the lists notwithstanding:
/// Google's BotGuard (attestation: without it YouTube's player refuses to
/// play), and the ad-status probe YouTube's player and IMA read (blocked, it
/// tells the page an ad blocker is there)
PLAYER_HOSTS :: [?]string{"jnn-pa.googleapis.com"}
PLAYER_URLS :: [?]string{"^https?://www\\.google\\.com/js/th/", "^https?://static\\.doubleclick\\.net/instream/ad_status\\.js"}

/// delivery networks many sites share: a rule that names one whole would break them
SHARED :: [?]string{"cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "akamaihd.net", "akamaized.net", "akamai.net", "edgekey.net", "edgesuite.net", "fastly.net", "fastlylb.net", "azureedge.net", "azurefd.net", "azurewebsites.net", "windows.net", "blob.core.windows.net", "msecnd.net", "googleusercontent.com", "googleapis.com", "storage.googleapis.com", "gstatic.com", "cloudflare.com", "cloudflare.net", "jsdelivr.net", "unpkg.com", "github.io", "githubusercontent.com", "netlify.app", "vercel.app", "herokuapp.com", "firebaseapp.com", "web.app", "appspot.com", "b-cdn.net", "cdn77.org", "kxcdn.com", "digitaloceanspaces.com", "r2.dev", "pages.dev", "workers.dev", "wp.com", "cloudinary.com", "imgix.net", "ctfassets.net", "backblazeb2.com", "rackcdn.com", "llnwd.net", "hwcdn.net", "edgecastcdn.net", "wixstatic.com", "squarespace-cdn.com", "shopifycdn.com", "myshopify.com"}

/// what a whole-host block stops: everything but the page itself, its
/// style sheets and its fonts (pages must look right)
ALL_TYPES :: Req_Types{.image, .script, .raw, .media, .popup, .ping, .fetch, .websocket, .other}

@(private="file") in_list :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}

@(private="file") ends_with_dot :: proc(s, suffix: string) -> bool {
	return len(s) > len(suffix) && strings.has_suffix(s, suffix) && s[len(s) - len(suffix) - 1] == '.'
}

@(private="file") host_chars :: proc(d: string) -> bool {
	for c in transmute([]u8)d {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_') do return false
	}
	return true
}

/// a domain that may be blocked whole (no shared delivery network, no
/// sign-in or messaging host nor a parent of one, no consent manager)
usable :: proc(d: string) -> bool {
	shared := SHARED
	if len(d) == 0 || in_list(shared[:], d) || strings.index_byte(d, '.') < 0 do return false
	for n in NEVER do if d == n || ends_with_dot(d, n) || ends_with_dot(n, d) do return false
	for n in CONSENT do if d == n || ends_with_dot(d, n) || ends_with_dot(n, d) do return false
	return host_chars(d)
}

// ---------------------------------------------------------------- host sets

/// A host set: sorted, lower-case names one a line (byte order, as
/// `LC_ALL=C sort` gives), looked up in place by binary search: no index,
/// nothing to build, any thread may read it.

/// s is one of the set's lines
set_has :: proc(set, s: string) -> bool {
	lo, hi := 0, len(set)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		st := mid
		for st > lo && set[st - 1] != '\n' do st -= 1
		en := st
		for en < hi && set[en] != '\n' do en += 1
		line := set[st:en]
		if line == s do return true
		if line < s {
			lo = en + 1
		} else {
			hi = st
		}
	}
	return false
}

/// the host, or the nearest parent domain of it, in the set (never a bare
/// top-level name)
set_find :: proc(set, host: string) -> (string, bool) {
	if len(set) == 0 do return "", false
	h := host
	for {
		if set_has(set, h) do return h, true
		dot := strings.index_byte(h, '.')
		if dot < 0 do return "", false
		h = h[dot + 1:]
		if strings.index_byte(h, '.') < 0 do return "", false
	}
}

/// a parent domain of host (not host itself) in the set
@(private="file") set_has_parent :: proc(set, host: string) -> bool {
	dot := strings.index_byte(host, '.')
	if dot < 0 do return false
	_, ok := set_find(set, host[dot + 1:])
	return ok
}

/// a host, or a parent domain of it, is in the sorted list
listed :: proc(sorted: []string, host: string) -> bool {
	h := host
	for {
		if _, found := slice.binary_search(sorted, h); found do return true
		dot := strings.index_byte(h, '.')
		if dot < 0 do return false
		h = h[dot + 1:]
		if strings.index_byte(h, '.') < 0 do return false
	}
}

// ---------------------------------------------------------------- rules

/// one rule, as WebKit's content rules say it
Rule :: struct {
	/// the url-filter is host_pattern(host) ("||host^"), else filter
	host, filter: string,
	selector:     string, // .hide
	if_dom:       []string, // "*a.com": a.com and under it (the page's)
	unless_dom:   []string,
	types:        Req_Types, // {}: every type
	action:       Rule_Action,
	party:        u8, // 0 any, 1 first-party, 2 third-party
	frames:       bool, // only loads in a child frame
}

/// the rules of a conversion, in WebKit's order
Rules :: struct {
	list:          [dynamic]Rule,
	/// the whole-host blocks (the sets) stand before list[block_at] (the
	/// lists the aggressive level reads too) and before list[ultra_at] (the
	/// ultra-only lists' and Iris's own); the rules every part ends with
	/// start at list[tail_at]
	ultra_at:      int,
	/// where the ultra-only lists' hiding begins (after the generic hiding)
	uhides_at:     int,
	/// the rule the video sites' pages stop the ultra level's at
	media_at:      int,
	block_at:      int,
	tail_at:       int,
	/// the lists' whole-host blocks: for any request, for other sites' only
	hosts_any:     string,
	hosts_third:   string,
	/// the same from the ultra-only lists
	uhosts_any:    string,
	uhosts_third:  string,
	/// Iris's own domains count too (builtin_hosts), for other sites'
	/// requests only at the moderate level
	builtin:       bool,
	builtin_third: bool,
	level:         Level,
}

Converter :: struct {
	level:      Level,
	blocks:     [dynamic]Rule,
	hides:      [dynamic]Rule,
	exceptions: [dynamic]Rule,
	generic:    [dynamic]string,
	/// what the ultra-only lists hide and block (list_ultra_only)
	uhides:     [dynamic]Rule,
	ublocks:    [dynamic]Rule,
	seen:       map[string]bool,
	/// hosts the lists block whole ("||host^"): 1 for any request, 2 for
	/// other sites' requests only (and those of the ultra-only lists)
	hosts:      map[string]u8,
	uhosts:     map[string]u8,
	/// the list being read is an ultra-only one
	ultra_only: bool,
	/// Iris's own domains count (until the lists come, and at ultra)
	builtin:    bool,
	/// the list being read gives hiding rules for every site
	no_generic: bool,
}

converter_add_list :: proc(c: ^Converter, text: string, generic := true, ultra_only := false) {
	c.no_generic = !generic
	c.ultra_only = ultra_only
	defer c.no_generic, c.ultra_only = false, false
	t := text
	for line in strings.split_lines_iterator(&t) do add_line(c, line)
}

/// domains to block whole, beside the lists' (tests; Iris's own come with
/// c.builtin)
converter_add_domains :: proc(c: ^Converter, domains: []string) {
	for d in domains do add_host(c, strings.to_lower(d), c.level == .moderate)
}

@(private="file") add_host :: proc(c: ^Converter, h: string, third: bool) {
	if !usable(h) do return
	v: u8 = third ? 2 : 1
	m := c.ultra_only ? &c.uhosts : &c.hosts
	if old, ok := m[h]; ok && old <= v do return
	m[h] = v
}

host_pattern :: proc(d: string) -> string {
	return strings.concatenate({"^[^:]+://+([^:/]+\\.)?", regex_escape(strings.to_lower(d)), "[:/]"})
}

@(private="file") add_line :: proc(c: ^Converter, raw: string) {
	line := strings.trim(raw, " \t\r")
	if len(line) == 0 || line[0] == '!' || line[0] == '[' do return
	if i := strings.index(line, "##"); i >= 0 {
		cosmetic(c, line[:i], line[i + 2:])
		return
	}
	// other cosmetic and scriptlet syntax WebKit cannot follow
	for m in ([?]string{"#@#", "#?#", "#$#", "#%#", "#@?#", "#@$#", "$$", "##^"}) do if strings.contains(line, m) do return
	network(c, line)
}

UNSUPPORTED :: [?]string{":has-text(", ":-abp-", ":style(", ":remove(", ":matches-", ":upward(", ":xpath(", ":watch-attr", ":min-text-length", ":others(", ":matches-path(", ":remove-attr(", ":remove-class(", ":contains(", "+js(", ":matches-media(", ":matches-prop("}

@(private="file") cosmetic :: proc(c: ^Converter, domains, sel: string) {
	s := strings.trim(sel, " \t")
	if len(s) == 0 || len(s) >= 400 || strings.has_prefix(s, "+js") || s[0] == '^' || strings.index_byte(s, '{') >= 0 do return
	for b in transmute([]u8)s do if b >= 0x80 do return
	for u in UNSUPPORTED do if strings.contains(s, u) do return
	if len(domains) == 0 {
		// the boxes ads leave, everywhere: aggressive and ultra only
		if c.level != .moderate && !c.no_generic do append(&c.generic, s)
		return
	}
	yes, no: [dynamic]string
	ds := domains
	for d0 in strings.split_iterator(&ds, ",") {
		d := strings.to_lower(strings.trim_space(d0))
		if len(d) > 0 && d[0] == '~' {
			if v, ok := domain(d[1:]); ok do append(&no, v)
		} else if v, ok := domain(d); ok {
			append(&yes, v)
		}
	}
	if len(yes) == 0 && len(no) == 0 do return
	r := Rule{filter = ".*", action = .hide, selector = s}
	if len(yes) > 0 { r.if_dom = yes[:] } else { r.unless_dom = no[:] }
	append(c.ultra_only ? &c.uhides : &c.hides, r)
}

@(private="file") domain :: proc(d: string) -> (string, bool) {
	if len(d) == 0 || strings.index_byte(d, '.') < 0 || strings.has_suffix(d, ".*") || strings.index_byte(d, '*') >= 0 || strings.index_byte(d, '/') >= 0 || !host_chars(d) do return "", false
	return strings.concatenate({"*", d}), true
}

@(private="file") type_of :: proc(name: string) -> (ts: Req_Types, frame: bool, ok: bool) {
	switch name {
	case "xmlhttprequest", "xhr": return {.raw, .fetch}, false, true
	case "object", "other": return {.other}, false, true
	case "subdocument", "frame": return {}, true, true
	case "font": return {.font}, false, true
	case "stylesheet", "css": return {.style_sheet}, false, true
	case "script": return {.script}, false, true
	case "image": return {.image}, false, true
	case "media": return {.media}, false, true
	case "ping": return {.ping}, false, true
	case "websocket": return {.websocket}, false, true
	case "popup": return {.popup}, false, true
	}
	return {}, false, false
}

@(private="file") network :: proc(c: ^Converter, line: string) {
	l := line
	exception := strings.has_prefix(l, "@@")
	if exception do l = l[2:]
	pattern, opts := l, ""
	// the options after the last $, when what follows it reads as options
	if i := strings.last_index_byte(l, '$'); i >= 0 {
		tail := l[i + 1:]
		ok := len(tail) > 0
		for b in transmute([]u8)tail {
			if !((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || strings.index_byte("-~=|._,*:", b) >= 0) do ok = false
		}
		if ok {
			pattern, opts = l[:i], tail
		}
	}
	// regular expressions: WebKit's are a smaller language; left out
	if len(pattern) > 1 && pattern[0] == '/' && pattern[len(pattern) - 1] == '/' do return
	types, not_types: Req_Types
	has_types, want_frame, not_frame := false, false, false
	party: u8 = 0
	if_domains, unless_domains: [dynamic]string
	document_exception := false
	os := opts
	for o in strings.split_iterator(&os, ",") {
		if len(o) == 0 do continue
		low := strings.to_lower(o, context.temp_allocator)
		name, value := low, ""
		if e := strings.index_byte(low, '='); e >= 0 do name, value = low[:e], low[e + 1:]
		negated := len(name) > 0 && name[0] == '~'
		if negated do name = name[1:]
		switch name {
		case "third-party", "3p":
			party = negated ? 1 : 2
		case "first-party", "1p":
			party = negated ? 2 : 1
		case "domain", "from":
			vs := value
			for d in strings.split_iterator(&vs, "|") {
				if len(d) > 0 && d[0] == '~' {
					if v, ok := domain(d[1:]); ok do append(&unless_domains, v)
				} else if v, ok := domain(d); ok {
					append(&if_domains, v)
				}
			}
			if len(if_domains) == 0 && len(unless_domains) == 0 do return
		case "match-case", "important", "all":
		case "document", "doc", "elemhide", "ehide", "generichide", "ghide":
			// on these pages, nothing is hidden or blocked: only as an exception
			if !exception || negated do return
			document_exception = true
		case:
			ts, frame, ok := type_of(name)
			if !ok do return // redirect, removeparam, csp: no WebKit equivalent
			if negated {
				not_types += ts
				if frame do not_frame = true
			} else {
				has_types = true
				types += ts
				if frame do want_frame = true
			}
		}
	}
	if len(if_domains) > 0 && len(unless_domains) > 0 do clear(&unless_domains)
	// the moderate level leaves a site's own requests alone
	if !exception && c.level == .moderate {
		if party == 1 do return
		party = 2
	}
	// "||host^", the commonest rule: a host, kept as such
	whole := ""
	if len(pattern) > 3 && strings.has_prefix(pattern, "||") && strings.has_suffix(pattern, "^") {
		h := pattern[2:len(pattern) - 1]
		if strings.index_byte(h, '.') > 0 && host_chars(h) do whole = strings.to_lower(h)
	}
	filter := ""
	if len(whole) == 0 {
		ok: bool
		filter, ok = url_filter(pattern)
		if !ok do return
	}
	if document_exception {
		append(&c.exceptions, Rule{host = whole, filter = filter, if_dom = if_domains[:], types = {.document}, action = .ignore})
		return
	}
	t := has_types ? types : ALL_TYPES
	t -= not_types
	// style sheets and fonts always load: pages must look right
	t -= {.style_sheet, .font}
	frames := want_frame && !not_frame
	if exception {
		append(&c.exceptions, Rule{host = whole, filter = filter, types = has_types ? t : {}, frames = frames, party = party, if_dom = if_domains[:], unless_dom = unless_domains[:], action = .ignore})
		return
	}
	if t == {} && !frames do return
	// a rule that names a whole delivery network would break many sites
	if strings.has_prefix(pattern, "||") {
		rest := pattern[2:]
		end := strings.index_any(rest, "^/:*")
		if end < 0 do end = len(rest)
		h := rest[:end]
		shared := SHARED
		if len(h) > 0 && in_list(shared[:], h) && len(rest) - len(h) <= 1 && len(if_domains) == 0 do return
	}
	// the whole host, for any type: into the host set, not a rule of its own
	if len(whole) > 0 && !has_types && not_types == {} && len(if_domains) == 0 && len(unless_domains) == 0 && party != 1 {
		add_host(c, whole, party == 2)
		return
	}
	if t != {} do emit_block(c, Rule{host = whole, filter = filter, types = t, party = party, if_dom = if_domains[:], unless_dom = unless_domains[:], action = .block})
	if frames do append(c.ultra_only ? &c.ublocks : &c.blocks, Rule{host = whole, filter = filter, types = {.document}, frames = true, party = party, if_dom = if_domains[:], unless_dom = unless_domains[:], action = .block})
}

@(private="file") emit_block :: proc(c: ^Converter, r: Rule) {
	b := strings.builder_make()
	strings.write_string(&b, r.host)
	strings.write_byte(&b, '|')
	strings.write_string(&b, r.filter)
	strings.write_byte(&b, '|')
	strings.write_int(&b, int(r.party))
	strings.write_byte(&b, '|')
	strings.write_int(&b, int(transmute(u16)r.types))
	for d in r.if_dom { strings.write_byte(&b, ','); strings.write_string(&b, d) }
	strings.write_byte(&b, '|')
	for d in r.unless_dom { strings.write_byte(&b, ','); strings.write_string(&b, d) }
	key := strings.to_string(b)
	if key in c.seen do return
	c.seen[key] = true
	append(c.ultra_only ? &c.ublocks : &c.blocks, r)
}

/// a filter's pattern as WebKit's url-filter (a small regular expression)
url_filter :: proc(p0: string) -> (string, bool) {
	p := p0
	b := strings.builder_make()
	if strings.has_prefix(p, "||") {
		p = p[2:]
		strings.write_string(&b, "^[^:]+://+([^:/]+\\.)?")
	} else if strings.has_prefix(p, "|") {
		p = p[1:]
		strings.write_byte(&b, '^')
	}
	end_anchor := false
	if strings.has_suffix(p, "|") {
		p = p[:len(p) - 1]
		end_anchor = true
	}
	p = strings.trim(p, "*")
	letters := 0
	for c in transmute([]u8)p {
		if c >= 0x80 || c == '\n' || c == '\r' do return "", false
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') do letters += 1
	}
	if strings.builder_len(b) == 0 && letters < 4 do return "", false // too short to say anything safely
	if len(p) == 0 {
		if strings.builder_len(b) == 0 do return "", false
		strings.write_string(&b, ".*")
		return strings.to_string(b), true
	}
	for c, i in transmute([]u8)p {
		switch c {
		case '*': strings.write_string(&b, ".*")
		case '^': strings.write_string(&b, i == len(p) - 1 ? "([^a-zA-Z0-9_.%-].*)?$" : "[^a-zA-Z0-9_.%-]")
		case:
			if strings.index_byte("\\.+?{}()[]$|^*", c) >= 0 do strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		}
	}
	s := strings.to_string(b)
	if end_anchor && !strings.has_suffix(s, "$") do s = strings.concatenate({s, "$"})
	return s, true
}

/// the rules in WebKit's order: hiding first (WebKit takes the rules that
/// hide everywhere only from before its other rules); then what only the
/// ultra level has (the ultra-only lists' rules, Iris's own domains, the
/// pings rule), which the video sites skip; then the blocks every level
/// above moderate has (the host sets among them); then the exceptions and
/// what is always left alone, which every part of WebKit's ends with
converter_rules :: proc(c: ^Converter) -> Rules {
	r := Rules{level = c.level}
	if c.level == .ultra do for s in CONSENT_HIDE do append(&c.generic, s)
	// generic hiding in batches of 12 (one bad selector loses only its batch)
	for i := 0; i < len(c.generic); i += 12 {
		append(&r.list, Rule{filter = ".*", action = .hide, selector = strings.join(c.generic[i:min(i + 12, len(c.generic))], ", ")})
	}
	media := make([]string, len(MEDIA_SITES))
	for d, i in MEDIA_SITES do media[i] = strings.concatenate({"*", d})
	if len(c.generic) > 0 {
		// Google's, YouTube's and the video sites' pages skip the thousands
		// of selectors meant for other sites' ad boxes (their style is
		// recomputed all the time, a player's among it; their own ads have
		// rules of their own, after this one)
		gy := make([dynamic]string)
		append(&gy, "*google.com")
		append(&gy, ..media)
		append(&r.list, Rule{filter = ".*", if_dom = gy[:], action = .ignore})
	}
	r.uhides_at = len(r.list)
	append(&r.list, ..c.uhides[:])
	r.ultra_at = len(r.list)
	append(&r.list, ..c.ublocks[:])
	if c.level == .ultra {
		// beacons and pings to other sites: tracking, nearly always
		append(&r.list, Rule{filter = ".*", types = {.ping}, party = 2, action = .block})
	}
	// the video sites: everything above stops here for them
	r.media_at = len(r.list)
	append(&r.list, Rule{filter = ".*", if_dom = media, action = .ignore})
	append(&r.list, ..c.hides[:])
	r.block_at = len(r.list)
	append(&r.list, ..c.blocks[:])
	r.tail_at = len(r.list)
	append(&r.list, ..c.exceptions[:])
	// messaging and sign-in pages, and requests to them, are left alone
	for d in NEVER {
		append(&r.list, Rule{host = d, action = .ignore})
		on := make([]string, 1)
		on[0] = strings.concatenate({"*", d})
		append(&r.list, Rule{filter = ".*", if_dom = on, action = .ignore})
	}
	// and requests to consent managers, and what players need
	for d in CONSENT do append(&r.list, Rule{host = d, action = .ignore})
	for d in PLAYER_HOSTS do append(&r.list, Rule{host = d, action = .ignore})
	for p in PLAYER_URLS do append(&r.list, Rule{filter = p, action = .ignore})
	// YouTube sees no ad blocker (it fights them): only its ad breaks go
	// (youtube.js takes the ads out of what the player reads)
	@(static) yt := [?]string{"*youtube.com", "*youtube-nocookie.com"}
	append(&r.list, Rule{filter = ".*", if_dom = yt[:], action = .ignore})
	for p in ([?]string{"^https?://(www\\.)?youtube\\.com/youtubei/v1/player/ad_break", "^https?://(www\\.)?youtube\\.com/pagead/", "^https?://(www\\.)?youtube\\.com/api/stats/ads"}) {
		append(&r.list, Rule{filter = p, types = {.raw, .fetch, .script, .image}, action = .block})
	}
	// the host sets: each less what a parent already covers; the ultra-only
	// lists' less what the other lists' or Iris's own (beside them) cover
	r.builtin = c.builtin
	r.builtin_third = c.builtin && c.level == .moderate
	builtin := c.builtin ? builtin_hosts() : ""
	r.hosts_any, r.hosts_third = host_sets(c.hosts, "", "", "", false, false)
	r.uhosts_any, r.uhosts_third = host_sets(c.uhosts, r.hosts_any, r.hosts_third, builtin, r.builtin, r.builtin_third)
	return r
}

/// a converter's hosts as two sets (any request, other sites' requests),
/// less those covered by a parent, by the sets given (any, third), or by
/// Iris's own list
@(private="file") host_sets :: proc(hosts: map[string]u8, any0, third0, builtin: string, use_builtin, builtin_third: bool) -> (any_set, third_set: string) {
	keys: [dynamic]string
	for h, v in hosts do if v == 1 do append(&keys, h)
	slice.sort(keys[:])
	all_any := strings.join(keys[:], "\n")
	kept: [dynamic]string
	for h in keys {
		if set_has_parent(all_any, h) do continue
		if _, ok := set_find(any0, h); ok do continue
		if use_builtin && !builtin_third {
			if e, ok := set_find(builtin, h); ok && usable(e) do continue
		}
		append(&kept, h)
	}
	any_set = strings.join(kept[:], "\n")
	clear(&keys)
	clear(&kept)
	for h, v in hosts do if v == 2 do append(&keys, h)
	slice.sort(keys[:])
	all_third := strings.join(keys[:], "\n")
	for h in keys {
		if _, ok := set_find(all_any, h); ok do continue
		if _, ok := set_find(any0, h); ok do continue
		if _, ok := set_find(third0, h); ok do continue
		if set_has_parent(all_third, h) do continue
		if use_builtin {
			if e, ok := set_find(builtin, h); ok && usable(e) do continue
		}
		append(&kept, h)
	}
	third_set = strings.join(kept[:], "\n")
	return
}

// ---------------------------------------------------------------- WebKit's JSON

@(private="file") TYPE_NAMES := [Req_Type]string {
	.document = "document", .image = "image", .style_sheet = "style-sheet", .script = "script", .font = "font", .raw = "raw",
	.svg_document = "svg-document", .media = "media", .popup = "popup", .ping = "ping", .fetch = "fetch", .websocket = "websocket", .other = "other",
}

@(private="file") write_json_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"': strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n', '\r', '\t': strings.write_byte(b, ' ')
		case: if c >= 0x20 do strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

@(private="file") write_json_list :: proc(b: ^strings.Builder, items: []string) {
	strings.write_byte(b, '[')
	for s, i in items {
		if i > 0 do strings.write_byte(b, ',')
		write_json_str(b, s)
	}
	strings.write_byte(b, ']')
}

/// host_pattern(h) as a JSON string, written straight (h is lower-case)
@(private="file") write_host_filter :: proc(b: ^strings.Builder, h: string) {
	strings.write_string(b, `"^[^:]+://+([^:/]+\\.)?`)
	for c in transmute([]u8)h {
		if strings.index_byte(".+?{}()[]$|^*", c) >= 0 do strings.write_string(b, "\\\\")
		strings.write_byte(b, c)
	}
	strings.write_string(b, `[:/]"`)
}

@(private="file") write_rule :: proc(b: ^strings.Builder, r: Rule) {
	strings.write_string(b, `{"trigger":{"url-filter":`)
	if len(r.host) > 0 { write_host_filter(b, r.host) } else { write_json_str(b, r.filter) }
	if r.types != {} {
		strings.write_string(b, `,"resource-type":[`)
		first := true
		for t in r.types {
			if !first do strings.write_byte(b, ',')
			first = false
			strings.write_byte(b, '"')
			strings.write_string(b, TYPE_NAMES[t])
			strings.write_byte(b, '"')
		}
		strings.write_byte(b, ']')
	}
	if r.frames do strings.write_string(b, `,"load-context":["child-frame"]`)
	if r.party == 1 do strings.write_string(b, `,"load-type":["first-party"]`)
	if r.party == 2 do strings.write_string(b, `,"load-type":["third-party"]`)
	if len(r.if_dom) > 0 {
		strings.write_string(b, `,"if-domain":`)
		write_json_list(b, r.if_dom)
	}
	if len(r.unless_dom) > 0 {
		strings.write_string(b, `,"unless-domain":`)
		write_json_list(b, r.unless_dom)
	}
	strings.write_string(b, `},"action":{"type":"`)
	switch r.action {
	case .block: strings.write_string(b, "block")
	case .ignore: strings.write_string(b, "ignore-previous-rules")
	case .hide:
		strings.write_string(b, `css-display-none","selector":`)
		write_json_str(b, r.selector)
		strings.write_string(b, "}}")
		return
	}
	strings.write_string(b, `"}}`)
}

@(private="file") Json_Parts :: struct {
	r:     ^Rules,
	parts: [dynamic]string,
	b:     strings.Builder,
	n:     int,
	room:  int,
	size:  int, // the bytes a full part took (the next one's builder starts there)
	alloc: runtime.Allocator,
	/// the ultra level's rules are being written: a part that ends among
	/// them ends with the video sites' rule too (an ignore rule only reaches
	/// the rules of its own part)
	ultra_open: bool,
}

@(private="file") part_end :: proc(j: ^Json_Parts) {
	if j.n == 0 {
		if len(j.parts) > 0 do return
		j.b = strings.builder_make(0, 1024, j.alloc)
		strings.write_byte(&j.b, '[')
	}
	if j.ultra_open {
		if j.n > 0 do strings.write_byte(&j.b, ',')
		write_rule(&j.b, j.r.list[j.r.media_at])
		j.n += 1
	}
	for x in j.r.list[j.r.tail_at:] {
		if j.n > 0 do strings.write_byte(&j.b, ',')
		write_rule(&j.b, x)
		j.n += 1
	}
	strings.write_byte(&j.b, ']')
	s := strings.to_string(j.b)
	j.size = max(j.size, len(s))
	// the part's builder gave back what it grew past
	append(&j.parts, strings.clone(s, j.alloc))
	strings.builder_destroy(&j.b)
	j.n = 0
}

@(private="file") part_add :: proc(j: ^Json_Parts, r: Rule) {
	if j.n == 0 {
		j.b = strings.builder_make(0, j.size + j.size / 8 + 1024, j.alloc)
		strings.write_byte(&j.b, '[')
	} else {
		strings.write_byte(&j.b, ',')
	}
	write_rule(&j.b, r)
	j.n += 1
	if j.n >= j.room do part_end(j)
}

/// the rules as WebKit's JSON arrays of at most max_rules each (every part
/// ends with the exceptions, so each part stands alone), written one rule
/// at a time from allocator (the heap, in Iris: a builder that grows in
/// an arena would leave every smaller copy of itself behind)
rules_json :: proc(r: ^Rules, max_rules: int, allocator: runtime.Allocator) -> []string {
	j := Json_Parts{r = r, room = max(1000, max_rules - (len(r.list) - r.tail_at) - 1), alloc = allocator}
	// the parts' list too: the caller's arena may be gone before it reads them
	j.parts.allocator = allocator
	any_t := Rule{types = ALL_TYPES, action = .block}
	third_t := Rule{types = ALL_TYPES, party = 2, action = .block}
	add_set :: proc(j: ^Json_Parts, set: string, t: Rule, builtin: bool, covered := "") {
		t := t
		s := set
		for h in strings.split_lines_iterator(&s) {
			if len(h) == 0 do continue
			if builtin && !usable(h) do continue
			// blocked everywhere already, by the other lists
			if _, ok := set_find(covered, h); ok do continue
			t.host = h
			part_add(j, t)
		}
	}
	for x, i in r.list[:r.ultra_at] {
		if i == r.uhides_at do j.ultra_open = true
		part_add(&j, x)
	}
	j.ultra_open = true
	// the ultra level's whole-host blocks
	if r.builtin do add_set(&j, builtin_hosts(), r.builtin_third ? third_t : any_t, true, r.hosts_any)
	add_set(&j, r.uhosts_any, any_t, false)
	add_set(&j, r.uhosts_third, third_t, false)
	for x, i in r.list[r.ultra_at:r.block_at] {
		if r.ultra_at + i == r.media_at do j.ultra_open = false
		part_add(&j, x)
	}
	// the other lists'
	add_set(&j, r.hosts_any, any_t, false)
	add_set(&j, r.hosts_third, third_t, false)
	for x in r.list[r.block_at:r.tail_at] do part_add(&j, x)
	part_end(&j)
	return j.parts[:]
}

/// the rules as WebKit's JSON (Converter in, parts out)
converter_finish :: proc(c: ^Converter, max_rules: int) -> []string {
	r := converter_rules(c)
	return rules_json(&r, max_rules, context.allocator)
}

regex_escape :: proc(s: string) -> string {
	b := strings.builder_make()
	for c in transmute([]u8)s {
		if strings.index_byte("\\.+?{}()[]$|^*", c) >= 0 do strings.write_byte(&b, '\\')
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

json_str :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_json_str(&b, s)
	return strings.to_string(b)
}

json_list :: proc(items: []string) -> string {
	b := strings.builder_make()
	write_json_list(&b, items)
	return strings.to_string(b)
}

// ---------------------------------------------------------------- tests

@(test) test_domain_rules :: proc(t: ^testing.T) {
	testing.expect(t, usable("ads.example.com"))
	testing.expect(t, !usable("cloudfront.net"))
	testing.expect(t, !usable("accounts.google.com"))
	testing.expect(t, !usable("cdn.cookielaw.org"))
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .aggressive}
	converter_add_domains(&c, {"ads.example.com", "gstatic.com", "x.ads.example.com"})
	all := strings.join(converter_finish(&c, 120_000), "")
	testing.expect(t, strings.contains(all, "ads\\\\.example\\\\.com"))
	// a parent covers its subdomains: one rule
	testing.expect(t, !strings.contains(all, "x\\\\.ads"))
	testing.expect(t, !strings.contains(all, "gstatic"))
	// the same JSON as before for a host: one host pattern
	testing.expect(t, strings.contains(all, `"url-filter":"^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[:/]"`))
}

@(test) test_filter_rules :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .moderate}
	converter_add_list(&c, "! comment\n||ads.example.com^$script\nexample.org##.ad-box\n##.generic-ad\n@@||good.example.com^$document\n||cdn.example.net/x.js$redirect=noop\n||whole.example^\n")
	r := converter_rules(&c)
	// the whole host goes into the set, for other sites' requests (moderate)
	testing.expect_value(t, r.hosts_third, "whole.example")
	all := strings.join(rules_json(&r, 120_000, context.allocator), "")
	// a third-party block at the moderate level
	testing.expect(t, strings.contains(all, "\"load-type\":[\"third-party\"]"))
	testing.expect(t, strings.contains(all, "\"resource-type\":[\"script\"]"))
	testing.expect(t, strings.contains(all, "whole\\\\.example"))
	// a site's own hiding stays, the generic one is for the higher levels
	testing.expect(t, strings.contains(all, ".ad-box"))
	testing.expect(t, !strings.contains(all, ".generic-ad"))
	// the page exception, and no rule from a redirect it cannot follow
	testing.expect(t, strings.contains(all, "ignore-previous-rules"))
	testing.expect(t, !strings.contains(all, "cdn\\\\.example"))
}

@(test) test_json_parts :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .aggressive}
	ds: [dynamic]string
	for i in 0 ..< 2500 do append(&ds, strings.concatenate({"ads", strings.repeat("a", i % 7 + 1), "-", strings.repeat("b", i / 7 + 1), ".example"}))
	converter_add_domains(&c, ds[:])
	parts := converter_finish(&c, 1000)
	testing.expect(t, len(parts) >= 3)
	for p in parts {
		testing.expect(t, strings.has_prefix(p, "[{") && strings.has_suffix(p, "}]"))
		// every part ends with the exceptions
		testing.expect(t, strings.contains(p, "whatsapp"))
	}
}

@(test) test_host_sets :: proc(t: ^testing.T) {
	set := "a.example\nads.tracker.net\nb.example\ntracker.org"
	testing.expect(t, set_has(set, "a.example"))
	testing.expect(t, set_has(set, "tracker.org"))
	testing.expect(t, set_has(set, "b.example"))
	testing.expect(t, !set_has(set, "c.example"))
	testing.expect(t, !set_has(set, "example"))
	e, ok := set_find(set, "x.y.ads.tracker.net")
	testing.expect(t, ok && e == "ads.tracker.net")
	_, ok = set_find(set, "tracker.net")
	testing.expect(t, !ok)
	_, ok = set_find("", "a.example")
	testing.expect(t, !ok)
	list := [?]string{"ads.example.com", "tracker.net"}
	testing.expect(t, listed(list[:], "x.tracker.net"))
	testing.expect(t, !listed(list[:], "example.com"))
}

/// every WebKit part with ultra-only rules in it stops them for the video
/// sites itself (an ignore rule reaches only the rules of its own part)
@(test) test_json_parts_media :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .ultra, builtin = true}
	converter_add_list(&c, "||ads.example.com^$script\n")
	parts := converter_finish(&c, 50_000)
	testing.expect(t, len(parts) >= 4)
	// (the generic hiding's rule names the video sites too: part 0 has both)
	for p, i in parts {
		n := strings.count(p, `"*youtube-nocookie.com","*linkedin.com"`)
		if i < len(parts) - 1 do testing.expectf(t, n >= (i == 0 ? 2 : 1), "part %d has no video sites' rule", i)
	}
}
