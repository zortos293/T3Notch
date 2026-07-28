import Foundation

/// One rollout file plus the facts the transport routes on.
public struct CodexRollout: Sendable, Equatable {
    public let sessionId: String
    public let url: URL
    public let modifiedAt: Date
    public let isLive: Bool
    /// Process still running this session, when the process manager knows one.
    public let ownerPid: Int?

    public init(
        sessionId: String,
        url: URL,
        modifiedAt: Date,
        isLive: Bool,
        ownerPid: Int? = nil
    ) {
        self.sessionId = sessionId
        self.url = url
        self.modifiedAt = modifiedAt
        self.isLive = isLive
        self.ownerPid = ownerPid
    }
}

/// Finds the rollouts worth tailing under `~/.codex/sessions/YYYY/MM/DD`.
///
/// Codex writes no end-of-session record, so liveness is inferred: a rollout
/// touched inside `liveWindow`, or one whose process is still in the process
/// manager. The day directories are re-resolved on every scan, which is what
/// carries the transport across midnight.
public final class CodexRolloutScanner: @unchecked Sendable {
    private let codexHome: URL
    private let liveWindow: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        codexHome: URL,
        liveWindow: TimeInterval = 1800,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.codexHome = codexHome
        self.liveWindow = liveWindow
        self.now = now
    }

    public var sessionsDirectory: URL {
        codexHome.appendingPathComponent("sessions")
    }

    /// Every day directory, not just recent ones: resuming a session appends to
    /// the rollout in its *original* date directory, so a conversation picked
    /// back up weeks later goes live in a folder named for the day it started.
    /// Liveness comes from file mtime, never from the folder date.
    public func dayDirectories() -> [URL] {
        var directories: [URL] = []
        let root = sessionsDirectory
        // Listed by path, not by URL: temp/symlinked homes (/var vs /private/var)
        // make the URL variant come back empty.
        for year in Self.numericChildren(of: root.path) {
            let yearURL = root.appendingPathComponent(year)
            for month in Self.numericChildren(of: yearURL.path) {
                let monthURL = yearURL.appendingPathComponent(month)
                for day in Self.numericChildren(of: monthURL.path) {
                    directories.append(monthURL.appendingPathComponent(day))
                }
            }
        }
        // Zero-padded components make lexicographic order chronological.
        return directories.sorted { $0.path < $1.path }
    }

    private static func numericChildren(of path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    public func scan() -> [CodexRollout] {
        let livePids = liveProcessSessionIds()
        let cutoff = now().addingTimeInterval(-liveWindow)
        var rollouts: [String: CodexRollout] = [:]

        for directory in dayDirectories() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

            for name in names where name.hasSuffix(".jsonl") {
                guard let sessionId = Self.sessionId(fromFileName: name) else { continue }
                let url = directory.appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
                let ownerPid = livePids[sessionId]
                let rollout = CodexRollout(
                    sessionId: sessionId,
                    url: url,
                    modifiedAt: modifiedAt,
                    isLive: modifiedAt > cutoff || ownerPid != nil,
                    ownerPid: ownerPid
                )
                // A session id can only have one rollout; keep the newest file.
                if let existing = rollouts[sessionId], existing.modifiedAt >= modifiedAt { continue }
                rollouts[sessionId] = rollout
            }
        }

        return rollouts.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// `rollout-2026-07-27T16-23-38-<uuid>.jsonl` — the timestamp carries dashes
    /// too, so the id is the last five dash-separated components.
    static func sessionId(fromFileName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(".jsonl".count)
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    /// session id -> pid, for the sessions the process manager still lists with a
    /// running process.
    private func liveProcessSessionIds() -> [String: Int] {
        let url = codexHome
            .appendingPathComponent("process_manager")
            .appendingPathComponent("chat_processes.json")
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([JSONValue].self, from: data)
        else { return [:] }

        var result: [String: Int] = [:]
        for entry in entries {
            guard let sessionId = entry["conversationId"]?.stringValue else { continue }
            guard let pid = Self.pid(from: entry["osPid"]) ?? Self.pid(from: entry["processId"])
            else { continue }
            guard Self.isRunning(pid: pid) else { continue }
            result[sessionId] = pid
        }
        return result
    }

    private static func pid(from value: JSONValue?) -> Int? {
        if let number = value?.numberValue { return Int(number) }
        if let string = value?.stringValue { return Int(string) }
        return nil
    }

    static func isRunning(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        // EPERM means the process exists but belongs to somebody else.
        return errno == EPERM
    }
}
