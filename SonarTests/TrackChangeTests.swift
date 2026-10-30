import XCTest

final class TrackChangeTests: XCTestCase {
    private let sampleRate = SyntheticAudio.sampleRate

    /// Seconds after `switchTime` until the estimate is within 1 BPM of `bpm` and stays there.
    private func settleTime(_ snapshots: [SyntheticAudio.Snapshot], to bpm: Double, after switchTime: Double) -> Double? {
        var settledAt: Double?
        for s in snapshots where s.time >= switchTime {
            if let e = s.estimate, abs(e.bpm - bpm) <= 1 {
                if settledAt == nil { settledAt = s.time }
            } else {
                settledAt = nil
            }
        }
        return settledAt.map { $0 - switchTime }
    }

    func testGaplessTempoChangeUpdatesQuickly() {
        let analyzer = TempoAnalyzer(sampleRate: sampleRate)
        SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: 120, seconds: 15), through: analyzer)
        XCTAssertEqual(analyzer.estimate?.bpm ?? 0, 120, accuracy: 1)

        let snapshots = SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: 140, seconds: 12, seed: 2), through: analyzer, startTime: 15)
        let settle = settleTime(snapshots, to: 140, after: 15)
        XCTAssertNotNil(settle, "never settled on 140")
        XCTAssertLessThanOrEqual(settle ?? .infinity, 5, "took \(settle ?? -1) s to follow the new track")
        XCTAssertGreaterThanOrEqual(analyzer.trackChangeCount, 1)
    }

    func testSilenceGapResetsOnce() {
        let analyzer = TempoAnalyzer(sampleRate: sampleRate)
        SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: 128, seconds: 12), through: analyzer)
        XCTAssertNotNil(analyzer.estimate)

        let gap = SyntheticAudio.run(SyntheticAudio.silence(seconds: 1.5), through: analyzer, startTime: 12)
        XCTAssertNil(gap.last?.estimate, "estimate should clear during the gap")
        XCTAssertEqual(analyzer.trackChangeCount, 1)

        let next = SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: 100, seconds: 10, seed: 3), through: analyzer, startTime: 13.5)
        let settle = settleTime(next, to: 100, after: 13.5)
        XCTAssertLessThanOrEqual(settle ?? .infinity, 5, "took \(settle ?? -1) s after the gap")
        XCTAssertEqual(analyzer.trackChangeCount, 1, "one gap should be one track change")
    }

    func testSteadyTrackHasNoFalseChanges() {
        let analyzer = TempoAnalyzer(sampleRate: sampleRate)
        var signal = SyntheticAudio.drumLoop(bpm: 128, seconds: 30)
        let noise = SyntheticAudio.noise(seconds: 30, amplitude: 0.05, seed: 9)
        for i in signal.indices { signal[i] += noise[i] }
        SyntheticAudio.run(signal, through: analyzer)
        XCTAssertEqual(analyzer.trackChangeCount, 0)
        XCTAssertEqual(analyzer.estimate?.bpm ?? 0, 128, accuracy: 1)
    }

    func testExplicitTrackChangeClearsEstimate() {
        let analyzer = TempoAnalyzer(sampleRate: sampleRate)
        SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: 128, seconds: 10), through: analyzer)
        analyzer.markTrackChange()
        XCTAssertNil(analyzer.estimate)
        XCTAssertEqual(analyzer.trackChangeCount, 1)
    }

    func testMetadataRightAfterGapIsOneChange() {
        let analyzer = TempoAnalyzer(sampleRate: sampleRate)
        SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: 128, seconds: 10), through: analyzer)
        SyntheticAudio.run(SyntheticAudio.silence(seconds: 1.2), through: analyzer)
        SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: 100, seconds: 1, seed: 4), through: analyzer)
        analyzer.markTrackChange() // the player's notification arrives a moment late
        XCTAssertEqual(analyzer.trackChangeCount, 1)
    }
}
