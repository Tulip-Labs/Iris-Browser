// Filter lists (EasyList and uBlock Origin's syntax) turned into WebKit
// content rules: blocks, hiding and exceptions, in parts small enough for
// WebKit's compiler. All the strings live in one arena: the caller makes
// it the context's allocator for the whole conversion.
package iris

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

/// delivery networks many sites share: a rule that names one whole would break them
SHARED :: [?]string{"cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "akamaihd.net", "akamaized.net", "akamai.net", "edgekey.net", "edgesuite.net", "fastly.net", "fastlylb.net", "azureedge.net", "azurefd.net", "azurewebsites.net", "windows.net", "blob.core.windows.net", "msecnd.net", "googleusercontent.com", "googleapis.com", "storage.googleapis.com", "gstatic.com", "cloudflare.com", "cloudflare.net", "jsdelivr.net", "unpkg.com", "github.io", "githubusercontent.com", "netlify.app", "vercel.app", "herokuapp.com", "firebaseapp.com", "web.app", "appspot.com", "b-cdn.net", "cdn77.org", "kxcdn.com", "digitaloceanspaces.com", "r2.dev", "pages.dev", "workers.dev", "wp.com", "cloudinary.com", "imgix.net", "ctfassets.net", "backblazeb2.com", "rackcdn.com", "llnwd.net", "hwcdn.net", "edgecastcdn.net", "wixstatic.com", "squarespace-cdn.com", "shopifycdn.com", "myshopify.com"}

ALL_TYPES :: [?]string{"image", "script", "raw", "media", "popup", "ping", "fetch", "websocket", "other"}

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

/// a domain of Iris's own list that can become a rule
usable :: proc(d: string) -> bool {
	shared := SHARED
	if len(d) == 0 || in_list(shared[:], d) || strings.index_byte(d, '.') < 0 do return false
	for n in NEVER do if d == n || ends_with_dot(d, n) || ends_with_dot(n, d) do return false
	return host_chars(d)
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

Converter :: struct {
	level:      Level,
	blocks:     [dynamic]string,
	hides:      [dynamic]string,
	exceptions: [dynamic]string,
	generic:    [dynamic]string,
	seen:       map[string]bool,
	/// hosts the lists block whole ("||host^"): Iris's own list skips them
	hosts:      map[string]bool,
	/// the list being read gives hiding rules for every site
	no_generic: bool,
}

converter_add_list :: proc(c: ^Converter, text: string, generic := true) {
	c.no_generic = !generic
	defer c.no_generic = false
	t := text
	for line in strings.split_lines_iterator(&t) do add_line(c, line)
}

converter_add_domains :: proc(c: ^Converter, domains: []string) {
	types := ALL_TYPES
	for d in domains {
		if !usable(d) || covered(c, d) do continue
		emit_block(c, host_pattern(d), types[:], c.level == .moderate ? "third-party" : "", nil, nil)
	}
}

/// a host, or a parent domain of it, the lists already block whole
@(private="file") covered :: proc(c: ^Converter, host: string) -> bool {
	if len(c.hosts) == 0 do return false
	h := host
	for {
		if h in c.hosts do return true
		dot := strings.index_byte(h, '.')
		if dot < 0 do return false
		h = h[dot + 1:]
		if strings.index_byte(h, '.') < 0 do return false
	}
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
	dom := len(yes) == 0 ? strings.concatenate({"\"unless-domain\":", json_list(no[:])}) : strings.concatenate({"\"if-domain\":", json_list(yes[:])})
	append(&c.hides, strings.concatenate({"{\"trigger\":{\"url-filter\":\".*\",", dom, "},\"action\":{\"type\":\"css-display-none\",\"selector\":", json_str(s), "}}"}))
}

@(private="file") domain :: proc(d: string) -> (string, bool) {
	if len(d) == 0 || strings.index_byte(d, '.') < 0 || strings.has_suffix(d, ".*") || strings.index_byte(d, '*') >= 0 || strings.index_byte(d, '/') >= 0 || !host_chars(d) do return "", false
	return strings.concatenate({"*", d}), true
}

@(private="file") type_of :: proc(name: string) -> []string {
	@(static) xhr := [?]string{"raw", "fetch"}
	@(static) other := [?]string{"other"}
	@(static) frame := [?]string{"child-frame"}
	@(static) font := [?]string{"font"}
	@(static) css := [?]string{"style-sheet"}
	@(static) one := [?]string{"script", "image", "media", "ping", "websocket", "popup"}
	switch name {
	case "xmlhttprequest", "xhr": return xhr[:]
	case "object", "other": return other[:]
	case "subdocument", "frame": return frame[:]
	case "font": return font[:]
	case "stylesheet", "css": return css[:]
	case "script": return one[0:1]
	case "image": return one[1:2]
	case "media": return one[2:3]
	case "ping": return one[3:4]
	case "websocket": return one[4:5]
	case "popup": return one[5:6]
	}
	return nil
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
	types: [dynamic]string
	has_types := false
	not_types: [dynamic]string
	party := ""
	if_domains, unless_domains: [dynamic]string
	document_exception := false
	os := opts
	for o in strings.split_iterator(&os, ",") {
		if len(o) == 0 do continue
		low := strings.to_lower(o)
		name, value := low, ""
		if e := strings.index_byte(low, '='); e >= 0 do name, value = low[:e], low[e + 1:]
		negated := len(name) > 0 && name[0] == '~'
		if negated do name = name[1:]
		switch name {
		case "third-party", "3p":
			party = negated ? "first-party" : "third-party"
		case "first-party", "1p":
			party = negated ? "third-party" : "first-party"
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
			ts := type_of(name)
			if ts == nil do return // redirect, removeparam, csp: no WebKit equivalent
			for t in ts {
				if negated {
					append(&not_types, t)
				} else {
					has_types = true
					if !in_list(types[:], t) do append(&types, t)
				}
			}
		}
	}
	if len(if_domains) > 0 && len(unless_domains) > 0 do clear(&unless_domains)
	// the moderate level leaves a site's own requests alone
	if !exception && c.level == .moderate {
		if party == "first-party" do return
		party = "third-party"
	}
	// "||host^", the commonest rule: the same short pattern as Iris's own
	// domains (a host is always followed by ':' or '/'), and remembered
	whole := ""
	if len(pattern) > 3 && strings.has_prefix(pattern, "||") && strings.has_suffix(pattern, "^") {
		h := pattern[2:len(pattern) - 1]
		if strings.index_byte(h, '.') > 0 && host_chars(h) do whole = strings.to_lower(h)
	}
	filter, fok := "", false
	if len(whole) > 0 {
		filter, fok = host_pattern(whole), true
	} else {
		filter, fok = url_filter(pattern)
	}
	if !fok do return
	if document_exception {
		dom := len(if_domains) == 0 ? "" : strings.concatenate({",\"if-domain\":", json_list(if_domains[:])})
		append(&c.exceptions, strings.concatenate({"{\"trigger\":{\"url-filter\":", json_str(filter), dom, ",\"resource-type\":[\"document\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}"}))
		return
	}
	t: [dynamic]string
	if has_types {
		for k in types do append(&t, k)
	} else {
		for k in ALL_TYPES do append(&t, k)
	}
	remove :: proc(t: ^[dynamic]string, k: string) -> bool {
		for x, i in t do if x == k {
			ordered_remove(t, i)
			return true
		}
		return false
	}
	for k in not_types do remove(&t, k)
	// style sheets and fonts always load: pages must look right
	remove(&t, "style-sheet")
	remove(&t, "font")
	frames := remove(&t, "child-frame")
	if exception {
		append(&c.exceptions, rule(filter, has_types ? t[:] : nil, frames, party, if_domains[:], unless_domains[:], "ignore-previous-rules"))
		return
	}
	if len(t) == 0 && !frames do return
	// a rule that names a whole delivery network would break many sites
	if strings.has_prefix(pattern, "||") {
		rest := pattern[2:]
		end := strings.index_any(rest, "^/:*")
		if end < 0 do end = len(rest)
		h := rest[:end]
		shared := SHARED
		if len(h) > 0 && in_list(shared[:], h) && len(rest) - len(h) <= 1 && len(if_domains) == 0 do return
	}
	if len(t) > 0 do emit_block(c, filter, t[:], party, if_domains[:], unless_domains[:])
	if len(whole) > 0 && !has_types && len(not_types) == 0 && len(if_domains) == 0 && len(unless_domains) == 0 && party != "first-party" {
		c.hosts[whole] = true
	}
	if frames {
		doc := [?]string{"document"}
		append(&c.blocks, rule(filter, doc[:], true, party, if_domains[:], unless_domains[:], "block"))
	}
}

@(private="file") emit_block :: proc(c: ^Converter, filter: string, types: []string, party: string, ifd, unlessd: []string) {
	sorted := slice.clone(types)
	slice.sort(sorted)
	key := strings.concatenate({filter, "|", party, "|", strings.join(ifd, ","), "|", strings.join(unlessd, ","), "|", strings.join(sorted, ",")})
	if key in c.seen do return
	c.seen[key] = true
	append(&c.blocks, rule(filter, types, false, party, ifd, unlessd, "block"))
}

@(private="file") rule :: proc(filter: string, types: []string, frames: bool, party: string, ifd, unlessd: []string, action: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"trigger\":{\"url-filter\":")
	strings.write_string(&b, json_str(filter))
	if len(types) > 0 {
		sorted := slice.clone(types)
		slice.sort(sorted)
		strings.write_string(&b, ",\"resource-type\":")
		strings.write_string(&b, json_list(sorted))
	}
	if frames do strings.write_string(&b, ",\"load-context\":[\"child-frame\"]")
	if len(party) > 0 do strings.write_string(&b, strings.concatenate({",\"load-type\":[\"", party, "\"]"}))
	if len(ifd) > 0 do strings.write_string(&b, strings.concatenate({",\"if-domain\":", json_list(ifd)}))
	if len(unlessd) > 0 do strings.write_string(&b, strings.concatenate({",\"unless-domain\":", json_list(unlessd)}))
	strings.write_string(&b, "},\"action\":{\"type\":\"")
	strings.write_string(&b, action)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
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

/// the rules as JSON arrays of at most max_rules each (every part ends with
/// the exceptions, so each part stands alone)
converter_finish :: proc(c: ^Converter, max_rules: int) -> []string {
	// generic hiding in batches of 12 (one bad selector loses only its batch)
	generic: [dynamic]string
	for i := 0; i < len(c.generic); i += 12 {
		batch := strings.join(c.generic[i:min(i + 12, len(c.generic))], ", ")
		append(&generic, strings.concatenate({"{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"css-display-none\",\"selector\":", json_str(batch), "}}"}))
	}
	clear(&c.generic)
	if len(generic) > 0 {
		// Google's and YouTube's pages skip the thousands of selectors meant
		// for other sites' ad boxes (their style is recomputed all the time;
		// their own ads have rules of their own, after this one)
		append(&generic, `{"trigger":{"url-filter":".*","if-domain":["*google.com","*youtube.com"]},"action":{"type":"ignore-previous-rules"}}`)
	}
	if c.level == .ultra {
		// beacons and pings to other sites: tracking, nearly always
		append(&c.blocks, `{"trigger":{"url-filter":".*","resource-type":["ping"],"load-type":["third-party"]},"action":{"type":"block"}}`)
	}
	tail: [dynamic]string
	append(&tail, ..c.exceptions[:])
	// messaging and sign-in pages, and requests to them, are left alone
	for d in NEVER {
		append(&tail, strings.concatenate({"{\"trigger\":{\"url-filter\":", json_str(host_pattern(d)), "},\"action\":{\"type\":\"ignore-previous-rules\"}}"}))
		append(&tail, strings.concatenate({"{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*", d, "\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}"}))
	}
	// YouTube sees no ad blocker (it fights them): only its ad breaks go
	append(&tail, "{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*youtube.com\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}")
	for p in ([?]string{"^https?://(www\\.)?youtube\\.com/youtubei/v1/player/ad_break", "^https?://(www\\.)?youtube\\.com/pagead/", "^https?://(www\\.)?youtube\\.com/api/stats/ads"}) {
		append(&tail, strings.concatenate({"{\"trigger\":{\"url-filter\":", json_str(p), ",\"resource-type\":[\"raw\",\"fetch\",\"script\",\"image\"]},\"action\":{\"type\":\"block\"}}"}))
	}
	// hiding first: WebKit takes the rules that hide everywhere only from
	// before its other rules
	body: [dynamic]string
	append(&body, ..generic[:])
	append(&body, ..c.hides[:])
	append(&body, ..c.blocks[:])
	room := max(1000, max_rules - len(tail))
	parts: [dynamic]string
	for j := 0; ; j += room {
		b := strings.builder_make()
		strings.write_byte(&b, '[')
		first := true
		for r in body[j:min(j + room, len(body))] {
			if !first do strings.write_byte(&b, ',')
			strings.write_string(&b, r)
			first = false
		}
		for r in tail {
			if !first do strings.write_byte(&b, ',')
			strings.write_string(&b, r)
			first = false
		}
		strings.write_byte(&b, ']')
		append(&parts, strings.to_string(b))
		if j + room >= len(body) do break
	}
	return parts[:]
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
	strings.write_byte(&b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"': strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n', '\r', '\t': strings.write_byte(&b, ' ')
		case: if c >= 0x20 do strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

json_list :: proc(items: []string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for s, i in items {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, json_str(s))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// ---------------------------------------------------------------- tests

@(test) test_domain_rules :: proc(t: ^testing.T) {
	testing.expect(t, usable("ads.example.com"))
	testing.expect(t, !usable("cloudfront.net"))
	testing.expect(t, !usable("accounts.google.com"))
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .aggressive}
	converter_add_domains(&c, {"ads.example.com", "gstatic.com"})
	all := strings.join(converter_finish(&c, 120_000), "")
	testing.expect(t, strings.contains(all, "ads\\\\.example\\\\.com"))
	testing.expect(t, !strings.contains(all, "gstatic"))
}

@(test) test_filter_rules :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = .moderate}
	converter_add_list(&c, "! comment\n||ads.example.com^$script\nexample.org##.ad-box\n##.generic-ad\n@@||good.example.com^$document\n||cdn.example.net/x.js$redirect=noop\n")
	all := strings.join(converter_finish(&c, 120_000), "")
	// a third-party block at the moderate level
	testing.expect(t, strings.contains(all, "\"load-type\":[\"third-party\"]"))
	testing.expect(t, strings.contains(all, "\"resource-type\":[\"script\"]"))
	// a site's own hiding stays, the generic one is for the higher levels
	testing.expect(t, strings.contains(all, ".ad-box"))
	testing.expect(t, !strings.contains(all, ".generic-ad"))
	// the page exception, and no rule from a redirect it cannot follow
	testing.expect(t, strings.contains(all, "ignore-previous-rules"))
	testing.expect(t, !strings.contains(all, "cdn\\\\.example"))
}

@(test) test_listed :: proc(t: ^testing.T) {
	list := [?]string{"ads.example.com", "tracker.net"}
	testing.expect(t, listed(list[:], "x.tracker.net"))
	testing.expect(t, listed(list[:], "ads.example.com"))
	testing.expect(t, !listed(list[:], "example.com"))
}
