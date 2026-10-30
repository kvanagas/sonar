import XCTest

/// Not a pass/fail benchmark; reports how much of one CPU core the analysis needs.
final class PerformanceTests: XCTestCase {
    func testAnalysisCostPerSecondOfAudio() {
        let seconds = 60.0
        let signal = SyntheticAudio.drumLoop(bpm: 128, seconds: seconds)
        let analyzer = TempoAnalyzer(sampleRate: SyntheticAudio.sampleRate)
        let start = DispatchTime.now().uptimeNanoseconds
        signal.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let n = min(2400, buf.count - i) // ~50 ms, like one engine tick
                analyzer.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
                i += n
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let load = elapsed / seconds * 100
        print(String(format: "PERF %.0f s of audio analysed in %.3f s → %.2f%% of one core", seconds, elapsed, load))
        XCTAssertLessThan(load, 5, "analysis should be a small fraction of real time")
    }
}
