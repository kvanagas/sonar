import AppKit
import CoreAudio

/// An app (with its helper processes) that Core Audio knows about.
struct AudioApp: Equatable {
    var bundleID: String
    var name: String
    /// Core Audio process objects belonging to this app, helpers included.
    var processes: [AudioObjectID]
    /// True if any of its processes is currently producing output.
    var isPlaying: Bool

    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// Enumerates Core Audio process objects and groups them by the app they belong to.
enum AudioProcessList {
    private struct Process {
        var object: AudioObjectID
        var pid: pid_t
        var bundleID: String
        var isPlaying: Bool
    }

    /// Bundle IDs whose audio is played by a shared system process rather than the app itself.
    private static let sharedAudioProcesses = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
        "com.apple.WebKit.WebContent": "com.apple.Safari",
    ]

    static func apps() -> [AudioApp] {
        let regularApps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        let ownBundleID = Bundle.main.bundleIdentifier

        var groups: [String: AudioApp] = [:]
        for process in processes() {
            guard let owner = owner(of: process.bundleID, regularApps: regularApps), owner != ownBundleID else { continue }
            var app = groups[owner] ?? AudioApp(
                bundleID: owner,
                name: regularApps[owner]?.localizedName ?? owner,
                processes: [],
                isPlaying: false
            )
            app.processes.append(process.object)
            app.isPlaying = app.isPlaying || process.isPlaying
            groups[owner] = app
        }
        return groups.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The running regular app a process's audio should be attributed to:
    /// itself, a parent bundle ID (`com.google.Chrome.helper` → `com.google.Chrome`),
    /// or the app that uses a shared system audio process.
    private static func owner(of bundleID: String, regularApps: [String: NSRunningApplication]) -> String? {
        if let shared = sharedAudioProcesses[bundleID] {
            return regularApps[shared] != nil ? shared : nil
        }
        var components = bundleID.split(separator: ".")
        while components.count >= 2 {
            let candidate = components.joined(separator: ".")
            if regularApps[candidate] != nil { return candidate }
            components.removeLast()
        }
        return nil
    }

    private static func processes() -> [Process] {
        var address = AudioObjectPropertyAddress.global(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID.system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            guard let bundleID = try? object.readString(kAudioProcessPropertyBundleID), !bundleID.isEmpty else { return nil }
            let pid = (try? object.read(kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
            let running = (try? object.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return Process(object: object, pid: pid, bundleID: bundleID, isPlaying: running != 0)
        }
    }
}
