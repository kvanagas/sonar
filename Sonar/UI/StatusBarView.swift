import Observation
import SwiftUI

/// Everything the menu bar view draws. Updated on the main thread by `StatusItemController`.
@Observable
final class StatusBarModel {
    enum Mode { case idle, listening, failed }

    var mode: Mode = .idle
    var bpm: Int?
    /// Shown faded while the reading is settling or unsure.
    var dimmed = false
    var trackChanges = 0
    /// Increments on every beat; drives the pulse.
    var beatCount = 0
    var beatPeriod = 0.5
    /// "Title — Artist" when the track name should be shown in the menu bar.
    var trackTitle: String?

    var icon: Image {
        switch mode {
        case .idle: Image(.menuBarIcon)
        case .listening: Image(systemName: "waveform")
        case .failed: Image(systemName: "exclamationmark.triangle")
        }
    }
}

struct StatusBarView: View {
    let model: StatusBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            model.icon
                .contentTransition(.symbolEffect(.replace))
                .keyframeAnimator(initialValue: 1.0, trigger: model.beatCount) { icon, scale in
                    icon.scaleEffect(scale)
                } keyframes: { _ in
                    // Quick hit, then settle; shorter at fast tempos so pulses don't blur together.
                    let release = min(0.25, model.beatPeriod * 0.6)
                    CubicKeyframe(1.25, duration: 0.04)
                    SpringKeyframe(1.0, duration: release, spring: .snappy)
                }

            if model.mode == .listening {
                if let trackTitle = model.trackTitle {
                    // Truncated rather than scrolled: a marquee would redraw the
                    // menu bar continuously. The full name is in the menu.
                    Text(trackTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 180, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                        .id(trackTitle)
                }
                reading
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: model.mode)
        .animation(.smooth(duration: 0.35), value: model.trackTitle)
    }

    private var reading: some View {
        // Reserve three digits so the menu bar doesn't shift as the number changes.
        Text("000").hidden().overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                Group {
                    if let bpm = model.bpm {
                        Text(bpm, format: .number.grouping(.never))
                            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(bpm)))
                    } else {
                        Text("—")
                    }
                }
                // A new identity per track makes track changes blur across instead of rolling.
                .id(model.trackChanges)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
            .opacity(model.dimmed ? 0.5 : 1)
            .animation(.snappy, value: model.bpm)
            .animation(.smooth(duration: 0.35), value: model.trackChanges)
            .animation(.easeInOut(duration: 0.3), value: model.dimmed)
        }
    }
}

/// Hosts SwiftUI inside the status item button without swallowing its clicks.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
