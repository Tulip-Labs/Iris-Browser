// Addresses and searches: what the address bar opens (an address, or a
// question for Google AI Mode), how an address is shown, which sites go to
// the sandbox, and Google's redirects skipped.
package iris

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"

GOOGLE :: "https://www.google.com/search?gl=us&hl=en"
INSTRUCTION :: "Use only high-quality, authoritative and up-to-date sources (official sites, documentation, peer-reviewed research, reputable news) and cite them. Answer clearly, precisely and concisely, with the most recent information."
SEPARATOR :: "\n\n"
/// every new tab: Google AI Mode, ready for a question
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
		end := strings.index_any(rest, "/?#")
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

/// a query parameter, decoded (allocated), or false
url_param :: proc(u: Url, name: string, allocator := context.allocator) -> (string, bool) {
	q := u.query
	for kv in strings.split_iterator(&q, "&") {
		eq := strings.index_byte(kv, '=')
		if eq < 0 do eq = len(kv)
		if kv[:eq] != name do continue
		return decode(eq < len(kv) ? kv[eq + 1:] : "", allocator), true
	}
	return "", false
}

decode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 3 <= len(s) {
			if v, ok := strconv.parse_uint(s[i + 1:i + 3], 16); ok {
				strings.write_byte(&b, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
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
	q, h2 := url_param(u, "q", context.temp_allocator)
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
	parts: [4]u64
	n := 0
	rest := h
	for p in strings.split_iterator(&rest, ".") {
		if n == 4 do return false
		v, ok := strconv.parse_u64(p, 10)
		if !ok || v > 255 do return h == "::1"
		parts[n] = v
		n += 1
	}
	if n != 4 do return h == "::1"
	return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31)
}

/// a site Iris does not trust (no encryption, or a bare IP address) opens in
/// the sandbox
untrusted :: proc(url: string) -> bool {
	u, ok := url_parse(url)
	if !ok do return false
	http := strings.equal_fold(u.scheme, "http")
	if !http && !strings.equal_fold(u.scheme, "https") do return false
	lh := strings.to_lower(u.host, context.temp_allocator)
	if is_private_host(lh) || strings.has_suffix(lh, ".local") || strings.has_suffix(lh, ".lan") || strings.has_suffix(lh, ".home.arpa") do return false
	if http do return true
	bare := strings.trim(lh, "[]")
	n := 0
	ipv4 := true
	rest := bare
	for p in strings.split_iterator(&rest, ".") {
		if _, ok2 := strconv.parse_u64(p, 10); !ok2 do ipv4 = false
		n += 1
	}
	return (ipv4 && n == 4) || strings.index_byte(bare, ':') >= 0
}

OPENABLE :: [?]string{"http", "https", "file", "about", "mailto", "tel"}

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

is_url_like :: proc(text: string) -> bool {
	t := strings.trim_space(text)
	if len(t) == 0 do return false
	if has_scheme(t) do return true
	if _, ok := scheme_part(t); ok do return false // "note: milk", "javascript:"
	if strings.index_byte(t, ' ') >= 0 do return false
	return strings.index_byte(t, '.') >= 0 || strings.equal_fold(t, "localhost") || strings.has_prefix(strings.to_lower(t, context.temp_allocator), "localhost:")
}

@(private="file") complete :: proc(t: string, allocator := context.allocator) -> string {
	if has_scheme(t) do return strings.clone(t, allocator)
	h := t
	if i := strings.index_byte(h, '/'); i >= 0 do h = h[:i]
	if i := strings.index_any(h, "?#"); i >= 0 do h = h[:i]
	if len(h) > 0 && h[0] != '[' {
		if i := strings.last_index_byte(h, ':'); i >= 0 do h = h[:i]
	}
	return strings.concatenate({is_private_host(h) ? "http://" : "https://", t}, allocator)
}

/// what the address bar opens for what was typed
resolve :: proc(input: string, allocator := context.allocator) -> string {
	t := strings.trim_space(input)
	if len(t) == 0 do return ""
	if is_url_like(t) do return complete(t, allocator)
	if len(t) > 3 && strings.has_prefix(strings.to_lower(t[:3], context.temp_allocator), "yt ") do return youtube_url(strings.trim_space(t[3:]), allocator)
	return ai_url(t, allocator)
}

/// how an address shows in the address bar: the question, or the host
display_url :: proc(url: string, allocator := context.allocator) -> string {
	if len(url) == 0 || url == "about:blank" do return ""
	if q, ok := ai_query(url, allocator); ok do return q
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
}

@(test) test_ai_mode :: proc(t: ^testing.T) {
	u := resolve("why is the sky blue", context.temp_allocator)
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
	testing.expect(t, strings.contains(resolve("javascript:alert(1)", context.temp_allocator), "udm=50"))
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

@(test) test_untrusted :: proc(t: ^testing.T) {
	testing.expect(t, untrusted("http://example.com/"))
	testing.expect(t, untrusted("https://203.0.113.7/login"))
	testing.expect(t, !untrusted("https://example.com/"))
	testing.expect(t, !untrusted("http://localhost:8080/"))
	testing.expect(t, !untrusted("http://192.168.1.1/"))
	testing.expect(t, !untrusted("http://printer.local/"))
	testing.expect(t, !untrusted("about:blank"))
}

@(test) test_sites :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve("yt cats", context.temp_allocator), "https://www.youtube.com/results?search_query=cats")
	testing.expect_value(t, site_of("news.bbc.co.uk"), "bbc.co.uk")
	testing.expect_value(t, site_of("a.b.example.com"), "example.com")
	testing.expect_value(t, display_url("https://www.example.com/x", context.temp_allocator), "example.com")
}
