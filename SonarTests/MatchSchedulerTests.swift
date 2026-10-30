import XCTest

final class MatchSchedulerTests: XCTestCase {
    /// Runs the scheduler in 50 ms ticks and returns the times attempts started.
    private func starts(
        _ scheduler: inout MatchScheduler,
        from: Double, to: Double,
        trackChanges: (Double) -> Int = { _ in 0 },
        suppressed: (Double) -> Bool = { _ in false },
        finishAfter: Double? = nil
    ) -> [Double] {
        var result: [Double] = []
        var t = from
        while t < to {
            if scheduler.tick(time: t, trackChanges: trackChanges(t), suppressed: suppressed(t)) {
                result.append(t)
            }
            if let finishAfter, let last = result.last, scheduler.isMatching, t - last >= finishAfter {
                scheduler.finish(time: t)
            }
            t += 0.05
        }
        return result
    }

    func testFirstAttemptSoonAfterStartThenPeriodic() {
        var scheduler = MatchScheduler()
        let s = starts(&scheduler, from: 0, to: 120)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0], MatchScheduler.changeDelay, accuracy: 0.06)
        // Each attempt runs its full length, then waits the interval.
        XCTAssertEqual(s[1] - s[0], MatchScheduler.attemptLength + MatchScheduler.interval, accuracy: 0.1)
    }

    func testTrackChangeTriggersEarlyAttempt() {
        var scheduler = MatchScheduler()
        let s = starts(&scheduler, from: 0, to: 40, trackChanges: { $0 >= 20 ? 1 : 0 }, finishAfter: 5)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[1], 20 + MatchScheduler.changeDelay, accuracy: 0.06)
    }

    func testSuppressedNeverMatches() {
        var scheduler = MatchScheduler()
        XCTAssertTrue(starts(&scheduler, from: 0, to: 200, suppressed: { _ in true }).isEmpty)
    }

    func testSuppressionCancelsRunningAttempt() {
        var scheduler = MatchScheduler()
        _ = starts(&scheduler, from: 0, to: 5)
        XCTAssertTrue(scheduler.isMatching)
        XCTAssertFalse(scheduler.tick(time: 5, trackChanges: 0, suppressed: true))
        XCTAssertFalse(scheduler.isMatching)
    }

    func testRequestedAttemptStartsAfterDelay() {
        var scheduler = MatchScheduler()
        _ = starts(&scheduler, from: 0, to: 4, finishAfter: 1) // first attempt done
        XCTAssertFalse(scheduler.isMatching)
        scheduler.request(at: 4, delay: 10)
        let s = starts(&scheduler, from: 4, to: 20)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0], 14, accuracy: 0.06)
    }

    func testFinishingEarlyStartsTheIntervalFromThen() {
        var scheduler = MatchScheduler()
        let s = starts(&scheduler, from: 0, to: 60, finishAfter: 3)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[1] - s[0], 3 + MatchScheduler.interval, accuracy: 0.15)
    }
}
