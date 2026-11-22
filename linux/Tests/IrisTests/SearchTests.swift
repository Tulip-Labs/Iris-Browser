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

    func testHomeIsAIMode() {
        XCTAssertTrue(Search.isAIMode(Search.home))
        XCTAssertTrue(Search.isAIMode(Search.aiURL("cats")))
        XCTAssertTrue(Search.isAIMode("https://www.google.com/aimode"))
        XCTAssertFalse(Search.isAIMode("https://www.google.com/search?q=cats"))
        XCTAssertFalse(Search.isAIMode("https://example.com/search?udm=50"))
    }

    func testRedirectsUnwrapped() {
        XCTAssertEqual(Search.unwrapRedirect("https://www.google.com/url?q=https://example.com/a%3Fb%3D1&sa=U"), "https://example.com/a?b=1")
        XCTAssertNil(Search.unwrapRedirect("https://www.google.com/url?q=javascript:alert(1)"))
        XCTAssertNil(Search.unwrapRedirect("https://evil.com/url?q=https://example.com"))
    }

    func testUntrustedSitesGoToTheSandbox() {
        XCTAssertTrue(Search.untrusted("http://example.com/"))
        XCTAssertTrue(Search.untrusted("https://203.0.113.7/login"))
        XCTAssertFalse(Search.untrusted("https://example.com/"))
        XCTAssertFalse(Search.untrusted("http://localhost:8080/"))
        XCTAssertFalse(Search.untrusted("http://192.168.1.1/"))
        XCTAssertFalse(Search.untrusted("http://printer.local/"))
        XCTAssertFalse(Search.untrusted("about:blank"))
    }

    func testAIModeGlassIsTheSameOnAndroid() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let linux = here.appendingPathComponent("../../Sources/Iris/Resources/js/aimode.js").standardized
        let android = here.appendingPathComponent("../../../android/app/src/main/assets/js/aimode.js").standardized
        guard FileManager.default.fileExists(atPath: android.path) else { return } // only the Linux part is here
        XCTAssertEqual(try String(contentsOf: linux, encoding: .utf8), try String(contentsOf: android, encoding: .utf8))
    }

    func testYouTube() {
        XCTAssertEqual(Search.resolve("yt cats"), "https://www.youtube.com/results?search_query=cats")
    }

    func testSites() {
        XCTAssertEqual(Search.site("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(Search.site("a.b.example.com"), "example.com")
        XCTAssertEqual(Search.display("https://www.example.com/x"), "example.com")
    }

    func testShieldDomains() {
        XCTAssertTrue(ShieldConverter.usable("ads.example.com"))
        XCTAssertFalse(ShieldConverter.usable("cloudfront.net"))
        XCTAssertFalse(ShieldConverter.usable("accounts.google.com"))
        var c = ShieldConverter(level: .aggressive)
        c.add(domains: ["ads.example.com", "gstatic.com"])
        let json = c.finish().joined()
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
