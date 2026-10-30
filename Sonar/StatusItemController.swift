import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Sparkle
import SwiftUI

/// Owns the menu bar item. Left-click toggles listening; right-click (or
/// control-click) opens the menu.
final class StatusItemController: NSObject {
    private static let animateBeatKey = "animateBeat"
    private static let showTrackKey = "showTrackInMenuBar"
    private static let targetKey = "captureTargetBundleID"
    private static let identifyKey = "identifyWithShazam"
    private static let browserPageKey = "saveBrowserPage"
    private static let notchKey = "showSongsInNotch"
    private static let recentCount = 10
    /// Seconds of audio before re-checking a match that contradicts the current song.
    private static let confirmDelay = 10.0
    /// Readings below this confidence are shown faded.
    private static let dimConfidence = 0.35

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine = BPMEngine()
    private let model = StatusBarModel()
    private let nowPlaying = NowPlayingMonitor()
    private let store = TrackStore()
    private let historyWindow = HistoryWindowController()
    private let notchBanner = NotchBanner()
    /// Checks the GitHub release feed daily (SUFeedURL in Info.plist) and offers updates.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    /// The confirmed Shazam match; cleared when a strong signal says the song changed.
    private var shazamTrack: Track?
    private var confirmer = MatchConfirmer()
    private var lastStrongChanges = 0
    /// History entry for the track playing now.
    private var currentEntryID: UUID?
    private var currentEntryKey: String?
    private var hostingView: NSView?
    private let menu = NSMenu()
    private let trackMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let identifyStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let identifyMenuItem = NSMenuItem(title: "Identify Songs with Shazam", action: #selector(toggleIdentify), keyEquivalent: "")
    private let browserPageMenuItem = NSMenuItem(title: "Save Browser Page", action: #selector(toggleBrowserPage), keyEquivalent: "")
    private let notchMenuItem = NSMenuItem(title: "Show Identified Songs at Top of Screen", action: #selector(toggleNotch), keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem(title: "", action: #selector(toggleListening), keyEquivalent: "")
    private let animateMenuItem = NSMenuItem(title: "Animate Beat", action: #selector(toggleAnimateBeat), keyEquivalent: "")
    private let showTrackMenuItem = NSMenuItem(title: "Show Track in Menu Bar", action: #selector(toggleShowTrack), keyEquivalent: "")
    private let recentMenuItem = NSMenuItem(title: "Recent Tracks", action: nil, keyEquivalent: "")
    private let sourceMenuItem = NSMenuItem(title: "Listen To", action: nil, keyEquivalent: "")
    private let loginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var toggleHotKey: GlobalHotKey?
    private var historyHotKey: GlobalHotKey?

    private var beatClock: BeatClock?
    private var beatTimer: DispatchSourceTimer?

    private var animateBeat: Bool {
        get { UserDefaults.standard.object(forKey: Self.animateBeatKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.animateBeatKey) }
    }

    /// Persisted as the app's bundle ID; absent means all system audio.
    private var savedTarget: CaptureTarget {
        get { UserDefaults.standard.string(forKey: Self.targetKey).map { .app(bundleID: $0) } ?? .system }
        set {
            switch newValue {
            case .system: UserDefaults.standard.removeObject(forKey: Self.targetKey)
            case .app(let bundleID): UserDefaults.standard.set(bundleID, forKey: Self.targetKey)
            }
        }
    }

    /// The now-playing track, ignoring players other than the one being listened to.
    private var relevantTrack: Track? {
        guard let track = nowPlaying.track else { return nil }
        if case .app(let bundleID) = engine.target, track.isFromOtherPlayer(than: bundleID) { return nil }
        return track
    }

    /// What's playing: the player's own metadata wins, otherwise Shazam's match.
    private var currentTrack: Track? {
        relevantTrack ?? shazamTrack
    }

    private var identifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.identifyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.identifyKey) }
    }

    private var saveBrowserPage: Bool {
        get { UserDefaults.standard.object(forKey: Self.browserPageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.browserPageKey) }
    }

    private var showInNotch: Bool {
        get { UserDefaults.standard.object(forKey: Self.notchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.notchKey) }
    }

    private var showTrack: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showTrackKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showTrackKey) }
    }

    override init() {
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Sonar — click to detect BPM, right-click for options"
            button.setAccessibilityLabel("Sonar")

            let hosting = PassthroughHostingView(rootView: StatusBarView(model: model))
            hosting.frame = button.bounds
            hosting.autoresizingMask = [.width, .height]
            button.addSubview(hosting)
            hostingView = hosting
        }

        trackMenuItem.isEnabled = false
        trackMenuItem.isHidden = true
        statusMenuItem.isEnabled = false
        identifyStatusMenuItem.isEnabled = false
        identifyStatusMenuItem.isHidden = true
        recentMenuItem.submenu = NSMenu()
        sourceMenuItem.submenu = NSMenu()
        engine.target = savedTarget
        engine.identifyEnabled = identifyEnabled
        for item in [toggleMenuItem, animateMenuItem, showTrackMenuItem, identifyMenuItem, notchMenuItem, browserPageMenuItem, loginMenuItem] {
            item.target = self
        }
        menu.addItem(trackMenuItem)
        menu.addItem(statusMenuItem)
        menu.addItem(identifyStatusMenuItem)
        menu.addItem(.separator())
        menu.addItem(toggleMenuItem)
        menu.addItem(sourceMenuItem)
        menu.addItem(recentMenuItem)
        menu.addItem(.separator())
        menu.addItem(animateMenuItem)
        menu.addItem(showTrackMenuItem)
        menu.addItem(identifyMenuItem)
        menu.addItem(notchMenuItem)
        menu.addItem(browserPageMenuItem)
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updater
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Quit Sonar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        toggleHotKey = GlobalHotKey(keyCode: kVK_ANSI_B, key: "b") { [weak self] in self?.toggleListening() }
        historyHotKey = GlobalHotKey(keyCode: kVK_ANSI_T, key: "t") { [weak self] in self?.showAllTracks() }
        toggleMenuItem.show(toggleHotKey)

        engine.onStateChange = { [weak self] state in self?.render(state) }
        engine.onIdentified = { [weak self] track in self?.shazamMatched(track) }
        engine.onIdentifyStatus = { [weak self] text in
            self?.identifyStatusMenuItem.title = "Shazam: \(text)"
        }
        nowPlaying.onChange = { [weak self] track, isNew in self?.nowPlayingChanged(track, isNew: isNew) }
        nowPlaying.start()
        render(engine.state)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            animateMenuItem.state = animateBeat ? .on : .off
            showTrackMenuItem.state = showTrack ? .on : .off
            identifyMenuItem.state = identifyEnabled ? .on : .off
            notchMenuItem.state = showInNotch ? .on : .off
            browserPageMenuItem.state = saveBrowserPage ? .on : .off
            rebuildRecentMenu()
            rebuildSourceMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleListening()
        }
    }

    @objc private func toggleListening() {
        engine.toggle()
        if engine.isListening {
            confirmer = MatchConfirmer()
            lastStrongChanges = 0
            nowPlaying.refresh()
            if let track = relevantTrack { startEntry(for: track) }
        } else {
            shazamTrack = nil
            currentEntryID = nil
            currentEntryKey = nil
            notchBanner.hide()
            store.saveNow()
        }
        render(engine.state)
    }

    @objc private func toggleIdentify() {
        identifyEnabled.toggle()
        engine.identifyEnabled = identifyEnabled
        render(engine.state)
    }

    @objc private func toggleNotch() {
        showInNotch.toggle()
        if !showInNotch { notchBanner.hide() }
    }

    @objc private func toggleBrowserPage() {
        saveBrowserPage.toggle()
    }

    @objc private func showAllTracks() {
        historyWindow.show(store: store)
    }

    func saveHistory() {
        store.saveNow()
    }

    // MARK: - History

    private func shazamMatched(_ track: Track) {
        switch confirmer.matched(track) {
        case .commit(let track):
            shazamTrack = track
            startEntry(for: track)
            // Only confirmed matches; nothing is shown while a match is unsure or missing.
            if showInNotch { notchBanner.show(track, bpm: model.bpm) }
        case .same(let track):
            // Another hearing (or another version) of the current song: just
            // fold it into the current entry, without asking the browser again.
            if currentEntryID != nil {
                currentEntryID = store.trackStarted(track, sourceApps: [], page: nil)
            }
        case .tentative(let track):
            // Could be a transition or a stray match; a second opinion decides.
            identifyStatusMenuItem.title = "Shazam: Checking \(track.displayName)?"
            engine.requestIdentification(after: Self.confirmDelay)
        }
        render(engine.state)
    }

    /// Starts (or continues) the history entry for `track` with where it came from.
    private func startEntry(for track: Track) {
        let apps = sourceApps()
        var page: (url: URL, title: String?)?
        if saveBrowserPage, let browser = apps.first(where: { BrowserPage.isBrowser($0.bundleID) }) {
            page = BrowserPage.current(in: browser.bundleID)
        }
        currentEntryID = store.trackStarted(track, sourceApps: apps, page: page)
        currentEntryKey = track.id
    }

    /// The app(s) the audio is coming from: the chosen one, or whichever are playing.
    private func sourceApps() -> [HistoryEntry.App] {
        let apps = AudioProcessList.apps()
        if case .app(let bundleID) = engine.target {
            let name = apps.first { $0.bundleID == bundleID }?.name ?? BPMEngine.displayName(of: bundleID)
            return [HistoryEntry.App(bundleID: bundleID, name: name)]
        }
        return apps.filter(\.isPlaying).map { HistoryEntry.App(bundleID: $0.bundleID, name: $0.name) }
    }

    private func rebuildSourceMenu() {
        guard let submenu = sourceMenuItem.submenu else { return }
        submenu.removeAllItems()

        let all = NSMenuItem(title: "All System Audio", action: #selector(selectSource(_:)), keyEquivalent: "")
        all.target = self
        all.state = engine.target == .system ? .on : .off
        submenu.addItem(all)
        submenu.addItem(.separator())

        // Apps playing right now, plus the saved choice even if it isn't.
        var apps = AudioProcessList.apps().filter(\.isPlaying)
        var selectedMissing: String?
        if case .app(let bundleID) = engine.target, !apps.contains(where: { $0.bundleID == bundleID }) {
            if let app = AudioProcessList.apps().first(where: { $0.bundleID == bundleID }) {
                apps.append(app)
            } else {
                selectedMissing = bundleID
            }
        }
        for app in apps {
            let item = NSMenuItem(title: app.name, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleID
            item.state = engine.target == .app(bundleID: app.bundleID) ? .on : .off
            item.image = app.icon.map(Self.menuIcon)
            if !app.isPlaying { item.title += " (silent)" }
            submenu.addItem(item)
        }
        if let selectedMissing {
            let item = NSMenuItem(title: BPMEngine.displayName(of: selectedMissing) + " (not running)", action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = selectedMissing
            item.state = .on
            submenu.addItem(item)
        }
        if apps.isEmpty && selectedMissing == nil {
            let empty = NSMenuItem(title: "No apps are playing audio", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
    }

    private static func menuIcon(_ image: NSImage) -> NSImage {
        let icon = image.copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        let target: CaptureTarget = (sender.representedObject as? String).map { .app(bundleID: $0) } ?? .system
        savedTarget = target
        engine.target = target
        if !engine.isListening { toggleListening() }
        render(engine.state)
    }

    @objc private func toggleShowTrack() {
        showTrack.toggle()
        render(engine.state)
    }

    private func nowPlayingChanged(_ track: Track?, isNew: Bool) {
        // When listening to one app, the other player's changes are irrelevant.
        if let track, case .app(let bundleID) = engine.target, track.isFromOtherPlayer(than: bundleID) { return }
        if let track, engine.isListening, track.id != currentEntryKey { startEntry(for: track) }
        if isNew { engine.markTrackChange() }
        render(engine.state)
    }

    private func rebuildRecentMenu() {
        guard let submenu = recentMenuItem.submenu else { return }
        submenu.removeAllItems()
        for entry in store.entries.prefix(Self.recentCount) {
            let bpm = entry.bpm.map { " · \(Int($0.rounded())) BPM" } ?? ""
            let item = NSMenuItem(title: entry.displayName + bpm, action: #selector(copyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.shareText
            item.toolTip = "Click to copy"
            submenu.addItem(item)
        }
        if store.entries.isEmpty {
            let empty = NSMenuItem(title: "Identified songs appear here", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: "Show All Tracks…", action: #selector(showAllTracks), keyEquivalent: "")
        all.target = self
        all.show(historyHotKey)
        submenu.addItem(all)
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleAnimateBeat() {
        animateBeat.toggle()
        render(engine.state)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Sonar: launch at login change failed: \(error)")
        }
    }

    @objc private func systemWillSleep() {
        if engine.isListening { engine.stop() }
    }

    private func render(_ state: BPMEngine.State) {
        switch state {
        case .idle:
            model.mode = .idle
            model.bpm = nil
            statusMenuItem.title = "Not listening"
            toggleMenuItem.title = "Start Listening"
            updateBeat(period: nil, lastBeat: nil)
        case .listening(let reading):
            model.mode = .listening
            model.trackChanges = reading.trackChanges
            if reading.strongChanges != lastStrongChanges {
                // A silence gap or player change: a new song for sure, so the
                // Shazam match no longer applies. (Tempo jumps alone only trigger
                // a rescan; the confirmer decides if the song really changed.)
                lastStrongChanges = reading.strongChanges
                confirmer.strongChange()
                if relevantTrack == nil {
                    shazamTrack = nil
                    currentEntryID = nil
                    currentEntryKey = nil
                }
            }
            if let estimate = reading.estimate {
                model.bpm = Int(estimate.bpm.rounded())
                model.dimmed = !estimate.settled || estimate.confidence < Self.dimConfidence
                let settling = estimate.settled ? "" : " (settling)"
                if estimate.settled, let id = currentEntryID {
                    store.record(bpm: estimate.bpm, for: id)
                }
                statusMenuItem.title = String(format: "%.1f BPM · confidence %.0f%%", estimate.bpm, estimate.confidence * 100) + settling
                updateBeat(period: reading.beatPeriod, lastBeat: reading.lastBeat)
            } else {
                model.bpm = nil
                model.dimmed = false
                statusMenuItem.title = reading.waitingFor.map { "Waiting for \($0)…" } ?? "Listening… (play something)"
                updateBeat(period: nil, lastBeat: nil)
            }
            toggleMenuItem.title = "Stop Listening"
        case .failed(let message):
            model.mode = .failed
            model.bpm = nil
            statusMenuItem.title = "Error: \(message)"
            toggleMenuItem.title = "Start Listening"
            updateBeat(period: nil, lastBeat: nil)
        }
        engine.identificationSuppressed = relevantTrack != nil
        identifyStatusMenuItem.isHidden = !(engine.isListening && identifyEnabled && relevantTrack == nil)
        if identifyStatusMenuItem.title.isEmpty { identifyStatusMenuItem.title = "Shazam: waiting…" }

        let track = currentTrack
        trackMenuItem.isHidden = track == nil
        trackMenuItem.title = track?.displayName ?? ""
        model.trackTitle = showTrack && model.mode == .listening ? track?.displayName : nil
        notchBanner.update(bpm: model.bpm)

        resizeStatusItem()
    }

    /// Sizes the item to the SwiftUI content. Measured again on the next run-loop
    /// turn because SwiftUI may apply the model change after this call.
    private func resizeStatusItem() {
        guard let hostingView else { return }
        statusItem.length = hostingView.fittingSize.width
        DispatchQueue.main.async { [weak self] in
            guard let self, let hostingView = self.hostingView else { return }
            let width = hostingView.fittingSize.width
            if self.statusItem.length != width { self.statusItem.length = width }
        }
    }

    // MARK: - Beat pulse

    /// Keeps a one-shot timer armed for the next predicted beat. Only one wakeup
    /// per beat, and none at all when there's no tempo or animation is off.
    private func updateBeat(period: Double?, lastBeat: Double?) {
        guard animateBeat, let period, let lastBeat else {
            beatClock = nil
            beatTimer?.cancel()
            beatTimer = nil
            return
        }
        if beatClock != nil {
            beatClock?.update(period: period, lastBeat: lastBeat)
        } else {
            beatClock = BeatClock(period: period, lastBeat: lastBeat)
        }
        if beatTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in self?.beatFired() }
            beatTimer = timer
            scheduleNextBeat()
            timer.resume()
        }
    }

    private func scheduleNextBeat() {
        guard let beatClock, let beatTimer else { return }
        let now = BPMEngine.uptime()
        // Skip a beat that's too close to schedule reliably.
        let delay = beatClock.nextBeat(after: now + 0.01) - now
        beatTimer.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(4))
    }

    private func beatFired() {
        guard let beatClock else { return }
        model.beatPeriod = beatClock.period
        model.beatCount &+= 1
        scheduleNextBeat()
    }
}
