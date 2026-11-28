import AppKit
import T3NotchCore

/// The T3 Code desktop app, as seen from outside it.
enum T3CodeApp {
    /// Nightly and stable ship under the same identifier; the dev build differs.
    static let stableBundleIdentifier = "com.t3tools.t3code"
    static let developmentBundleIdentifiers = [
        "com.t3tools.t3code-dev",
        "com.t3tools.t3code.dev",
    ]
    static var bundleIdentifiers: [String] {
        [stableBundleIdentifier] + developmentBundleIdentifiers
    }

    static var running: NSRunningApplication? {
        bundleIdentifiers
            .lazy
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .first
    }

    /// The scheme the running build answers to. The dev build registers `t3code-dev`,
    /// so a `t3code://` link would go to the stable app instead.
    static var urlScheme: String {
        guard let identifier = running?.bundleIdentifier,
              developmentBundleIdentifiers.contains(identifier)
        else { return ThreadDeepLink.productionScheme }
        return ThreadDeepLink.developmentScheme
    }

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
