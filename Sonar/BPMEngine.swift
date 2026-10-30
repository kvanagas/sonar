import AppKit
import CoreAudio
import os

/// What to listen to.
enum CaptureTarget: Equatable {
    case system
    case app(bundleID: String)
}

/// Glues the audio tap to the tempo analyser and reports results on the main thread.
final class BPMEngine {
    struct Reading: Equatable {
        var estimate: TempoEstimate?
        /// Increments each time a new track is detected; lets the UI animate transitions.
        var trackChanges = 0
        /// The subset of `trackChanges` from strong signals (silence gaps, player
        /// notifications) rather than tempo jumps, which also happen within a song.
        var strongChanges = 0
        /// Beat period and when the latest beat was heard, in `BPMEngine.uptime()` seconds.
        var beatPeriod: Double?
        var lastBeat: Double?
        /// Set while the selected app isn't running, so there's nothing to tap.
        var waitingFor: String?
    }

    enum State: Equatable {
        case idle
        case listening(Reading)
        case failed(String)
    }

    /// Clock used for beat times; the same base as `DispatchTime.now()`.
    static func uptime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// Roughly how long captured audio waits in the ring buffer before analysis.
    private static let captureDelay = 0.01
    private static let scratchSize = 8192

    /// Called on the main thread whenever the state changes.
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Changing the target while listening rebuilds the tap and starts a fresh reading.
    /// Called on the main thread when Shazam identifies what's playing.
    var onIdentified: ((Track) -> Void)?
    /// Called on the main thread with Shazam's status for the menu.
    var onIdentifyStatus: ((String) -> Void)?

    /// Whether to identify songs with Shazam while listening.
    var identifyEnabled = true {
        didSet {
            guard identifyEnabled != oldValue else { return }
            let enabled = identifyEnabled
            queue.async { [weak self] in
                guard let self else { return }
                self.matcherEnabled = enabled
                if !enabled { self.matcher = nil } else if let analyzer = self.analyzer { self.makeMatcher(sampleRate: analyzer.sampleRate) }
            }
        }
    }

    /// Set while a player already reports the current song; Shazam then stays quiet.
    var identificationSuppressed = false {
        didSet {
            let suppressed = identificationSuppressed
            queue.async { [weak self] in
                self?.matcherSuppressed = suppressed
                self?.matcher?.suppressed = suppressed
            }
        }
    }

    var target: CaptureTarget = .system {
        didSet {
            guard target != oldValue, isListening else { return }
            rebuildTap(resetAnalysis: true)
        }
    }

    private let ring = RingBuffer(capacity: 1 << 18)
    private lazy var tap = SystemAudioTap(ring: ring)
    private let queue = DispatchQueue(label: "com.karolisvanagas.sonar.analysis", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    /// The processes the current tap covers (nil for the global tap or while waiting).
    private var tappedProcesses: [AudioObjectID]?
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private let log = Logger(subsystem: "com.karolisvanagas.sonar", category: "engine")

    // Analysis-queue state.
    private var analyzer: TempoAnalyzer?
    private var outputLatency = 0.0
    private var matcher: ShazamMatcher?
    private var matcherSuppressed = false
    private var matcherEnabled = true
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: BPMEngine.scratchSize)

    deinit {
        scratch.deallocate()
    }

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        state = .listening(Reading())
        addListeners()
        startTimer()
        rebuildTap(resetAnalysis: true)
    }

    func stop() {
        removeListeners()
        timer?.cancel()
        timer = nil
        tap.stop()
        tappedProcesses = nil
        queue.sync { analyzer = nil; matcher = nil }
        state = .idle
    }

    /// Runs an extra Shazam attempt `delay` seconds of audio from now.
    func requestIdentification(after delay: Double) {
        queue.async { [weak self] in self?.matcher?.requestAttempt(after: delay) }
    }

    /// Tells the analyser the track changed (from player metadata) so it starts fresh.
    func markTrackChange() {
        guard isListening else { return }
        queue.async { [weak self] in
            guard let self, let analyzer = self.analyzer else { return }
            analyzer.markTrackChange()
            self.publish(from: analyzer)
        }
    }

    // MARK: - Tap lifecycle (main thread)

    /// (Re)creates the tap for the current target. The analyser survives unless
    /// `resetAnalysis` is set or the sample rate changed, so a device switch or a
    /// browser spawning a new audio helper doesn't throw away the tempo.
    private func rebuildTap(resetAnalysis: Bool) {
        var processes: [AudioObjectID]?
        if case .app(let bundleID) = target {
            guard let app = AudioProcessList.apps().first(where: { $0.bundleID == bundleID }) else {
                let name = Self.displayName(of: bundleID)
                log.info("Waiting for \(name) to start")
                tap.stop()
                tappedProcesses = nil
                queue.sync { analyzer = nil; matcher = nil }
                state = .listening(Reading(waitingFor: name))
                return
            }
            processes = app.processes
        }

        tap.stop()
        tappedProcesses = processes
        do {
            try tap.start(processes: processes)
        } catch {
            log.error("Tap failed: \(error.localizedDescription)")
            stop()
            state = .failed(error.localizedDescription)
            return
        }

        let sampleRate = tap.sampleRate
        let latency = tap.outputLatency - Self.captureDelay
        let ring = self.ring
        var replaced = false
        queue.sync {
            ring.drain()
            outputLatency = latency
            if resetAnalysis || analyzer?.sampleRate != sampleRate {
                analyzer = TempoAnalyzer(sampleRate: sampleRate)
                replaced = true
            }
            if matcherEnabled, matcher == nil || replaced {
                makeMatcher(sampleRate: sampleRate)
            }
        }
        if replaced { state = .listening(Reading()) }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Runs on the analysis queue: feeds everything buffered to the analyser.
    private func drain() {
        guard let analyzer else {
            ring.drain()
            return
        }
        var changed = false
        while true {
            let n = ring.read(into: scratch, maxCount: Self.scratchSize)
            guard n > 0 else { break }
            if analyzer.process(UnsafeBufferPointer(start: scratch, count: n)) { changed = true }
            matcher?.feed(scratch, count: n, streamTime: analyzer.streamTime, trackChanges: analyzer.trackChangeCount)
        }
        if changed { publish(from: analyzer) }
    }

    /// Runs on the analysis queue.
    private func makeMatcher(sampleRate: Double) {
        let matcher = ShazamMatcher(sampleRate: sampleRate, queue: queue)
        matcher.suppressed = matcherSuppressed
        matcher.onMatch = { [weak self] track in
            guard let self, self.isListening else { return }
            self.onIdentified?(track)
        }
        matcher.onStatus = { [weak self] text in self?.onIdentifyStatus?(text) }
        self.matcher = matcher
    }

    /// Runs on the analysis queue.
    private func publish(from analyzer: TempoAnalyzer) {
        var reading = Reading(
            estimate: analyzer.estimate,
            trackChanges: analyzer.trackChangeCount,
            strongChanges: analyzer.strongChangeCount
        )
        if let beat = analyzer.beat {
            // Map the analyser's stream clock onto wall-clock uptime.
            reading.beatPeriod = beat.period
            reading.lastBeat = Self.uptime() - (analyzer.streamTime - beat.lastBeat) + outputLatency
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isListening else { return }
            self.state = .listening(reading)
        }
    }

    // MARK: - Hardware changes

    private func addListeners() {
        guard listeners.isEmpty else { return }
        // A new default output means a new clock source for the aggregate device.
        addListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.log.info("Default output changed; rebuilding tap")
            self?.rebuildTap(resetAnalysis: false)
        }
        // Apps launching, quitting or spawning audio helpers change which processes to tap.
        addListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in
            guard let self, case .app(let bundleID) = self.target else { return }
            let current = AudioProcessList.apps().first { $0.bundleID == bundleID }?.processes
            guard current.map(Set.init) != self.tappedProcesses.map(Set.init) else { return }
            self.log.info("Processes for \(bundleID) changed; rebuilding tap")
            self.rebuildTap(resetAnalysis: false)
        }
    }

    private func addListener(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard self?.isListening == true else { return }
            handler()
        }
        var address = AudioObjectPropertyAddress.global(selector)
        AudioObjectAddPropertyListenerBlock(.system, &address, .main, block)
        listeners.append((selector, block))
    }

    private func removeListeners() {
        for (selector, block) in listeners {
            var address = AudioObjectPropertyAddress.global(selector)
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, block)
        }
        listeners.removeAll()
    }

    static func displayName(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
