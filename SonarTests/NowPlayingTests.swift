import XCTest

final class NowPlayingTests: XCTestCase {
    private func spotify(_ id: String, _ name: String, state: String = "Playing") -> [AnyHashable: Any] {
        ["Track ID": id, "Name": name, "Artist": "Artist", "Album": "Album", "Player State": state]
    }

    func testParsesSpotify() {
        let track = NowPlayingMonitor.parse(name: NowPlayingMonitor.spotifyNotification, userInfo: spotify("spotify:track:1", "Song"))
        XCTAssertEqual(track, Track(id: "spotify:track:1", title: "Song", artist: "Artist", album: "Album", source: .spotify))
        XCTAssertEqual(track?.displayName, "Song — Artist")
    }

    func testParsesMusicWithNumericID() {
        let info: [AnyHashable: Any] = ["Name": "Tune", "Artist": "Band", "Player State": "Playing", "PersistentID": NSNumber(value: 42)]
        let track = NowPlayingMonitor.parse(name: NowPlayingMonitor.musicNotification, userInfo: info)
        XCTAssertEqual(track?.id, "42")
        XCTAssertEqual(track?.source, .music)
    }

    func testPausedIsNotPlaying() {
        XCTAssertNil(NowPlayingMonitor.parse(name: NowPlayingMonitor.spotifyNotification, userInfo: spotify("1", "Song", state: "Paused")))
    }

    func testOnlyNewIDsCountAsTrackChanges() {
        let monitor = NowPlayingMonitor()
        let name = NowPlayingMonitor.spotifyNotification
        XCTAssertEqual(monitor.ingest(name: name, userInfo: spotify("1", "One")), true)
        XCTAssertNil(monitor.ingest(name: name, userInfo: spotify("1", "One")), "duplicate notification")
        XCTAssertEqual(monitor.ingest(name: name, userInfo: spotify("1", "One", state: "Paused")), false, "pause clears, same track")
        XCTAssertNil(monitor.track)
        XCTAssertEqual(monitor.ingest(name: name, userInfo: spotify("1", "One")), false, "resuming the same song")
        XCTAssertEqual(monitor.ingest(name: name, userInfo: spotify("2", "Two")), true)
        XCTAssertEqual(monitor.track?.title, "Two")
    }

    func testOtherPlayerStoppingDoesNotClear() {
        let monitor = NowPlayingMonitor()
        monitor.ingest(name: NowPlayingMonitor.spotifyNotification, userInfo: spotify("1", "One"))
        XCTAssertNil(monitor.ingest(name: NowPlayingMonitor.musicNotification, userInfo: ["Player State": "Stopped"]))
        XCTAssertEqual(monitor.track?.title, "One")
    }

    func testSpotifyWebURL() {
        let track = Track(id: "spotify:track:4uLU6hMCjMI75M1A2tKUQC", title: "T", source: .spotify)
        XCTAssertEqual(track.spotifyURL?.absoluteString, "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertNil(Track(id: "spotify:ad:1", title: "Ad", source: .spotify).spotifyURL)
        XCTAssertNil(Track(id: "42", title: "T", source: .music).spotifyURL)
    }

    func testOtherPlayerCheck() {
        let spotify = Track(id: "1", title: "T", source: .spotify)
        XCTAssertTrue(spotify.isFromOtherPlayer(than: "com.google.Chrome"))
        XCTAssertFalse(spotify.isFromOtherPlayer(than: "com.spotify.client"))
        XCTAssertFalse(Track(id: "s", title: "T", source: .shazam).isFromOtherPlayer(than: "com.google.Chrome"))
    }
}
