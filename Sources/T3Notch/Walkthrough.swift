import Foundation

/// What the notch shows while the quick start window is open.
///
/// Without this the walkthrough would describe an invisible panel: with no agents
/// running the notch hides itself, so "hover the notch" points at nothing.
struct Walkthrough: Equatable {
    /// The step being pointed at, when the reader is hovering one.
    var step: Step?
    /// The window's connection test, echoed in the notch as it runs.
    var status: Status = .idle

    struct Step: Equatable, Identifiable {
        let id: Int
        let title: String
        /// Long form, for the window.
        let detail: String
        /// Short form, for the much narrower notch.
        let hint: String
        let symbol: String
    }

    enum Status: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    /// Whether there is something worth opening the panel for. An idle window
    /// with nothing hovered only earns the collapsed pill.
    var wantsPanel: Bool {
        step != nil || status != .idle
    }

    static let steps: [Step] = [
        Step(
            id: 1,
            title: "Hover the notch",
            detail: "It stays a small pill while agents work, and expands when you point at "
                + "it. ⌘E from the menu bar item opens it too.",
            hint: "Like this — the panel follows your pointer.",
            symbol: "hand.point.up.left.fill"
        ),
        Step(
            id: 2,
            title: "Answer without leaving",
            detail: "Approvals and questions appear one at a time; answering one slides to "
                + "the next. A finished agent stays pinned until you open it in T3 Code.",
            hint: "Approvals and questions land right here.",
            symbol: "questionmark.bubble.fill"
        ),
        Step(
            id: 3,
            title: "Tune it later",
            detail: "Settings… in the menu bar item controls sounds, animations, row "
                + "counts, which display it lives on, and merge watching.",
            hint: "⌘, opens the control panel.",
            symbol: "slider.horizontal.3"
        ),
    ]
}
