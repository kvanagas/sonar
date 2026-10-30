import XCTest

final class BeatClockTests: XCTestCase {
    func testNextBeatIsStrictlyAfter() {
        let clock = BeatClock(period: 0.5, lastBeat: 10)
        XCTAssertEqual(clock.nextBeat(after: 10), 10.5, accuracy: 1e-9)
        XCTAssertEqual(clock.nextBeat(after: 10.2), 10.5, accuracy: 1e-9)
        XCTAssertEqual(clock.nextBeat(after: 9.9), 10, accuracy: 1e-9)
        XCTAssertEqual(clock.nextBeat(after: 12.75), 13, accuracy: 1e-9)
    }

    func testSmallJitterIsSmoothed() {
        var clock = BeatClock(period: 0.5, lastBeat: 10)
        clock.update(period: 0.5, lastBeat: 11.02) // 20 ms late
        XCTAssertEqual(clock.nextBeat(after: 11.1), 11.506, accuracy: 1e-6)
    }

    func testLargeErrorSnaps() {
        var clock = BeatClock(period: 0.5, lastBeat: 10)
        clock.update(period: 0.5, lastBeat: 11.2)
        XCTAssertEqual(clock.nextBeat(after: 11.3), 11.7, accuracy: 1e-9)
    }

    func testTempoChangeReanchors() {
        var clock = BeatClock(period: 0.5, lastBeat: 10)
        clock.update(period: 0.4, lastBeat: 11.03)
        XCTAssertEqual(clock.period, 0.4)
        XCTAssertEqual(clock.nextBeat(after: 11.1), 11.43, accuracy: 1e-9)
    }
}
