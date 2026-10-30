import AVFoundation
import ShazamKit
import os

/// Identifies songs by streaming captured audio to Shazam during the attempts
/// `MatchScheduler` opens. Only signatures leave the Mac, never audio.
///
/// Everything except the callbacks runs on the analysis queue passed in.
final class ShazamMatcher: NSObject, SHSessionDelegate {
    private static let supportedRates: Set<Double> = [48_000, 44_100, 32_000, 16_000]

    /// Called on the main thread for every match, including repeats of the same song.
    var onMatch: ((Track) -> Void)?
    /// Called on the main thread with a short status for the menu.
    var onStatus: ((String) -> Void)?
    /// Set when a player already reports the song, so there's nothing to identify.
    var suppressed = false

    private let queue: DispatchQueue
    private let inputFormat: AVAudioFormat
    private let matchFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var scheduler = MatchScheduler()
    private var session: SHSession?
    private var streamTime = 0.0
    private let log = Logger(subsystem: "com.karolisvanagas.sonar", category: "shazam")

    init(sampleRate: Double, queue: DispatchQueue) {
        self.queue = queue
        inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        if Self.supportedRates.contains(sampleRate) {
            matchFormat = inputFormat
            converter = nil
        } else {
            matchFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            converter = AVAudioConverter(from: inputFormat, to: matchFormat)
        }
        super.init()
    }

    /// Asks for an extra attempt soon, e.g. to confirm a surprising match.
    func requestAttempt(after delay: Double) {
        scheduler.request(at: streamTime, delay: delay)
    }

    /// Feeds mono samples; streams them to Shazam only while an attempt is open.
    func feed(_ samples: UnsafePointer<Float>, count: Int, streamTime: Double, trackChanges: Int) {
        self.streamTime = streamTime
        if scheduler.tick(time: streamTime, trackChanges: trackChanges, suppressed: suppressed) {
            let session = SHSession()
            session.delegate = self
            self.session = session
            status("Identifying…")
        }
        guard scheduler.isMatching, let session else {
            if session != nil {
                session = nil
                status(suppressed ? nil : "No match")
            }
            return
        }
        guard let buffer = makeBuffer(samples, count: count) else { return }
        session.matchStreamingBuffer(buffer, at: nil)
    }

    private func makeBuffer(_ samples: UnsafePointer<Float>, count: Int) -> AVAudioPCMBuffer? {
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: samples, count: count)
        guard let converter else { return input }

        let ratio = matchFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(count) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: matchFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }

    private func status(_ text: String?) {
        guard let text else { return }
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }

    // MARK: - SHSessionDelegate (arbitrary thread)

    func session(_ session: SHSession, didFind match: SHMatch) {
        queue.async { [weak self] in
            guard let self, session === self.session else { return }
            self.scheduler.finish(time: self.streamTime)
            self.session = nil
            guard let item = match.mediaItems.first, let track = Self.track(from: item) else { return }
            self.log.info("Matched \(track.displayName)")
            self.status("Identified by Shazam")
            DispatchQueue.main.async { self.onMatch?(track) }
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // Misses are normal mid-attempt (Shazam keeps listening); only errors are interesting.
        guard let error else { return }
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.domain) \($0.code): \($0.localizedDescription)" } ?? ""
        log.error("Shazam error \(nsError.code): \(nsError.localizedDescription, privacy: .public)\(underlying, privacy: .public) \(nsError.userInfo, privacy: .public)")
        queue.async { [weak self] in
            guard let self, session === self.session else { return }
            self.scheduler.finish(time: self.streamTime)
            self.session = nil
            self.status(Self.shortDescription(of: error))
        }
    }

    /// A few words for the menu; the full error goes to the log.
    static func shortDescription(of error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == SHError.errorDomain, let code = SHError.Code(rawValue: nsError.code) else {
            return "Error \(nsError.code)"
        }
        return switch code {
        case .matchAttemptFailed: "Match failed (\(nsError.code))"
        case .invalidAudioFormat, .audioDiscontinuity: "Audio problem (\(nsError.code))"
        case .signatureInvalid, .signatureDurationInvalid: "Bad signature (\(nsError.code))"
        default: "Error \(nsError.code)"
        }
    }

    static func track(from item: SHMatchedMediaItem) -> Track? {
        guard let title = item.title else { return nil }
        return Track(
            id: item.shazamID ?? item.isrc ?? "\(title)|\(item.artist ?? "")",
            title: title,
            artist: item.artist,
            album: nil,
            source: .shazam,
            appleMusicURL: item.appleMusicURL,
            shazamURL: item.webURL,
            artworkURL: item.artworkURL
        )
    }
}
