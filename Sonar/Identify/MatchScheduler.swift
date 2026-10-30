import Foundation

/// Decides when to stream audio to Shazam. Pure logic on the analyser's stream
/// clock (seconds of audio), so it's testable without ShazamKit or a network.
///
/// An attempt starts right after a detected track change, and periodically
/// regardless — DJ transitions keep the tempo and have no gaps, so change
/// detection alone would miss them. Nothing is sent between attempts.
struct MatchScheduler {
    static let interval = 45.0
    static let attemptLength = 12.0
    /// Let a new track play a moment before matching so the old one has faded out.
    static let changeDelay = 2.0

    enum Phase: Equatable {
        case idle(since: Double)
        case pending(startAt: Double)
        case matching(since: Double)
    }

    private(set) var phase: Phase = .pending(startAt: changeDelay)
    private var lastTrackChanges = 0

    /// True while audio should be streamed to the matcher.
    var isMatching: Bool {
        if case .matching = phase { return true }
        return false
    }

    /// Advances the schedule. Returns true when a new attempt starts, so the
    /// caller can open a fresh session. `suppressed` (e.g. the player already
    /// told us the song) cancels and holds off attempts.
    mutating func tick(time: Double, trackChanges: Int, suppressed: Bool) -> Bool {
        if trackChanges != lastTrackChanges {
            lastTrackChanges = trackChanges
            phase = .pending(startAt: time + Self.changeDelay)
        }
        if suppressed {
            if isMatching { phase = .idle(since: time) }
            if case .pending = phase { phase = .idle(since: time) }
            return false
        }
        switch phase {
        case .idle(let since) where time - since >= Self.interval,
             .pending(let since) where time >= since:
            phase = .matching(since: time)
            return true
        case .matching(let since) where time - since >= Self.attemptLength:
            phase = .idle(since: time)
        default:
            break
        }
        return false
    }

    /// Schedules an extra attempt `delay` seconds after `time` (e.g. to confirm a
    /// surprising match) unless one is already running.
    mutating func request(at time: Double, delay: Double) {
        guard !isMatching else { return }
        phase = .pending(startAt: time + delay)
    }

    /// Ends the current attempt (a match or a definitive miss arrived).
    mutating func finish(time: Double) {
        if isMatching { phase = .idle(since: time) }
    }
}
