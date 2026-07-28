import Foundation
import os

/// Watches Codex CLI sessions by tailing their rollout files.
///
/// Status-only: Codex never persists approvals or questions, and it exposes no
/// local command channel, so nothing here can be answered from the notch.
public final class CodexTransport: AgentTransport, @unchecked Sendable {
    private struct SessionEntry {
        var mapper: CodexRolloutMapper
        var url: URL
        var tailer: JSONLTailer
        var ownerPid: Int?
        /// Last scan that still called the rollout live; starts the settle grace.
        var lastLiveAt: Date
        var isLive: Bool
    }

    private struct State {
        var sessions: [String: SessionEntry] = [:]
        var focusedThreadId: String?
        var isExpanded = false
        var connectionState: ConnectionState = .connecting
        var snapshotSequence = 0
        var lastShell: ShellSnapshot?
        var detailContinuations: [String: AsyncStream<ThreadDetailSnapshot>.Continuation] = [:]
        var detailSequences: [String: Int] = [:]
        var dayDirectories: [URL] = []
        var watchers: [DirectoryWatcher] = []
        var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)?
        var stopped = false
    }

    private let scanner: CodexRolloutScanner
    /// A finished session stays on screen long enough to read "Done" before it
    /// disappears.
    private let settleGrace: TimeInterval
    private let pollInterval: UInt64
    private let queue = DispatchQueue(label: "gg.t3tools.t3notch.codex")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let shellContinuation: AsyncStream<ShellSnapshot>.Continuation
    private let gitRoots = OSAllocatedUnfairLock(initialState: [String: String]())
    private var pollTask: Task<Void, Never>?

    public let shell: AsyncStream<ShellSnapshot>

    public var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)? {
        get { state.withLock(\.onConnectionStateChange) }
        set { state.withLock { $0.onConnectionStateChange = newValue } }
    }

    public var connectionState: ConnectionState {
        state.withLock(\.connectionState)
    }

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex"),
        liveWindow: TimeInterval = 1800,
        settleGrace: TimeInterval = 60,
        pollNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.scanner = CodexRolloutScanner(codexHome: codexHome, liveWindow: liveWindow)
        self.settleGrace = settleGrace
        self.pollInterval = pollNanoseconds
        let (stream, continuation) = AsyncStream<ShellSnapshot>.makeStream()
        self.shell = stream
        self.shellContinuation = continuation
        queue.async { [weak self] in self?.refresh() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                guard let self, !Task.isCancelled else { return }
                queue.async { [weak self] in self?.refresh() }
            }
        }
    }

    deinit {
        stop()
    }

    public func threadDetail(_ id: String) -> AsyncStream<ThreadDetailSnapshot> {
        let (stream, continuation) = AsyncStream<ThreadDetailSnapshot>.makeStream()
        state.withLock { state in
            state.detailContinuations[id]?.finish()
            state.detailContinuations[id] = continuation
        }
        queue.async { [weak self] in self?.emitDetail(for: id) }
        return stream
    }

    public func dispatch(_ command: DispatchCommand) async throws {
        throw AgentTransportError.unsupported("Codex sessions cannot be driven from the notch")
    }

    public func requestImmediatePoll() {
        queue.async { [weak self] in
            guard let self else { return }
            let tailers = state.withLock { $0.sessions.values.map(\.tailer) }
            for tailer in tailers { tailer.poke() }
            refresh()
        }
    }

    /// Focus only picks the fast-refresh thread. It must not touch the detail
    /// continuations, or the stream the UI is iterating would end.
    public func setFocusedThread(_ id: String?) {
        state.withLock { $0.focusedThreadId = id }
    }

    public func setExpanded(_ expanded: Bool) {
        state.withLock { $0.isExpanded = expanded }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        let (tailers, watchers): ([JSONLTailer], [DirectoryWatcher]) = state.withLock { state in
            state.stopped = true
            let tailers = state.sessions.values.map(\.tailer)
            let watchers = state.watchers
            state.watchers.removeAll()
            state.sessions.removeAll()
            for continuation in state.detailContinuations.values { continuation.finish() }
            state.detailContinuations.removeAll()
            return (tailers, watchers)
        }
        for watcher in watchers { watcher.stop() }
        for tailer in tailers { tailer.stop() }
        shellContinuation.finish()
    }

    // MARK: - Discovery

    private func refresh() {
        guard !state.withLock(\.stopped) else { return }

        let sessionsExist = FileManager.default.fileExists(
            atPath: scanner.sessionsDirectory.path
        )
        setConnectionState(sessionsExist ? .connected : .disconnected)
        refreshWatchers()

        let rollouts = scanner.scan()
        let now = Date()

        let (started, dropped): ([JSONLTailer], [JSONLTailer]) = state.withLock { state in
            var started: [JSONLTailer] = []
            var seen: Set<String> = []
            for rollout in rollouts where rollout.isLive {
                seen.insert(rollout.sessionId)
                if var entry = state.sessions[rollout.sessionId] {
                    entry.lastLiveAt = now
                    entry.isLive = true
                    entry.ownerPid = rollout.ownerPid
                    state.sessions[rollout.sessionId] = entry
                    continue
                }
                let sessionId = rollout.sessionId
                let tailer = JSONLTailer(url: rollout.url, queue: queue) { [weak self] lines in
                    self?.apply(lines: lines, to: sessionId)
                }
                state.sessions[sessionId] = SessionEntry(
                    mapper: CodexRolloutMapper(sessionId: sessionId),
                    url: rollout.url,
                    tailer: tailer,
                    ownerPid: rollout.ownerPid,
                    lastLiveAt: now,
                    isLive: true
                )
                started.append(tailer)
            }

            var dropped: [JSONLTailer] = []
            for (sessionId, entry) in state.sessions where !seen.contains(sessionId) {
                if entry.isLive {
                    var entry = entry
                    entry.isLive = false
                    entry.lastLiveAt = now
                    state.sessions[sessionId] = entry
                    continue
                }
                guard now.timeIntervalSince(entry.lastLiveAt) > settleGrace else { continue }
                dropped.append(entry.tailer)
                state.sessions.removeValue(forKey: sessionId)
                state.detailContinuations.removeValue(forKey: sessionId)?.finish()
                state.detailSequences.removeValue(forKey: sessionId)
            }
            return (started, dropped)
        }

        for tailer in dropped { tailer.stop() }
        for tailer in started { tailer.start() }
        emitShell()
    }

    /// The swap runs under the lock — including `start()` — because `stop()` is
    /// called from the main actor: two threads writing the same array corrupts
    /// it, and starting outside the lock could leave watchers running with open
    /// descriptors after shutdown.
    private func refreshWatchers() {
        // Directory events only announce new files, and new rollouts only land
        // in the newest directories — appends to a resumed session's old file
        // are caught by the poll's mtime sweep, so watching history buys
        // nothing and costs a descriptor per folder.
        let directories = Array(scanner.dayDirectories().suffix(2))
        let previous: [DirectoryWatcher] = state.withLock { state in
            guard !state.stopped, state.dayDirectories != directories else { return [] }
            state.dayDirectories = directories
            let previous = state.watchers
            state.watchers = directories.map { directory in
                DirectoryWatcher(url: directory, queue: queue) { [weak self] in
                    self?.refresh()
                }
            }
            for watcher in state.watchers { try? watcher.start() }
            return previous
        }
        for watcher in previous { watcher.stop() }
    }

    private func apply(lines: [Data], to sessionId: String) {
        let changed = state.withLock { state -> Bool in
            guard var entry = state.sessions[sessionId] else { return false }
            var changed = false
            for line in lines {
                if entry.mapper.ingest(line: line) { changed = true }
            }
            state.sessions[sessionId] = entry
            return changed
        }
        guard changed else { return }
        emitShell()
        emitDetail(for: sessionId)
    }

    // MARK: - Snapshots

    private func emitShell() {
        let states = state.withLock { state in
            state.sessions.values.map { ($0.mapper.state, $0.ownerPid, $0.isLive) }
        }
        var projectsByCwd: [String: ProjectShell] = [:]
        var built: [ThreadShell] = []
        for (session, ownerPid, isLive) in states {
            built.append(thread(for: session, ownerPid: ownerPid, isLive: isLive))
            let cwd = session.cwd ?? "codex"
            if projectsByCwd[cwd] == nil { projectsByCwd[cwd] = project(for: cwd) }
        }
        built.sort { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        let threads = built
        let projects = projectsByCwd.values.sorted { $0.id < $1.id }

        let updatedAt = threads.map(\.updatedAt).max() ?? ISO8601DateFormatter().string(from: Date())
        let snapshot: ShellSnapshot? = state.withLock { state in
            let candidate = ShellSnapshot(
                snapshotSequence: state.snapshotSequence,
                projects: projects,
                threads: threads,
                updatedAt: updatedAt
            )
            guard state.lastShell != candidate else { return nil }
            state.snapshotSequence += 1
            var next = candidate
            next.snapshotSequence = state.snapshotSequence
            state.lastShell = next
            return next
        }
        guard let snapshot else { return }
        shellContinuation.yield(snapshot)
    }

    private func emitDetail(for sessionId: String) {
        let payload: (AsyncStream<ThreadDetailSnapshot>.Continuation, ThreadDetailSnapshot)? =
            state.withLock { state in
                guard let continuation = state.detailContinuations[sessionId],
                      let entry = state.sessions[sessionId]
                else { return nil }
                let sequence = (state.detailSequences[sessionId] ?? 0) + 1
                state.detailSequences[sessionId] = sequence
                let session = entry.mapper.state
                let shell = thread(for: session, ownerPid: entry.ownerPid, isLive: entry.isLive)
                let detail = ThreadDetail(
                    id: shell.id,
                    projectId: shell.projectId,
                    title: shell.title,
                    modelSelection: shell.modelSelection,
                    branch: shell.branch,
                    latestTurn: shell.latestTurn,
                    createdAt: session.startedAt,
                    updatedAt: shell.updatedAt,
                    activities: session.activities,
                    session: shell.session
                )
                return (
                    continuation,
                    ThreadDetailSnapshot(snapshotSequence: sequence, thread: detail)
                )
            }
        guard let payload else { return }
        payload.0.yield(payload.1)
    }

    private func thread(
        for session: CodexSessionState,
        ownerPid: Int?,
        isLive: Bool
    ) -> ThreadShell {
        let cwd = session.cwd ?? "codex"
        let updatedAt = session.updatedAt ?? session.startedAt ?? ""
        // A rollout that stopped being written mid-turn has no completion record,
        // so liveness is what settles it.
        let status = isLive ? session.status : "stopped"
        return ThreadShell(
            id: session.sessionId,
            projectId: cwd,
            title: session.title ?? Self.lastComponent(cwd),
            modelSelection: ModelSelection(
                instanceId: "codex",
                provider: "codex",
                model: session.model ?? "codex"
            ),
            branch: session.branch,
            latestTurn: session.latestTurn,
            createdAt: session.startedAt,
            updatedAt: updatedAt,
            settledAt: isLive ? session.settledAt : (session.settledAt ?? updatedAt),
            session: Session(
                threadId: session.sessionId,
                status: status,
                providerName: "codex",
                providerInstanceId: "codex",
                activeTurnId: session.currentTurnId,
                updatedAt: updatedAt
            ),
            hasPendingApprovals: false,
            hasPendingUserInput: false,
            ownerPid: ownerPid
        )
    }

    private func project(for cwd: String) -> ProjectShell {
        ProjectShell(id: cwd, title: Self.lastComponent(cwd), workspaceRoot: gitRoot(of: cwd))
    }

    private func setConnectionState(_ next: ConnectionState) {
        let callback: (@Sendable (ConnectionState) -> Void)? = state.withLock { state in
            guard state.connectionState != next else { return nil }
            state.connectionState = next
            return state.onConnectionStateChange
        }
        callback?(next)
    }

    private static func lastComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// MergeWatcher needs the worktree root, and a cwd is often a subdirectory.
    private func gitRoot(of cwd: String) -> String {
        if let cached = gitRoots.withLock({ $0[cwd] }) { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var root = cwd
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, !output.isEmpty { root = output }
        }
        let resolved = root
        gitRoots.withLock { $0[cwd] = resolved }
        return resolved
    }
}
