import Foundation
import os

/// Watches locally running Claude Code sessions.
///
/// The session registry (`~/.claude/sessions/<pid>.json`) is the roster; the
/// per-session transcript is the only source of activities. Hooks, when the
/// listener is installed, add approvals — which transcripts do not carry — and
/// nudge the tailers.
public final class ClaudeCodeTransport: AgentTransport, @unchecked Sendable {
    private struct SessionState {
        var entry: ClaudeSessionEntry
        var mapper: ClaudeTranscriptMapper
        var tailer: JSONLTailer?
        var workspaceRoot: String?
        var pendingApprovals: [String: String] = [:]  // requestId -> requestKind
        var discoveredAt: String
        /// Set when the registry entry disappears; the card lingers briefly so
        /// "Done" is visible before it drops off.
        var settledAt: String?
        var droppedAt: Date?
        var detailSequence = 0
        var lastDetail: ThreadDetail?
    }

    private struct State {
        var sessions: [String: SessionState] = [:]
        var order: [String] = []
        var gitRoots: [String: String] = [:]
        var snapshotSequence = 0
        var lastSnapshot: ShellSnapshot?
        var focusedThreadId: String?
        var isExpanded = false
        var connectionState: ConnectionState = .connecting
        var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)?
        var detailContinuations: [String: AsyncStream<ThreadDetailSnapshot>.Continuation] = [:]
        var stopped = false
    }

    /// How long a vanished session stays on screen after its process exits.
    private static let completedGrace: TimeInterval = 60
    private static let tickInterval: DispatchTimeInterval = .seconds(2)

    private let claudeHome: URL
    private let hookServer: ClaudeHookServer?
    private let queue = DispatchQueue(label: "gg.t3tools.t3notch.claude-transport")
    private let startedAt = ClaudeTimestamp.now()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let shellContinuation: AsyncStream<ShellSnapshot>.Continuation
    public let shell: AsyncStream<ShellSnapshot>
    private var registry: ClaudeSessionRegistry?

    /// The aggregator installs this from whichever thread built it while the
    /// registry scan is already running on the transport queue, so it lives
    /// under the lock like every other transport's.
    public var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)? {
        get { state.withLock(\.onConnectionStateChange) }
        set { state.withLock { $0.onConnectionStateChange = newValue } }
    }

    public var connectionState: ConnectionState { state.withLock(\.connectionState) }

    public init(
        claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude"),
        hookServer: ClaudeHookServer? = nil,
        isProcessAlive: @escaping @Sendable (Int) -> Bool = ClaudeSessionRegistry.processIsAlive
    ) {
        self.claudeHome = claudeHome
        self.hookServer = hookServer
        let (stream, continuation) = AsyncStream<ShellSnapshot>.makeStream()
        self.shell = stream
        self.shellContinuation = continuation

        let registry = ClaudeSessionRegistry(
            directory: claudeHome.appendingPathComponent("sessions"),
            queue: queue,
            isProcessAlive: isProcessAlive
        ) { [weak self] entries in
            self?.applyRegistry(entries)
        }
        self.registry = registry

        hookServer?.onApprovalRequest = { [weak self] context in
            self?.approvalRequested(context)
        }
        hookServer?.onApprovalResolved = { [weak self] requestId, _ in
            self?.approvalResolved(requestId)
        }
        hookServer?.onEvent = { [weak self] event in
            self?.hookNudge(sessionId: event.sessionId)
        }

        refreshConnectionState()
        registry.start()
        scheduleTick()
    }

    deinit {
        stop()
    }

    // MARK: - AgentTransport

    public func threadDetail(_ id: String) -> AsyncStream<ThreadDetailSnapshot> {
        let (stream, continuation) = AsyncStream<ThreadDetailSnapshot>.makeStream()
        let snapshot: ThreadDetailSnapshot? = state.withLock { state in
            state.detailContinuations[id]?.finish()
            guard !state.stopped else {
                continuation.finish()
                return nil
            }
            state.detailContinuations[id] = continuation
            guard var session = state.sessions[id] else { return nil }
            let detail = buildDetail(id: id, session: session)
            session.detailSequence += 1
            session.lastDetail = detail
            state.sessions[id] = session
            return ThreadDetailSnapshot(snapshotSequence: session.detailSequence, thread: detail)
        }
        if let snapshot { continuation.yield(snapshot) }
        return stream
    }

    public func dispatch(_ command: DispatchCommand) async throws {
        switch command {
        case let .approvalRespond(_, threadId, requestId, decision, _):
            guard let hookServer else {
                throw AgentTransportError.unsupported("Claude Code hooks are not installed")
            }
            guard state.withLock({ $0.sessions[threadId] }) != nil else {
                throw AgentTransportError.threadNotFound(threadId)
            }
            guard hookServer.resolve(requestId: requestId, decision: decision) else {
                throw AgentTransportError.requestExpired(requestId)
            }
        case .userInputRespond:
            throw AgentTransportError.unsupported(
                "Claude Code questions can only be answered in the terminal"
            )
        case .turnInterrupt:
            throw AgentTransportError.unsupported("Claude Code turns cannot be interrupted remotely")
        }
    }

    public func requestImmediatePoll() {
        registry?.rescan()
        pokeTailers(sessionId: nil)
    }

    /// Records the focused thread only. Opening the detail stream from here
    /// would replace — and end — the stream the UI is already iterating.
    public func setFocusedThread(_ id: String?) {
        state.withLock { $0.focusedThreadId = id }
    }

    public func setExpanded(_ expanded: Bool) {
        state.withLock { $0.isExpanded = expanded }
    }

    public func stop() {
        let (tailers, continuations) = state.withLock { state -> ([JSONLTailer], [AsyncStream<ThreadDetailSnapshot>.Continuation]) in
            state.stopped = true
            let tailers = state.sessions.values.compactMap(\.tailer)
            let continuations = Array(state.detailContinuations.values)
            state.sessions.removeAll()
            state.order.removeAll()
            state.detailContinuations.removeAll()
            return (tailers, continuations)
        }
        registry?.stop()
        for tailer in tailers { tailer.stop() }
        for continuation in continuations { continuation.finish() }
        shellContinuation.finish()
    }

    // MARK: - Registry

    private func applyRegistry(_ entries: [ClaudeSessionEntry]) {
        Logger(subsystem: "gg.t3tools.t3notch", category: "trace")
            .debug("claude: applyRegistry \(entries.count) entries")
        let known = state.withLock { Set($0.sessions.keys) }
        // File and process work stays outside the lock.
        var resolved: [String: (url: URL, root: String?)] = [:]
        for entry in entries {
            let needsTranscript = !known.contains(entry.sessionId)
                || state.withLock { $0.sessions[entry.sessionId]?.tailer == nil }
            guard needsTranscript, let url = transcriptURL(for: entry) else { continue }
            resolved[entry.sessionId] = (url, gitRoot(for: entry.cwd))
        }

        let now = Date()
        let timestamp = ClaudeTimestamp.now()
        let resolutions = resolved

        let (changed, started, stopped) = state.withLock { state -> (Bool, [JSONLTailer], [JSONLTailer]) in
            guard !state.stopped else { return (false, [], []) }
            var started: [JSONLTailer] = []
            var stopped: [JSONLTailer] = []
            var changed = false
            var live = Set<String>()

            for entry in entries {
                live.insert(entry.sessionId)
                if var session = state.sessions[entry.sessionId] {
                    if session.entry != entry {
                        session.entry = entry
                        changed = true
                    }
                    if session.settledAt != nil {
                        session.settledAt = nil
                        session.droppedAt = nil
                        changed = true
                    }
                    if session.tailer == nil, let resolution = resolutions[entry.sessionId] {
                        let tailer = makeTailer(sessionId: entry.sessionId, url: resolution.url)
                        session.tailer = tailer
                        session.workspaceRoot = resolution.root
                        started.append(tailer)
                    }
                    state.sessions[entry.sessionId] = session
                    continue
                }

                let resolution = resolutions[entry.sessionId]
                var session = SessionState(
                    entry: entry,
                    mapper: ClaudeTranscriptMapper(root: entry.cwd),
                    tailer: nil,
                    workspaceRoot: resolution?.root,
                    discoveredAt: entry.startedAt ?? timestamp
                )
                if let url = resolution?.url {
                    let tailer = makeTailer(sessionId: entry.sessionId, url: url)
                    session.tailer = tailer
                    started.append(tailer)
                }
                state.sessions[entry.sessionId] = session
                state.order.append(entry.sessionId)
                changed = true
            }

            for id in state.order where !live.contains(id) {
                guard var session = state.sessions[id], session.settledAt == nil else { continue }
                session.settledAt = timestamp
                session.droppedAt = now
                if let tailer = session.tailer {
                    stopped.append(tailer)
                    session.tailer = nil
                }
                state.sessions[id] = session
                changed = true
            }
            return (changed, started, stopped)
        }

        for tailer in started { tailer.start() }
        for tailer in stopped { tailer.stop() }
        if changed { emit() }
    }

    private func makeTailer(sessionId: String, url: URL) -> JSONLTailer {
        JSONLTailer(url: url, queue: queue) { [weak self] lines in
            self?.ingest(sessionId: sessionId, lines: lines)
        }
    }

    private func ingest(sessionId: String, lines: [Data]) {
        let changed = state.withLock { state -> Bool in
            guard var session = state.sessions[sessionId] else { return false }
            var changed = false
            for line in lines {
                changed = session.mapper.ingest(line: line) || changed
            }
            state.sessions[sessionId] = session
            return changed
        }
        if changed { emit() }
    }

    private func scheduleTick() {
        queue.asyncAfter(deadline: .now() + Self.tickInterval) { [weak self] in
            guard let self, !state.withLock(\.stopped) else { return }
            refreshConnectionState()
            if pruneSettledSessions() { emit() }
            scheduleTick()
        }
    }

    private func pruneSettledSessions() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.completedGrace)
        return state.withLock { state -> Bool in
            let expired = state.sessions.filter { _, session in
                guard let droppedAt = session.droppedAt else { return false }
                return droppedAt < cutoff
            }
            guard !expired.isEmpty else { return false }
            for id in expired.keys {
                state.sessions.removeValue(forKey: id)
                state.order.removeAll { $0 == id }
                state.detailContinuations[id]?.finish()
                state.detailContinuations.removeValue(forKey: id)
            }
            return true
        }
    }

    private func refreshConnectionState() {
        let readable = FileManager.default.isReadableFile(atPath: claudeHome.path)
        let newState: ConnectionState = readable ? .connected : .disconnected
        let callback: (@Sendable (ConnectionState) -> Void)? = state.withLock { state in
            guard state.connectionState != newState else { return nil }
            state.connectionState = newState
            return state.onConnectionStateChange
        }
        callback?(newState)
    }

    // MARK: - Hooks

    private func approvalRequested(_ context: ClaudeHookServer.PendingApprovalContext) {
        Logger(subsystem: "gg.t3tools.t3notch", category: "trace")
            .debug("claude: approvalRequested session=\(context.sessionId ?? "nil", privacy: .public) known=\(self.state.withLock { $0.sessions.keys.joined(separator: ",") }, privacy: .public)")
        guard let sessionId = context.sessionId else { return }
        var payload: [String: JSONValue] = [
            "requestId": .string(context.requestId),
            "requestKind": .string(context.requestKind),
        ]
        if let detail = context.detail { payload["detail"] = .string(detail) }
        let requestPayload = JSONValue.object(payload)

        let changed = state.withLock { state -> Bool in
            guard var session = state.sessions[sessionId] else { return false }
            session.pendingApprovals[context.requestId] = context.requestKind
            session.mapper.appendExternalActivity(
                id: "approval-requested-\(context.requestId)",
                kind: "approval.requested",
                tone: nil,
                summary: "Approval requested",
                payload: requestPayload,
                createdAt: context.createdAt
            )
            state.sessions[sessionId] = session
            return true
        }
        if changed { emit() }
    }

    private func approvalResolved(_ requestId: String) {
        let timestamp = ClaudeTimestamp.now()
        let changed = state.withLock { state -> Bool in
            guard let sessionId = state.sessions.first(where: { $0.value.pendingApprovals[requestId] != nil })?.key,
                  var session = state.sessions[sessionId]
            else { return false }
            let kind = session.pendingApprovals.removeValue(forKey: requestId) ?? "command"
            session.mapper.appendExternalActivity(
                id: "approval-resolved-\(requestId)",
                kind: "approval.resolved",
                tone: nil,
                summary: "Approval resolved",
                payload: .object([
                    "requestId": .string(requestId),
                    "requestKind": .string(kind),
                ]),
                createdAt: timestamp
            )
            state.sessions[sessionId] = session
            return true
        }
        if changed { emit() }
    }

    private func hookNudge(sessionId: String?) {
        registry?.rescan()
        pokeTailers(sessionId: sessionId)
    }

    private func pokeTailers(sessionId: String?) {
        let tailers: [JSONLTailer] = state.withLock { state in
            if let sessionId {
                return [state.sessions[sessionId]?.tailer].compactMap(\.self)
            }
            return state.sessions.values.compactMap(\.tailer)
        }
        for tailer in tailers { tailer.poke() }
    }

    // MARK: - Snapshots

    /// Called from the transport queue *and* from the hook server's queue, so
    /// the yields stay inside the lock: an out-of-order delivery would let a
    /// snapshot built before an approval arrived overwrite the one carrying it,
    /// and neither side re-emits an identical snapshot to repair that.
    private func emit() {
        state.withLock { state in
            guard !state.stopped else { return }

            var projects: [ProjectShell] = []
            var threads: [ThreadShell] = []
            var seenProjects = Set<String>()
            for id in state.order {
                guard let session = state.sessions[id] else { continue }
                if seenProjects.insert(session.entry.cwd).inserted {
                    projects.append(
                        ProjectShell(
                            id: session.entry.cwd,
                            title: lastComponent(session.entry.cwd),
                            workspaceRoot: session.workspaceRoot ?? session.entry.cwd
                        )
                    )
                }
                threads.append(buildThread(id: id, session: session))
            }

            let candidate = ShellSnapshot(
                snapshotSequence: state.snapshotSequence,
                projects: projects,
                threads: threads,
                updatedAt: threads.map(\.updatedAt).max() ?? startedAt
            )
            if state.lastSnapshot != candidate {
                state.snapshotSequence += 1
                var snapshot = candidate
                snapshot.snapshotSequence = state.snapshotSequence
                state.lastSnapshot = snapshot
                shellContinuation.yield(snapshot)
            }

            for (id, continuation) in state.detailContinuations {
                guard var session = state.sessions[id] else { continue }
                let detail = buildDetail(id: id, session: session)
                guard session.lastDetail != detail else { continue }
                session.detailSequence += 1
                session.lastDetail = detail
                state.sessions[id] = session
                continuation.yield(
                    ThreadDetailSnapshot(snapshotSequence: session.detailSequence, thread: detail)
                )
            }
        }
    }

    private func buildThread(id: String, session: SessionState) -> ThreadShell {
        let status: String
        if session.settledAt != nil {
            status = "stopped"
        } else {
            status = session.entry.isBusy ? "running" : "idle"
        }
        let updatedAt = session.entry.statusUpdatedAt
            ?? session.entry.updatedAt
            ?? session.discoveredAt

        return ThreadShell(
            id: id,
            projectId: session.entry.cwd,
            title: session.entry.name?.nilIfEmpty ?? lastComponent(session.entry.cwd),
            modelSelection: ModelSelection(
                instanceId: "claude",
                provider: "claude",
                model: session.mapper.model ?? "claude"
            ),
            branch: session.mapper.branch,
            worktreePath: session.workspaceRoot,
            latestTurn: session.mapper.latestTurn,
            createdAt: session.entry.startedAt ?? session.discoveredAt,
            updatedAt: updatedAt,
            settledAt: session.settledAt,
            session: Session(
                threadId: id,
                status: status,
                providerName: "claude",
                providerInstanceId: "claude",
                activeTurnId: session.mapper.latestTurn?.turnId,
                updatedAt: updatedAt
            ),
            hasPendingApprovals: !session.pendingApprovals.isEmpty,
            hasPendingUserInput: session.mapper.hasPendingUserInput,
            ownerPid: session.entry.pid
        )
    }

    private func buildDetail(id: String, session: SessionState) -> ThreadDetail {
        let thread = buildThread(id: id, session: session)
        return ThreadDetail(
            id: id,
            projectId: thread.projectId,
            title: thread.title,
            modelSelection: thread.modelSelection,
            branch: thread.branch,
            worktreePath: thread.worktreePath,
            latestTurn: thread.latestTurn,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            activities: session.mapper.activities,
            session: thread.session
        )
    }

    // MARK: - Paths

    /// `~/.claude/projects/<slug>/<sessionId>.jsonl`. The slug rule is
    /// unofficial, so a miss falls back to scanning the project directories.
    private func transcriptURL(for entry: ClaudeSessionEntry) -> URL? {
        let projects = claudeHome.appendingPathComponent("projects")
        let slug = entry.cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let file = "\(entry.sessionId).jsonl"
        let direct = projects.appendingPathComponent(slug).appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let directories = (try? FileManager.default.contentsOfDirectory(
            at: projects,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories {
            let candidate = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func gitRoot(for cwd: String) -> String? {
        if let cached = state.withLock({ $0.gitRoots[cwd] }) { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return cwd }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let root = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? cwd
        state.withLock { $0.gitRoots[cwd] = root }
        return root
    }

    private func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
