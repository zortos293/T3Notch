import AppKit
import Darwin

/// Whatever app is hosting a locally running agent CLI.
///
/// There is no deep link into a terminal session, so "open this thread" means
/// raising the window the shell lives in. The session only knows its own pid,
/// so the owning app is found by walking up the parent chain until a pid turns
/// out to belong to a GUI application — which covers Terminal, iTerm, Ghostty,
/// WezTerm, kitty and the editors' built-in terminals without naming any of them.
enum TerminalApp {
    /// Apps to try when the pid chain leads nowhere (the session outlived its
    /// launcher, or the notch has no pid for it at all, as with Codex).
    static let fallbackBundleIdentifiers = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
    ]

    /// Raises the app owning `pid`. Returns false when nothing could be found,
    /// so the caller can fall back.
    @discardableResult
    static func activate(forPid pid: Int?) -> Bool {
        guard let pid else { return false }
        var current: pid_t? = pid_t(pid)
        // Bounded because a broken ppid chain would otherwise loop forever.
        for _ in 0..<32 {
            guard let candidate = current, candidate > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.activationPolicy == .regular,
               raise(app)
            {
                return true
            }
            current = parentPid(of: candidate)
        }
        return false
    }

    /// Last resort: bring forward the first terminal-ish app that is running.
    @discardableResult
    static func activateAnyTerminal() -> Bool {
        for identifier in fallbackBundleIdentifiers {
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier).first
            else {
                continue
            }
            if raise(app) { return true }
        }
        return false
    }

    private static func raise(_ app: NSRunningApplication) -> Bool {
        // Same reason as `T3CodeApp.activate()`: a non-activating panel cannot
        // make another app key, but LaunchServices can.
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        }
        return app.activate(options: [.activateAllWindows])
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
