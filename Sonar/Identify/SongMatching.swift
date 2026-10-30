import Foundation

/// Decides whether two catalog entries are versions of the same song
/// ("Da Fonk (feat. Joni)" vs "Da Fonk (feat. Joni) [Bronka Remix]").
enum SongMatching {
    /// Words that mark a trailing " - …" segment as a version note rather than part of the title.
    private static let versionWords = [
        "remix", "mix", "edit", "version", "remaster", "remastered", "rework", "bootleg",
        "dub", "vip", "instrumental", "extended", "radio", "original", "live", "flip",
    ]

    static func sameSong(title: String, artist: String?, as otherTitle: String, artist otherArtist: String?) -> Bool {
        guard baseTitle(title) == baseTitle(otherTitle), !baseTitle(title).isEmpty else { return false }
        let a = artists(artist), b = artists(otherArtist)
        // Unknown artists can't contradict a title match.
        return a.isEmpty || b.isEmpty || !a.isDisjoint(with: b)
    }

    /// Lowercased title without bracketed notes, featured artists or a version suffix.
    static func baseTitle(_ title: String) -> String {
        var t = title.lowercased()
        // Drop (…) and […] segments.
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        // Drop "feat. X" / "ft. X" to the end.
        t = t.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        // Drop " - Something Remix" style suffixes.
        if let dash = t.range(of: " - ", options: .backwards) {
            let suffix = t[dash.upperBound...]
            if versionWords.contains(where: { suffix.contains($0) }) { t = String(t[..<dash.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Individual artist names: "A & B", "A, B", "A x B", "A feat. B" → {a, b}.
    static func artists(_ artist: String?) -> Set<String> {
        guard let artist else { return [] }
        let separated = artist.lowercased().replacingOccurrences(
            of: #"\s*(,|&|\band\b|\bx\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\bvs\.?|/)\s*"#,
            with: "|", options: .regularExpression
        )
        return Set(separated.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

extension Track {
    func isSameSong(as other: Track) -> Bool {
        id == other.id || SongMatching.sameSong(title: title, artist: artist, as: other.title, artist: other.artist)
    }
}

/// Filters Shazam matches before they reach the history. A match that disagrees
/// with the current song is only *tentative* until a second attempt agrees.
/// A strong signal that a new song began (silence gap, player change, starting
/// to listen) clears the current song, so the next match commits directly.
/// Tempo jumps alone don't count: they also happen within a song, and that's
/// exactly when Shazam tends to drift.
struct MatchConfirmer {
    enum Decision: Equatable {
        /// A new song: add it to the history.
        case commit(Track)
        /// Same song as the current one (possibly another version of it).
        case same(Track)
        /// Disagrees with the current song; ask for a confirming attempt.
        case tentative(Track)
    }

    private(set) var current: Track?
    private(set) var tentative: Track?

    mutating func strongChange() {
        current = nil
        tentative = nil
    }

    mutating func matched(_ track: Track) -> Decision {
        if let current, track.isSameSong(as: current) {
            tentative = nil
            return .same(track)
        }
        if current == nil || tentative.map(track.isSameSong) == true {
            current = track
            tentative = nil
            return .commit(track)
        }
        tentative = track
        return .tentative(track)
    }
}
