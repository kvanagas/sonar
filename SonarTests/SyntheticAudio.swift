import Foundation

/// Test signals and helpers shared by the tempo tests.
enum SyntheticAudio {
    static let sampleRate = 44_100.0

    /// A simple drum loop: kick on beats 1 & 3, snare on 2 & 4, quieter hi-hats on eighths.
    /// `offset` delays the first beat, which lets beat-phase tests check alignment.
    static func drumLoop(bpm: Double, seconds: Double, offset: Double = 0, seed: UInt64 = 1) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let count = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        let beat = 60 / bpm

        func add(at time: Double, length: Double, _ voice: (Double) -> Double) {
            let start = Int(time * sampleRate)
            let n = Int(length * sampleRate)
            for i in 0..<n where start + i < count {
                out[start + i] += Float(voice(Double(i) / sampleRate))
            }
        }

        var eighth = 0
        var t = offset
        while t < seconds {
            let beatIndex = eighth / 2
            if eighth % 2 == 0 {
                if beatIndex % 2 == 0 {
                    add(at: t, length: 0.25) { x in 0.9 * sin(2 * .pi * (55 + 90 * exp(-x * 30)) * x) * exp(-x * 12) }
                } else {
                    add(at: t, length: 0.18) { x in 0.5 * Double.random(in: -1...1, using: &rng) * exp(-x * 25) }
                }
            }
            add(at: t, length: 0.05) { x in 0.12 * Double.random(in: -1...1, using: &rng) * exp(-x * 80) }
            eighth += 1
            t = offset + Double(eighth) * beat / 2
        }
        return out
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    static func noise(seconds: Double, amplitude: Float, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude, using: &rng) }
    }

    struct Snapshot {
        var time: Double
        var estimate: TempoEstimate?
        var trackChanges: Int
    }

    /// Feeds `signal` through `analyzer` in hardware-sized chunks, like the live tap does,
    /// and records the analyzer's output after each chunk.
    @discardableResult
    static func run(_ signal: [Float], through analyzer: TempoAnalyzer, startTime: Double = 0) -> [Snapshot] {
        var snapshots: [Snapshot] = []
        signal.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let n = min(512, buf.count - i)
                analyzer.process(UnsafeBufferPointer(rebasing: buf[i..<(i + n)]))
                i += n
                snapshots.append(Snapshot(
                    time: startTime + Double(i) / sampleRate,
                    estimate: analyzer.estimate,
                    trackChanges: analyzer.trackChangeCount
                ))
            }
        }
        return snapshots
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
