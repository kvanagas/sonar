import Foundation
import Observation
import os

/// One song heard while listening.
struct HistoryEntry: Codable, Identifiable, Equatable {
    struct App: Codable, Equatable {
        var bundleID: String
        var name: String
    }

    var id = UUID()
    var firstHeard: Date
    var lastHeard: Date
    var title: String
    var artist: String?
    var album: String?
    /// Player track ID or Shazam ID; used to recognise the same song again.
    var trackKey: String
    var identifiedBy: Track.Source
    /// Typical tempo (median of samples), and the 10th–90th percentile range,
    /// so a few glitchy readings don't stretch it.
    var bpm: Double?
    var bpmMin: Double?
    var bpmMax: Double?
    /// Settled readings, one every few seconds; the source of the values above.
    var bpmSamples: [Double]?
    /// Other catalog versions this entry was also identified as.
    var alsoMatchedAs: [String]?
    /// The app(s) the audio came from.
    var sourceApps: [App] = []
    /// The page playing it, when the source was a browser.
    var pageURL: URL?
    var pageTitle: String?
    var spotifyURL: URL?
    var appleMusicURL: URL?
    var shazamURL: URL?
    var artworkURL: URL?

    var displayName: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(title) — \(artist)"
    }

    var sourceName: String {
        sourceApps.isEmpty ? "Unknown" : sourceApps.map(\.name).joined(separator: ", ")
    }

    /// Best link to open: the song itself first, then the page it played on.
    var bestURL: URL? {
        spotifyURL ?? appleMusicURL ?? shazamURL ?? pageURL
    }

    /// "124", or "120–126" when the tempo moved during the track.
    var bpmText: String {
        guard let bpm else { return "—" }
        if let lo = bpmMin, let hi = bpmMax, hi - lo >= 2 {
            return "\(Int(lo.rounded()))–\(Int(hi.rounded()))"
        }
        return "\(Int(bpm.rounded()))"
    }

    enum SearchSite: String, CaseIterable {
        case soundCloud = "SoundCloud"
        case bandcamp = "Bandcamp"
        case discogs = "Discogs"
    }

    /// A search for this song ("Artist Title") on another site.
    func searchURL(on site: SearchSite) -> URL? {
        let query = [artist, title].compactMap { $0 }.joined(separator: " ")
        var components: URLComponents
        switch site {
        case .soundCloud:
            components = URLComponents(string: "https://soundcloud.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .bandcamp:
            components = URLComponents(string: "https://bandcamp.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .discogs:
            components = URLComponents(string: "https://www.discogs.com/search/")!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "all")]
        }
        return components.url
    }

    /// "Title — Artist (128 BPM)".
    var shareText: String {
        displayName + (bpm.map { " (\(Int($0.rounded())) BPM)" } ?? "")
    }
}

/// Every track heard, newest first, saved as JSON in Application Support.
@Observable
final class TrackStore {
    /// Hearing the same song again within this window continues its entry.
    static let resumeWindow: TimeInterval = 10 * 60
    private static let saveDelay: TimeInterval = 5
    private static let sampleInterval: TimeInterval = 3
    private static let maxSamples = 120

    private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var lastSample: [UUID: Date] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.karolisvanagas.sonar", category: "history")

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sonar", isDirectory: true).appendingPathComponent("history.json")
    }

    init(fileURL: URL = TrackStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    /// Starts (or continues) an entry for `track`. Returns its id.
    @discardableResult
    func trackStarted(
        _ track: Track,
        sourceApps: [HistoryEntry.App],
        page: (url: URL, title: String?)?,
        at date: Date = Date()
    ) -> UUID {
        // The same recording, or another version of the song that's playing now.
        let index = entries.firstIndex { $0.trackKey == track.id }
            ?? entries.indices.first.flatMap { i in
                SongMatching.sameSong(title: entries[i].title, artist: entries[i].artist, as: track.title, artist: track.artist) ? i : nil
            }
        if let index, date.timeIntervalSince(entries[index].lastHeard) < Self.resumeWindow {
            var entry = entries.remove(at: index)
            entry.lastHeard = date
            merge(track, sourceApps: sourceApps, page: page, into: &entry)
            entries.insert(entry, at: 0)
            scheduleSave()
            return entry.id
        }
        var entry = HistoryEntry(
            firstHeard: date, lastHeard: date,
            title: track.title, trackKey: track.id, identifiedBy: track.source
        )
        merge(track, sourceApps: sourceApps, page: page, into: &entry)
        entries.insert(entry, at: 0)
        scheduleSave()
        return entry.id
    }

    /// Fills in details without overwriting ones we already have (a later
    /// Shazam match can add artwork to a Spotify entry, for instance).
    private func merge(_ track: Track, sourceApps: [HistoryEntry.App], page: (url: URL, title: String?)?, into entry: inout HistoryEntry) {
        entry.artist = entry.artist ?? track.artist
        entry.album = entry.album ?? track.album
        entry.spotifyURL = entry.spotifyURL ?? track.spotifyURL
        entry.appleMusicURL = entry.appleMusicURL ?? track.appleMusicURL
        entry.shazamURL = entry.shazamURL ?? track.shazamURL
        entry.artworkURL = entry.artworkURL ?? track.artworkURL
        for app in sourceApps where !entry.sourceApps.contains(app) { entry.sourceApps.append(app) }
        if track.displayName != entry.displayName, !(entry.alsoMatchedAs ?? []).contains(track.displayName) {
            entry.alsoMatchedAs = (entry.alsoMatchedAs ?? []) + [track.displayName]
        }
        if let page, entry.pageURL == nil {
            entry.pageURL = page.url
            entry.pageTitle = page.title
        }
    }

    /// Records a settled tempo reading for an entry.
    /// Called on every settled reading. Keeps a sample every few seconds and
    /// only touches disk when the displayed values change; samples and
    /// lastHeard alone are saved with the next write or on quit.
    func record(bpm: Double, for id: UUID, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastHeard = date
        if let last = lastSample[id], date.timeIntervalSince(last) < Self.sampleInterval { return }
        lastSample[id] = date

        var entry = entries[index]
        var samples = entry.bpmSamples ?? []
        samples.append(bpm)
        if samples.count > Self.maxSamples {
            // Halve the resolution rather than forgetting the start of the track.
            samples = samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        }
        entry.bpmSamples = samples
        let before = (entry.bpm, entry.bpmMin, entry.bpmMax)
        Self.summarize(&entry)
        entries[index] = entry
        if before != (entry.bpm, entry.bpmMin, entry.bpmMax) { scheduleSave() }
    }

    /// Recomputes bpm / bpmMin / bpmMax from the samples.
    static func summarize(_ entry: inout HistoryEntry) {
        guard let samples = entry.bpmSamples, !samples.isEmpty else { return }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            let rounded = sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
            return (rounded * 10).rounded() / 10
        }
        entry.bpm = percentile(0.5)
        entry.bpmMin = percentile(0.1)
        entry.bpmMax = percentile(0.9)
    }

    /// Combines entries into the earliest one: other titles become "also matched
    /// as", and links, sources and tempo samples are pooled.
    func merge(_ ids: Set<UUID>) {
        let group = entries.filter { ids.contains($0.id) }.sorted { $0.firstHeard < $1.firstHeard }
        guard var keep = group.first, group.count > 1 else { return }
        for other in group.dropFirst() {
            keep.firstHeard = min(keep.firstHeard, other.firstHeard)
            keep.lastHeard = max(keep.lastHeard, other.lastHeard)
            keep.artist = keep.artist ?? other.artist
            keep.album = keep.album ?? other.album
            keep.spotifyURL = keep.spotifyURL ?? other.spotifyURL
            keep.appleMusicURL = keep.appleMusicURL ?? other.appleMusicURL
            keep.shazamURL = keep.shazamURL ?? other.shazamURL
            keep.artworkURL = keep.artworkURL ?? other.artworkURL
            if keep.pageURL == nil {
                keep.pageURL = other.pageURL
                keep.pageTitle = other.pageTitle
            }
            for app in other.sourceApps where !keep.sourceApps.contains(app) { keep.sourceApps.append(app) }
            var names = keep.alsoMatchedAs ?? []
            for name in [other.displayName] + (other.alsoMatchedAs ?? []) where name != keep.displayName && !names.contains(name) {
                names.append(name)
            }
            keep.alsoMatchedAs = names.isEmpty ? nil : names
            if let samples = other.bpmSamples {
                keep.bpmSamples = (keep.bpmSamples ?? []) + samples
            } else if keep.bpmSamples == nil, keep.bpm == nil {
                keep.bpm = other.bpm
                keep.bpmMin = other.bpmMin
                keep.bpmMax = other.bpmMax
            }
        }
        Self.summarize(&keep)
        let keepID = keep.id
        entries.removeAll { ids.contains($0.id) && $0.id != keepID }
        if let index = entries.firstIndex(where: { $0.id == keepID }) { entries[index] = keep }
        scheduleSave()
    }

    func delete(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    // MARK: - CSV

    func csv(for selected: [HistoryEntry]? = nil) -> String {
        let iso = ISO8601DateFormatter()
        let header = ["Date", "Title", "Artist", "Album", "BPM", "BPM Min", "BPM Max", "Source", "Identified By", "Page", "Spotify", "Apple Music", "Shazam"]
        let rows = (selected ?? entries).map { e -> [String] in
            let bpm = { (v: Double?) in v.map { String(format: "%.1f", $0) } ?? "" }
            return [
                iso.string(from: e.firstHeard), e.title, e.artist ?? "", e.album ?? "",
                bpm(e.bpm), bpm(e.bpmMin), bpm(e.bpmMax), e.sourceName, e.identifiedBy.displayName,
                e.pageURL?.absoluteString ?? "", e.spotifyURL?.absoluteString ?? "",
                e.appleMusicURL?.absoluteString ?? "", e.shazamURL?.absoluteString ?? "",
            ]
        }
        return ([header] + rows).map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func csvField(_ value: String) -> String {
        // Titles can come from any web page; a leading = + - @ would run as a
        // formula when the export is opened in a spreadsheet.
        var value = value
        if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            // Keep the unreadable file aside rather than overwriting it.
            log.error("Couldn't read history: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("corrupt"))
        }
    }

    /// Coalesces writes: at most one every `saveDelay` seconds.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Writes immediately; also called on quit.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
