import Accelerate

/// Mono samples in, smoothed tempo estimates out. Not thread-safe; drive it
/// from a single queue.
final class TempoAnalyzer {
    /// Below this RMS (~ -70 dBFS) a block counts as silent.
    private static let silenceRMS: Float = 3e-4
    private static let levelBlockSeconds = 0.1
    /// This much continuous silence after music is treated as a gap between tracks.
    private static let gapSeconds = 0.8
    /// A marked change this soon after an inferred one is the same transition.
    private static let duplicateChangeSeconds = 3.0

    let sampleRate: Double
    private let onsets: OnsetDetector
    private let tempo: TempoEstimator
    private var levelSum: Double = 0
    private var levelCount = 0
    private let levelBlock: Int
    private let gapBlocks: Int
    private var silentBlocks = 0
    private var heardMusicSinceGap = false
    private var gapChanges = 0
    private var lastInferredChange: Double?
    private(set) var isSilent = true

    /// Increments whenever a new track is inferred (silence gap, tempo jump) or marked.
    var trackChangeCount: Int { gapChanges + tempo.detectedChanges }
    /// Only the changes from silence gaps or `markTrackChange()`: reliable
    /// enough to treat as a new song without further evidence.
    var strongChangeCount: Int { gapChanges }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        onsets = OnsetDetector(sampleRate: sampleRate)
        tempo = TempoEstimator(frameRate: onsets.frameRate)
        levelBlock = Int(Self.levelBlockSeconds * sampleRate)
        gapBlocks = Int((Self.gapSeconds / Self.levelBlockSeconds).rounded())
    }

    /// Seconds of audio processed so far; the analyser's own clock.
    var streamTime: Double { Double(samplesProcessed) / sampleRate }
    private var samplesProcessed = 0

    /// Beat period and the stream time of the most recent beat, when there's a tempo.
    var beat: (period: Double, lastBeat: Double)? {
        guard let estimate, let frame = tempo.lastBeatFrame else { return nil }
        return (60 / estimate.bpm, onsets.time(ofFrame: frame))
    }

    /// The current estimate, or nil while silent or unsure.
    var estimate: TempoEstimate? {
        isSilent ? nil : tempo.current
    }

    func reset() {
        tempo.reset()
        levelSum = 0
        levelCount = 0
        silentBlocks = 0
        heardMusicSinceGap = false
        isSilent = true
    }

    /// Called when something outside the audio (e.g. player metadata) says the track changed.
    /// Ignored if a silence gap was just detected, since that was this same change.
    func markTrackChange() {
        if let last = lastInferredChange, streamTime - last < Self.duplicateChangeSeconds { return }
        tempo.reset()
        gapChanges += 1
        heardMusicSinceGap = false
    }

    /// Returns true if `estimate` may have changed.
    @discardableResult
    func process(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard !samples.isEmpty else { return false }
        samplesProcessed += samples.count
        var updated = false
        levelSum += Double(vDSP.sumOfSquares(samples))
        levelCount += samples.count
        if levelCount >= levelBlock {
            let silent = Float(sqrt(levelSum / Double(levelCount))) < Self.silenceRMS
            levelSum = 0
            levelCount = 0
            if silent {
                silentBlocks += 1
                if silentBlocks == gapBlocks {
                    isSilent = true
                    updated = true
                    if heardMusicSinceGap {
                        tempo.reset()
                        gapChanges += 1
                        heardMusicSinceGap = false
                        lastInferredChange = streamTime
                    }
                }
            } else {
                silentBlocks = 0
                heardMusicSinceGap = true
                if isSilent { isSilent = false; updated = true }
            }
        }

        onsets.process(samples) { value in
            if tempo.append(value) { updated = true }
        }
        return updated
    }
}
