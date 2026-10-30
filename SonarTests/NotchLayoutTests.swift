import XCTest

final class NotchLayoutTests: XCTestCase {
    /// A 13" MacBook Air: 1470×956 points with a 185pt notch, 32pt tall.
    private let air = CGRect(x: 0, y: 0, width: 1470, height: 956)

    func testBannerGrowsOutOfTheNotch() {
        let layout = NotchLayout(screen: air, safeTop: 32, leftWidth: 642.5, rightWidth: 642.5,
                                 menuBarHeight: 32, contentHeight: 56, minWidth: 340)
        XCTAssertTrue(layout.hasNotch)
        XCTAssertEqual(layout.notch, CGRect(x: 642.5, y: 924, width: 185, height: 32))
        XCTAssertEqual(layout.banner.midX, layout.notch.midX)
        XCTAssertEqual(layout.banner.maxY, air.maxY)
        XCTAssertEqual(layout.banner.height, 88)
        XCTAssertEqual(layout.banner.width, 340)
    }

    func testWideNotchStillGetsWings() {
        let layout = NotchLayout(screen: air, safeTop: 32, leftWidth: 500, rightWidth: 500,
                                 menuBarHeight: 32, contentHeight: 56, minWidth: 340)
        XCTAssertEqual(layout.banner.width, 470 + 2 * NotchLayout.wing)
    }

    func testScreenWithoutNotchDropsFromTopCenter() {
        let display = CGRect(x: 1470, y: 0, width: 2560, height: 1440)
        let layout = NotchLayout(screen: display, safeTop: 0, leftWidth: nil, rightWidth: nil,
                                 menuBarHeight: 25, contentHeight: 56, minWidth: 340)
        XCTAssertFalse(layout.hasNotch)
        XCTAssertEqual(layout.notch.midX, display.midX)
        XCTAssertEqual(layout.banner, CGRect(x: display.midX - 170, y: 1440 - 81, width: 340, height: 81))
    }

    func testBannerStaysOnANarrowScreen() {
        let small = CGRect(x: -300, y: 0, width: 300, height: 600)
        let layout = NotchLayout(screen: small, safeTop: 0, leftWidth: nil, rightWidth: nil,
                                 menuBarHeight: 24, contentHeight: 56, minWidth: 340)
        XCTAssertEqual(layout.banner.minX, small.minX)
        XCTAssertEqual(layout.banner.width, small.width)
    }
}
