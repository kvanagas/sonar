import XCTest

final class TempoEstimatorTests: XCTestCase {
    private func detect(_ signal: [Float]) -> TempoEstimate? {
        let analyzer = TempoAnalyzer(sampleRate: SyntheticAudio.sampleRate)
        SyntheticAudio.run(signal, through: analyzer)
        return analyzer.estimate
    }

    func testDetectsKnownTempos() {
        for bpm in [90.0, 120, 128, 140, 174] {
            let estimate = detect(SyntheticAudio.drumLoop(bpm: bpm, seconds: 12))
            XCTAssertNotNil(estimate, "no estimate for \(bpm)")
            if let estimate {
                XCTAssertEqual(estimate.bpm, bpm, accuracy: 1, "expected \(bpm), got \(estimate.bpm) (conf \(estimate.confidence))")
            }
        }
    }

    func testSilenceGivesNoEstimate() {
        XCTAssertNil(detect(SyntheticAudio.silence(seconds: 10)))
    }

    func testNoiseIsLowConfidence() {
        XCTAssertNil(detect(SyntheticAudio.noise(seconds: 10, amplitude: 0.3, seed: 7)))
    }
}
