import Foundation

/// What the address bar does with typed text: an address opens, anything
/// else is a question for Google AI Mode (with Iris's instruction to rest the
/// answer on the best sources). "yt cats" searches YouTube.
enum Search {
    static let google = "https://www.google.com/search?gl=us&hl=en"
    static let instruction = "Use only high-quality, authoritative and up-to-date sources (official sites, documentation, peer-reviewed research, reputable news) and cite them. Answer clearly, precisely and concisely, with the most recent information."
    static let separator = "\n\n"

    static func escape(_ s: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-_.~")
        // alphanumerics holds letters beyond ASCII; keep only ASCII ones
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: ascii.intersection(ok)) ?? s
    }

    static func aiURL(_ q: String) -> String {
        google + "&udm=50&q=" + escape(q.trimmingCharacters(in: .whitespacesAndNewlines) + separator + instruction)
    }

    /// the home of every new tab: Google AI Mode, ready for a question
    static let home = google + "&udm=50"

    /// whether an address is Google AI Mode (its page gets Iris's glass)
    static func isAIMode(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), let h = c.host, h == "www.google.com" || h == "google.com" else { return false }
        return c.path == "/aimode" || (c.path == "/search" && c.queryItems?.first(where: { $0.name == "udm" })?.value == "50")
    }

    /// Google's way out to a result (google.com/url?q=…): the result itself,
    /// so a link opens without the extra stop
    static func unwrapRedirect(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let h = c.host, h == "www.google.com" || h == "google.com", c.path == "/url",
              let target = c.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value,
              target.hasPrefix("https://") || target.hasPrefix("http://") else { return nil }
        return target
    }

    /// Sites Iris does not trust, opened in the sandbox without asking: no
    /// encryption (http), or an address that is a bare public IP. (A site
    /// whose certificate fails joins them when it fails.) Your own network
    /// and this computer are trusted.
    static func untrusted(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return false }
        if scheme != "http" && scheme != "https" { return false }
        if isPrivateHost(host) || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return false }
        if scheme == "http" { return true }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let ipv4 = bare.split(separator: ".").count == 4 && bare.split(separator: ".").allSatisfy { UInt8($0) != nil }
        return ipv4 || bare.contains(":")
    }

    static func youtubeURL(_ q: String) -> String {
        "https://www.youtube.com/results?search_query=" + escape(q)
    }

    /// The reader's own words in an AI Mode address made by Iris (for the
    /// address bar and history), without the instruction.
    static func aiQuery(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host,
              host == "www.google.com" || host == "google.com", c.path == "/search",
              c.queryItems?.first(where: { $0.name == "udm" })?.value == "50",
              var q = c.queryItems?.first(where: { $0.name == "q" })?.value else { return nil }
        if let r = q.range(of: separator + instruction) { q = String(q[..<r.lowerBound]) }
        else if q == instruction { q = "" }
        q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    private static let openable: Set<String> = ["http", "https", "file", "about", "mailto", "tel"]

    /// "word:rest" where rest is not a port
    private static func schemePart(_ t: String) -> (scheme: String, rest: Substring)? {
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let s = t[..<colon]
        guard let f = s.first, f.isASCII, f.isLetter,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) else { return nil }
        let rest = t[t.index(after: colon)...]
        // "localhost:8080" is a host and a port, not a scheme
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty {
            let after = rest.dropFirst(digits.count)
            if after.isEmpty || "/?#".contains(after.first!) { return nil }
        }
        return (s.lowercased(), rest)
    }

    static func hasScheme(_ t: String) -> Bool {
        guard let p = schemePart(t) else { return false }
        // a pasted javascript: link never runs from the address bar
        return openable.contains(p.scheme)
    }

    static func isURLLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if hasScheme(t) { return true }
        if schemePart(t) != nil { return false } // "note: milk", "javascript:"
        if t.contains(" ") { return false }
        let l = t.lowercased()
        return t.contains(".") || l == "localhost" || l.hasPrefix("localhost:")
    }

    /// this computer or the local network: http, everything else https
    static func isPrivateHost(_ h: String) -> Bool {
        var h = h.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        let parts = h.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4, h.split(separator: ".").count == 4 {
            switch (parts[0], parts[1]) {
            case (127, _), (10, _), (192, 168): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        return h == "::1"
    }

    static func complete(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasScheme(t) { return t }
        var host = String(t.split(separator: "/", maxSplits: 1).first ?? "")
        if let i = host.firstIndex(where: { $0 == "?" || $0 == "#" }) { host = String(host[..<i]) }
        if !host.hasPrefix("["), let i = host.lastIndex(of: ":") { host = String(host[..<i]) }
        return (isPrivateHost(host) ? "http://" : "https://") + t
    }

    /// address-bar text to the address to open ("" for nothing)
    static func resolve(_ input: String) -> String {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if isURLLike(t) { return complete(t) }
        let l = t.lowercased()
        if l.hasPrefix("yt "), t.count > 3 { return youtubeURL(String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)) }
        return aiURL(t)
    }

    /// what the address bar shows for an address while it is not being edited
    static func display(_ url: String) -> String {
        if url.isEmpty || url == "about:blank" { return "" }
        if let q = aiQuery(url) { return q }
        guard let c = URLComponents(string: url), let host = c.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// the address, for editing (an Iris AI search shows the question)
    static func editable(_ url: String) -> String {
        if url == "about:blank" { return "" }
        return aiQuery(url) ?? url
    }

    static func host(_ url: String) -> String? {
        URLComponents(string: url)?.host?.lowercased()
    }

    /// the registrable part of a host, roughly (two labels, three for
    /// co.uk-like endings): enough to tell one site from another
    static func site(_ host: String) -> String {
        let l = host.split(separator: ".")
        guard l.count > 2 else { return host }
        let two = l.suffix(2).joined(separator: ".")
        let shortSLD = ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go"]
        if l[l.count - 1].count == 2 && shortSLD.contains(String(l[l.count - 2])) {
            return l.suffix(3).joined(separator: ".")
        }
        return two
    }
}
