import AppKit
import os

/// Follows what Spotify and Apple Music are playing via the distributed
/// notifications they post on every track or play-state change. No permission
/// is needed for these; only the optional initial query uses Apple Events.
final class NowPlayingMonitor {
    static let spotifyNotification = "com.spotify.client.PlaybackStateChanged"
    static let musicNotification = "com.apple.Music.playerInfo"

    /// Called on the main thread with the new track (nil when playback stopped).
    /// `isNewTrack` is false for play/pause of the same track.
    var onChange: ((_ track: Track?, _ isNewTrack: Bool) -> Void)?
    private(set) var track: Track?
    /// Survives pauses, so resuming the same song isn't a new track.
    private var lastTrackID: String?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.karolisvanagas.sonar", category: "nowplaying")

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for name in [Self.spotifyNotification, Self.musicNotification] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                self?.handle(name: name, userInfo: note.userInfo ?? [:])
            })
        }
    }

    func stop() {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers.removeAll()
    }

    private func handle(name: String, userInfo: [AnyHashable: Any]) {
        if let change = ingest(name: name, userInfo: userInfo) {
            onChange?(track, change)
        }
    }

    /// Updates `track` from a notification payload. Returns nil if nothing visible
    /// changed, otherwise whether it's a different track. Internal for tests.
    @discardableResult
    func ingest(name: String, userInfo: [AnyHashable: Any]) -> Bool? {
        let parsed = Self.parse(name: name, userInfo: userInfo)
        switch (parsed, track) {
        case (nil, nil):
            return nil
        case (nil, let current?):
            // Only the player that's showing can clear it (e.g. Music stopping
            // shouldn't hide a Spotify track).
            guard Self.source(of: name) == current.source else { return nil }
            track = nil
            return false
        case (let new?, let current):
            guard new != current else { return nil }
            return setTrack(new)
        }
    }

    private func setTrack(_ new: Track) -> Bool {
        let isNew = new.id != lastTrackID
        track = new
        lastTrackID = new.id
        return isNew
    }

    /// Asks the players directly what's playing. Used once when listening starts,
    /// since notifications only arrive on the next change. May show an
    /// Automation permission prompt the first time; never launches a player.
    func refresh() {
        for source in [Track.Source.spotify, .music] {
            guard let bundleID = source.bundleID,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { continue }
            if let found = query(source) {
                if found != track { onChange?(found, setTrack(found)) }
                return
            }
        }
    }

    private func query(_ source: Track.Source) -> Track? {
        guard let bundleID = source.bundleID else { return nil }
        let script = """
        tell application id "\(bundleID)"
            if player state is playing then
                set t to current track
                return {name of t, artist of t, album of t, (\(source == .spotify ? "id" : "persistent ID") of t) as text}
            end if
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), result.numberOfItems == 4 else {
            if let error { log.info("Now playing query for \(bundleID) failed: \(error)") }
            return nil
        }
        let field = { (i: Int) in result.atIndex(i)?.stringValue }
        guard let title = field(1), let id = field(4) else { return nil }
        return Track(id: id, title: title, artist: field(2), album: field(3), source: source)
    }

    static func source(of notification: String) -> Track.Source? {
        switch notification {
        case spotifyNotification: .spotify
        case musicNotification: .music
        default: nil
        }
    }

    /// The playing track described by a notification, or nil if paused/stopped/unknown.
    static func parse(name: String, userInfo: [AnyHashable: Any]) -> Track? {
        guard let source = source(of: name),
              userInfo["Player State"] as? String == "Playing",
              let title = userInfo["Name"] as? String, !title.isEmpty
        else { return nil }
        let artist = userInfo["Artist"] as? String
        let album = userInfo["Album"] as? String

        let idValue: Any? = switch source {
        case .spotify: userInfo["Track ID"]
        case .music: userInfo["PersistentID"] ?? userInfo["Persistent ID"]
        case .shazam: nil
        }
        let id = idValue.map { "\($0)" } ?? "\(title)|\(artist ?? "")|\(album ?? "")"
        return Track(id: id, title: title, artist: artist, album: album, source: source)
    }
}
