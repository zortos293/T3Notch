import AppKit

/// The T3 Code desktop app, as seen from outside it.
enum T3CodeApp {
    /// Nightly and stable ship under the same identifier; the dev build differs.
    static let bundleIdentifiers = [
        "com.t3tools.t3code",
        "com.t3tools.t3code-dev",
        "com.t3tools.t3code.dev",
    ]

    static var running: NSRunningApplication? {
        bundleIdentifiers
            .lazy
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .first
    }

    static var isRunning: Bool { running != nil }

    /// Brings it forward. Returns false when it is not running, so the caller can
    /// fall back to the web UI rather than silently doing nothing.
    @discardableResult
    static func activate() -> Bool {
        guard let app = running else { return false }
        // `NSRunningApplication.activate()` is ignored unless the caller is itself
        // active, which the non-activating notch panel never is. Asking
        // LaunchServices raises it the way `open -a` does.
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        }
        return app.activate(options: [.activateAllWindows])
    }
}
