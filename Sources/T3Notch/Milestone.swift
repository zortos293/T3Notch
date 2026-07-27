import SwiftUI

/// Something worth a moment of celebration in the notch.
enum Milestone: Equatable, Sendable {
    case tasksComplete(count: Int)
    case branchMerged(branch: String, into: String)

    var headline: String {
        switch self {
        case let .tasksComplete(count):
            count == 1 ? "Task complete" : "All \(count) tasks complete"
        case .branchMerged:
            "Branch merged"
        }
    }

    var detail: String? {
        switch self {
        case .tasksComplete:
            nil
        case let .branchMerged(branch, into):
            "\(branch) → \(into)"
        }
    }

    var symbol: String {
        switch self {
        case .tasksComplete: "checkmark.seal.fill"
        case .branchMerged: "arrow.triangle.merge"
        }
    }

    var tint: Color {
        switch self {
        case .tasksComplete: Color(red: 0.42, green: 0.95, blue: 0.55)
        case .branchMerged: Color(red: 0.66, green: 0.55, blue: 1.0)
        }
    }

    /// How long the banner stays up. A merge is rarer, so it lingers.
    var duration: Double {
        switch self {
        case .tasksComplete: 2.6
        case .branchMerged: 4.5
        }
    }

    /// Merges get confetti; finishing tasks is frequent enough that it would
    /// wear out its welcome.
    var showsConfetti: Bool {
        switch self {
        case .tasksComplete: false
        case .branchMerged: true
        }
    }
}

/// A milestone plus a token, so the same milestone twice still re-animates.
struct Celebration: Equatable, Identifiable {
    let id: Int
    let milestone: Milestone
}
