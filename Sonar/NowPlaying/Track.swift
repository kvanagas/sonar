import Foundation

/// A song identified either by a player's own metadata or by Shazam.
struct Track: Equatable {
    enum Source: String, Codable {
        case spotify, music, shazam

        /// The player app reporting it; nil for tracks identified from the audio.
        var bundleID: String? {
            switch self {
            case .spotify: "com.spotify.client"
            case .music: "com.apple.Music"
            case .shazam: nil
            }
        }

        var displayName: String {
            switch self {
            case .spotify: "Spotify"
            case .music: "Music"
            case .shazam: "Shazam"
            }
        }
    }

    var id: String
    var title: String
    var artist: String?
    var album: String?
    var source: Source
    var appleMusicURL: URL?
    var shazamURL: URL?
    var artworkURL: URL?

    /// "Title — Artist", or just the title.
    var displayName: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(title) — \(artist)"
    }

    /// Web link for Spotify tracks (`spotify:track:ID` → open.spotify.com).
    var spotifyURL: URL? {
        guard source == .spotify else { return nil }
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" else { return nil }
        return URL(string: "https://open.spotify.com/track/\(parts[2])")
    }

    /// True if this track came from a player other than `bundleID`.
    func isFromOtherPlayer(than bundleID: String) -> Bool {
        source.bundleID.map { $0 != bundleID } ?? false
    }
}
