import AppKit
import Observation
import SwiftUI

/// What the notch banner draws. Updated on the main thread by `NotchBanner`.
@Observable
final class NotchBannerModel {
    var track: Track?
    var bpm: Int?
    var isOpen = false
    var layout = NotchLayout(screen: .zero, safeTop: 0, leftWidth: nil, rightWidth: nil,
                             menuBarHeight: 0, contentHeight: 0, minWidth: 0)
}

/// Briefly grows the identified song out of the notch, Dynamic Island style.
/// On screens without a notch it drops down from the top center instead.
final class NotchBanner {
    /// Seconds the banner stays open.
    private static let holdDuration = 5.0
    /// Time for the close animation to finish before the window goes away.
    private static let closeDuration = 0.45
    private static let contentHeight: CGFloat = 56
    private static let minWidth: CGFloat = 340

    private let model = NotchBannerModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ track: Track, bpm: Int?) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let layout = NotchLayout(
            screen: screen.frame,
            safeTop: screen.safeAreaInsets.top,
            leftWidth: screen.auxiliaryTopLeftArea?.width,
            rightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY > 0 ? screen.frame.maxY - screen.visibleFrame.maxY : 24,
            contentHeight: Self.contentHeight,
            minWidth: Self.minWidth)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.layout = layout
        model.track = track
        model.bpm = bpm
        panel.setFrame(layout.banner, display: true)
        panel.orderFrontRegardless()
        // Open on the next turn so SwiftUI first draws the closed state and animates from it.
        DispatchQueue.main.async { [weak self] in self?.model.isOpen = true }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
    }

    /// Keeps the BPM current while the banner is open.
    func update(bpm: Int?) {
        if model.isOpen { model.bpm = bpm }
    }

    func hide() {
        hideWork?.cancel()
        guard model.isOpen else { return }
        model.isOpen = false
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, and never in the way of clicks on it.
        panel.level = NSWindow.Level(NSWindow.Level.mainMenu.rawValue + 3)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: NotchBannerView(model: model))
        return panel
    }
}

struct NotchBannerView: View {
    let model: NotchBannerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: NotchLayout { model.layout }

    var body: some View {
        let open = model.isOpen
        // Closed, the shape is exactly the notch, so it appears to grow out of it.
        let width = open || reduceMotion ? layout.banner.width : layout.notch.width
        let height = open || reduceMotion ? layout.banner.height : layout.notch.height
        let radius: CGFloat = open ? 20 : 8

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .fill(.black)
                .frame(width: width, height: height)

            if let track = model.track {
                content(track)
                    .padding(.top, layout.notch.height)
                    .frame(width: layout.banner.width, height: layout.banner.height, alignment: .top)
                    .opacity(open ? 1 : 0)
                    .blur(radius: open || reduceMotion ? 0 : 6)
            }
        }
        .opacity(reduceMotion && !open ? 0 : 1)
        .frame(width: layout.banner.width, height: layout.banner.height, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.25), value: open)
        .environment(\.colorScheme, .dark)
    }

    private func content(_ track: Track) -> some View {
        HStack(spacing: 10) {
            artwork(track.artworkURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 8)
            if let bpm = model.bpm {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(bpm, format: .number.grouping(.never))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(bpm)))
                        .animation(.snappy, value: bpm)
                    Text("BPM")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func artwork(_ url: URL?) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.white.opacity(0.12)
                }
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
