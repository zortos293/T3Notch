import Foundation
import os

/// One `~/.claude/sessions/<pid>.json` entry. Only `pid`/`sessionId`/`cwd` are
/// relied on; the format is unofficial, so everything else decodes optionally.
public struct ClaudeSessionEntry: Codable, Sendable, Equatable {
    public var pid: Int
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var status: String?
    public var version: String?
    public var kind: String?
    public var startedAt: String?
    public var updatedAt: String?
    public var statusUpdatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, name, status, version, kind
        case startedAt, updatedAt, statusUpdatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int.self, forKey: .pid)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decode(String.self, forKey: .cwd)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        startedAt = Self.timestamp(container, .startedAt)
        updatedAt = Self.timestamp(container, .updatedAt)
        statusUpdatedAt = Self.timestamp(container, .statusUpdatedAt)
    }

    /// The registry writes these as millisecond epochs today, but the format is
    /// unofficial and the fixture history shows strings too — accept both, and
    /// never fail the whole entry over a timestamp.
    private static func timestamp(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let millis = try? container.decodeIfPresent(Double.self, forKey: key) {
            return ClaudeTimestamp.iso8601(fromMilliseconds: millis)
        }
        return nil
    }

    public init(
        pid: Int,
        sessionId: String,
        cwd: String,
        name: String? = nil,
        status: String? = nil,
        version: String? = nil,
        kind: String? = nil,
        startedAt: String? = nil,
        updatedAt: String? = nil,
        statusUpdatedAt: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.status = status
        self.version = version
        self.kind = kind
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
    }

    /// Registry `status` vocabulary is unofficial: only "busy" is verified, so
    /// anything else reads as idle rather than failing.
    public var isBusy: Bool { status == "busy" }

    /// Claude also registers non-interactive runs (`claude -p`); those have no
    /// terminal to bring forward and are skipped.
    public var isInteractive: Bool { kind == nil || kind == "interactive" }
}

/// Watches `~/.claude/sessions` and reports the live interactive sessions.
public final class ClaudeSessionRegistry: @unchecked Sendable {
    private struct State {
        var entries: [ClaudeSessionEntry] = []
        var watcher: DirectoryWatcher?
        var started = false
        var stopped = false
    }

    private let directory: URL
    private let queue: DispatchQueue
    private let pollInterval: DispatchTimeInterval
    private let isProcessAlive: @Sendable (Int) -> Bool
    private let onChange: @Sendable ([ClaudeSessionEntry]) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        directory: URL,
        queue: DispatchQueue,
        pollInterval: DispatchTimeInterval = .seconds(2),
        isProcessAlive: @escaping @Sendable (Int) -> Bool = ClaudeSessionRegistry.processIsAlive,
        onChange: @escaping @Sendable ([ClaudeSessionEntry]) -> Void
    ) {
        self.directory = directory
        self.queue = queue
        self.pollInterval = pollInterval
        self.isProcessAlive = isProcessAlive
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public var entries: [ClaudeSessionEntry] { state.withLock(\.entries) }

    public func start() {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.stopped, !state.started else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }

        let watcher = DirectoryWatcher(url: directory, queue: queue) { [weak self] in
            self?.rescan()
        }
        state.withLock { $0.watcher = watcher }
        // The directory may not exist yet; the poll below picks it up later.
        try? watcher.start()

        queue.async { [weak self] in self?.scanAndSchedule() }
    }

    public func stop() {
        let watcher: DirectoryWatcher? = state.withLock { state in
            state.stopped = true
            let watcher = state.watcher
            state.watcher = nil
            return watcher
        }
        watcher?.stop()
    }

    /// Forces an immediate rescan (hook nudge, `requestImmediatePoll`).
    public func rescan() {
        queue.async { [weak self] in self?.scan() }
    }

    /// `kill(pid, 0)` — EPERM means the process exists under another user.
    public static func processIsAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Queue-confined work

    private func scanAndSchedule() {
        guard !state.withLock(\.stopped) else { return }
        scan()
        // The watcher misses in-place rewrites of an existing file on some
        // filesystems, and pid liveness has no event at all.
        queue.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.scanAndSchedule()
        }
    }

    private func scan() {
        guard !state.withLock(\.stopped) else { return }
        let entries = readEntries()
        let changed = state.withLock { state -> Bool in
            guard state.entries != entries else { return false }
            state.entries = entries
            return true
        }
        Logger(subsystem: "gg.t3tools.t3notch", category: "trace")
            .debug("registry: scan \(entries.count) entries changed=\(changed)")
        if changed { onChange(entries) }
    }

    private func readEntries() -> [ClaudeSessionEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        var entries: [ClaudeSessionEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(ClaudeSessionEntry.self, from: data),
                  entry.isInteractive,
                  isProcessAlive(entry.pid)
            else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.sessionId < $1.sessionId }
    }
}
