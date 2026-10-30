import Foundation

/// A free-running beat grid that is nudged toward each new measurement, so the
/// pulse stays steady when individual phase readings jitter by a frame or two.
struct BeatClock: Equatable {
    /// Phase errors larger than this are treated as a real jump and snapped to.
    private static let snapThreshold = 0.08
    /// Fraction of a small phase error corrected per update.
    private static let correction = 0.3
    /// Relative period change beyond which we re-anchor instead of smoothing.
    private static let periodTolerance = 0.02

    private(set) var period: TimeInterval
    /// Time of a beat on the grid; any time `anchor + k·period` is a beat.
    private(set) var anchor: TimeInterval

    init(period: TimeInterval, lastBeat: TimeInterval) {
        self.period = period
        anchor = lastBeat
    }

    mutating func update(period newPeriod: TimeInterval, lastBeat: TimeInterval) {
        guard abs(newPeriod - period) / period <= Self.periodTolerance else {
            self = BeatClock(period: newPeriod, lastBeat: lastBeat)
            return
        }
        let predicted = anchor + ((lastBeat - anchor) / period).rounded() * period
        let error = lastBeat - predicted
        anchor = abs(error) > Self.snapThreshold ? lastBeat : predicted + error * Self.correction
        period = newPeriod
    }

    /// The first beat strictly after `time`.
    func nextBeat(after time: TimeInterval) -> TimeInterval {
        var beat = anchor + ((time - anchor) / period).rounded(.up) * period
        if beat <= time { beat += period }
        return beat
    }
}
