import Foundation
import Testing
@testable import T3NotchCore

@Suite("Claude hook installer")
struct ClaudeHookInstallerTests {
    @Test func appendsWithoutTouchingThirdPartyHooks() throws {
        let settings = try temporarySettings()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let before = try document(at: settings)
        let installer = ClaudeHookInstaller(settingsURL: settings)

        try installer.install(port: 19725)
        let after = try document(at: settings)

        // Unknown top-level keys round-trip untouched.
        for key in ["env", "enabledPlugins", "statusLine", "permissions"] {
            #expect(equal(after[key], before[key]), "\(key) changed")
        }
        let beforeHooks = try #require(before["hooks"] as? [String: Any])
        let afterHooks = try #require(after["hooks"] as? [String: Any])
        // An event we do not use stays byte-identical.
        #expect(equal(afterHooks["PreCompact"], beforeHooks["PreCompact"]))

        for event in ClaudeHookInstaller.events {
            let existing = (beforeHooks[event] as? [Any]) ?? []
            let groups = try #require(afterHooks[event] as? [Any])
            #expect(groups.count == existing.count + 1, "\(event) group count")
            for (index, group) in existing.enumerated() {
                #expect(equal(groups[index], group), "\(event) entry \(index) rewritten")
            }
            #expect(commands(in: groups).filter { $0.contains("/t3notch/hook") }.count == 1)
        }
    }

    @Test func entriesMatchTheHookContract() throws {
        let settings = try temporarySettings()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let installer = ClaudeHookInstaller(settingsURL: settings)
        try installer.install(port: 19725)
        let hooks = try #require(try document(at: settings)["hooks"] as? [String: Any])

        let stop = try #require(ownHook(in: hooks["Stop"]))
        #expect(stop["type"] as? String == "command")
        let stopCommand = try #require(stop["command"] as? String)
        #expect(stopCommand.contains("http://127.0.0.1:19725/t3notch/hook"))
        #expect(stopCommand.contains("-m 5"))
        #expect(stopCommand.contains("exit 0"))
        // curl proxies loopback too when http_proxy is exported.
        #expect(stopCommand.contains("--noproxy \"*\""))
        #expect(stop["timeout"] == nil)

        // curl's stdout is the decision document, so nothing may be appended to
        // it and the hook needs room to wait for an answer.
        let permission = try #require(ownHook(in: hooks["PermissionRequest"]))
        let permissionCommand = try #require(permission["command"] as? String)
        #expect(permissionCommand.contains("-m 120"))
        #expect(permissionCommand.contains("--noproxy \"*\""))
        #expect(!permissionCommand.contains("exit 0"))
        #expect(!permissionCommand.contains("2>/dev/null"))
        #expect(permission["timeout"] as? Int == 120)
    }

    /// Claude Code's own `/hooks` writer merges into the group that already
    /// matches, so our entry can end up sharing one with a third-party hook.
    /// Reinstalling or removing must take only our own entry with it.
    @Test func keepsThirdPartyHooksSharingOurMatcherGroup() throws {
        let settings = try temporarySettings()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let installer = ClaudeHookInstaller(settingsURL: settings)
        try installer.install(port: 19725)

        // Merge a neighbour into the group holding our Stop hook.
        var updated = try document(at: settings)
        var hooks = try #require(updated["hooks"] as? [String: Any])
        var groups = try #require(hooks["Stop"] as? [Any])
        let index = try #require(
            groups.firstIndex { group in
                commands(in: [group]).contains { $0.contains("/t3notch/hook") }
            }
        )
        var group = try #require(groups[index] as? [String: Any])
        var entries = try #require(group["hooks"] as? [Any])
        entries.append(["type": "command", "command": "~/bin/notify-done.sh"])
        group["hooks"] = entries
        groups[index] = group
        hooks["Stop"] = groups
        updated["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: updated).write(to: settings)

        try installer.install(port: 20001)
        var stop = try #require(try document(at: settings)["hooks"] as? [String: Any])["Stop"]
        #expect(commands(in: try #require(stop as? [Any])).contains("~/bin/notify-done.sh"))

        try installer.uninstall()
        stop = try #require(try document(at: settings)["hooks"] as? [String: Any])["Stop"]
        let remaining = commands(in: try #require(stop as? [Any]))
        #expect(remaining.contains("~/bin/notify-done.sh"))
        #expect(!remaining.contains { $0.contains("/t3notch/hook") })
    }

    @Test func installIsIdempotentAndFollowsThePort() throws {
        let settings = try temporarySettings()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let installer = ClaudeHookInstaller(settingsURL: settings)

        try installer.install(port: 19725)
        let once = try document(at: settings)
        try installer.install(port: 19725)
        #expect(equal(try document(at: settings), once))
        #expect(installer.status() == .installed(port: 19725))

        try installer.install(port: 20001)
        #expect(installer.status() == .installed(port: 20001))
        let hooks = try #require(try document(at: settings)["hooks"] as? [String: Any])
        for event in ClaudeHookInstaller.events {
            let ours = commands(in: (hooks[event] as? [Any]) ?? [])
                .filter { $0.contains("/t3notch/hook") }
            #expect(ours.count == 1)
            #expect(ours[0].contains("127.0.0.1:20001"))
        }
    }

    @Test func uninstallRestoresTheOriginalDocument() throws {
        let settings = try temporarySettings()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let before = try document(at: settings)
        let installer = ClaudeHookInstaller(settingsURL: settings)

        try installer.install(port: 19725)
        try installer.uninstall()

        #expect(equal(try document(at: settings), before))
        #expect(installer.status() == .notInstalled)
        // The one-shot backup stays behind as the pre-install copy.
        #expect(FileManager.default.fileExists(atPath: installer.backupURL.path))
    }

    @Test func statusReportsPartialInstalls() throws {
        let settings = try temporarySettings()
        defer { try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }
        let installer = ClaudeHookInstaller(settingsURL: settings)
        #expect(installer.status() == .notInstalled)

        try installer.install(port: 19725)
        var updated = try document(at: settings)
        var hooks = try #require(updated["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "SessionEnd")
        updated["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: updated).write(to: settings)

        #expect(installer.status() == .partial(missing: ["SessionEnd"]))
    }

    @Test func installCreatesMissingSettings() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t3notch-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let installer = ClaudeHookInstaller(settingsURL: settings)

        try installer.install(port: 19725)
        #expect(installer.status() == .installed(port: 19725))
        // Nothing existed to back up.
        #expect(!FileManager.default.fileExists(atPath: installer.backupURL.path))
    }
}

// MARK: - Helpers

private func temporarySettings() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t3notch-hooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let settings = directory.appendingPathComponent("settings.json")
    let fixture = try #require(
        Bundle.module.url(
            forResource: "claude_settings_thirdparty",
            withExtension: "json",
            subdirectory: "Fixtures"
        )
    )
    try FileManager.default.copyItem(at: fixture, to: settings)
    return settings
}

private func document(at url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
}

private func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (lhs?, rhs?): return NSDictionary(dictionary: ["v": lhs])
        .isEqual(to: ["v": rhs])
    default: return false
    }
}

private func commands(in groups: [Any]) -> [String] {
    groups.flatMap { group -> [String] in
        guard let object = group as? [String: Any],
              let hooks = object["hooks"] as? [Any]
        else { return [] }
        return hooks.compactMap { ($0 as? [String: Any])?["command"] as? String }
    }
}

private func ownHook(in event: Any?) -> [String: Any]? {
    guard let groups = event as? [Any] else { return nil }
    for group in groups {
        guard let object = group as? [String: Any],
              let hooks = object["hooks"] as? [Any]
        else { continue }
        for entry in hooks {
            guard let hook = entry as? [String: Any],
                  let command = hook["command"] as? String,
                  command.contains("/t3notch/hook")
            else { continue }
            return hook
        }
    }
    return nil
}
