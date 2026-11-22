//! Iris Shields' rules, as in Brave: the same filter lists as uBlock Origin,
//! with uBlock's own fixes for sites they would break always on, turned into
//! WebKit content rules (blocking, hiding with CSS, exceptions). WPE WebKit
//! compiles them and stops a request inside the engine before it leaves.
//! Scriptlets, redirects and other uBlock extensions have no WebKit
//! equivalent and are left out; so are rules a wrong guess would turn into
//! breakage.
//!
//! Pure Zig (no C): the build's domain tool uses it too.
const std = @import("std");

pub const Level = enum {
    /// ads and trackers from other sites (EasyList, EasyPrivacy); a site's
    /// own requests always go
    moderate,
    /// also the site's own ads and trackers, uBlock's filters, and the empty
    /// boxes ads leave behind
    aggressive,
    /// also cookie notices, newsletter and sign-up pop-ups and other annoyances
    ultra,

    pub fn title(l: Level) []const u8 {
        return switch (l) {
            .moderate => "Moderate",
            .aggressive => "Aggressive",
            .ultra => "Ultra aggressive",
        };
    }

    pub fn hint(l: Level) []const u8 {
        return switch (l) {
            .moderate => "Other sites' ads",
            .aggressive => "All ads, trackers",
            .ultra => "Also pop-ups, cookies",
        };
    }

    /// the lists this level reads
    pub fn lists(l: Level) []const List {
        return switch (l) {
            .moderate => &.{ .easylist, .easyprivacy, .unbreak },
            .aggressive => &.{ .easylist, .easyprivacy, .unbreak, .ublock, .ublock_privacy, .quick_fixes },
            .ultra => &.{ .easylist, .easyprivacy, .unbreak, .ublock, .ublock_privacy, .quick_fixes, .cookies, .annoyances },
        };
    }
};

/// a filter list, with where it comes from (uBlock Origin's mirrors)
pub const List = enum {
    easylist,
    easyprivacy,
    unbreak,
    ublock,
    ublock_privacy,
    quick_fixes,
    cookies,
    annoyances,

    /// the file name Iris keeps it under (as Iris 2.1 did)
    pub fn id(l: List) []const u8 {
        return switch (l) {
            .ublock_privacy => "ublock-privacy",
            .quick_fixes => "quick-fixes",
            else => @tagName(l),
        };
    }

    pub fn path(l: List) []const u8 {
        return switch (l) {
            .easylist => "thirdparties/easylist.txt",
            .easyprivacy => "thirdparties/easyprivacy.txt",
            .unbreak => "filters/unbreak.txt",
            .ublock => "filters/filters.txt",
            .ublock_privacy => "filters/privacy.txt",
            .quick_fixes => "filters/quick-fixes.txt",
            .cookies => "thirdparties/easylist-cookies.txt",
            .annoyances => "filters/annoyances-others.txt",
        };
    }

    pub const mirrors = [_][]const u8{
        "https://ublockorigin.github.io/uAssets/",
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/gh-pages/",
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/",
    };
};

/// messaging, sign-in and human checks: never blocked
pub const never = [_][]const u8{ "whatsapp.com", "whatsapp.net", "accounts.google.com", "login.microsoftonline.com", "login.live.com", "teams.microsoft.com", "meet.google.com", "challenges.cloudflare.com", "hcaptcha.com", "recaptcha.net", "appleid.apple.com" };

/// delivery networks that carry countless ordinary sites: a whole-domain
/// rule naming one of them would break those sites
pub const shared = [_][]const u8{ "cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "akamaihd.net", "akamaized.net", "akamai.net", "edgekey.net", "edgesuite.net", "fastly.net", "fastlylb.net", "azureedge.net", "azurefd.net", "azurewebsites.net", "windows.net", "blob.core.windows.net", "msecnd.net", "googleusercontent.com", "googleapis.com", "storage.googleapis.com", "gstatic.com", "cloudflare.com", "cloudflare.net", "jsdelivr.net", "unpkg.com", "github.io", "githubusercontent.com", "netlify.app", "vercel.app", "herokuapp.com", "firebaseapp.com", "web.app", "appspot.com", "b-cdn.net", "cdn77.org", "kxcdn.com", "digitaloceanspaces.com", "r2.dev", "pages.dev", "workers.dev", "wp.com", "cloudinary.com", "imgix.net", "ctfassets.net", "backblazeb2.com", "rackcdn.com", "llnwd.net", "hwcdn.net", "edgecastcdn.net", "wixstatic.com", "squarespace-cdn.com", "shopifycdn.com", "myshopify.com" };

const all_types = [_][]const u8{ "image", "script", "raw", "media", "popup", "ping", "fetch", "websocket", "other" };

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn endsWithDot(s: []const u8, suffix: []const u8) bool {
    return s.len > suffix.len and std.mem.endsWith(u8, s, suffix) and s[s.len - suffix.len - 1] == '.';
}

fn hostChars(d: []const u8) bool {
    for (d) |b| if (!(std.ascii.isAlphanumeric(b) or b == '.' or b == '-' or b == '_')) return false;
    return true;
}

/// a domain of Iris's own list that may be blocked whole
pub fn usable(d: []const u8) bool {
    if (d.len == 0 or inList(&shared, d) or std.mem.indexOfScalar(u8, d, '.') == null) return false;
    for (never) |n| if (std.mem.eql(u8, d, n) or endsWithDot(d, n) or endsWithDot(n, d)) return false;
    return hostChars(d);
}

/// whether a host, or a domain it belongs to, is in a sorted list
pub fn listed(sorted: []const []const u8, host: []const u8) bool {
    var h = host;
    while (true) {
        if (contains(sorted, h)) return true;
        const dot = std.mem.indexOfScalar(u8, h, '.') orelse return false;
        h = h[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, h, '.') == null) return false;
    }
}

fn contains(sorted: []const []const u8, s: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, sorted[mid], s)) {
            .eq => return true,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return false;
}

// ---------------------------------------------------------------- the converter

pub const Converter = struct {
    a: std.mem.Allocator,
    level: Level,
    blocks: std.ArrayList([]const u8) = .empty,
    hides: std.ArrayList([]const u8) = .empty,
    exceptions: std.ArrayList([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// generic hiding, gathered and written in small batches
    generic: std.ArrayList([]const u8) = .empty,

    /// a converter whose rules live in `arena` (freed all at once)
    pub fn init(arena: std.mem.Allocator, level: Level) Converter {
        return .{ .a = arena, .level = level };
    }

    pub fn addList(c: *Converter, text: []const u8) void {
        var it = std.mem.tokenizeAny(u8, text, "\r\n");
        while (it.next()) |line| c.addLine(line);
    }

    /// the domains of Iris's own list
    pub fn addDomains(c: *Converter, domains: []const []const u8) void {
        for (domains) |d| {
            if (!usable(d)) continue;
            c.emitBlock(hostPattern(c.a, d), &all_types, if (c.level == .moderate) "third-party" else null, &.{}, &.{});
        }
    }

    pub fn hostPattern(a: std.mem.Allocator, d: []const u8) []const u8 {
        const low = std.ascii.allocLowerString(a, d) catch return "";
        return std.mem.concat(a, u8, &.{ "^[^:]+://+([^:/]+\\.)?", escape(a, low), "[:/]" }) catch "";
    }

    pub fn addLine(c: *Converter, raw: []const u8) void {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '!' or line[0] == '[') return;
        if (std.mem.indexOf(u8, line, "##")) |i| {
            c.cosmetic(line[0..i], line[i + 2 ..]);
            return;
        }
        // other cosmetic and scriptlet syntax WebKit cannot follow
        for ([_][]const u8{ "#@#", "#?#", "#$#", "#%#", "#@?#", "#@$#", "$$", "##^" }) |m| if (std.mem.indexOf(u8, line, m) != null) return;
        c.network(line);
    }

    const unsupported = [_][]const u8{ ":has-text(", ":-abp-", ":style(", ":remove(", ":matches-", ":upward(", ":xpath(", ":watch-attr", ":min-text-length", ":others(", ":matches-path(", ":remove-attr(", ":remove-class(", ":contains(", "+js(", ":matches-media(", ":matches-prop(" };

    fn cosmetic(c: *Converter, domains: []const u8, sel: []const u8) void {
        const s = std.mem.trim(u8, sel, " \t");
        if (s.len == 0 or s.len >= 400 or std.mem.startsWith(u8, s, "+js") or s[0] == '^' or std.mem.indexOfScalar(u8, s, '{') != null) return;
        for (s) |b| if (b >= 0x80) return;
        for (unsupported) |u| if (std.mem.indexOf(u8, s, u) != null) return;
        if (domains.len == 0) {
            // the boxes ads leave, everywhere: aggressive and ultra only
            if (c.level != .moderate) c.generic.append(c.a, s) catch {};
            return;
        }
        var yes: std.ArrayList([]const u8) = .empty;
        var no: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, domains, ',');
        while (it.next()) |d0| {
            const d = std.ascii.allocLowerString(c.a, std.mem.trim(u8, d0, " ")) catch return;
            if (d.len > 0 and d[0] == '~') {
                if (domain(c.a, d[1..])) |v| no.append(c.a, v) catch {};
            } else if (domain(c.a, d)) |v| yes.append(c.a, v) catch {};
        }
        if (yes.items.len == 0 and no.items.len == 0) return;
        const dom = if (yes.items.len == 0) cat(c.a, &.{ "\"unless-domain\":", jsonList(c.a, no.items) }) else cat(c.a, &.{ "\"if-domain\":", jsonList(c.a, yes.items) });
        c.hides.append(c.a, cat(c.a, &.{ "{\"trigger\":{\"url-filter\":\".*\",", dom, "},\"action\":{\"type\":\"css-display-none\",\"selector\":", json(c.a, s), "}}" })) catch {};
    }

    /// a domain as WebKit takes it ("*example.com" for it and its
    /// subdomains); null for forms it cannot (example.*, paths)
    fn domain(a: std.mem.Allocator, d: []const u8) ?[]const u8 {
        if (d.len == 0 or std.mem.indexOfScalar(u8, d, '.') == null or std.mem.endsWith(u8, d, ".*") or std.mem.indexOfScalar(u8, d, '*') != null or std.mem.indexOfScalar(u8, d, '/') != null or !hostChars(d)) return null;
        return cat(a, &.{ "*", d });
    }

    const TypeSet = std.StringArrayHashMapUnmanaged(void);

    fn network(c: *Converter, line: []const u8) void {
        var l = line;
        const exception = std.mem.startsWith(u8, l, "@@");
        if (exception) l = l[2..];
        var pattern = l;
        var opts: []const u8 = "";
        // the options after the last $, when what follows it reads as options
        if (std.mem.lastIndexOfScalar(u8, l, '$')) |i| {
            const tail = l[i + 1 ..];
            var ok = tail.len > 0;
            for (tail) |b| if (!(std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-~=|._,*:", b) != null)) {
                ok = false;
            };
            if (ok) {
                pattern = l[0..i];
                opts = tail;
            }
        }
        // regular expressions: WebKit's are a smaller language; left out
        if (pattern.len > 1 and pattern[0] == '/' and pattern[pattern.len - 1] == '/') return;
        var types: ?TypeSet = null;
        var notTypes: TypeSet = .empty;
        var party: ?[]const u8 = null;
        var ifDomains: std.ArrayList([]const u8) = .empty;
        var unlessDomains: std.ArrayList([]const u8) = .empty;
        var documentException = false;
        var oi = std.mem.tokenizeScalar(u8, opts, ',');
        while (oi.next()) |o| {
            const low = std.ascii.allocLowerString(c.a, o) catch return;
            var name: []const u8 = low;
            var value: []const u8 = "";
            if (std.mem.indexOfScalar(u8, low, '=')) |e| {
                value = low[e + 1 ..];
                name = low[0..e];
            }
            const negated = name.len > 0 and name[0] == '~';
            if (negated) name = name[1..];
            if (eq(name, "third-party") or eq(name, "3p")) {
                party = if (negated) "first-party" else "third-party";
            } else if (eq(name, "first-party") or eq(name, "1p")) {
                party = if (negated) "third-party" else "first-party";
            } else if (eq(name, "domain") or eq(name, "from")) {
                var di = std.mem.splitScalar(u8, value, '|');
                while (di.next()) |d| {
                    if (d.len > 0 and d[0] == '~') {
                        if (domain(c.a, d[1..])) |v| unlessDomains.append(c.a, v) catch {};
                    } else if (domain(c.a, d)) |v| ifDomains.append(c.a, v) catch {};
                }
                if (ifDomains.items.len == 0 and unlessDomains.items.len == 0) return;
            } else if (eq(name, "match-case") or eq(name, "important") or eq(name, "all")) {
                // nothing to do
            } else if (eq(name, "document") or eq(name, "doc") or eq(name, "elemhide") or eq(name, "ehide") or eq(name, "generichide") or eq(name, "ghide")) {
                // on these pages, nothing is hidden or blocked: only as an exception
                if (!exception or negated) return;
                documentException = true;
            } else if (typeOf(name)) |ts| {
                for (ts) |t| {
                    if (negated) {
                        notTypes.put(c.a, t, {}) catch {};
                    } else {
                        if (types == null) types = .empty;
                        types.?.put(c.a, t, {}) catch {};
                    }
                }
            } else return; // redirect, removeparam, csp and the rest: no WebKit equivalent
        }
        if (ifDomains.items.len > 0 and unlessDomains.items.len > 0) unlessDomains.clearRetainingCapacity();
        // the moderate level leaves a site's own requests alone
        if (!exception and c.level == .moderate) {
            if (party != null and eq(party.?, "first-party")) return;
            party = "third-party";
        }
        const filter = urlFilter(c.a, pattern) orelse return;
        if (documentException) {
            const dom = if (ifDomains.items.len == 0) "" else cat(c.a, &.{ ",\"if-domain\":", jsonList(c.a, ifDomains.items) });
            c.exceptions.append(c.a, cat(c.a, &.{ "{\"trigger\":{\"url-filter\":", json(c.a, filter), dom, ",\"resource-type\":[\"document\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}" })) catch {};
            return;
        }
        var t: TypeSet = .empty;
        if (types) |ts| {
            for (ts.keys()) |k| t.put(c.a, k, {}) catch {};
        } else for (all_types) |k| t.put(c.a, k, {}) catch {};
        for (notTypes.keys()) |k| _ = t.orderedRemove(k);
        // style sheets and fonts always load: pages must look right
        _ = t.orderedRemove("style-sheet");
        _ = t.orderedRemove("font");
        const frames = t.orderedRemove("child-frame");
        if (exception) {
            c.exceptions.append(c.a, rule(c.a, filter, if (types == null) null else t.keys(), frames, party, ifDomains.items, unlessDomains.items, "ignore-previous-rules")) catch {};
            return;
        }
        if (t.count() == 0 and !frames) return;
        // a rule that names a whole delivery network would break many sites
        if (std.mem.startsWith(u8, pattern, "||")) {
            const rest = pattern[2..];
            const end = std.mem.indexOfAny(u8, rest, "^/:*") orelse rest.len;
            const h = rest[0..end];
            if (h.len > 0 and inList(&shared, h) and rest.len - h.len <= 1 and ifDomains.items.len == 0) return;
        }
        if (t.count() > 0) c.emitBlock(filter, t.keys(), party, ifDomains.items, unlessDomains.items);
        if (frames) c.blocks.append(c.a, rule(c.a, filter, &.{"document"}, true, party, ifDomains.items, unlessDomains.items, "block")) catch {};
    }

    fn typeOf(name: []const u8) ?[]const []const u8 {
        if (eq(name, "xmlhttprequest") or eq(name, "xhr")) return &.{ "raw", "fetch" };
        if (eq(name, "object")) return &.{"other"};
        if (eq(name, "subdocument") or eq(name, "frame")) return &.{"child-frame"};
        if (eq(name, "font")) return &.{"font"};
        if (eq(name, "stylesheet") or eq(name, "css")) return &.{"style-sheet"};
        for ([_][]const u8{ "script", "image", "media", "ping", "websocket", "popup", "other" }) |n| if (eq(name, n)) return switch (n[0]) {
            's' => &.{"script"},
            'i' => &.{"image"},
            'm' => &.{"media"},
            'w' => &.{"websocket"},
            'o' => &.{"other"},
            else => if (eq(n, "ping")) &.{"ping"} else &.{"popup"},
        };
        return null;
    }

    fn emitBlock(c: *Converter, filter: []const u8, types: []const []const u8, party: ?[]const u8, ifDomains: []const []const u8, unlessDomains: []const []const u8) void {
        const sorted = sortedCopy(c.a, types);
        const key = cat(c.a, &.{ filter, "|", party orelse "", "|", join(c.a, ifDomains, ","), "|", join(c.a, unlessDomains, ","), "|", join(c.a, sorted, ",") });
        const g = c.seen.getOrPut(c.a, key) catch return;
        if (g.found_existing) return;
        c.blocks.append(c.a, rule(c.a, filter, types, false, party, ifDomains, unlessDomains, "block")) catch {};
    }

    /// one rule as JSON
    fn rule(a: std.mem.Allocator, filter: []const u8, types: ?[]const []const u8, frames: bool, party: ?[]const u8, ifDomains: []const []const u8, unlessDomains: []const []const u8, action: []const u8) []const u8 {
        var trig: std.ArrayList(u8) = .empty;
        trig.appendSlice(a, "\"url-filter\":") catch {};
        trig.appendSlice(a, json(a, filter)) catch {};
        if (types) |ts| if (ts.len > 0) {
            trig.appendSlice(a, ",\"resource-type\":") catch {};
            trig.appendSlice(a, jsonList(a, sortedCopy(a, ts))) catch {};
        };
        if (frames) trig.appendSlice(a, ",\"load-context\":[\"child-frame\"]") catch {};
        if (party) |p| trig.appendSlice(a, cat(a, &.{ ",\"load-type\":[\"", p, "\"]" })) catch {};
        if (ifDomains.len > 0) trig.appendSlice(a, cat(a, &.{ ",\"if-domain\":", jsonList(a, ifDomains) })) catch {};
        if (unlessDomains.len > 0) trig.appendSlice(a, cat(a, &.{ ",\"unless-domain\":", jsonList(a, unlessDomains) })) catch {};
        return cat(a, &.{ "{\"trigger\":{", trig.items, "},\"action\":{\"type\":\"", action, "\"}}" });
    }

    /// the filter's address pattern as a WebKit url-filter, or null when it
    /// cannot be said in WebKit's regular expressions (or says too little)
    pub fn urlFilter(a: std.mem.Allocator, p0: []const u8) ?[]const u8 {
        var p = p0;
        var out: std.ArrayList(u8) = .empty;
        if (std.mem.startsWith(u8, p, "||")) {
            p = p[2..];
            out.appendSlice(a, "^[^:]+://+([^:/]+\\.)?") catch return null;
        } else if (std.mem.startsWith(u8, p, "|")) {
            p = p[1..];
            out.append(a, '^') catch return null;
        }
        var endAnchor = false;
        if (std.mem.endsWith(u8, p, "|")) {
            p = p[0 .. p.len - 1];
            endAnchor = true;
        }
        while (p.len > 0 and p[0] == '*') p = p[1..];
        while (p.len > 0 and p[p.len - 1] == '*') p = p[0 .. p.len - 1];
        var letters: usize = 0;
        for (p) |b| {
            if (b >= 0x80 or b == '\n' or b == '\r') return null;
            if (std.ascii.isAlphanumeric(b)) letters += 1;
        }
        if (out.items.len == 0 and letters < 4) return null; // too short to say anything safely
        if (p.len == 0) return if (out.items.len == 0) null else cat(a, &.{ out.items, ".*" });
        for (p, 0..) |ch, i| {
            switch (ch) {
                '*' => out.appendSlice(a, ".*") catch {},
                '^' => out.appendSlice(a, if (i == p.len - 1) "([^a-zA-Z0-9_.%-].*)?$" else "[^a-zA-Z0-9_.%-]") catch {},
                else => {
                    if (std.mem.indexOfScalar(u8, "\\.+?{}()[]$|^*", ch) != null) out.append(a, '\\') catch {};
                    out.append(a, ch) catch {};
                },
            }
        }
        if (endAnchor and !std.mem.endsWith(u8, out.items, "$")) out.append(a, '$') catch {};
        return out.items;
    }

    /// the rules in WebKit's JSON, cut into lists WebKit accepts (at most
    /// 150,000 rules in one); every part ends with all exceptions, because
    /// an exception only reaches the rules before it in its list
    pub fn finish(c: *Converter, maxRules: usize) []const []const u8 {
        const a = c.a;
        // generic hiding in batches of 12 (one bad selector loses only its batch)
        var i: usize = 0;
        while (i < c.generic.items.len) : (i += 12) {
            const batch = join(a, c.generic.items[i..@min(i + 12, c.generic.items.len)], ", ");
            c.hides.append(a, cat(a, &.{ "{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"css-display-none\",\"selector\":", json(a, batch), "}}" })) catch {};
        }
        c.generic.clearRetainingCapacity();
        var tail: std.ArrayList([]const u8) = .empty;
        tail.appendSlice(a, c.exceptions.items) catch {};
        // messaging and sign-in pages, and requests to them, are left alone
        for (never) |d| {
            tail.append(a, cat(a, &.{ "{\"trigger\":{\"url-filter\":", json(a, hostPattern(a, d)), "},\"action\":{\"type\":\"ignore-previous-rules\"}}" })) catch {};
            tail.append(a, cat(a, &.{ "{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*", d, "\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}" })) catch {};
        }
        // YouTube sees no ad blocker (it fights them): only its ad breaks go
        tail.append(a, "{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*youtube.com\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}") catch {};
        for ([_][]const u8{ "^https?://(www\\.)?youtube\\.com/youtubei/v1/player/ad_break", "^https?://(www\\.)?youtube\\.com/pagead/", "^https?://(www\\.)?youtube\\.com/api/stats/ads" }) |p| {
            tail.append(a, cat(a, &.{ "{\"trigger\":{\"url-filter\":", json(a, p), ",\"resource-type\":[\"raw\",\"fetch\",\"script\",\"image\"]},\"action\":{\"type\":\"block\"}}" })) catch {};
        }
        // hiding first: WebKit takes the rules that hide everywhere only
        // from before its other rules
        var body: std.ArrayList([]const u8) = .empty;
        body.appendSlice(a, c.hides.items) catch {};
        body.appendSlice(a, c.blocks.items) catch {};
        const room = @max(1000, maxRules -| tail.items.len);
        var parts: std.ArrayList([]const u8) = .empty;
        var j: usize = 0;
        while (true) {
            var part: std.ArrayList(u8) = .empty;
            part.append(a, '[') catch {};
            var first = true;
            for (body.items[j..@min(j + room, body.items.len)]) |r| {
                if (!first) part.append(a, ',') catch {};
                part.appendSlice(a, r) catch {};
                first = false;
            }
            for (tail.items) |r| {
                if (!first) part.append(a, ',') catch {};
                part.appendSlice(a, r) catch {};
                first = false;
            }
            part.append(a, ']') catch {};
            parts.append(a, part.items) catch {};
            j += room;
            if (j >= body.items.len) break;
        }
        return parts.items;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn cat(a: std.mem.Allocator, parts: []const []const u8) []const u8 {
    return std.mem.concat(a, u8, parts) catch "";
}

fn join(a: std.mem.Allocator, parts: []const []const u8, sep: []const u8) []const u8 {
    return std.mem.join(a, sep, parts) catch "";
}

fn sortedCopy(a: std.mem.Allocator, items: []const []const u8) []const []const u8 {
    const out = a.dupe([]const u8, items) catch return items;
    std.sort.pdq([]const u8, out, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f);
    return out;
}

pub fn escape(a: std.mem.Allocator, s: []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.mem.indexOfScalar(u8, "\\.+?{}()[]$|^*", ch) != null) o.append(a, '\\') catch {};
        o.append(a, ch) catch {};
    }
    return o.items;
}

pub fn json(a: std.mem.Allocator, s: []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    o.append(a, '"') catch {};
    for (s) |ch| switch (ch) {
        '"' => o.appendSlice(a, "\\\"") catch {},
        '\\' => o.appendSlice(a, "\\\\") catch {},
        '\n', '\r', '\t' => o.append(a, ' ') catch {},
        else => if (ch >= 0x20) o.append(a, ch) catch {},
    };
    o.append(a, '"') catch {};
    return o.items;
}

fn jsonList(a: std.mem.Allocator, items: []const []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    o.append(a, '[') catch {};
    for (items, 0..) |s, i| {
        if (i > 0) o.append(a, ',') catch {};
        o.appendSlice(a, json(a, s)) catch {};
    }
    o.append(a, ']') catch {};
    return o.items;
}

// ---------------------------------------------------------------- tests

test "domains of Iris's list" {
    try std.testing.expect(usable("ads.example.com"));
    try std.testing.expect(!usable("cloudfront.net"));
    try std.testing.expect(!usable("accounts.google.com"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = Converter.init(arena.allocator(), .aggressive);
    c.addDomains(&.{ "ads.example.com", "gstatic.com" });
    const parts = c.finish(120_000);
    const all = join(arena.allocator(), parts, "");
    try std.testing.expect(std.mem.indexOf(u8, all, "ads\\\\.example\\\\.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "gstatic") == null);
}

test "filters become content rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = Converter.init(arena.allocator(), .moderate);
    c.addList("! comment\n||ads.example.com^$script\nexample.org##.ad-box\n##.generic-ad\n@@||good.example.com^$document\n||cdn.example.net/x.js$redirect=noop\n");
    const all = join(arena.allocator(), c.finish(120_000), "");
    // a third-party block at the moderate level
    try std.testing.expect(std.mem.indexOf(u8, all, "\"load-type\":[\"third-party\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "\"resource-type\":[\"script\"]") != null);
    // a site's own hiding stays, the generic one is for the higher levels
    try std.testing.expect(std.mem.indexOf(u8, all, ".ad-box") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, ".generic-ad") == null);
    // the page exception, and no rule from a redirect it cannot follow
    try std.testing.expect(std.mem.indexOf(u8, all, "ignore-previous-rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "cdn\\\\.example") == null);
}

test "a host and its parent domains are listed" {
    const list = [_][]const u8{ "ads.example.com", "tracker.net" };
    try std.testing.expect(listed(&list, "x.tracker.net"));
    try std.testing.expect(listed(&list, "ads.example.com"));
    try std.testing.expect(!listed(&list, "example.com"));
}
