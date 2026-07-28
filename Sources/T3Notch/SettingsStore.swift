import AppKit
import SwiftUI
import T3NotchCore

/// User-adjustable behaviour, persisted in `UserDefaults`.
///
/// Values live in one struct so the view can bind to any of them through a key
/// path, and every write goes through `set`, which persists and then tells the
/// app to re-read itself. Nothing here is cosmetic: each field is consumed
/// somewhere that changes what the notch does.
@MainActor
@Observable
final class SettingsStore {
    struct Values: Equatable, Sendable {
        /// Open the panel by itself when an agent needs an answer.
        var expandOnAttention = true
        /// Play a sound when that happens.
        var soundOnAttention = true
        /// Keep a finished agent pinned as a Done card until it is reviewed.
        var keepFinishedUntilReviewed = true

        /// Banner and tick animations for finished tasks and landed branches.
        var celebrateMilestones = true
        /// Confetti on the merge banner.
        var confetti = true
        /// Watch thread branches to notice when they land.
        var watchMerges = true
        /// Ask the GitHub CLI about pull requests, the only way to see a squash
        /// merge. Off means local merges only.
        var askForgeForMerges = true

        /// Rows in the Activity feed.
        var activityRows = 5
        /// Rows in the task list before "+N more".
        var taskRows = 5
        /// `nil` prefers the built-in notched display.
        var displayName: String?

        /// Bring the T3 Code desktop app forward instead of opening the web UI,
        /// when it is running.
        var openInDesktopApp = true

        /// Look for a newer release shortly after launch and every few hours.
        var automaticUpdates = true
        /// Fetch the zip as soon as one is found. Installing still waits for a
        /// click, since it restarts the app.
        var automaticDownload = true
        /// `.prerelease` also takes GitHub pre-releases, like T3 Code's nightly.
        var updateChannel = UpdateChannel.stable
        /// Cleared once the quick start has been dismissed.
        var needsQuickStart = true

        /// Which agent runtimes the notch watches.
        var watchT3 = true
        var watchClaude = true
        var watchCodex = true

        /// Listen for Claude Code hook callbacks, which is what makes its
        /// permission prompts answerable from the notch.
        var claudeHookListener = true
        /// Fixed on purpose: the installed hook entries carry this port, so
        /// falling back to another one would silently desync them.
        var claudeHookPort = 19725
    }

    private(set) var values: Values

    /// Called after any change so the app can apply it without waiting for a poll.
    var onChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private static let prefix = "settings."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = Self.load(from: defaults)
    }

    func binding<V>(_ keyPath: WritableKeyPath<Values, V>) -> Binding<V> {
        Binding(
            get: { self.values[keyPath: keyPath] },
            set: { self.set(keyPath, to: $0) }
        )
    }

    func set<V>(_ keyPath: WritableKeyPath<Values, V>, to newValue: V) {
        var updated = values
        updated[keyPath: keyPath] = newValue
        guard updated != values else { return }
        values = updated
        save()
        onChange?()
    }

    func resetToDefaults() {
        // Resetting preferences should not replay the onboarding.
        let needsQuickStart = values.needsQuickStart
        values = Values()
        values.needsQuickStart = needsQuickStart
        save()
        onChange?()
    }

    /// Displays the notch can be pinned to, newest geometry first.
    var availableDisplays: [String] {
        NSScreen.screens.compactMap { $0.localizedName.nilIfBlank }
    }

    private static func load(from defaults: UserDefaults) -> Values {
        var values = Values()

        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: prefix + key) as? Bool ?? fallback
        }
        func int(_ key: String, _ fallback: Int, in range: ClosedRange<Int>) -> Int {
            guard let stored = defaults.object(forKey: prefix + key) as? Int else { return fallback }
            return min(max(stored, range.lowerBound), range.upperBound)
        }

        values.expandOnAttention = bool("expandOnAttention", values.expandOnAttention)
        values.soundOnAttention = bool("soundOnAttention", values.soundOnAttention)
        values.keepFinishedUntilReviewed = bool(
            "keepFinishedUntilReviewed",
            values.keepFinishedUntilReviewed
        )
        values.celebrateMilestones = bool("celebrateMilestones", values.celebrateMilestones)
        values.confetti = bool("confetti", values.confetti)
        values.watchMerges = bool("watchMerges", values.watchMerges)
        values.askForgeForMerges = bool("askForgeForMerges", values.askForgeForMerges)
        values.activityRows = int("activityRows", values.activityRows, in: Self.rowRange)
        values.taskRows = int("taskRows", values.taskRows, in: Self.rowRange)
        values.displayName = defaults.string(forKey: prefix + "displayName")?.nilIfBlank
        values.openInDesktopApp = bool("openInDesktopApp", values.openInDesktopApp)
        values.needsQuickStart = bool("needsQuickStart", values.needsQuickStart)
        values.automaticUpdates = bool("automaticUpdates", values.automaticUpdates)
        values.automaticDownload = bool("automaticDownload", values.automaticDownload)
        values.updateChannel =
            defaults.string(forKey: prefix + "updateChannel")
            .flatMap(UpdateChannel.init(rawValue:)) ?? values.updateChannel
        values.watchT3 = bool("watchT3", values.watchT3)
        values.watchClaude = bool("watchClaude", values.watchClaude)
        values.watchCodex = bool("watchCodex", values.watchCodex)
        values.claudeHookListener = bool("claudeHookListener", values.claudeHookListener)
        values.claudeHookPort = int("claudeHookPort", values.claudeHookPort, in: portRange)

        return values
    }

    private func save() {
        defaults.set(values.expandOnAttention, forKey: Self.prefix + "expandOnAttention")
        defaults.set(values.soundOnAttention, forKey: Self.prefix + "soundOnAttention")
        defaults.set(
            values.keepFinishedUntilReviewed,
            forKey: Self.prefix + "keepFinishedUntilReviewed"
        )
        defaults.set(values.celebrateMilestones, forKey: Self.prefix + "celebrateMilestones")
        defaults.set(values.confetti, forKey: Self.prefix + "confetti")
        defaults.set(values.watchMerges, forKey: Self.prefix + "watchMerges")
        defaults.set(values.askForgeForMerges, forKey: Self.prefix + "askForgeForMerges")
        defaults.set(values.activityRows, forKey: Self.prefix + "activityRows")
        defaults.set(values.taskRows, forKey: Self.prefix + "taskRows")
        defaults.set(values.openInDesktopApp, forKey: Self.prefix + "openInDesktopApp")
        defaults.set(values.needsQuickStart, forKey: Self.prefix + "needsQuickStart")
        defaults.set(values.automaticUpdates, forKey: Self.prefix + "automaticUpdates")
        defaults.set(values.automaticDownload, forKey: Self.prefix + "automaticDownload")
        defaults.set(values.updateChannel.rawValue, forKey: Self.prefix + "updateChannel")
        defaults.set(values.watchT3, forKey: Self.prefix + "watchT3")
        defaults.set(values.watchClaude, forKey: Self.prefix + "watchClaude")
        defaults.set(values.watchCodex, forKey: Self.prefix + "watchCodex")
        defaults.set(values.claudeHookListener, forKey: Self.prefix + "claudeHookListener")
        defaults.set(values.claudeHookPort, forKey: Self.prefix + "claudeHookPort")
        if let displayName = values.displayName {
            defaults.set(displayName, forKey: Self.prefix + "displayName")
        } else {
            defaults.removeObject(forKey: Self.prefix + "displayName")
        }
    }

    static let rowRange = 3...8
    static let portRange = 1024...65535
}
