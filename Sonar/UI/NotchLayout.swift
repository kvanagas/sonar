import CoreGraphics

/// Where the notch banner sits on a screen, in screen coordinates (origin bottom-left).
struct NotchLayout: Equatable {
    /// The hardware notch, or a zero-width strip at the top center on screens without one.
    var notch: CGRect
    /// The banner when open. Its top edge is the top of the screen.
    var banner: CGRect

    var hasNotch: Bool { notch.width > 0 }

    /// - Parameters:
    ///   - safeTop: `NSScreen.safeAreaInsets.top`; nonzero only on notched screens.
    ///   - leftWidth, rightWidth: widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
    ///   - menuBarHeight: used for the top band on screens without a notch.
    ///   - contentHeight: height of the content shown below the notch.
    init(screen: CGRect, safeTop: CGFloat, leftWidth: CGFloat?, rightWidth: CGFloat?,
         menuBarHeight: CGFloat, contentHeight: CGFloat, minWidth: CGFloat) {
        let top: CGFloat
        if safeTop > 0, let leftWidth, let rightWidth, screen.width - leftWidth - rightWidth > 0 {
            top = safeTop
            notch = CGRect(x: screen.minX + leftWidth, y: screen.maxY - top,
                           width: screen.width - leftWidth - rightWidth, height: top)
        } else {
            top = menuBarHeight
            notch = CGRect(x: screen.midX, y: screen.maxY - top, width: 0, height: top)
        }
        let width = min(screen.width, max(minWidth, notch.width + 2 * Self.wing))
        let height = top + contentHeight
        let x = min(max(notch.midX - width / 2, screen.minX), screen.maxX - width)
        banner = CGRect(x: x, y: screen.maxY - height, width: width, height: height)
    }

    /// How far the open banner reaches past each side of the notch, at least.
    static let wing: CGFloat = 60
}
