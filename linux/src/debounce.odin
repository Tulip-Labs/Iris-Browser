// Debouncing and De-AMP, as Brave does them: a link that goes through a
// tracking redirector (a social network's "leaving this site" page, a
// search engine's click counter, a Google AMP viewer) opens its real
// address at once, so the redirector never learns the click. Only
// http(s) addresses on a short list of known redirectors are followed, one
// step each; anything else is left alone.
package iris

import "core:encoding/base64"
import "core:strings"
import "core:testing"

@(private="file") Redirector :: struct {
	host:  string, // exact host, or a suffix starting with "."
	path:  string, // prefix the path must have
	param: string, // the parameter holding the target
}

@(private="file") REDIRECTORS :: [?]Redirector{
	{"l.facebook.com", "/l.php", "u"}, {"lm.facebook.com", "/l.php", "u"}, {"l.instagram.com", "/", "u"},
	{"www.youtube.com", "/redirect", "q"}, {"youtube.com", "/redirect", "q"},
	{"slack-redir.net", "/link", "url"}, {"steamcommunity.com", "/linkfilter", "url"}, {"steamcommunity.com", "/linkfilter", "u"},
	{"www.linkedin.com", "/safety/go", "url"}, {"vk.com", "/away.php", "to"},
	{"duckduckgo.com", "/l/", "uddg"}, {"disq.us", "/url", "url"}, {"getpocket.com", "/redirect", "url"},
	{"out.reddit.com", "/", "url"}, {"www.bing.com", "/ck/a", "u"}, {"www.google.com", "/url", "q"}, {"www.google.com", "/url", "url"},
	{"google.com", "/url", "q"}, {"away.vk.com", "/", "to"}, {"t.umblr.com", "/redirect", "z"},
}

/// the real address behind a known tracking redirector or AMP viewer, if
/// the address is one
debounce_url :: proc(url: string, allocator := context.allocator) -> (string, bool) {
	u, ok := url_parse(url)
	if !ok || len(u.host) == 0 do return "", false
	if !strings.equal_fold(u.scheme, "https") && !strings.equal_fold(u.scheme, "http") do return "", false
	host := strings.to_lower(u.host, context.temp_allocator)
	if t, k := deamp_url(host, u.path, u.query, allocator); k do return t, true
	for r in REDIRECTORS {
		if host != r.host || !strings.has_prefix(u.path, r.path) do continue
		t, has := url_param(u, r.param, context.temp_allocator)
		if !has do continue
		// Bing hides the address in base64url behind "a1"
		if r.host == "www.bing.com" {
			if len(t) < 3 || !strings.has_prefix(t, "a1") do continue
			raw, err := base64.decode(pad4(t[2:]), base64.DEC_URL_TABLE, allocator = context.temp_allocator)
			if err != nil do continue
			t = string(raw)
		}
		if target_ok(t, host) do return strings.clone(t, allocator), true
	}
	return "", false
}

/// a redirector's target must be a web address on another host (never the
/// redirector itself again, never javascript: or data:)
@(private="file") target_ok :: proc(t, from_host: string) -> bool {
	if !strings.has_prefix(t, "https://") && !strings.has_prefix(t, "http://") do return false
	th, ok := host_of(t, context.temp_allocator)
	return ok && th != from_host
}

@(private="file") pad4 :: proc(s: string) -> string {
	r := len(s) % 4
	if r == 0 do return s
	return strings.concatenate({s, strings.repeat("=", 4 - r, context.temp_allocator)}, context.temp_allocator)
}

/// De-AMP: google.com/amp/s/example.com/a and example-com.cdn.ampproject.org
/// and cdn.ampproject.org/c/s/example.com/a are the page itself, as its
/// own site serves it
@(private="file") deamp_url :: proc(host, path, query: string, allocator := context.allocator) -> (string, bool) {
	rest: string
	secure := true
	switch {
	case host == "www.google.com" || host == "google.com":
		if strings.has_prefix(path, "/amp/s/") do rest = path[len("/amp/s/"):]
		else if strings.has_prefix(path, "/amp/") do rest, secure = path[len("/amp/"):], false
	case host == "cdn.ampproject.org":
		if strings.has_prefix(path, "/c/s/") || strings.has_prefix(path, "/v/s/") do rest = path[len("/c/s/"):]
		else if strings.has_prefix(path, "/c/") || strings.has_prefix(path, "/v/") do rest, secure = path[len("/c/"):], false
	}
	if len(rest) == 0 do return "", false
	slash := strings.index_byte(rest, '/')
	h := slash < 0 ? rest : rest[:slash]
	// a plain host name, with a dot, and nothing else in it
	if len(h) < 3 || strings.index_byte(h, '.') < 0 do return "", false
	for c in h do if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '.' && c != '-' do return "", false
	out := strings.concatenate({secure ? "https://" : "http://", rest, len(query) > 0 && !strings.has_prefix(query, "amp") ? "?" : "", len(query) > 0 && !strings.has_prefix(query, "amp") ? query : ""}, allocator)
	return out, true
}

@(test) test_debounce :: proc(t: ^testing.T) {
	r, ok := debounce_url("https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&h=AT0x", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r, "https://example.com/a?b=1")
	_, ok = debounce_url("https://l.facebook.com/l.php?u=javascript%3Aalert(1)", context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = debounce_url("https://l.facebook.com/l.php?u=https%3A%2F%2Fl.facebook.com%2Fx", context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = debounce_url("https://evil.example/l.php?u=https%3A%2F%2Fexample.com", context.temp_allocator)
	testing.expect(t, !ok)
	r, ok = debounce_url("https://www.google.com/amp/s/example.com/news/1", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r, "https://example.com/news/1")
	r, ok = debounce_url("https://cdn.ampproject.org/c/s/example.com/a?x=1", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r, "https://example.com/a?x=1")
	_, ok = debounce_url("https://www.google.com/amp/s/not a host/x", context.temp_allocator)
	testing.expect(t, !ok)
	// Bing: "a1" + base64url of the address
	r, ok = debounce_url("https://www.bing.com/ck/a?!&&p=x&u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS9h&ntb=1", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, r, "https://example.com/a")
}
