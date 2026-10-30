import XCTest

final class BeatPhaseTests: XCTestCase {
    /// Signed distance from `time` to the nearest beat of a grid starting at `offset`.
    private func phaseError(_ time: Double, period: Double, offset: Double) -> Double {
        var e = (time - offset).truncatingRemainder(dividingBy: period)
        if e > period / 2 { e -= period }
        if e < -period / 2 { e += period }
        return e
    }

    func testBeatPhaseMatchesSignal() {
        var errors: [Double] = []
        for (bpm, offset) in [(120.0, 0.137), (128, 0.05), (90, 0.31), (140, 0.2), (174, 0.11)] {
            let analyzer = TempoAnalyzer(sampleRate: SyntheticAudio.sampleRate)
            SyntheticAudio.run(SyntheticAudio.drumLoop(bpm: bpm, seconds: 12, offset: offset), through: analyzer)
            guard let beat = analyzer.beat else { return XCTFail("no beat for \(bpm)") }
            XCTAssertEqual(beat.period, 60 / bpm, accuracy: 0.005)
            XCTAssertLessThanOrEqual(beat.lastBeat, analyzer.streamTime)
            errors.append(phaseError(beat.lastBeat, period: 60 / bpm, offset: offset))
        }
        for e in errors { XCTAssertEqual(e, 0, accuracy: 0.025) }
    }
}
