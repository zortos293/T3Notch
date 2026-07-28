import Foundation

public enum ClaudeHookStatus: Sendable, Equatable {
    case installed(port: UInt16)
    case notInstalled
    case partial(missing: [String])
    case unreadable(String)
}

public enum ClaudeHookInstallerError: Error, Sendable {
    case unreadableSettings(String)
    case unexpectedShape(String)
}

/// Adds and removes T3Notch's entries in `~/.claude/settings.json`.
///
/// The file is shared with every other hook consumer on the machine, so it is
/// read, modified and written back as one JSON document: unknown top-level keys
/// survive untouched, existing hook entries are never rewritten, and only
/// entries whose command names our own URL are ever removed.
public struct ClaudeHookInstaller: Sendable {
    /// Every event the notch listens to. Order is the write order.
    public static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Notification",
        "Stop",
        "SubagentStop",
        "SessionEnd",
    ]

    /// Substring identifying our entries regardless of port.
    static let marker = ClaudeHookServer.hookPath
    /// The held approval curl waits ~2 min; the notch answers `ask` before that.
    static let approvalTimeoutSeconds = 120

    private let settingsURL: URL

    public init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    ) {
        self.settingsURL = settingsURL
    }

    public var backupURL: URL {
        settingsURL.deletingLastPathComponent()
            .appendingPathComponent(settingsURL.lastPathComponent + ".t3notch-bak")
    }

    public func install(port: UInt16) throws {
        var document = try readDocument()
        var hooks = document["hooks"] as? [String: Any] ?? [:]

        for event in Self.events {
            var groups = ((hooks[event] as? [Any]) ?? []).compactMap(strippingOwnHooks)
            groups.append(group(for: event, port: port))
            hooks[event] = groups
        }
        document["hooks"] = hooks

        try writeBackupIfNeeded()
        try write(document)
    }

    public func uninstall() throws {
        var document = try readDocument()
        guard var hooks = document["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard let groups = value as? [Any], groups.contains(where: isOwnGroup) else { continue }
            let remaining = groups.compactMap(strippingOwnHooks)
            // An array we emptied did not exist before us.
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }
        if hooks.isEmpty {
            document.removeValue(forKey: "hooks")
        } else {
            document["hooks"] = hooks
        }
        try write(document)
    }

    public func status() -> ClaudeHookStatus {
        let document: [String: Any]
        do {
            document = try readDocument()
        } catch {
            return .unreadable(String(describing: error))
        }
        let hooks = document["hooks"] as? [String: Any] ?? [:]

        var ports: Set<UInt16> = []
        var missing: [String] = []
        for event in Self.events {
            let groups = (hooks[event] as? [Any]) ?? []
            let commands = groups.flatMap(ownCommands)
            if commands.isEmpty {
                missing.append(event)
            } else {
                ports.formUnion(commands.compactMap(Self.port(inCommand:)))
            }
        }

        if missing.count == Self.events.count { return .notInstalled }
        if !missing.isEmpty { return .partial(missing: missing) }
        // Several ports means a half-finished reinstall; treat it as partial so
        // the app offers to install again.
        guard ports.count == 1, let port = ports.first else {
            return .partial(missing: [])
        }
        return .installed(port: port)
    }

    // MARK: - Entry shapes

    private func group(for event: String, port: UInt16) -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "command": command(for: event, port: port)]
        if event == "PermissionRequest" {
            hook["timeout"] = Self.approvalTimeoutSeconds
        }
        return ["matcher": "*", "hooks": [hook]]
    }

    /// `--noproxy "*"`: curl honours `http_proxy`/`all_proxy` even for loopback,
    /// so an exported proxy would silently break every hook.
    private func command(for event: String, port: UInt16) -> String {
        let url = "http://127.0.0.1:\(port)\(Self.marker)"
        if event == "PermissionRequest" {
            // curl's stdout IS the decision document, so nothing may be appended
            // to it and the exit code must stay curl's own.
            return "/bin/sh -c 'curl -s --noproxy \"*\" -m \(Self.approvalTimeoutSeconds) -X POST "
                + "-H \"Content-Type: application/json\" --data-binary @- \(url)'"
        }
        return "/bin/sh -c 'curl -s --noproxy \"*\" -m 5 -X POST "
            + "-H \"Content-Type: application/json\" "
            + "--data-binary @- \(url) 2>/dev/null; exit 0'"
    }

    private func isOwnGroup(_ group: Any) -> Bool {
        !ownCommands(group).isEmpty
    }

    /// Removes only our own hook entries, keeping any third-party hook that
    /// shares the matcher group; `nil` means the group held nothing else.
    private func strippingOwnHooks(_ group: Any) -> Any? {
        guard var object = group as? [String: Any],
              let hooks = object["hooks"] as? [Any]
        else { return group }
        let remaining = hooks.filter { entry in
            guard let hook = entry as? [String: Any],
                  let command = hook["command"] as? String
            else { return true }
            return !command.contains(Self.marker)
        }
        guard remaining.count != hooks.count else { return group }
        guard !remaining.isEmpty else { return nil }
        object["hooks"] = remaining
        return object
    }

    private func ownCommands(_ group: Any) -> [String] {
        guard let object = group as? [String: Any],
              let hooks = object["hooks"] as? [Any]
        else { return [] }
        return hooks.compactMap { entry in
            guard let hook = entry as? [String: Any],
                  let command = hook["command"] as? String,
                  command.contains(Self.marker)
            else { return nil }
            return command
        }
    }

    static func port(inCommand command: String) -> UInt16? {
        guard let range = command.range(of: "127.0.0.1:") else { return nil }
        let digits = command[range.upperBound...].prefix { $0.isNumber }
        return UInt16(digits)
    }

    // MARK: - File IO

    private func readDocument() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw ClaudeHookInstallerError.unreadableSettings(String(describing: error))
        }
        guard !data.isEmpty else { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let document = parsed as? [String: Any] else {
            throw ClaudeHookInstallerError.unexpectedShape("settings.json is not a JSON object")
        }
        return document
    }

    private func writeBackupIfNeeded() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: settingsURL.path),
              !manager.fileExists(atPath: backupURL.path)
        else { return }
        try manager.copyItem(at: settingsURL, to: backupURL)
    }

    private func write(_ document: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
