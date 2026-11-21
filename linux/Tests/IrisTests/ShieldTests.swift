import XCTest
@testable import Iris

final class ShieldTests: XCTestCase {
    func testURLFilters() {
        XCTAssertEqual(ShieldConverter.urlFilter("||ads.example.com^"), "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com([^a-zA-Z0-9_.%-].*)?$")
        XCTAssertEqual(ShieldConverter.urlFilter("/ads/banners/*"), "/ads/banners/")
        XCTAssertEqual(ShieldConverter.urlFilter("|https://x.com/a"), "^https://x\\.com/a")
        XCTAssertNil(ShieldConverter.urlFilter("ad"))        // too short to say anything
        XCTAssertNil(ShieldConverter.urlFilter("/ünï/"))     // WebKit wants ASCII
    }

    func testLevels() {
        var m = ShieldConverter(level: .moderate)
        m.add(line: "||tracker.example^")
        m.add(line: "/adserver.$~third-party")
        m.add(line: "##.ad-box")
        m.add(line: "news.example##.sponsor")
        XCTAssertEqual(m.blocks.count, 1)
        XCTAssertTrue(m.blocks[0].contains("\"load-type\":[\"third-party\"]"))
        XCTAssertEqual(m.hides.count, 1) // only the site's own hiding

        var a = ShieldConverter(level: .aggressive)
        a.add(line: "||tracker.example^")
        a.add(line: "/adserver.$~third-party")
        a.add(line: "##.ad-box")
        a.add(line: "example.com##+js(nowebrtc)")
        a.add(line: "||x.example^$redirect=noop.js")
        a.add(line: "@@||cdn.example^$script,domain=site.example")
        XCTAssertEqual(a.blocks.count, 2)
        XCTAssertFalse(a.blocks[0].contains("load-type"))
        XCTAssertEqual(a.exceptions.count, 1)
        let parts = a.finish()
        XCTAssertEqual(parts.count, 1)
        // hiding first, then blocks, then the exceptions and the never list
        let j = parts[0]
        let hide = j.range(of: "css-display-none")!.lowerBound, block = j.range(of: "\"block\"")!.lowerBound, ex = j.range(of: "ignore-previous-rules")!.lowerBound
        XCTAssertTrue(hide < block && block < ex)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(j.utf8)))
    }

    func testSharedNetworksAreNotBlockedWhole() {
        var a = ShieldConverter(level: .aggressive)
        a.add(line: "||cloudfront.net^")
        a.add(line: "||cloudfront.net^$domain=bad.example")
        XCTAssertEqual(a.blocks.count, 1)
    }
}
