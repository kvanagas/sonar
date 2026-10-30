import XCTest

final class TrackStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonarTests-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private let chrome = HistoryEntry.App(bundleID: "com.google.Chrome", name: "Google Chrome")
    private func shazam(_ id: String, _ title: String) -> Track {
        Track(id: id, title: title, artist: "DJ", source: .shazam,
              appleMusicURL: URL(string: "https://music.apple.com/x/\(id)"),
              shazamURL: URL(string: "https://www.shazam.com/track/\(id)"))
    }

    func testSurvivesReload() throws {
        let store = TrackStore(fileURL: fileURL)
        let page = (url: URL(string: "https://www.youtube.com/watch?v=abc")!, title: Optional("Boiler Room set"))
        let id = store.trackStarted(shazam("1", "One"), sourceApps: [chrome], page: page)
        store.record(bpm: 124.04, for: id)
        store.saveNow()

        let reloaded = TrackStore(fileURL: fileURL)
        let entry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertEqual(entry.title, "One")
        XCTAssertEqual(entry.bpm, 124.0)
        XCTAssertEqual(entry.identifiedBy, .shazam)
        XCTAssertEqual(entry.sourceApps, [chrome])
        XCTAssertEqual(entry.pageURL, page.url)
        XCTAssertEqual(entry.pageTitle, "Boiler Room set")
        XCTAssertEqual(entry.bestURL?.host(), "music.apple.com")
    }

    func testSameSongSoonContinuesItsEntry() {
        let store = TrackStore(fileURL: fileURL)
        let start = Date()
        let a = store.trackStarted(shazam("1", "One"), sourceApps: [chrome], page: nil, at: start)
        store.trackStarted(shazam("2", "Two"), sourceApps: [chrome], page: nil, at: start + 60)
        let again = store.trackStarted(shazam("1", "One"), sourceApps: [chrome], page: nil, at: start + 120)
        XCTAssertEqual(a, again)
        XCTAssertEqual(store.entries.map(\.title), ["One", "Two"])

        let later = store.trackStarted(shazam("1", "One"), sourceApps: [chrome], page: nil, at: start + 120 + TrackStore.resumeWindow + 1)
        XCTAssertNotEqual(a, later)
        XCTAssertEqual(store.entries.count, 3)
    }

    func testBPMRangeAndCSV() {
        let store = TrackStore(fileURL: fileURL)
        let id = store.trackStarted(shazam("1", "One, with comma"), sourceApps: [chrome], page: nil)
        let start = Date()
        store.record(bpm: 120, for: id, at: start)
        store.record(bpm: 126, for: id, at: start + 3)
        XCTAssertEqual(store.entries[0].bpmMin, 120)
        XCTAssertEqual(store.entries[0].bpmMax, 126)
        XCTAssertEqual(store.entries[0].bpmText, "120–126")

        let lines = store.csv().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("\"One, with comma\""))
        XCTAssertTrue(lines[1].contains("Google Chrome"))
    }

    func testDeleteAndClear() {
        let store = TrackStore(fileURL: fileURL)
        let a = store.trackStarted(shazam("1", "One"), sourceApps: [], page: nil)
        store.trackStarted(shazam("2", "Two"), sourceApps: [], page: nil)
        store.delete([a])
        XCTAssertEqual(store.entries.map(\.title), ["Two"])
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }
}

extension TrackStoreTests {
    func testVersionOfCurrentSongJoinsItsEntry() {
        let store = TrackStore(fileURL: fileURL)
        let fonk = Track(id: "1", title: "Da Fonk (feat. Joni)", artist: "Mochakk", source: .shazam)
        let remix = Track(id: "2", title: "Da Fonk (feat. Joni) [Bronka Remix]", artist: "Mochakk", source: .shazam)
        let a = store.trackStarted(fonk, sourceApps: [], page: nil)
        let b = store.trackStarted(remix, sourceApps: [], page: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].title, "Da Fonk (feat. Joni)")
        XCTAssertEqual(store.entries[0].alsoMatchedAs, ["Da Fonk (feat. Joni) [Bronka Remix] — Mochakk"])
    }

    func testRangeIgnoresGlitches() {
        let store = TrackStore(fileURL: fileURL)
        let id = store.trackStarted(shazam("1", "One"), sourceApps: [], page: nil)
        let start = Date()
        // A steady 126 with a short burst of bogus 165 readings.
        let readings = Array(repeating: 126.0, count: 40) + Array(repeating: 165.0, count: 3) + Array(repeating: 126.2, count: 20)
        for (i, bpm) in readings.enumerated() {
            store.record(bpm: bpm, for: id, at: start + Double(i) * 3)
        }
        XCTAssertEqual(store.entries[0].bpmText, "126")
        XCTAssertEqual(store.entries[0].bpmMax ?? 0, 126.2, accuracy: 0.01)
    }

    func testSamplesAreThrottledAndCapped() {
        let store = TrackStore(fileURL: fileURL)
        let id = store.trackStarted(shazam("1", "One"), sourceApps: [], page: nil)
        let start = Date()
        for i in 0..<20 { store.record(bpm: 120, for: id, at: start + Double(i) * 0.5) } // 10 s of readings
        XCTAssertEqual(store.entries[0].bpmSamples?.count, 4)
        for i in 0..<1000 { store.record(bpm: 120, for: id, at: start + 20 + Double(i) * 3) }
        XCTAssertLessThanOrEqual(store.entries[0].bpmSamples?.count ?? 0, 120)
    }

    func testMergeKeepsEarliestAndPoolsDetails() {
        let store = TrackStore(fileURL: fileURL)
        let start = Date()
        let a = store.trackStarted(shazam("1", "One"), sourceApps: [chrome], page: nil, at: start)
        store.record(bpm: 120, for: a, at: start)
        let stray = Track(id: "2", title: "Stray", artist: "Other", source: .shazam, artworkURL: URL(string: "https://x/art.jpg"))
        let b = store.trackStarted(stray, sourceApps: [], page: nil, at: start + 60)
        store.record(bpm: 122, for: b, at: start + 60)
        store.merge([a, b])
        XCTAssertEqual(store.entries.count, 1)
        let entry = store.entries[0]
        XCTAssertEqual(entry.id, a)
        XCTAssertEqual(entry.title, "One")
        XCTAssertEqual(entry.alsoMatchedAs, ["Stray — Other"])
        XCTAssertEqual(entry.artworkURL?.absoluteString, "https://x/art.jpg")
        XCTAssertEqual(entry.bpmSamples?.count, 2)
    }

    func testOldFilesWithoutNewFieldsStillLoad() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","firstHeard":"2026-10-25T15:12:00Z","lastHeard":"2026-10-25T15:15:00Z",
          "title":"Back Again","artist":"Loquace","trackKey":"9","identifiedBy":"shazam","bpm":120,"sourceApps":[]}]
        """
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)
        let store = TrackStore(fileURL: fileURL)
        XCTAssertEqual(store.entries.first?.title, "Back Again")
        XCTAssertEqual(store.entries.first?.bpm, 120)
    }
}

extension TrackStoreTests {
    func testSearchLinks() {
        let store = TrackStore(fileURL: fileURL)
        store.trackStarted(Track(id: "1", title: "Da Fonk (feat. Joni)", artist: "Mochakk", source: .shazam), sourceApps: [], page: nil)
        let entry = store.entries[0]
        XCTAssertEqual(entry.searchURL(on: .soundCloud)?.absoluteString, "https://soundcloud.com/search?q=Mochakk%20Da%20Fonk%20(feat.%20Joni)")
        XCTAssertEqual(entry.searchURL(on: .bandcamp)?.host(), "bandcamp.com")
        XCTAssertEqual(entry.searchURL(on: .discogs)?.absoluteString, "https://www.discogs.com/search/?q=Mochakk%20Da%20Fonk%20(feat.%20Joni)&type=all")
    }
}

final class CSVFieldTests: XCTestCase {
    func testFormulasAreDefused() {
        XCTAssertEqual(TrackStore.csvField("=HYPERLINK(\"http://x\")"), "\"'=HYPERLINK(\"\"http://x\"\")\"")
        XCTAssertEqual(TrackStore.csvField("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(TrackStore.csvField("-1+2"), "'-1+2")
    }

    func testPlainValuesUnchanged() {
        XCTAssertEqual(TrackStore.csvField("Windowlicker"), "Windowlicker")
        XCTAssertEqual(TrackStore.csvField("Title, Part 2"), "\"Title, Part 2\"")
    }
}
