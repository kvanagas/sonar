import Accelerate
import Foundation

struct TempoEstimate: Equatable {
    var bpm: Double
    /// Rough 0…1 measure of how periodic the onset envelope is.
    var confidence: Double
    /// False for the first few readings after a reset, while the value may still move.
    var settled = true
}

/// Estimates tempo from an onset strength envelope using autocorrelation
/// scored with a harmonic comb and a log-Gaussian tempo prior.
final class TempoEstimator {
    static let bpmRange = 60.0...200.0
    private static let windowSeconds = 8.0
    private static let minimumSeconds = 3.0
    /// Older onsets are faded out with this time constant so a new track takes over sooner.
    private static let recencySeconds = 6.0
    private static let updateSeconds = 0.5
    private static let priorCenterBPM = 130.0
    private static let priorOctaves = 1.0
    private static let bpmStep = 0.1
    private static let combWeights: [Double] = [1, 1, 1, 1]
    private static let historySize = 7
    static let confidenceThreshold = 0.15
    /// A raw reading this far (relative) from the smoothed tempo counts as disagreeing.
    private static let changeTolerance = 0.04
    /// Disagreeing readings must agree with each other this closely…
    private static let changeAgreement = 0.02
    /// …this many times in a row before we call it a new track.
    private static let changeConfirmations = 3
    /// Envelope kept after a detected change; older audio belongs to the previous track.
    private static let keepAfterChangeSeconds = 3.0
    /// Readings needed before an estimate counts as settled.
    private static let settledReadings = 3
    /// Envelope span searched for the beat phase.
    private static let phaseSeconds = 4.0

    let frameRate: Double

    private let windowFrames: Int
    private let minimumFrames: Int
    private let updateFrames: Int
    private let maxLag: Int
    private var envelope: [Float]
    private var envelopeHead = 0
    private var envelopeCount = 0
    private var framesSinceUpdate = 0
    private var history: [Double] = []
    private var pending: [Double] = []

    /// Number of track changes inferred from the tempo jumping to a new, stable value.
    private(set) var detectedChanges = 0

    /// Onset peaks from the most recent analysis, oldest first; reused for beat phase.
    private var lastPeaks: [Float] = []
    /// Envelope frames appended since creation.
    private var framesAppended = 0
    /// Absolute index (in appended frames, possibly fractional) of the most recent beat, if known.
    private(set) var lastBeatFrame: Double?

    /// Most recent smoothed estimate, or nil when there's nothing reliable.
    private(set) var current: TempoEstimate?

    init(frameRate: Double) {
        self.frameRate = frameRate
        windowFrames = Int(Self.windowSeconds * frameRate)
        minimumFrames = Int(Self.minimumSeconds * frameRate)
        updateFrames = max(1, Int(Self.updateSeconds * frameRate))
        let slowestLag = 60 * frameRate / Self.bpmRange.lowerBound
        maxLag = min(Int((slowestLag * Double(Self.combWeights.count)).rounded(.up)) + 2, windowFrames - 1)
        envelope = [Float](repeating: 0, count: windowFrames)
    }

    /// Forgets the tempo history and all but the last `keepingSeconds` of the envelope.
    func reset(keepingSeconds: Double = 0) {
        envelopeCount = min(envelopeCount, Int(keepingSeconds * frameRate))
        framesSinceUpdate = 0
        history.removeAll()
        pending.removeAll()
        current = nil
        lastBeatFrame = nil
    }

    /// Appends one onset strength value. Returns true when a new estimate was computed.
    @discardableResult
    func append(_ value: Float) -> Bool {
        envelope[envelopeHead] = value
        framesAppended += 1
        envelopeHead = (envelopeHead + 1) % windowFrames
        envelopeCount = min(envelopeCount + 1, windowFrames)
        framesSinceUpdate += 1
        guard envelopeCount >= minimumFrames, framesSinceUpdate >= updateFrames else { return false }
        framesSinceUpdate = 0
        update()
        return true
    }

    private func update() {
        guard let raw = estimateRaw() else {
            history.removeAll()
            current = nil
            return
        }
        guard raw.confidence >= Self.confidenceThreshold else {
            // Keep showing the last good value briefly, but decay it out.
            if !history.isEmpty { history.removeFirst() }
            pending.removeAll()
            current = history.isEmpty ? nil : TempoEstimate(bpm: median(history), confidence: raw.confidence)
            return
        }

        if !history.isEmpty, abs(raw.bpm - median(history)) / median(history) > Self.changeTolerance {
            // Disagrees with what we're showing: either a glitch or a new track.
            if let first = pending.first, abs(raw.bpm - first) / first > Self.changeAgreement {
                pending.removeAll()
            }
            pending.append(raw.bpm)
            guard pending.count >= Self.changeConfirmations else { return }
            let confirmed = pending
            reset(keepingSeconds: Self.keepAfterChangeSeconds)
            history = confirmed
            detectedChanges += 1
            publish(confidence: raw.confidence)
            return
        }

        pending.removeAll()
        history.append(raw.bpm)
        if history.count > Self.historySize { history.removeFirst() }
        publish(confidence: raw.confidence)
    }

    private func publish(confidence: Double) {
        let bpm = median(history)
        current = TempoEstimate(bpm: bpm, confidence: confidence, settled: history.count >= Self.settledReadings)
        // lastPeaks ends at the newest frame, i.e. framesAppended - 1.
        lastBeatFrame = phase(bpm: bpm).map { Double(framesAppended - 1) - $0 }
    }

    /// Finds where beats fall by sliding a pulse train at the beat period over
    /// the recent onset peaks; returns frames from the newest frame back to the last beat.
    private func phase(bpm: Double) -> Double? {
        let period = 60 * frameRate / bpm
        let n = lastPeaks.count
        let span = Double(min(n, Int(Self.phaseSeconds * frameRate)))
        guard span > 2 * period else { return nil }

        func peak(at position: Double) -> Float {
            let i = Int(position)
            let frac = Float(position - Double(i))
            return i + 1 < n ? lastPeaks[i] * (1 - frac) + lastPeaks[i + 1] * frac : lastPeaks[i]
        }

        var bestOffset = 0.0
        var bestScore: Float = -1
        let newest = Double(n - 1)
        let oldest = Double(n) - span
        var offset = 0.0
        while offset < period {
            var score: Float = 0
            var count = 0
            var position = newest - offset
            while position >= oldest {
                score += peak(at: position)
                count += 1
                position -= period
            }
            score /= Float(max(count, 1))
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
            offset += 0.25
        }
        return bestOffset
    }

    /// Unsmoothed estimate for the current envelope window.
    func estimateRaw() -> TempoEstimate? {
        let n = envelopeCount
        // While warming up, only use lags with enough overlap to be meaningful.
        let lagLimit = min(maxLag, Int(Double(n) * 0.75))
        let fastestPeriod = 60 * frameRate / Self.bpmRange.upperBound
        guard Double(lagLimit) > 2 * fastestPeriod + 1 else { return nil }

        // Unroll the circular buffer into chronological order.
        var env = [Float](repeating: 0, count: n)
        let start = (envelopeHead - n + windowFrames) % windowFrames
        for i in 0..<n { env[i] = envelope[(start + i) % windowFrames] }

        // Adaptive threshold: subtract a ~0.25 s moving average and keep only
        // the peaks above it, so the ACF sees sharp onsets rather than loudness swells.
        let radius = max(1, Int(0.125 * frameRate))
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + env[i] }
        var peaks = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius), hi = min(n, i + radius + 1)
            let local = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            peaks[i] = max(0, env[i] - local)
        }
        env = peaks
        lastPeaks = peaks
        let mean = vDSP.mean(env)
        vDSP.add(-mean, env, result: &env)
        let decay = -1 / (Self.recencySeconds * frameRate)
        for i in 0..<n { env[i] *= Float(exp(Double(n - 1 - i) * decay)) }
        let energy = vDSP.sumOfSquares(env)
        guard energy > 1e-9 else { return nil }

        // Unbiased, normalised autocorrelation for lags 0…lagLimit.
        var acf = [Double](repeating: 0, count: lagLimit + 1)
        env.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for lag in 0...lagLimit {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(n - lag))
                acf[lag] = Double(dot) / Double(n - lag)
            }
        }
        let zero = acf[0]
        for i in acf.indices { acf[i] /= zero }

        func acfAt(_ lag: Double) -> Double {
            guard lag >= 0, lag < Double(lagLimit) else { return 0 }
            let i = Int(lag)
            let frac = lag - Double(i)
            return acf[i] * (1 - frac) + acf[i + 1] * frac
        }

        /// Mean autocorrelation at the first few multiples of the beat period
        /// (only those within `lagLimit`; at least two are required).
        func comb(bpm: Double) -> Double {
            let period = 60 * frameRate / bpm
            var s = 0.0, total = 0.0, terms = 0
            for (k, w) in Self.combWeights.enumerated() {
                let lag = period * Double(k + 1)
                guard lag < Double(lagLimit) else { break }
                s += w * acfAt(lag)
                total += w
                terms += 1
            }
            return terms >= 2 ? s / total : 0
        }

        func prior(bpm: Double) -> Double {
            let octaves = log2(bpm / Self.priorCenterBPM) / Self.priorOctaves
            return exp(-0.5 * octaves * octaves)
        }

        let lower = Self.bpmRange.lowerBound
        let count = Int((Self.bpmRange.upperBound - lower) / Self.bpmStep) + 1
        var scores = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let bpm = lower + Double(i) * Self.bpmStep
            scores[i] = comb(bpm: bpm) * prior(bpm: bpm)
        }

        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }

        // Parabolic refinement around the peak.
        var bpm = lower + Double(best) * Self.bpmStep
        if best > 0, best < count - 1 {
            let a = scores[best - 1], b = scores[best], c = scores[best + 1]
            let denom = a - 2 * b + c
            if denom != 0 { bpm += 0.5 * (a - c) / denom * Self.bpmStep }
        }

        // Confidence is the raw periodicity at the chosen tempo: ~0 for noise.
        let confidence = max(0, min(1, comb(bpm: bpm)))
        return TempoEstimate(bpm: bpm, confidence: confidence)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
