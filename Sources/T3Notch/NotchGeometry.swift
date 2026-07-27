import AppKit

struct NotchMetrics: Equatable, Sendable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasPhysicalNotch: Bool

    static let fallback = NotchMetrics(
        notchWidth: NotchGeometry.virtualNotchWidth,
        notchHeight: NotchGeometry.virtualNotchHeight,
        hasPhysicalNotch: false
    )
}

enum NotchGeometry {
    static let virtualNotchWidth: CGFloat = 200
    static let virtualNotchHeight: CGFloat = 32

    /// Width of the inverted corner that flares the panel out into the menu bar.
    static let wing: CGFloat = 14
    /// How far the collapsed pill reaches past each side of the physical notch.
    /// Wide enough for the provider logo plus a phase label like "Needs input".
    static let collapsedSideWidth: CGFloat = 104
    static let defaultExpandedBodyWidth: CGFloat = 470
    /// Horizontal inset of the expanded body content.
    static let bodyPadding: CGFloat = 16
    static let cardWidth: CGFloat = 152
    /// Tall enough for a two-line thread title above the status line.
    static let cardHeight: CGFloat = 84
    static let cardSpacing: CGFloat = 7
    /// More agents than this wrap onto another row rather than widening further.
    static let maxCardsPerRow = 3
    /// Window height ceiling. Only hit-testing tracks the drawn panel, so this
    /// just has to be tall enough for the deepest layout: two rows of agent
    /// cards, the task list, and an open question.
    static let windowHeight: CGFloat = 860

    /// The screen to live on. A name from settings wins if that display is still
    /// attached; otherwise the built-in notched screen, then whatever is main.
    static func preferredScreen(named name: String? = nil) -> NSScreen? {
        if let name, let chosen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return chosen
        }
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        if let physical = physicalNotchRect(on: screen) {
            return NotchMetrics(
                notchWidth: physical.width,
                notchHeight: physical.height,
                hasPhysicalNotch: true
            )
        }
        return NotchMetrics(
            notchWidth: virtualNotchWidth,
            notchHeight: max(screen.safeAreaInsets.top, virtualNotchHeight),
            hasPhysicalNotch: false
        )
    }

    /// The notch is the gap between the two menu bar areas that flank it.
    static func physicalNotchRect(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX
        else { return nil }

        return CGRect(
            x: left.maxX,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: right.minX - left.maxX,
            height: screen.safeAreaInsets.top
        )
    }

    static func notchRect(on screen: NSScreen) -> CGRect {
        if let physical = physicalNotchRect(on: screen) {
            return physical
        }
        let metrics = metrics(for: screen)
        return CGRect(
            x: screen.frame.midX - metrics.notchWidth / 2,
            y: screen.frame.maxY - metrics.notchHeight,
            width: metrics.notchWidth,
            height: metrics.notchHeight
        )
    }

    static func collapsedBodyWidth(_ metrics: NotchMetrics) -> CGFloat {
        metrics.notchWidth + collapsedSideWidth * 2
    }

    /// Grows with the agent card deck so every card fits without scrolling.
    static func expandedBodyWidth(_ metrics: NotchMetrics, agentCount: Int = 1) -> CGFloat {
        let base = max(defaultExpandedBodyWidth, metrics.notchWidth + 200)
        guard agentCount > 1 else { return base }
        let cards = CGFloat(min(agentCount, maxCardsPerRow))
        let deck = cards * cardWidth + (cards - 1) * cardSpacing + bodyPadding * 2
        return max(base, deck)
    }

    /// One fixed window sized for the largest panel. The shape animates inside it,
    /// which is what keeps the expand/collapse spring smooth.
    static func windowFrame(on screen: NSScreen) -> CGRect {
        let metrics = metrics(for: screen)
        let notch = notchRect(on: screen)
        let widest = expandedBodyWidth(metrics, agentCount: maxCardsPerRow)
        let width = max(collapsedBodyWidth(metrics), widest) + wing * 2
        return CGRect(
            x: notch.midX - width / 2,
            y: screen.frame.maxY - windowHeight,
            width: width,
            height: windowHeight
        )
    }
}
