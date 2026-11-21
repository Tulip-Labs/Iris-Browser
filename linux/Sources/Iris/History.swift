import Foundation

/// The pages you have been to, for the address bar's suggestions and the
/// new-tab page's sites. Private tabs leave nothing here.
struct Visit: Codable {
    var url: String
    var title: String
    var visits: Int
    var last: Double
}

final class History {
    static let shared = History()
    private let file = JSONFile<[Visit]>("history.json")
    private(set) var list: [Visit]
    private var dirty = false

    private init() { list = file.load() ?? [] }

    func record(_ url: String, title: String) {
        guard url.hasPrefix("http"), Search.aiQuery(url) == nil else { return }
        let now = Date().timeIntervalSince1970
        if let i = list.firstIndex(where: { $0.url == url }) {
            list[i].visits += 1
            list[i].last = now
            if !title.isEmpty { list[i].title = title }
        } else {
            list.append(Visit(url: url, title: title, visits: 1, last: now))
        }
        if list.count > 3000 {
            list.sort { score($0, now) > score($1, now) }
            list.removeLast(list.count - 2500)
        }
        later()
    }

    func title(_ url: String, _ title: String) {
        guard !title.isEmpty, let i = list.firstIndex(where: { $0.url == url }) else { return }
        list[i].title = title
        later()
    }

    private func later() {
        if dirty { return }
        dirty = true
        after(ms: 2000) { [weak self] in self?.flush() }
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        file.save(list)
    }

    func clear() {
        list.removeAll()
        file.save(list)
    }

    private func score(_ v: Visit, _ now: Double) -> Double {
        let days = max(0, now - v.last) / 86400
        return Double(v.visits) / (1 + days / 7)
    }

    /// up to n pages matching typed text, best first
    func suggest(_ q: String, n: Int = 6) -> [Visit] {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [(Visit, Double)] = []
        for v in list {
            let host = Search.display(v.url).lowercased()
            let u = v.url.lowercased()
            var s = 0.0
            if host.hasPrefix(q) { s = 4 } else if u.contains(q) { s = 2 } else if v.title.lowercased().contains(q) { s = 1.5 }
            if s > 0 { out.append((v, s * (1 + score(v, now)))) }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(n).map(\.0)
    }

    /// the sites you go to most, one page per site
    func top(_ n: Int) -> [Visit] {
        let now = Date().timeIntervalSince1970
        var seen = Set<String>()
        var out: [Visit] = []
        for v in list.sorted(by: { score($0, now) > score($1, now) }) {
            guard let h = Search.host(v.url) else { continue }
            let site = Search.site(h)
            if seen.insert(site).inserted {
                // the site's front page
                out.append(Visit(url: "https://" + h + "/", title: v.title, visits: v.visits, last: v.last))
            }
            if out.count == n { break }
        }
        return out
    }
}
