import XCTest
@testable import Iris

final class SearchTests: XCTestCase {
    func testAddressesOpen() {
        XCTAssertEqual(Search.resolve("example.com"), "https://example.com")
        XCTAssertEqual(Search.resolve("https://example.com/a?b"), "https://example.com/a?b")
        XCTAssertEqual(Search.resolve("localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(Search.resolve("192.168.1.4/admin"), "http://192.168.1.4/admin")
    }

    func testEverythingElseAsksAIMode() {
        let u = Search.resolve("why is the sky blue")
        XCTAssertTrue(u.hasPrefix("https://www.google.com/search?gl=us&hl=en&udm=50&q=why%20is%20the%20sky%20blue"))
        XCTAssertEqual(Search.aiQuery(u), "why is the sky blue")
        XCTAssertEqual(Search.display(u), "why is the sky blue")
    }

    func testPastedScriptsNeverRun() {
        XCTAssertFalse(Search.isURLLike("javascript:alert(1)"))
        XCTAssertTrue(Search.resolve("javascript:alert(1)").contains("udm=50"))
        XCTAssertFalse(Search.isURLLike("note: milk"))
    }

    func testYouTube() {
        XCTAssertEqual(Search.resolve("yt cats"), "https://www.youtube.com/results?search_query=cats")
    }

    func testSites() {
        XCTAssertEqual(Search.site("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(Search.site("a.b.example.com"), "example.com")
        XCTAssertEqual(Search.display("https://www.example.com/x"), "example.com")
    }

    func testShieldRules() {
        XCTAssertTrue(ShieldRules.usable("ads.example.com"))
        XCTAssertFalse(ShieldRules.usable("cloudfront.net"))
        XCTAssertFalse(ShieldRules.usable("accounts.google.com"))
        let json = ShieldRules.json(domains: ["ads.example.com", "gstatic.com"])
        XCTAssertTrue(json.contains("ads\\\\.example\\\\.com"))
        XCTAssertFalse(json.contains("gstatic"))
    }

    func testVersions() {
        XCTAssertTrue(Updates.newer("2.0.1", than: "2.0.0"))
        XCTAssertTrue(Updates.newer("2.1", than: "2.0.9"))
        XCTAssertFalse(Updates.newer("2.0.0", than: "2.0.0"))
    }

    func testSprings() {
        var s = Spring(0)
        s.target = 1
        for _ in 0..<120 { s.step(1.0 / 60) }
        XCTAssertEqual(s.value, 1, accuracy: 0.01)
        XCTAssertTrue(s.settled)
    }
}
