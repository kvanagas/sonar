import XCTest

final class BrowserPageTests: XCTestCase {
    private func saved(_ string: String) -> String? {
        BrowserPage.saveable(URL(string: string))?.absoluteString
    }

    func testMediaPagesKeepTheirQuery() {
        XCTAssertEqual(saved("https://www.youtube.com/watch?v=abc&t=60"), "https://www.youtube.com/watch?v=abc&t=60")
    }

    func testOtherPagesDropQueryFragmentAndCredentials() {
        XCTAssertEqual(saved("https://docs.example.com/d/123/edit?token=secret#heading"), "https://docs.example.com/d/123/edit")
        XCTAssertEqual(saved("https://user:pass@example.com/radio"), "https://example.com/radio")
    }

    func testOnlyWebPages() {
        XCTAssertNil(saved("file:///Users/me/Music/set.mp3"))
        XCTAssertNil(saved("javascript:alert(1)"))
        XCTAssertNil(saved("chrome://settings"))
    }
}
