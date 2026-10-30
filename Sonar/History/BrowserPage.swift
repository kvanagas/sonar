import AppKit
import os

/// Best-effort lookup of the page a browser is playing audio from.
///
/// Browsers don't expose which tab is audible, so we prefer a tab on a known
/// music/video site (front tab first), then fall back to the front tab.
/// Each browser asks for Automation permission the first time.
enum BrowserPage {
    private enum Family { case chromium, safari }

    private static let browsers: [String: Family] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "company.thebrowser.Browser": .chromium, // Arc
        "com.apple.Safari": .safari,
    ]

    static let mediaHosts = [
        "youtube.com", "youtu.be", "soundcloud.com", "mixcloud.com", "twitch.tv", "bandcamp.com",
        "open.spotify.com", "music.apple.com", "boilerroom.tv", "hearthis.at", "beatport.com", "music.youtube.com",
    ]

    private static let log = Logger(subsystem: "com.karolisvanagas.sonar", category: "browser")

    static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    /// Must be called on the main thread (NSAppleScript).
    static func current(in bundleID: String) -> (url: URL, title: String?)? {
        guard let family = browsers[bundleID] else { return nil }
        let (tabs, front) = switch family {
        case .chromium: ("tabs", "active tab")
        case .safari: ("tabs", "current tab")
        }
        let titleProperty = family == .safari ? "name" : "title"
        // Returns {url, title} pairs, front tab first, skipping private windows
        // (Chromium's `mode`, Arc's `incognito`; the property a browser lacks just errors).
        let script = """
        tell application id "\(bundleID)"
            set out to {}
            repeat with w in windows
                set priv to false
                try
                    set priv to (mode of w is "incognito")
                end try
                try
                    set priv to (incognito of w)
                end try
                if not priv then
                    set ft to \(front) of w
                    set end of out to {URL of ft, \(titleProperty) of ft}
                    repeat with t in \(tabs) of w
                        set end of out to {URL of t, \(titleProperty) of t}
                    end repeat
                end if
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            if let error { log.info("Browser query for \(bundleID, privacy: .public) failed: \(error)") }
            return nil
        }
        var pages: [(url: URL, title: String?)] = []
        if result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                guard let pair = result.atIndex(i), pair.numberOfItems == 2,
                      let urlString = pair.atIndex(1)?.stringValue, let url = saveable(URL(string: urlString)) else { continue }
                pages.append((url, pair.atIndex(2)?.stringValue))
            }
        }
        return pages.first(where: { isMedia($0.url) }) ?? pages.first
    }

    /// Web pages only, and only the address of non-media pages: query strings
    /// and fragments often carry tokens or private IDs that history shouldn't keep.
    static func saveable(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        guard !isMedia(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    static func isMedia(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return mediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
