import Foundation

/// How hard Iris Shields block, as in Brave: the same filter lists as
/// uBlock Origin, with uBlock's own fixes for sites they would break always
/// on, at every level.
enum ShieldLevel: String, Codable, CaseIterable {
    /// ads and trackers from other sites (EasyList, EasyPrivacy); a site's
    /// own requests always go, so nothing a site needs is lost
    case moderate
    /// also the site's own ads and trackers, uBlock's filters, and the
    /// empty boxes ads leave behind
    case aggressive
    /// also cookie notices, newsletter and sign-up pop-ups, and other
    /// annoyances, with uBlock's lists (tested against breaking sites)
    case ultra

    var title: String { ["moderate": "Moderate", "aggressive": "Aggressive", "ultra": "Ultra aggressive"][rawValue]! }
    var hint: String { ["moderate": "Other sites' ads", "aggressive": "All ads, trackers", "ultra": "Also pop-ups, cookies"][rawValue]! }
    var about: String {
        switch self {
        case .moderate: return "Ads and trackers from other sites (EasyList, EasyPrivacy). A site's own requests always load."
        case .aggressive: return "Also a site's own ads and trackers, uBlock Origin's filters, and the empty boxes ads leave."
        case .ultra: return "Also cookie notices, newsletter and sign-up pop-ups and other annoyances. uBlock's fixes for broken sites stay on."
        }
    }

    /// the lists this level reads
    var lists: [ShieldList] {
        let base: [ShieldList] = [.easylist, .easyprivacy, .unbreak]
        switch self {
        case .moderate: return base
        case .aggressive: return base + [.ublock, .ublockPrivacy, .quickFixes]
        case .ultra: return base + [.ublock, .ublockPrivacy, .quickFixes, .cookies, .annoyances]
        }
    }
}

/// a filter list, with where it comes from (uBlock Origin's mirrors)
enum ShieldList: String, CaseIterable {
    case easylist, easyprivacy, unbreak, ublock, ublockPrivacy = "ublock-privacy", quickFixes = "quick-fixes"
    case cookies, annoyances

    var urls: [String] {
        let gh = "https://ublockorigin.github.io/uAssets/", raw = "https://raw.githubusercontent.com/uBlockOrigin/uAssets/"
        let path: String
        switch self {
        case .easylist: path = "thirdparties/easylist.txt"
        case .easyprivacy: path = "thirdparties/easyprivacy.txt"
        case .unbreak: path = "filters/unbreak.txt"
        case .ublock: path = "filters/filters.txt"
        case .ublockPrivacy: path = "filters/privacy.txt"
        case .quickFixes: path = "filters/quick-fixes.txt"
        case .cookies: path = "thirdparties/easylist-cookies.txt"
        case .annoyances: path = "filters/annoyances-others.txt"
        }
        return [gh + path, raw + "gh-pages/" + path, raw + "master/" + path]
    }
}

/// ABP and uBlock filter syntax turned into WebKit content rules: what the
/// engine can do before a request leaves (blocking, hiding with CSS,
/// exceptions). Scriptlets, redirects and other uBlock extensions have no
/// WebKit equivalent and are left out; so are rules a wrong guess would
/// turn into breakage.
struct ShieldConverter {
    let level: ShieldLevel
    private(set) var blocks: [String] = []
    private(set) var hides: [String] = []
    private(set) var exceptions: [String] = []
    private var seen = Set<String>()
    /// generic hiding, gathered and written in small batches
    private var generic: [String] = []

    init(level: ShieldLevel) { self.level = level }

    /// messaging, sign-in and human checks: never blocked
    static let never = ["whatsapp.com", "whatsapp.net", "accounts.google.com", "login.microsoftonline.com",
                        "login.live.com", "teams.microsoft.com", "meet.google.com", "challenges.cloudflare.com",
                        "hcaptcha.com", "recaptcha.net", "appleid.apple.com"]

    /// delivery networks that carry countless ordinary sites: a whole-domain
    /// rule naming one of them would break those sites
    static let shared: Set<String> = ["cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "akamaihd.net",
        "akamaized.net", "akamai.net", "edgekey.net", "edgesuite.net", "fastly.net", "fastlylb.net", "azureedge.net",
        "azurefd.net", "azurewebsites.net", "windows.net", "blob.core.windows.net", "msecnd.net",
        "googleusercontent.com", "googleapis.com", "storage.googleapis.com", "gstatic.com", "cloudflare.com",
        "cloudflare.net", "jsdelivr.net", "unpkg.com", "github.io", "githubusercontent.com", "netlify.app",
        "vercel.app", "herokuapp.com", "firebaseapp.com", "web.app", "appspot.com", "b-cdn.net", "cdn77.org",
        "kxcdn.com", "digitaloceanspaces.com", "r2.dev", "pages.dev", "workers.dev", "wp.com", "cloudinary.com",
        "imgix.net", "ctfassets.net", "backblazeb2.com", "rackcdn.com", "llnwd.net", "hwcdn.net",
        "edgecastcdn.net", "wixstatic.com", "squarespace-cdn.com", "shopifycdn.com", "myshopify.com"]

    static let allTypes = ["image", "script", "raw", "media", "popup", "ping", "fetch", "websocket", "other"]

    // MARK: input

    mutating func add(list text: String) {
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) { add(line: line) }
    }

    /// the domains of Iris's own list (about 100,000 ad and tracker hosts)
    mutating func add(domains: [String]) {
        for d in domains where Self.usable(d) {
            emitBlock(filter: Self.hostPattern(d), types: Self.allTypes, party: level == .moderate ? "third-party" : nil, ifDomains: [], unlessDomains: [])
        }
    }

    static func usable(_ d: String) -> Bool {
        if d.isEmpty || shared.contains(d) || !d.contains(".") { return false }
        if never.contains(where: { d == $0 || d.hasSuffix("." + $0) || $0.hasSuffix("." + d) }) { return false }
        return d.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    static func hostPattern(_ d: String) -> String {
        "^[^:]+://+([^:/]+\\.)?" + escape(d.lowercased()) + "[:/]"
    }

    mutating func add(line raw: Substring) { add(line: String(raw)) }

    mutating func add(line raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return }
        if let r = line.range(of: "##") {
            cosmetic(domains: String(line[..<r.lowerBound]), selector: String(line[r.upperBound...]))
            return
        }
        // other cosmetic and scriptlet syntax WebKit cannot follow
        for m in ["#@#", "#?#", "#$#", "#%#", "#@?#", "#@$#", "$$", "##^"] where line.contains(m) { return }
        network(line)
    }

    // MARK: hiding

    static let unsupportedSelector = [":has-text(", ":-abp-", ":style(", ":remove(", ":matches-", ":upward(", ":xpath(",
                                      ":watch-attr", ":min-text-length", ":others(", ":matches-path(", ":remove-attr(",
                                      ":remove-class(", ":contains(", "+js(", ":matches-media(", ":matches-prop("]

    private mutating func cosmetic(domains: String, selector sel: String) {
        let s = sel.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count < 400, s.allSatisfy(\.isASCII), !s.hasPrefix("+js"), !s.hasPrefix("^"),
              !Self.unsupportedSelector.contains(where: s.contains), !s.contains("{") else { return }
        if domains.isEmpty {
            // the boxes ads leave, everywhere: aggressive and ultra only
            if level != .moderate { generic.append(s) }
            return
        }
        var yes: [String] = [], no: [String] = []
        for d in domains.split(separator: ",") {
            let d = d.trimmingCharacters(in: .whitespaces).lowercased()
            if d.hasPrefix("~") { if let v = Self.domain(String(d.dropFirst())) { no.append(v) } } else if let v = Self.domain(d) { yes.append(v) }
        }
        if yes.isEmpty && no.isEmpty { return }
        let dom = yes.isEmpty ? "\"unless-domain\":" + Self.jsonList(no) : "\"if-domain\":" + Self.jsonList(yes)
        hides.append("{\"trigger\":{\"url-filter\":\".*\"," + dom + "},\"action\":{\"type\":\"css-display-none\",\"selector\":" + Self.json(s) + "}}")
    }

    /// a domain as WebKit takes it ("*example.com" for it and its subdomains);
    /// nil for forms it cannot (example.*, IP ranges, paths)
    static func domain(_ d: String) -> String? {
        guard !d.isEmpty, d.contains("."), !d.hasSuffix(".*"), !d.contains("*"), !d.contains("/"),
              d.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else { return nil }
        return "*" + d
    }

    // MARK: requests

    private mutating func network(_ line: String) {
        var l = Substring(line)
        let exception = l.hasPrefix("@@")
        if exception { l = l.dropFirst(2) }
        var pattern = l
        var options: [Substring] = []
        // the options after the last $, when what follows it reads as options
        if let i = l.lastIndex(of: "$") {
            let tail = l[l.index(after: i)...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isLetter || $0.isNumber || "-~=|._,*:".contains($0) }) {
                pattern = l[..<i]
                options = tail.split(separator: ",")
            }
        }
        // regular expressions: WebKit's are a smaller language; left out
        if pattern.count > 1 && pattern.hasPrefix("/") && pattern.hasSuffix("/") { return }
        var types: Set<String>? = nil
        var notTypes = Set<String>()
        var party: String?
        var ifDomains: [String] = [], unlessDomains: [String] = []
        var documentException = false
        for o in options {
            var name = o.lowercased()
            var value = ""
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            let negated = name.hasPrefix("~")
            if negated { name.removeFirst() }
            switch name {
            case "third-party", "3p": party = negated ? "first-party" : "third-party"
            case "first-party", "1p": party = negated ? "third-party" : "first-party"
            case "domain", "from":
                for d in value.split(separator: "|") {
                    if d.hasPrefix("~") { if let v = Self.domain(String(d.dropFirst())) { unlessDomains.append(v) } } else if let v = Self.domain(String(d)) { ifDomains.append(v) }
                }
                if ifDomains.isEmpty && unlessDomains.isEmpty { return }
            case "match-case", "important", "all": break
            case "document", "doc", "elemhide", "ehide", "generichide", "ghide":
                // on these pages, nothing is hidden or blocked: only as an exception
                guard exception, !negated else { return }
                documentException = true
            case "script", "image", "media", "ping", "websocket", "popup", "other", "object", "xmlhttprequest", "xhr", "subdocument", "frame", "font", "stylesheet", "css":
                let t: [String]
                switch name {
                case "xmlhttprequest", "xhr": t = ["raw", "fetch"]
                case "object": t = ["other"]
                case "subdocument", "frame": t = ["child-frame"]
                case "font": t = ["font"]
                case "stylesheet", "css": t = ["style-sheet"]
                default: t = [name]
                }
                if negated { notTypes.formUnion(t) } else { types = (types ?? []).union(t) }
            default:
                return // redirect, removeparam, csp and the rest: no WebKit equivalent
            }
        }
        if !ifDomains.isEmpty && !unlessDomains.isEmpty { unlessDomains = [] }
        // the moderate level leaves a site's own requests alone
        if !exception && level == .moderate {
            if party == "first-party" { return }
            party = "third-party"
        }
        guard let filter = Self.urlFilter(pattern) else { return }
        if documentException {
            let dom = ifDomains.isEmpty ? "" : ",\"if-domain\":" + Self.jsonList(ifDomains)
            exceptions.append("{\"trigger\":{\"url-filter\":" + Self.json(filter) + dom + ",\"resource-type\":[\"document\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}")
            return
        }
        var t = types ?? Set(Self.allTypes)
        t.subtract(notTypes)
        // style sheets and fonts always load: pages must look right
        t.remove("style-sheet")
        t.remove("font")
        var frames = false
        if t.remove("child-frame") != nil { frames = true }
        if exception {
            exceptions.append(Self.rule(filter: filter, types: types == nil ? nil : Array(t), frames: frames, party: party, ifDomains: ifDomains, unlessDomains: unlessDomains, action: "ignore-previous-rules"))
            return
        }
        if t.isEmpty && !frames { return }
        // a rule that names a whole delivery network would break many sites
        if pattern.hasPrefix("||"), let host = pattern.dropFirst(2).split(whereSeparator: { "^/:*".contains($0) }).first,
           Self.shared.contains(String(host)) && pattern.dropFirst(2 + host.count).count <= 1 && ifDomains.isEmpty { return }
        if !t.isEmpty { emitBlock(filter: filter, types: Array(t), party: party, ifDomains: ifDomains, unlessDomains: unlessDomains) }
        if frames { blocks.append(Self.rule(filter: filter, types: ["document"], frames: true, party: party, ifDomains: ifDomains, unlessDomains: unlessDomains, action: "block")) }
    }

    private mutating func emitBlock(filter: String, types: [String], party: String?, ifDomains: [String], unlessDomains: [String]) {
        let key = filter + "|" + (party ?? "") + "|" + ifDomains.joined(separator: ",") + "|" + unlessDomains.joined(separator: ",") + "|" + types.sorted().joined(separator: ",")
        guard seen.insert(key).inserted else { return }
        blocks.append(Self.rule(filter: filter, types: types, frames: false, party: party, ifDomains: ifDomains, unlessDomains: unlessDomains, action: "block"))
    }

    /// one rule as JSON (static: building it never copies the converter)
    private static func rule(filter: String, types: [String]?, frames: Bool, party: String?, ifDomains: [String], unlessDomains: [String], action: String) -> String {
        var trig = "\"url-filter\":" + Self.json(filter)
        if let types, !types.isEmpty { trig += ",\"resource-type\":" + Self.jsonList(types.sorted()) }
        if frames { trig += ",\"load-context\":[\"child-frame\"]" }
        if let party { trig += ",\"load-type\":[\"" + party + "\"]" }
        if !ifDomains.isEmpty { trig += ",\"if-domain\":" + Self.jsonList(ifDomains) }
        if !unlessDomains.isEmpty { trig += ",\"unless-domain\":" + Self.jsonList(unlessDomains) }
        return "{\"trigger\":{" + trig + "},\"action\":{\"type\":\"" + action + "\"}}"
    }

    /// the filter's address pattern as a WebKit url-filter, or nil when it
    /// cannot be said in WebKit's regular expressions (or says too little)
    static func urlFilter(_ p: Substring) -> String? {
        var p = p
        var out = ""
        if p.hasPrefix("||") {
            p = p.dropFirst(2)
            out = "^[^:]+://+([^:/]+\\.)?"
        } else if p.hasPrefix("|") {
            p = p.dropFirst()
            out = "^"
        }
        var endAnchor = false
        if p.hasSuffix("|") { p = p.dropLast(); endAnchor = true }
        while p.hasPrefix("*") { p = p.dropFirst() }
        while p.hasSuffix("*") && !p.isEmpty { p = p.dropLast() }
        guard p.allSatisfy({ $0.isASCII && !$0.isNewline }) else { return nil }
        let letters = p.filter { $0.isLetter || $0.isNumber }.count
        if out.isEmpty && letters < 4 { return nil } // too short to say anything safely
        if p.isEmpty { return out.isEmpty ? nil : out + ".*" }
        let chars = Array(p)
        for (i, c) in chars.enumerated() {
            switch c {
            case "*": out += ".*"
            case "^": out += i == chars.count - 1 ? "([^a-zA-Z0-9_.%-].*)?$" : "[^a-zA-Z0-9_.%-]"
            default: out += escape(String(c))
            }
        }
        if endAnchor && !out.hasSuffix("$") { out += "$" }
        return out
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for c in s {
            if "\\.+?{}()[]$|^*".contains(c) { o += "\\" }
            o.append(c)
        }
        return o
    }

    static func json(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n", "\r", "\t": o += " "
            default: if u.value >= 0x20 { o.unicodeScalars.append(u) }
            }
        }
        return o + "\""
    }

    static func jsonList(_ a: [String]) -> String { "[" + a.map(json).joined(separator: ",") + "]" }

    // MARK: output

    /// the rules in WebKit's JSON, cut into lists WebKit accepts (it takes
    /// at most 150,000 rules in one); every part ends with all exceptions,
    /// because an exception only reaches the rules before it in its list
    mutating func finish(maxRules: Int = 120_000) -> [String] {
        // generic hiding in batches of 12 (one bad selector loses only its batch)
        var i = 0
        while i < generic.count {
            let batch = generic[i..<min(i + 12, generic.count)].joined(separator: ", ")
            hides.append("{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"css-display-none\",\"selector\":" + Self.json(batch) + "}}")
            i += 12
        }
        generic.removeAll()
        var tail = exceptions
        // messaging and sign-in pages, and requests to them, are left alone
        for d in Self.never {
            tail.append("{\"trigger\":{\"url-filter\":" + Self.json(Self.hostPattern(d)) + "},\"action\":{\"type\":\"ignore-previous-rules\"}}")
            tail.append("{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*" + d + "\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}")
        }
        // YouTube sees no ad blocker (it fights them): only its ad breaks go
        tail.append("{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*youtube.com\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}")
        for p in ["^https?://(www\\.)?youtube\\.com/youtubei/v1/player/ad_break", "^https?://(www\\.)?youtube\\.com/pagead/",
                  "^https?://(www\\.)?youtube\\.com/api/stats/ads"] {
            tail.append("{\"trigger\":{\"url-filter\":" + Self.json(p) + ",\"resource-type\":[\"raw\",\"fetch\",\"script\",\"image\"]},\"action\":{\"type\":\"block\"}}")
        }
        // hiding first: WebKit takes the rules that hide everywhere only
        // from before its other rules
        let body = hides + blocks
        let room = max(1000, maxRules - tail.count)
        var parts: [String] = []
        var j = 0
        repeat {
            let slice = body[j..<min(j + room, body.count)]
            parts.append("[" + (Array(slice) + tail).joined(separator: ",") + "]")
            j += room
        } while j < body.count
        return parts
    }
}
