// Addresses and searches: what the address bar opens (an address, or a
// Google search; Google AI Mode when you ask for it), how an address is shown, which sites go to
// the sandbox, and Google's redirects skipped.
package iris

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

GOOGLE :: "https://www.google.com/search?gl=us&hl=en"
INSTRUCTION :: "Use only high-quality, authoritative and up-to-date sources (official sites, documentation, peer-reviewed research, reputable news) and cite them. Answer clearly, precisely and concisely, with the most recent information."
SEPARATOR :: "\n\n"
/// Google AI Mode's own page (new tabs are Iris's start page: start.odin)
HOME :: GOOGLE + "&udm=50"

Url :: struct {
	scheme, host, path, query: string,
}

url_parse :: proc(u: string) -> (r: Url, ok: bool) {
	colon := strings.index_byte(u, ':')
	if colon <= 0 do return {}, false
	r.scheme = u[:colon]
	rest := u[colon + 1:]
	if strings.has_prefix(rest, "//") {
		rest = rest[2:]
		// for the web's own schemes a backslash ends the host too, as in
		// every engine (https://evil.com\@www.google.com is evil.com)
		stops := special_scheme(r.scheme) ? "/?#\\" : "/?#"
		end := strings.index_any(rest, stops)
		if end < 0 do end = len(rest)
		auth := rest[:end]
		rest = rest[end:]
		if at := strings.last_index_byte(auth, '@'); at >= 0 do auth = auth[at + 1:]
		if p := strings.last_index_byte(auth, ':'); p >= 0 {
			// not inside an IPv6 literal ([::1]:80 keeps its brackets)
			if !(len(auth) > 0 && auth[0] == '[' && strings.last_index_byte(auth, ']') > p) do auth = auth[:p]
		}
		r.host = auth
	}
	if h := strings.index_byte(rest, '#'); h >= 0 do rest = rest[:h]
	r.path = rest
	if q := strings.index_byte(rest, '?'); q >= 0 {
		r.path = rest[:q]
		r.query = rest[q + 1:]
	}
	return r, true
}

@(private="file") special_scheme :: proc(s: string) -> bool {
	for x in ([?]string{"http", "https", "ws", "wss", "ftp", "file"}) do if strings.equal_fold(s, x) do return true
	return false
}

/// a query parameter, decoded (allocated), or false; plus_space reads a
/// "+" as a space, as forms write them
url_param :: proc(u: Url, name: string, allocator := context.allocator, plus_space := false) -> (string, bool) {
	q := u.query
	for kv in strings.split_iterator(&q, "&") {
		eq := strings.index_byte(kv, '=')
		if eq < 0 do eq = len(kv)
		if kv[:eq] != name do continue
		return decode(eq < len(kv) ? kv[eq + 1:] : "", allocator, plus_space), true
	}
	return "", false
}

@(private="file") hex_value :: proc(c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9': return c - '0', true
	case 'a' ..= 'f': return c - 'a' + 10, true
	case 'A' ..= 'F': return c - 'A' + 10, true
	}
	return 0, false
}

/// %XX escapes undone (exactly two hex digits; anything else stays as it is)
decode :: proc(s: string, allocator := context.allocator, plus_space := false) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			hi, ok1 := hex_value(s[i + 1])
			lo, ok2 := hex_value(s[i + 2])
			if ok1 && ok2 {
				strings.write_byte(&b, hi << 4 | lo)
				i += 2
				continue
			}
		}
		strings.write_byte(&b, plus_space && s[i] == '+' ? ' ' : s[i])
	}
	return strings.to_string(b)
}

/// a file:// address for a path on this computer (each part escaped)
file_uri :: proc(path: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file://")
	for c in transmute([]u8)path {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~', '/':
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~':
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

@(private="file") is_google :: proc(h: string) -> bool {
	return strings.equal_fold(h, "www.google.com") || strings.equal_fold(h, "google.com")
}

/// a Google search, straight to the results: www (no redirect from the
/// bare name), no client or source parameters
search_url :: proc(q: string, allocator := context.allocator) -> string {
	return strings.concatenate({GOOGLE, "&q=", escape(strings.trim_space(q), context.temp_allocator)}, allocator)
}

/// the words of a Google search's address (not AI Mode's: ai_query)
search_query :: proc(url: string, allocator := context.allocator) -> (string, bool) {
	u, ok := url_parse(url)
	if !ok || !is_google(u.host) || u.path != "/search" do return "", false
	if udm, has := url_param(u, "udm", context.temp_allocator); has && udm == "50" do return "", false
	q, has := url_param(u, "q", context.temp_allocator, plus_space = true)
	t := strings.trim_space(q)
	if !has || len(t) == 0 do return "", false
	return strings.clone(t, allocator), true
}

/// Google AI Mode, asked a question (only when you choose it)
ai_url :: proc(q: string, allocator := context.allocator) -> string {
	t := strings.trim_space(q)
	full := strings.concatenate({t, SEPARATOR, INSTRUCTION}, context.temp_allocator)
	return strings.concatenate({GOOGLE, "&udm=50&q=", escape(full, context.temp_allocator)}, allocator)
}

youtube_url :: proc(q: string, allocator := context.allocator) -> string {
	return strings.concatenate({"https://www.youtube.com/results?search_query=", escape(q, context.temp_allocator)}, allocator)
}

is_ai_mode :: proc(url: string) -> bool {
	u, ok := url_parse(url)
	if !ok || !is_google(u.host) do return false
	if u.path == "/aimode" do return true
	if u.path != "/search" do return false
	v, has := url_param(u, "udm", context.temp_allocator)
	return has && v == "50"
}

/// the question an AI Mode address asks (without Iris's instruction)
ai_query :: proc(url: string, allocator := context.allocator) -> (string, bool) {
	u, ok := url_parse(url)
	if !ok || !is_google(u.host) || u.path != "/search" do return "", false
	udm, h1 := url_param(u, "udm", context.temp_allocator)
	if !h1 || udm != "50" do return "", false
	// Google's own search box writes the question with "+" for spaces
	q, h2 := url_param(u, "q", context.temp_allocator, plus_space = true)
	if !h2 do return "", false
	words := q
	if i := strings.index(q, SEPARATOR + INSTRUCTION); i >= 0 {
		words = q[:i]
	} else if q == INSTRUCTION {
		words = ""
	}
	t := strings.trim_space(words)
	if len(t) == 0 do return "", false
	return strings.clone(t, allocator), true
}

/// a Google result link goes straight to the site
unwrap_redirect :: proc(url: string, allocator := context.allocator) -> (string, bool) {
	u, ok := url_parse(url)
	if !ok || !is_google(u.host) || u.path != "/url" do return "", false
	t, has := url_param(u, "q", allocator)
	if !has do t, has = url_param(u, "url", allocator)
	if !has do return "", false
	if strings.has_prefix(t, "https://") || strings.has_prefix(t, "http://") do return t, true
	delete(t, allocator)
	return "", false
}

/// the parameters sites add to links only to follow you from site to site
/// (EasyList's and AdGuard's URL tracking lists agree on these); utm_
/// anything goes too
TRACKING_PARAMS :: [?]string{
	"fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid", "msclkid",
	"mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok",
	"yclid", "ysclid", "igshid", "twclid", "ttclid", "li_fat_id", "epik", "oly_anon_id", "oly_enc_id",
	"rb_clickid", "_openstat", "vero_id", "vero_conv", "wickedid", "_gl", "srsltid", "s_kwcid", "ef_id",
	"irclickid", "irgwc", "cjevent", "sccid", "scclid", "obclid", "dicbo", "spm_id_from", "ml_subscriber",
	"ml_subscriber_hash", "trk_contact", "trk_msg", "trk_module", "trk_sid", "pk_campaign", "pk_kwd",
	"piwik_campaign", "piwik_kwd", "mtm_campaign", "mtm_source", "mtm_medium", "mtm_cid", "matomo_campaign",
}

@(private="file") tracking_param :: proc(key: string) -> bool {
	k := strings.to_lower(key, context.temp_allocator)
	if strings.has_prefix(k, "utm_") do return true
	for p in TRACKING_PARAMS do if k == p do return true
	return false
}

/// the address without its tracking parameters (utm_*, fbclid, gclid...),
/// and whether it had any; Google's own addresses are left as they are
strip_tracking :: proc(url: string, allocator := context.allocator) -> (string, bool) {
	u, ok := url_parse(url)
	if !ok || len(u.query) == 0 || is_google(u.host) do return "", false
	if !strings.equal_fold(u.scheme, "https") && !strings.equal_fold(u.scheme, "http") do return "", false
	q := strings.index_byte(url, '?')
	if q < 0 do return "", false
	end := len(url)
	if h := strings.index_byte(url[q:], '#'); h >= 0 do end = q + h
	kept := strings.builder_make(context.temp_allocator)
	dropped := false
	rest := url[q + 1:end]
	for kv in strings.split_iterator(&rest, "&") {
		if len(kv) == 0 do continue
		eq := strings.index_byte(kv, '=')
		if tracking_param(eq < 0 ? kv : kv[:eq]) {
			dropped = true
			continue
		}
		if strings.builder_len(kept) > 0 do strings.write_byte(&kept, '&')
		strings.write_string(&kept, kv)
	}
	if !dropped do return "", false
	query := strings.to_string(kept)
	return strings.concatenate({url[:q], len(query) > 0 ? "?" : "", query, url[end:]}, allocator), true
}

host_of :: proc(url: string, allocator := context.allocator) -> (string, bool) {
	u, ok := url_parse(url)
	if !ok || len(u.host) == 0 do return "", false
	return strings.to_lower(u.host, allocator), true
}

/// the site a host belongs to ("news.bbc.co.uk" is "bbc.co.uk")
site_of :: proc(h: string) -> string {
	dots: [64]int
	n := 0
	for c, i in transmute([]u8)h do if c == '.' && n < len(dots) {
		dots[n] = i
		n += 1
	}
	if n < 2 do return h
	two := h[dots[n - 2] + 1:]
	last := h[dots[n - 1] + 1:]
	sld := h[dots[n - 2] + 1:dots[n - 1]]
	short := [?]string{"co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go"}
	if len(last) == 2 do for s in short do if s == sld {
		return n >= 3 ? h[dots[n - 3] + 1:] : h
	}
	return two
}

is_private_host :: proc(h0: string) -> bool {
	h := strings.trim(h0, "[]")
	h = strings.trim_suffix(h, ".")
	if strings.equal_fold(h, "localhost") || strings.has_suffix(strings.to_lower(h, context.temp_allocator), ".localhost") do return true
	ip, ok := ipv4_parse(h)
	if !ok do return h == "::1"
	return ip[0] == 127 || ip[0] == 10 || (ip[0] == 192 && ip[1] == 168) || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31)
}

/// a host the web reads as an IPv4 address: the dotted form, and the short
/// and numeric ones every engine accepts too ("127.1", "0x7f.0.0.1",
/// "2130706433"), so none of them passes for a name
ipv4_parse :: proc(host: string) -> (ip: [4]u8, ok: bool) {
	h := strings.trim_suffix(host, ".")
	if len(h) == 0 do return
	parts: [4]u64
	n := 0
	rest := h
	for p in strings.split_iterator(&rest, ".") {
		if n == 4 do return
		parts[n] = ipv4_number(p) or_return
		n += 1
	}
	for i in 0 ..< n - 1 do if parts[i] > 255 do return
	if parts[n - 1] >= u64(1) << (8 * u64(5 - n)) do return
	v := parts[n - 1]
	for i in 0 ..< n - 1 do v += parts[i] << (8 * u64(3 - i))
	return {u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}, true
}

/// one part of an IPv4 address: decimal, 0x hexadecimal or 0 octal
@(private="file") ipv4_number :: proc(s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 do return
	digits, base := s, u64(10)
	if len(s) >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		digits, base = s[2:], 16
	} else if len(s) >= 2 && s[0] == '0' {
		digits, base = s[1:], 8
	}
	if len(digits) > 16 do return
	for c in transmute([]u8)digits {
		d := hex_value(c) or_return
		if u64(d) >= base do return
		v = v * base + u64(d)
	}
	return v, true
}

/// a site Iris does not trust (no encryption, or a bare IP address) opens in
/// the sandbox
untrusted :: proc(url: string) -> bool {
	u, ok := url_parse(url)
	if !ok do return false
	http := strings.equal_fold(u.scheme, "http")
	if !http && !strings.equal_fold(u.scheme, "https") do return false
	lh := strings.to_lower(u.host, context.temp_allocator)
	// a host whose failing certificate you chose to see (interstitial.odin)
	if cert_host_sandboxed(lh) do return true
	if is_private_host(lh) || strings.has_suffix(lh, ".local") || strings.has_suffix(lh, ".lan") || strings.has_suffix(lh, ".home.arpa") do return false
	if http do return true
	bare := strings.trim(lh, "[]")
	if _, ip := ipv4_parse(bare); ip do return true
	return strings.index_byte(bare, ':') >= 0
}

/// what a page may open in a new tab of its own: a web address, never a
/// file of yours (WebKit keeps web pages away from file: addresses, and a
/// tab Iris opens for them must too) unless the page is a local file itself
page_may_open :: proc(url: string, from: string) -> bool {
	if url == "about:blank" do return true
	s, ok := scheme_part(url)
	if !ok do return false
	if s == "http" || s == "https" do return true
	if s == "file" {
		f, fok := scheme_part(from)
		return fok && f == "file"
	}
	return false
}

OPENABLE :: [?]string{"http", "https", "file", "about", "mailto", "tel", "sip", "sms", "magnet"}

/// schemes that are no web address: "tel:123" is a number to call, never
/// the host "tel" on port 123
@(rodata) NON_WEB_SCHEMES := [?]string{"mailto", "tel", "sip", "sms", "magnet"}

@(private="file") scheme_part :: proc(t: string) -> (string, bool) {
	colon := strings.index_byte(t, ':')
	if colon <= 0 || colon > 32 do return "", false
	s := t[:colon]
	c0 := s[0]
	if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z')) do return "", false
	for c in transmute([]u8)s {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-') do return "", false
	}
	rest := t[colon + 1:]
	low := strings.to_lower(s, context.temp_allocator)
	for n in NON_WEB_SCHEMES do if low == n do return low, true
	// "localhost:8080" is a host and a port, not a scheme
	d := 0
	for d < len(rest) && rest[d] >= '0' && rest[d] <= '9' do d += 1
	if d > 0 && (d == len(rest) || strings.index_byte("/?#", rest[d]) >= 0) do return "", false
	return strings.to_lower(s, context.temp_allocator), true
}

has_scheme :: proc(t: string) -> bool {
	s, ok := scheme_part(t)
	if !ok do return false
	// a pasted javascript: link never runs from the address bar
	for o in OPENABLE do if o == s do return true
	return false
}

/// typed text that is an address (a path, a scheme, a host Iris can tell
/// from words); anything else is a search
is_url_like :: proc(text: string) -> bool {
	_, ok := address_of(strings.trim_space(text), context.temp_allocator)
	return ok
}

/// what look like files, not sites: "node.js", "main.go", "notes.md" are
/// words unless a scheme, a path or a port says they are addresses
@(rodata) FILE_EXTENSIONS := [?]string{"js", "py", "md", "txt", "json", "ts", "go", "rs", "c", "h", "cpp", "java", "sh", "exe", "pdf", "png", "jpg", "zip"}

/// names of your own network: never on the web, opened over http
@(rodata) LOCAL_SUFFIXES := [?]string{".local", ".lan", ".home.arpa", ".internal", ".localhost"}

Host_Kind :: enum u8 { None, Local, Public }

/// whether a typed host is one: an address (all four parts, or [IPv6]),
/// localhost or a name of your network, or a dotted name whose parts are
/// all a name's and whose last is 2 to 63 letters (or xn--), not a file's
/// extension unless a port or a path follows
host_kind :: proc(host: string, has_port, has_path: bool) -> Host_Kind {
	if len(host) == 0 do return .None
	if host[0] == '[' {
		if len(host) < 4 || host[len(host) - 1] != ']' do return .None
		inner := host[1:len(host) - 1]
		if strings.index_byte(inner, ':') < 0 do return .None
		for c in transmute([]u8)inner {
			if _, ok := hex_value(c); !ok && c != ':' && c != '.' do return .None
		}
		return inner == "::1" || strings.has_prefix(strings.to_lower(inner, context.temp_allocator), "fe80:") ? .Local : .Public
	}
	h := strings.to_lower(strings.trim_suffix(host, "."), context.temp_allocator)
	if len(h) == 0 || h[0] == '.' || strings.contains(h, "..") do return .None
	numeric := true
	for c in transmute([]u8)h {
		switch c {
		case '0' ..= '9', '.':
		case 'a' ..= 'z', '-', '_': numeric = false
		case:
			if c < 0x80 do return .None // no other signs in a name
			numeric = false
		}
	}
	if h == "localhost" || strings.has_suffix(h, ".localhost") do return .Local
	if numeric {
		// "3.14" is a number: an address is all four parts
		if strings.count(h, ".") != 3 do return .None
		rest := h
		for p in strings.split_iterator(&rest, ".") {
			if len(p) == 0 || len(p) > 3 || (len(p) > 1 && p[0] == '0') do return .None
			v := 0
			for c in transmute([]u8)p do v = v * 10 + int(c - '0')
			if v > 255 do return .None
		}
		return is_private_host(h) ? .Local : .Public
	}
	dot := strings.last_index_byte(h, '.')
	// a single name ("devbox:8080") is no address: localhost is one (above)
	if dot < 0 do return .None
	// every part a name's: letters, digits and hyphens (or another
	// script's letters), 1 to 63 of them, no hyphen at either end
	rest := h
	for label in strings.split_iterator(&rest, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label) - 1] == '-' do return .None
	}
	for s in LOCAL_SUFFIXES do if strings.has_suffix(h, s) && len(h) > len(s) do return .Local
	tld := h[dot + 1:]
	if len(tld) < 2 || len(tld) > 63 do return .None
	if strings.has_prefix(tld, "xn--") do return .Public // an internationalised one, as written in DNS
	for c in transmute([]u8)tld {
		if c >= 0x80 do return .Public // an internationalised one
		if c < 'a' || c > 'z' do return .None // "v2.3.1", "a.b_c"
	}
	if has_port || has_path do return .Public
	for x in FILE_EXTENSIONS do if x == tld do return .None
	return .Public
}

/// what typed text opens as an address, or false (words: a search)
address_of :: proc(t: string, allocator := context.allocator) -> (string, bool) {
	if len(t) == 0 do return "", false
	// a file of yours that is there ("/etc/hosts", "~/a.txt"); "/r/golang"
	// is words
	if t[0] == '/' || t == "~" || strings.has_prefix(t, "~/") {
		path := t[0] == '~' ? strings.concatenate({home_dir(), t[1:]}, context.temp_allocator) : t
		if !os.exists(path) do return "", false
		return file_uri(path, allocator), true
	}
	if has_scheme(t) do return strings.clone(t, allocator), true
	if _, ok := scheme_part(t); ok do return "", false // "note: milk", "javascript:"
	if strings.index_any(t, " \t") >= 0 do return "", false
	end := strings.index_any(t, "/?#")
	if end < 0 do end = len(t)
	hp := t[:end]
	// a name with a user before it ("user@example.com") is an e-mail address
	if strings.index_byte(hp, '@') >= 0 do return "", false
	host, port := hp, ""
	if len(hp) > 0 && hp[0] == '[' {
		close := strings.index_byte(hp, ']')
		if close < 0 do return "", false
		host = hp[:close + 1]
		after := hp[close + 1:]
		if len(after) > 0 {
			if after[0] != ':' do return "", false
			port = after[1:]
			if len(port) == 0 do return "", false
		}
	} else if c := strings.last_index_byte(hp, ':'); c >= 0 {
		host, port = hp[:c], hp[c + 1:]
		if len(port) == 0 do return "", false
	}
	if len(port) > 5 do return "", false
	for c in transmute([]u8)port do if c < '0' || c > '9' do return "", false
	kind := host_kind(host, len(port) > 0, end < len(t) && t[end] == '/')
	switch kind {
	case .None: return "", false
	case .Local: return strings.concatenate({"http://", t}, allocator), true
	case .Public:
	}
	// Google and YouTube answer their bare names with a redirect to www.
	for bare in ([?]string{"google.com", "youtube.com"}) do if strings.equal_fold(host, bare) && len(port) == 0 {
		return strings.concatenate({"https://www.", bare, t[len(host):]}, allocator), true
	}
	return strings.concatenate({"https://", t}, allocator), true
}

/// what the address bar opens for what was typed
resolve :: proc(input: string, allocator := context.allocator) -> string {
	t := strings.trim_space(input)
	if len(t) == 0 do return ""
	if u, ok := address_of(t, allocator); ok do return u
	if len(t) > 3 && strings.has_prefix(strings.to_lower(t[:3], context.temp_allocator), "yt ") do return youtube_url(strings.trim_space(t[3:]), allocator)
	// words are a Google search (AI Mode is its own choice: ai_url)
	return search_url(t, allocator)
}

/// what an address given to Iris when it starts opens: an address as typed
/// in the address bar, and a path a local file. Anything else (a
/// javascript: link from another program, words) is a question, never run.
resolve_arg :: proc(arg: string, cwd: string, allocator := context.allocator) -> string {
	t := strings.trim_space(arg)
	if len(t) == 0 do return ""
	// a path: a file, there or not (a program gave it); "~/..." as typed in
	// the address bar (address_of)
	if t[0] == '/' do return file_uri(t, allocator)
	if strings.has_prefix(t, "./") || strings.has_prefix(t, "../") {
		return file_uri(strings.concatenate({cwd, "/", t}, context.temp_allocator), allocator)
	}
	return resolve(t, allocator)
}

/// how an address shows in the address bar: the question, or the host
display_url :: proc(url: string, allocator := context.allocator) -> string {
	if len(url) == 0 || url == "about:blank" do return ""
	if q, ok := ai_query(url, allocator); ok do return q
	if q, ok := search_query(url, allocator); ok do return q
	u, ok := url_parse(url)
	if !ok || len(u.host) == 0 do return strings.clone(url, allocator)
	h := u.host
	if strings.has_prefix(strings.to_lower(h, context.temp_allocator), "www.") do h = h[4:]
	return strings.to_lower(h, allocator)
}

/// what the address bar shows while editing
editable_url :: proc(url: string, allocator := context.allocator) -> string {
	if url == "about:blank" do return ""
	if q, ok := ai_query(url, allocator); ok do return q
	if q, ok := search_query(url, allocator); ok do return q
	return strings.clone(url, allocator)
}

/// sign-in pages a script may open as a pop-up
is_sign_in :: proc(h: string) -> bool {
	list := [?]string{"accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com", "github.com", "facebook.com", "x.com", "challenges.cloudflare.com", "hcaptcha.com", "recaptcha.net", "paypal.com", "whatsapp.com", "teams.microsoft.com", "meet.google.com"}
	for s in list do if h == s || (strings.has_suffix(h, s) && len(h) > len(s) && h[len(h) - len(s) - 1] == '.') do return true
	return false
}

// ---------------------------------------------------------------- tests

@(test) test_addresses :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve("example.com", context.temp_allocator), "https://example.com")
	testing.expect_value(t, resolve("https://example.com/a?b", context.temp_allocator), "https://example.com/a?b")
	testing.expect_value(t, resolve("localhost:8080", context.temp_allocator), "http://localhost:8080")
	testing.expect_value(t, resolve("192.168.1.4/admin", context.temp_allocator), "http://192.168.1.4/admin")
	// no redirect from the bare name to www.
	testing.expect_value(t, resolve("youtube.com/watch?v=x", context.temp_allocator), "https://www.youtube.com/watch?v=x")
	testing.expect_value(t, resolve("Google.com", context.temp_allocator), "https://www.google.com")
}

@(test) test_ai_mode :: proc(t: ^testing.T) {
	// words are a Google search; AI Mode only when chosen
	s := resolve("why is the sky blue", context.temp_allocator)
	testing.expect_value(t, s, "https://www.google.com/search?gl=us&hl=en&q=why%20is%20the%20sky%20blue")
	testing.expect(t, !is_ai_mode(s))
	sq, sok := search_query(s, context.temp_allocator)
	testing.expect(t, sok)
	testing.expect_value(t, sq, "why is the sky blue")
	testing.expect_value(t, display_url(s, context.temp_allocator), "why is the sky blue")
	u := ai_url("why is the sky blue", context.temp_allocator)
	testing.expect(t, strings.has_prefix(u, "https://www.google.com/search?gl=us&hl=en&udm=50&q=why%20is%20the%20sky%20blue"))
	q, ok := ai_query(u, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, q, "why is the sky blue")
	testing.expect_value(t, display_url(u, context.temp_allocator), "why is the sky blue")
	testing.expect(t, is_ai_mode(HOME))
	testing.expect(t, is_ai_mode("https://www.google.com/aimode"))
	testing.expect(t, !is_ai_mode("https://www.google.com/search?q=cats"))
	testing.expect(t, !is_ai_mode("https://example.com/search?udm=50"))
}

@(test) test_scripts_never_run :: proc(t: ^testing.T) {
	testing.expect(t, !is_url_like("javascript:alert(1)"))
	testing.expect(t, strings.has_prefix(resolve("javascript:alert(1)", context.temp_allocator), "https://www.google.com/search?"))
	testing.expect(t, !is_url_like("note: milk"))
}

@(test) test_redirects :: proc(t: ^testing.T) {
	r, ok := unwrap_redirect("https://www.google.com/url?q=https://example.com/a%3Fb%3D1&sa=U", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r, "https://example.com/a?b=1")
	_, ok2 := unwrap_redirect("https://www.google.com/url?q=javascript:alert(1)", context.temp_allocator)
	testing.expect(t, !ok2)
	_, ok3 := unwrap_redirect("https://evil.com/url?q=https://example.com", context.temp_allocator)
	testing.expect(t, !ok3)
}

@(test) test_tracking :: proc(t: ^testing.T) {
	r, ok := strip_tracking("https://shop.example/p?id=7&utm_source=news&utm_medium=mail&fbclid=abc#top", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r, "https://shop.example/p?id=7#top")
	r, ok = strip_tracking("https://a.example/?gclid=1&UTM_Campaign=x", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r, "https://a.example/")
	_, ok = strip_tracking("https://a.example/?q=utm_source&page=2", context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = strip_tracking("https://www.google.com/search?q=x&gclid=1", context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = strip_tracking("https://a.example/#?utm_source=x", context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = strip_tracking("mailto:a@b.c?utm_source=x", context.temp_allocator)
	testing.expect(t, !ok)
}

@(test) test_url_edges :: proc(t: ^testing.T) {
	// a backslash ends the host, as WebKit reads it: no spoofed AI Mode
	u, _ := url_parse("https://evil.com\\@www.google.com/search?udm=50&q=hi")
	testing.expect_value(t, u.host, "evil.com")
	testing.expect(t, !is_ai_mode("https://evil.com\\@www.google.com/search?udm=50&q=hi"))
	testing.expect_value(t, display_url("https://evil.com\\@www.google.com/search?udm=50&q=hi", context.temp_allocator), "evil.com")
	// escapes: two hex digits exactly
	testing.expect_value(t, decode("a%20b%zz%_1%4", context.temp_allocator), "a b%zz%_1%4")
	testing.expect_value(t, decode("%E2%9C%93", context.temp_allocator), "\u2713")
	testing.expect_value(t, decode("a+b", context.temp_allocator), "a+b")
	testing.expect_value(t, decode("a+b", context.temp_allocator, true), "a b")
	q, ok := ai_query("https://www.google.com/search?q=why+is+the+sky+blue&udm=50", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, q, "why is the sky blue")
	// a redirect target keeps its plus signs
	r, ok2 := unwrap_redirect("https://www.google.com/url?q=https://example.com/a+b", context.temp_allocator)
	testing.expect(t, ok2)
	testing.expect_value(t, r, "https://example.com/a+b")
}

@(test) test_start_arguments :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve_arg("example.com", "/home/a", context.temp_allocator), "https://example.com")
	testing.expect_value(t, resolve_arg("https://example.com/x", "/home/a", context.temp_allocator), "https://example.com/x")
	testing.expect_value(t, resolve_arg("/home/a/My Page#1.html", "/x", context.temp_allocator), "file:///home/a/My%20Page%231.html")
	testing.expect_value(t, resolve_arg("./b.html", "/home/a", context.temp_allocator), "file:///home/a/./b.html")
	testing.expect(t, strings.has_prefix(resolve_arg("javascript:alert(1)", "/", context.temp_allocator), "https://www.google.com/search?"))
	testing.expect_value(t, resolve_arg("   ", "/", context.temp_allocator), "")
}

@(test) test_untrusted :: proc(t: ^testing.T) {
	testing.expect(t, untrusted("http://example.com/"))
	testing.expect(t, untrusted("https://203.0.113.7/login"))
	testing.expect(t, !untrusted("https://example.com/"))
	testing.expect(t, !untrusted("http://localhost:8080/"))
	testing.expect(t, !untrusted("http://192.168.1.1/"))
	testing.expect(t, !untrusted("http://printer.local/"))
	testing.expect(t, !untrusted("about:blank"))
	// an address in any of the forms WebKit reads as IPv4 is an address
	testing.expect(t, untrusted("https://3405803783/"))
	testing.expect(t, untrusted("https://0xcb.0.113.7/"))
	testing.expect(t, untrusted("https://203.0.113.7./"))
	testing.expect(t, !untrusted("http://127.1:8000/"))
	testing.expect(t, !untrusted("http://0x7f000001/"))
	testing.expect(t, !untrusted("https://1.2.3.4.example.com/"))
}

@(test) test_ipv4 :: proc(t: ^testing.T) {
	ip, ok := ipv4_parse("192.168.1.4")
	testing.expect(t, ok)
	testing.expect_value(t, ip, [4]u8{192, 168, 1, 4})
	ip, ok = ipv4_parse("2130706433")
	testing.expect_value(t, ip, [4]u8{127, 0, 0, 1})
	ip, ok = ipv4_parse("0x7f.1")
	testing.expect_value(t, ip, [4]u8{127, 0, 0, 1})
	ip, ok = ipv4_parse("010.0.0.1")
	testing.expect_value(t, ip, [4]u8{8, 0, 0, 1})
	ip, ok = ipv4_parse("10.65535")
	testing.expect_value(t, ip, [4]u8{10, 0, 255, 255})
	_, ok = ipv4_parse("256.1.1.1")
	testing.expect(t, !ok)
	_, ok = ipv4_parse("1.2.3.4.5")
	testing.expect(t, !ok)
	_, ok = ipv4_parse("1..2")
	testing.expect(t, !ok)
	_, ok = ipv4_parse("4294967296")
	testing.expect(t, !ok)
	_, ok = ipv4_parse("example.com")
	testing.expect(t, !ok)
	_, ok = ipv4_parse("08.0.0.1")
	testing.expect(t, !ok)
	testing.expect(t, is_private_host("127.1"))
	testing.expect(t, is_private_host("[::1]"))
	testing.expect(t, !is_private_host("8.8.8.8"))
}

@(test) test_new_tabs_from_pages :: proc(t: ^testing.T) {
	testing.expect(t, page_may_open("https://example.com/", "https://a.com/"))
	testing.expect(t, page_may_open("about:blank", "https://a.com/"))
	testing.expect(t, !page_may_open("file:///home/a/Downloads/x.html", "https://a.com/"))
	testing.expect(t, !page_may_open("FILE:///etc/passwd", "https://a.com/"))
	testing.expect(t, page_may_open("file:///home/a/b.html", "file:///home/a/a.html"))
	testing.expect(t, !page_may_open("javascript:alert(1)", "https://a.com/"))
	testing.expect(t, !page_may_open("data:text/html,hi", "https://a.com/"))
	testing.expect(t, !page_may_open("", "https://a.com/"))
}

@(test) test_sites :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve("yt cats", context.temp_allocator), "https://www.youtube.com/results?search_query=cats")
	testing.expect_value(t, site_of("news.bbc.co.uk"), "bbc.co.uk")
	testing.expect_value(t, site_of("a.b.example.com"), "example.com")
	testing.expect_value(t, display_url("https://www.example.com/x", context.temp_allocator), "example.com")
}

@(test) test_address_bar :: proc(t: ^testing.T) {
	Case :: struct { typed, want: string }
	SEARCH :: "?" // a Google search
	cases := [?]Case{
		// the everyday ones
		{"google.com", "https://www.google.com"},
		{"youtube.com/watch?v=x", "https://www.youtube.com/watch?v=x"},
		{"example.com", "https://example.com"},
		{"news.bbc.co.uk/sport", "https://news.bbc.co.uk/sport"},
		{"localhost:3000", "http://localhost:3000"},
		{"localhost", "http://localhost"},
		{"192.168.1.1", "http://192.168.1.1"},
		{"8.8.8.8", "https://8.8.8.8"},
		{"https://x.y/z", "https://x.y/z"},
		{"mailto:a@b.c", "mailto:a@b.c"},
		{"why is the sky blue", SEARCH},
		{"cats", SEARCH},
		// files of yours, when they are there
		{"/etc/hosts", "file:///etc/hosts"},
		{"/home/nobody-here/file.pdf", SEARCH},
		{"/r/golang", SEARCH},
		// any top-level name, written as names are
		{"deno.land", "https://deno.land"},
		{"goo.gle", "https://goo.gle"},
		{"home.cern", "https://home.cern"},
		{"x.lol", "https://x.lol"},
		{"foo.bar", "https://foo.bar"},
		{"example.xn--p1ai", "https://example.xn--p1ai"},
		{"-bad.example", SEARCH},
		{"a.b_c", SEARCH},
		// what looks like a file is words, unless a path or a port says otherwise
		{"notes.md", SEARCH},
		{"main.go", SEARCH},
		{"setup.py", SEARCH},
		{"docs.rs/serde", "https://docs.rs/serde"},
		// other programs' schemes, as given
		{"tel:123", "tel:123"},
		{"TEL:+15551234", "TEL:+15551234"},
		{"sip:a@b.example", "sip:a@b.example"},
		{"magnet:?xt=urn:btih:abc", "magnet:?xt=urn:btih:abc"},
		// numbers and words with dots are words
		{"3.14", SEARCH},
		{"127.1", SEARCH},
		{"1.2.3.4.5", SEARCH},
		{"256.1.1.1", SEARCH},
		{"v2.3.1", SEARCH},
		{"node.js", SEARCH},
		{"e.g.", SEARCH},
		{"i.e", SEARCH},
		{"user@example.com", SEARCH},
		{"note: milk", SEARCH},
		{"javascript:alert(1)", SEARCH},
		{"a..b.com", SEARCH},
		// a top-level name Iris does not know, with a path or a port, is a site
		{"node.js/docs", "https://node.js/docs"},
		{"site.example:8443", "https://site.example:8443"},
		// IPv6
		{"[::1]:8080", "http://[::1]:8080"},
		{"[::1]", "http://[::1]"},
		{"[2001:db8::1]/x", "https://[2001:db8::1]/x"},
		{"[zz::1]", SEARCH},
		// your own network: http
		{"router.local", "http://router.local"},
		{"nas.lan/admin", "http://nas.lan/admin"},
		{"printer.home.arpa", "http://printer.home.arpa"},
		// a single name with a port: only localhost
		{"devbox:8080", SEARCH},
		{"devbox", SEARCH},
		{"localhost:5173/app", "http://localhost:5173/app"},
		{"devbox:abc", SEARCH},
	}
	for c in cases {
		got := resolve(c.typed, context.temp_allocator)
		if c.want == SEARCH {
			testing.expectf(t, strings.has_prefix(got, GOOGLE), "%q: want a search, got %q", c.typed, got)
			testing.expectf(t, !is_url_like(c.typed), "%q is not an address", c.typed)
		} else {
			testing.expectf(t, got == c.want, "%q: want %q, got %q", c.typed, c.want, got)
			testing.expectf(t, is_url_like(c.typed), "%q is an address", c.typed)
		}
	}
	// ~ is your home folder
	home := resolve("~", context.temp_allocator)
	testing.expect(t, strings.has_prefix(home, "file:///"))
	testing.expect(t, strings.index_byte(home, '~') < 0)
	testing.expect(t, strings.has_prefix(resolve("~/surely-no-such-file-here.txt", context.temp_allocator), GOOGLE))
}
