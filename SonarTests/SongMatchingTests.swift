import XCTest

final class SongMatchingTests: XCTestCase {
    private func shazam(_ id: String, _ title: String, _ artist: String) -> Track {
        Track(id: id, title: title, artist: artist, source: .shazam)
    }

    func testVersionsAreTheSameSong() {
        let pairs: [(String, String)] = [
            ("Da Fonk (feat. Joni)", "Da Fonk (feat. Joni) [Bronka Remix]"),
            ("Da Fonk", "Da Fonk - Extended Mix"),
            ("Da Fonk feat. Joni", "Da Fonk (Edit)"),
            ("Back Again", "Back Again - Radio Edit"),
        ]
        for (a, b) in pairs {
            XCTAssertTrue(SongMatching.sameSong(title: a, artist: "Mochakk", as: b, artist: "Mochakk"), "\(a) vs \(b)")
        }
    }

    func testDifferentSongsStayApart() {
        XCTAssertFalse(SongMatching.sameSong(title: "Da Fonk", artist: "Mochakk", as: "Ymmfltf", artist: "qjuju"))
        XCTAssertFalse(SongMatching.sameSong(title: "Da Fonk", artist: "Mochakk", as: "Da Fonk", artist: "Someone Else"))
        // A dash that's part of the title, not a version note.
        XCTAssertFalse(SongMatching.sameSong(title: "Love - Hate", artist: "A", as: "Love", artist: "A"))
    }

    func testArtistCollaborationsOverlap() {
        XCTAssertEqual(SongMatching.artists("Mochakk & Joni"), ["mochakk", "joni"])
        XCTAssertEqual(SongMatching.artists("A x B, C feat. D"), ["a", "b", "c", "d"])
        XCTAssertTrue(SongMatching.sameSong(title: "Da Fonk", artist: "Mochakk & Joni", as: "Da Fonk [Remix]", artist: "Mochakk"))
    }

    // MARK: - Confirmer

    func testFirstMatchCommits() {
        var confirmer = MatchConfirmer()
        let one = shazam("1", "Back Again", "Loquace")
        XCTAssertEqual(confirmer.matched(one), .commit(one))
    }

    func testStrayMatchIsDroppedWhenTheSongContinues() {
        // The screenshot case: Mochakk, then a one-off qjuju match, then Mochakk again.
        var confirmer = MatchConfirmer()
        let fonk = shazam("1", "Da Fonk (feat. Joni)", "Mochakk")
        let stray = shazam("2", "Ymmfltf", "qjuju")
        let remix = shazam("3", "Da Fonk (feat. Joni) [Bronka Remix]", "Mochakk")
        XCTAssertEqual(confirmer.matched(fonk), .commit(fonk))
        XCTAssertEqual(confirmer.matched(stray), .tentative(stray))
        XCTAssertEqual(confirmer.matched(remix), .same(remix))
        XCTAssertNil(confirmer.tentative)
        XCTAssertEqual(confirmer.current, fonk)
    }

    func testRealTransitionCommitsOnSecondAgreeingMatch() {
        var confirmer = MatchConfirmer()
        let a = shazam("1", "A", "X")
        let b = shazam("2", "B", "Y")
        XCTAssertEqual(confirmer.matched(a), .commit(a))
        XCTAssertEqual(confirmer.matched(b), .tentative(b))
        XCTAssertEqual(confirmer.matched(b), .commit(b))
        XCTAssertEqual(confirmer.current, b)
    }

    func testTwoDifferentStraysDontCommit() {
        var confirmer = MatchConfirmer()
        let a = shazam("1", "A", "X")
        _ = confirmer.matched(a)
        let b = shazam("2", "B", "Y"), c = shazam("3", "C", "Z")
        XCTAssertEqual(confirmer.matched(b), .tentative(b))
        XCTAssertEqual(confirmer.matched(c), .tentative(c))
        XCTAssertEqual(confirmer.current, a)
    }

    func testStrongChangeCommitsNextMatch() {
        var confirmer = MatchConfirmer()
        let a = shazam("1", "A", "X")
        let b = shazam("2", "B", "Y")
        _ = confirmer.matched(a)
        confirmer.strongChange()
        XCTAssertEqual(confirmer.matched(b), .commit(b))
        let c = shazam("3", "C", "Z")
        XCTAssertEqual(confirmer.matched(c), .tentative(c), "only the first match after the change gets the shortcut")
    }
}
