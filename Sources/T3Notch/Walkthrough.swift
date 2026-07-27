import Foundation
import SwiftUI

/// What the notch is doing while the welcome window is open.
///
/// The window cannot show the notch — it *is* the notch's job to be looked at —
/// so the welcome walks through a pretend agent instead of describing one. This
/// is the notch's half of that: which chapter it is playing, and the caption that
/// keeps the demonstration honest about being a demonstration.
struct Walkthrough: Equatable {
    enum Stage: Equatable {
        /// Window open, nothing to demonstrate yet.
        case waiting
        /// A pretend agent is working away.
        case demo
        /// The pretend agent is asking something, and the reader has to answer.
        case asking
        /// Its plan landed.
        case landed
        /// Several pretend agents at once; the flag turns once a card is pressed.
        case crowd(switched: Bool)
        /// The real connection test, echoed as it runs.
        case testing(Status)
    }

    enum Status: Equatable {
        case running
        case passed(String)
        case failed(String)
    }

    var stage: Stage = .waiting

    /// Whether the panel is worth opening by itself. A window that has not
    /// started the demo yet only earns the collapsed pill.
    var wantsPanel: Bool {
        stage != .waiting
    }

    /// What the notch says about itself while the tour runs: a badge in the top
    /// strip, and the whole caption when there is no agent to put one beside.
    /// Nil while the panel is showing real work.
    var caption: Caption? {
        switch stage {
        case .waiting:
            return nil
        case .demo:
            return Caption(
                title: "Demo agent",
                detail: "Pretend work, so you can see the real thing.",
                symbol: "sparkles",
                tint: .cyan
            )
        case .asking:
            return Caption(
                title: "Your turn",
                detail: "Answer below — this is how real questions arrive.",
                symbol: "hand.point.down.fill",
                tint: .orange,
                chip: "Your turn"
            )
        case .landed:
            return Caption(
                title: "Demo agent",
                detail: "That is what finishing looks like.",
                symbol: "checkmark.seal.fill",
                tint: .green
            )
        case let .crowd(switched):
            return Caption(
                title: switched ? "That is the switch" : "Three pretend agents",
                detail: switched
                    ? "The panel below follows whichever card is lit."
                    : "Press another card to follow it instead.",
                symbol: switched ? "checkmark.seal.fill" : "square.stack.3d.up.fill",
                tint: switched ? .green : .cyan
            )
        case let .testing(status):
            switch status {
            case .running:
                return Caption(
                    title: "Testing the connection",
                    detail: "Asking the local server who is running.",
                    symbol: "antenna.radiowaves.left.and.right",
                    tint: .cyan,
                    chip: "Testing"
                )
            case let .passed(summary):
                return Caption(
                    title: "Connected to T3 Code",
                    detail: summary,
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    chip: "Connected"
                )
            case let .failed(message):
                return Caption(
                    title: "Cannot reach T3 Code",
                    detail: message,
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    chip: "No answer"
                )
            }
        }
    }

    struct Caption: Equatable {
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        /// A word or two, for the badge in the top strip.
        var chip: String = "Demo"
        var isBusy: Bool = false
    }
}
