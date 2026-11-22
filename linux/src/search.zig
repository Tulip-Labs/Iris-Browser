//! What the address bar does with typed text: an address opens, anything
//! else is a question for Google AI Mode (with Iris's instruction to rest
//! the answer on the best sources). "yt cats" searches YouTube. And the
//! small facts about addresses the rest of Iris asks: the site, whether it
//! is AI Mode, whether Iris trusts it.
//!
//! Strings these return are Iris's own (core.gpa); callers free them.
const std = @import("std");
const core = @import("core.zig");

pub const google = "https://www.google.com/search?gl=us&hl=en";
pub const instruction = "Use only high-quality, authoritative and up-to-date sources (official sites, documentation, peer-reviewed research, reputable news) and cite them. Answer clearly, precisely and concisely, with the most recent information.";
const separator = "\n\n";

/// the home of every new tab: Google AI Mode, ready for a question
pub const home = google ++ "&udm=50";

// ---------------------------------------------------------------- addresses

/// the parts of an address Iris looks at (slices of the address itself)
pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    path: []const u8,
    query: []const u8,

    pub fn parse(u: []const u8) ?Url {
        const colon = std.mem.indexOfScalar(u8, u, ':') orelse return null;
        const scheme = u[0..colon];
        if (scheme.len == 0) return null;
        var rest = u[colon + 1 ..];
        var hst: []const u8 = "";
        if (std.mem.startsWith(u8, rest, "//")) {
            rest = rest[2..];
            const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
            var auth = rest[0..end];
            rest = rest[end..];
            if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| auth = auth[at + 1 ..];
            // the port goes (not inside [IPv6])
            if (std.mem.lastIndexOfScalar(u8, auth, ':')) |p| {
                if (!(auth.len > 0 and auth[0] == '[' and (std.mem.lastIndexOfScalar(u8, auth, ']') orelse 0) > p)) auth = auth[0..p];
            }
            hst = auth;
        }
        if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
        var path = rest;
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
            path = rest[0..q];
            query = rest[q + 1 ..];
        }
        return .{ .scheme = scheme, .host = hst, .path = path, .query = query };
    }

    /// a query parameter, percent-decoded (Iris's heap)
    pub fn param(u: Url, name: []const u8) ?[]u8 {
        var it = std.mem.splitScalar(u8, u.query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse kv.len;
            if (!std.mem.eql(u8, kv[0..eq], name)) continue;
            return decode(if (eq < kv.len) kv[eq + 1 ..] else "");
        }
        return null;
    }
};

fn decode(s: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 3 <= s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out.append(core.gpa, b) catch {};
                i += 2;
                continue;
            } else |_| {}
        }
        out.append(core.gpa, s[i]) catch {};
    }
    return out.toOwnedSlice(core.gpa) catch &.{};
}

fn escape(s: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') {
            out.append(core.gpa, b) catch {};
        } else {
            const h = std.fmt.allocPrint(core.gpa, "%{X:0>2}", .{b}) catch continue;
            defer core.gpa.free(h);
            out.appendSlice(core.gpa, h) catch {};
        }
    }
    return out.toOwnedSlice(core.gpa) catch &.{};
}

fn isGoogle(hn: []const u8) bool {
    return std.ascii.eqlIgnoreCase(hn, "www.google.com") or std.ascii.eqlIgnoreCase(hn, "google.com");
}

pub fn aiURL(q: []const u8) []u8 {
    const t = std.mem.trim(u8, q, " \t\r\n");
    const full = core.fmt("{s}{s}{s}", .{ t, separator, instruction });
    defer core.gpa.free(full);
    const e = escape(full);
    defer core.gpa.free(e);
    return core.fmt("{s}&udm=50&q={s}", .{ google, e });
}

pub fn youtubeURL(q: []const u8) []u8 {
    const e = escape(q);
    defer core.gpa.free(e);
    return core.fmt("https://www.youtube.com/results?search_query={s}", .{e});
}

/// whether an address is Google AI Mode (its page gets Iris's glass)
pub fn isAIMode(url: []const u8) bool {
    const u = Url.parse(url) orelse return false;
    if (!isGoogle(u.host)) return false;
    if (std.mem.eql(u8, u.path, "/aimode")) return true;
    if (!std.mem.eql(u8, u.path, "/search")) return false;
    const v = u.param("udm") orelse return false;
    defer core.gpa.free(v);
    return std.mem.eql(u8, v, "50");
}

/// the reader's own words in an AI Mode address made by Iris, without the
/// instruction
pub fn aiQuery(url: []const u8) ?[]u8 {
    const u = Url.parse(url) orelse return null;
    if (!isGoogle(u.host) or !std.mem.eql(u8, u.path, "/search")) return null;
    const udm = u.param("udm") orelse return null;
    defer core.gpa.free(udm);
    if (!std.mem.eql(u8, udm, "50")) return null;
    const q = u.param("q") orelse return null;
    defer core.gpa.free(q);
    var words: []const u8 = q;
    if (std.mem.indexOf(u8, q, separator ++ instruction)) |i| words = q[0..i] else if (std.mem.eql(u8, q, instruction)) words = "";
    const t = std.mem.trim(u8, words, " \t\r\n");
    return if (t.len == 0) null else core.dupe(t);
}

/// Google's way out to a result (google.com/url?q=…): the result itself
pub fn unwrapRedirect(url: []const u8) ?[]u8 {
    const u = Url.parse(url) orelse return null;
    if (!isGoogle(u.host) or !std.mem.eql(u8, u.path, "/url")) return null;
    const t = u.param("q") orelse u.param("url") orelse return null;
    if (std.mem.startsWith(u8, t, "https://") or std.mem.startsWith(u8, t, "http://")) return t;
    core.gpa.free(t);
    return null;
}

/// the host, lowercased (Iris's heap)
pub fn host(url: []const u8) ?[]u8 {
    const u = Url.parse(url) orelse return null;
    if (u.host.len == 0) return null;
    return std.ascii.allocLowerString(core.gpa, u.host) catch null;
}

/// the registrable part of a host, roughly (two labels, three for co.uk-like
/// endings): enough to tell one site from another (a slice of h)
pub fn site(h: []const u8) []const u8 {
    var dots: [64]usize = undefined;
    var n: usize = 0;
    for (h, 0..) |b, i| if (b == '.' and n < dots.len) {
        dots[n] = i;
        n += 1;
    };
    if (n < 2) return h;
    const two = h[dots[n - 2] + 1 ..];
    const last = h[dots[n - 1] + 1 ..];
    const sld = h[dots[n - 2] + 1 .. dots[n - 1]];
    const short = [_][]const u8{ "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go" };
    if (last.len == 2) for (short) |s| if (std.mem.eql(u8, s, sld)) {
        return if (n >= 3) h[dots[n - 3] + 1 ..] else h;
    };
    return two;
}

/// this computer or the local network: http, everything else https
pub fn isPrivateHost(h0: []const u8) bool {
    var h = std.mem.trim(u8, h0, "[]");
    if (std.mem.endsWith(u8, h, ".")) h = h[0 .. h.len - 1];
    if (std.ascii.eqlIgnoreCase(h, "localhost") or std.ascii.endsWithIgnoreCase(h, ".localhost")) return true;
    var parts: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, h, '.');
    var n: usize = 0;
    while (it.next()) |p| {
        if (n == 4) return false;
        parts[n] = std.fmt.parseInt(u8, p, 10) catch return std.mem.eql(u8, h, "::1");
        n += 1;
    }
    if (n != 4) return std.mem.eql(u8, h, "::1");
    return parts[0] == 127 or parts[0] == 10 or (parts[0] == 192 and parts[1] == 168) or (parts[0] == 172 and parts[1] >= 16 and parts[1] <= 31);
}

/// Sites Iris does not trust, opened in the sandbox without asking: no
/// encryption (http), or a bare public IP. (A site whose certificate fails
/// joins them when it fails.) Your own network and this computer are trusted.
pub fn untrusted(url: []const u8) bool {
    const u = Url.parse(url) orelse return false;
    const http = std.ascii.eqlIgnoreCase(u.scheme, "http");
    if (!http and !std.ascii.eqlIgnoreCase(u.scheme, "https")) return false;
    const h = u.host;
    if (isPrivateHost(h) or std.ascii.endsWithIgnoreCase(h, ".local") or std.ascii.endsWithIgnoreCase(h, ".lan") or std.ascii.endsWithIgnoreCase(h, ".home.arpa")) return false;
    if (http) return true;
    const bare = std.mem.trim(u8, h, "[]");
    var it = std.mem.splitScalar(u8, bare, '.');
    var n: usize = 0;
    var ipv4 = true;
    while (it.next()) |p| : (n += 1) {
        _ = std.fmt.parseInt(u8, p, 10) catch {
            ipv4 = false;
        };
    }
    return (ipv4 and n == 4) or std.mem.indexOfScalar(u8, bare, ':') != null;
}

// ---------------------------------------------------------------- typed text

const openable = [_][]const u8{ "http", "https", "file", "about", "mailto", "tel" };

/// "word:rest" where rest is not a port: the scheme, lowercased in place
/// into buf
fn schemePart(t: []const u8, buf: []u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    const s = t[0..colon];
    if (s.len == 0 or s.len > buf.len or !std.ascii.isAlphabetic(s[0])) return null;
    for (s) |b| if (!(std.ascii.isAlphanumeric(b) or b == '+' or b == '.' or b == '-')) return null;
    const rest = t[colon + 1 ..];
    // "localhost:8080" is a host and a port, not a scheme
    var d: usize = 0;
    while (d < rest.len and std.ascii.isDigit(rest[d])) d += 1;
    if (d > 0 and (d == rest.len or std.mem.indexOfScalar(u8, "/?#", rest[d]) != null)) return null;
    return std.ascii.lowerString(buf[0..s.len], s);
}

pub fn hasScheme(t: []const u8) bool {
    var buf: [32]u8 = undefined;
    const s = schemePart(t, &buf) orelse return false;
    // a pasted javascript: link never runs from the address bar
    for (openable) |o| if (std.mem.eql(u8, o, s)) return true;
    return false;
}

pub fn isURLLike(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return false;
    if (hasScheme(t)) return true;
    var buf: [32]u8 = undefined;
    if (schemePart(t, &buf) != null) return false; // "note: milk", "javascript:"
    if (std.mem.indexOfScalar(u8, t, ' ') != null) return false;
    return std.mem.indexOfScalar(u8, t, '.') != null or std.ascii.eqlIgnoreCase(t, "localhost") or std.ascii.startsWithIgnoreCase(t, "localhost:");
}

fn complete(t: []const u8) []u8 {
    if (hasScheme(t)) return core.dupe(t);
    var h = t[0 .. std.mem.indexOfScalar(u8, t, '/') orelse t.len];
    if (std.mem.indexOfAny(u8, h, "?#")) |i| h = h[0..i];
    if (h.len > 0 and h[0] != '[') if (std.mem.lastIndexOfScalar(u8, h, ':')) |i| {
        h = h[0..i];
    };
    return core.fmt("{s}{s}", .{ if (isPrivateHost(h)) "http://" else "https://", t });
}

/// address-bar text to the address to open ("" for nothing)
pub fn resolve(input: []const u8) []u8 {
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return core.dupe("");
    if (isURLLike(t)) return complete(t);
    if (t.len > 3 and std.ascii.startsWithIgnoreCase(t, "yt ")) return youtubeURL(std.mem.trim(u8, t[3..], " "));
    return aiURL(t);
}

/// what the address bar shows for an address while it is not being edited
pub fn display(url: []const u8) []u8 {
    if (url.len == 0 or std.mem.eql(u8, url, "about:blank")) return core.dupe("");
    if (aiQuery(url)) |q| return q;
    const u = Url.parse(url) orelse return core.dupe(url);
    if (u.host.len == 0) return core.dupe(url);
    const h = if (std.ascii.startsWithIgnoreCase(u.host, "www.")) u.host[4..] else u.host;
    return std.ascii.allocLowerString(core.gpa, h) catch core.dupe(h);
}

/// the address, for editing (an Iris AI search shows the question)
pub fn editable(url: []const u8) []u8 {
    if (std.mem.eql(u8, url, "about:blank")) return core.dupe("");
    return aiQuery(url) orelse core.dupe(url);
}

/// sign-in pages and human checks: pop-ups to these are allowed
pub fn isSignIn(h: []const u8) bool {
    const list = [_][]const u8{ "accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com", "github.com", "facebook.com", "x.com", "challenges.cloudflare.com", "hcaptcha.com", "recaptcha.net", "paypal.com", "whatsapp.com", "teams.microsoft.com", "meet.google.com" };
    for (list) |s| if (std.mem.eql(u8, h, s) or (std.mem.endsWith(u8, h, s) and h.len > s.len and h[h.len - s.len - 1] == '.')) return true;
    return false;
}

// ---------------------------------------------------------------- tests

const tt = std.testing;

fn expectStr(want: []const u8, got: []u8) !void {
    defer core.gpa.free(got);
    try tt.expectEqualStrings(want, got);
}

test "addresses open" {
    try expectStr("https://example.com", resolve("example.com"));
    try expectStr("https://example.com/a?b", resolve("https://example.com/a?b"));
    try expectStr("http://localhost:8080", resolve("localhost:8080"));
    try expectStr("http://192.168.1.4/admin", resolve("192.168.1.4/admin"));
}

test "everything else asks AI Mode" {
    const u = resolve("why is the sky blue");
    defer core.gpa.free(u);
    try tt.expect(std.mem.startsWith(u8, u, "https://www.google.com/search?gl=us&hl=en&udm=50&q=why%20is%20the%20sky%20blue"));
    try expectStr("why is the sky blue", aiQuery(u).?);
    try expectStr("why is the sky blue", display(u));
}

test "pasted scripts never run" {
    try tt.expect(!isURLLike("javascript:alert(1)"));
    const u = resolve("javascript:alert(1)");
    defer core.gpa.free(u);
    try tt.expect(std.mem.indexOf(u8, u, "udm=50") != null);
    try tt.expect(!isURLLike("note: milk"));
}

test "home is AI Mode" {
    try tt.expect(isAIMode(home));
    const a = aiURL("cats");
    defer core.gpa.free(a);
    try tt.expect(isAIMode(a));
    try tt.expect(isAIMode("https://www.google.com/aimode"));
    try tt.expect(!isAIMode("https://www.google.com/search?q=cats"));
    try tt.expect(!isAIMode("https://example.com/search?udm=50"));
}

test "redirects unwrapped" {
    try expectStr("https://example.com/a?b=1", unwrapRedirect("https://www.google.com/url?q=https://example.com/a%3Fb%3D1&sa=U").?);
    try tt.expect(unwrapRedirect("https://www.google.com/url?q=javascript:alert(1)") == null);
    try tt.expect(unwrapRedirect("https://evil.com/url?q=https://example.com") == null);
}

test "untrusted sites go to the sandbox" {
    try tt.expect(untrusted("http://example.com/"));
    try tt.expect(untrusted("https://203.0.113.7/login"));
    try tt.expect(!untrusted("https://example.com/"));
    try tt.expect(!untrusted("http://localhost:8080/"));
    try tt.expect(!untrusted("http://192.168.1.1/"));
    try tt.expect(!untrusted("http://printer.local/"));
    try tt.expect(!untrusted("about:blank"));
}

test "youtube" {
    try expectStr("https://www.youtube.com/results?search_query=cats", resolve("yt cats"));
}

test "sites" {
    try tt.expectEqualStrings("bbc.co.uk", site("news.bbc.co.uk"));
    try tt.expectEqualStrings("example.com", site("a.b.example.com"));
    try expectStr("example.com", display("https://www.example.com/x"));
}
