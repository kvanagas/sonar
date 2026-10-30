import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "All Tracks" window content: every song heard, searchable and sortable.
struct HistoryView: View {
    let store: TrackStore

    @State private var search = ""
    @State private var selection = Set<HistoryEntry.ID>()
    @State private var sortOrder = [KeyPathComparator(\HistoryEntry.firstHeard, order: .reverse)]
    @State private var confirmingClear = false

    private var rows: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? store.entries : store.entries.filter { entry in
            [entry.title, entry.artist ?? "", entry.album ?? "", entry.sourceName, entry.pageTitle ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { entry in
                Artwork(url: entry.artworkURL)
            }
            .width(30)

            TableColumn("Date", value: \.firstHeard) { entry in
                Text(entry.firstHeard, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 140)

            TableColumn("Title", value: \.title) { entry in
                TitleCell(entry: entry)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Artist", value: \.artistSortKey) { entry in
                Text(entry.artist ?? "")
            }
            .width(min: 100, ideal: 160)

            TableColumn("BPM", value: \.bpmSortKey) { entry in
                Text(entry.bpmText).monospacedDigit()
            }
            .width(min: 50, ideal: 70)

            TableColumn("Source", value: \.sourceName) { entry in
                SourceCell(entry: entry)
            }
            .width(min: 120, ideal: 220)
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            contextMenu(for: entries(ids))
        } primaryAction: { ids in
            entries(ids).compactMap(\.bestURL).forEach { NSWorkspace.shared.open($0) }
        }
        .overlay {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No Tracks Yet",
                    systemImage: "music.note.list",
                    description: Text("Songs identified while Sonar is listening appear here.")
                )
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Title, artist or source")
        .toolbar {
            ToolbarItemGroup {
                Button("Export CSV…", systemImage: "square.and.arrow.up", action: exportCSV)
                    .disabled(store.entries.isEmpty)
                Button("Clear History…", systemImage: "trash") { confirmingClear = true }
                    .disabled(store.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear all \(store.entries.count) tracks?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { store.clear() }
        } message: {
            Text("This can't be undone.")
        }
        .frame(minWidth: 720, minHeight: 320)
    }

    private func entries(_ ids: Set<HistoryEntry.ID>) -> [HistoryEntry] {
        store.entries.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func contextMenu(for entries: [HistoryEntry]) -> some View {
        if let entry = entries.first, entries.count == 1 {
            if let url = entry.spotifyURL { Button("Open in Spotify") { NSWorkspace.shared.open(url) } }
            if let url = entry.appleMusicURL { Button("Open in Apple Music") { NSWorkspace.shared.open(url) } }
            if let url = entry.shazamURL { Button("Open on Shazam") { NSWorkspace.shared.open(url) } }
            if let url = entry.pageURL { Button("Open Source Page") { NSWorkspace.shared.open(url) } }
            Divider()
            ForEach(HistoryEntry.SearchSite.allCases, id: \.self) { site in
                if let url = entry.searchURL(on: site) {
                    Button("Search on \(site.rawValue)") { NSWorkspace.shared.open(url) }
                }
            }
            Divider()
        }
        if !entries.isEmpty {
            Button(entries.count == 1 ? "Copy" : "Copy \(entries.count) Tracks") {
                copy(entries.map(\.shareText).joined(separator: "\n"))
            }
            if let url = entries.first?.bestURL, entries.count == 1 {
                Button("Copy Link") { copy(url.absoluteString) }
            }
            if entries.count > 1 {
                Button("Merge \(entries.count) Tracks") { store.merge(Set(entries.map(\.id))) }
                    .help("Combine into the earliest entry; the other titles are kept as “also matched as”.")
            }
            Divider()
            Button(entries.count == 1 ? "Delete" : "Delete \(entries.count) Tracks", role: .destructive) {
                store.delete(Set(entries.map(\.id)))
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Sonar Tracks.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selected = selection.isEmpty ? nil : rows.filter { selection.contains($0.id) }
        try? store.csv(for: selected).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct TitleCell: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 4) {
            Text(entry.title)
            if let others = entry.alsoMatchedAs, !others.isEmpty {
                Text("+\(others.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .help(entry.alsoMatchedAs.map { "Also matched as:\n" + $0.joined(separator: "\n") } ?? entry.displayName)
    }
}

private struct SourceCell: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 4) {
            Text(entry.sourceName)
            if let url = entry.pageURL {
                Link(destination: url) {
                    Text(entry.pageTitle ?? url.host() ?? url.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(url.absoluteString)
            }
        }
    }
}

private struct Artwork: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private extension HistoryEntry {
    var artistSortKey: String { artist ?? "" }
    var bpmSortKey: Double { bpm ?? 0 }
}

/// Owns the single "All Tracks" window.
final class HistoryWindowController {
    private var window: NSWindow?

    func show(store: TrackStore) {
        if window == nil {
            let host = NSHostingController(rootView: HistoryView(store: store))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.title = "All Tracks"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 960, height: 520))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("SonarHistoryWindow")
            self.window = window
        }
        // Sonar has no Dock icon, so bring it forward explicitly.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
