import Foundation
import os

/// Which agent runtime a namespaced thread id belongs to.
public enum AgentSource: String, Sendable, CaseIterable {
    case t3
    case claude
    case codex

    /// Threads coming from the default (T3) child keep their raw ids, so an
    /// unprefixed id resolves to `.t3`.
    public init(threadId: String) {
        guard let separator = threadId.firstIndex(of: ":"),
              let source = AgentSource(rawValue: String(threadId[threadId.startIndex..<separator])),
              source != .t3
        else {
            self = .t3
            return
        }
        self = source
    }
}

/// Presents several transports as one. Ids of namespaced children are prefixed
/// outbound (`claude:<id>`) and stripped inbound; the default child (namespace
/// `nil`, i.e. T3) passes ids through so persisted focus keeps working.
public final class AggregatingTransport: AgentTransport, @unchecked Sendable {
    public struct Child: Sendable {
        public let transport: any AgentTransport
        public let namespace: String?

        public init(transport: any AgentTransport, namespace: String?) {
            self.transport = transport
            self.namespace = namespace
        }
    }

    private struct State {
        var snapshots: [ShellSnapshot?]
        var childStates: [ConnectionState]
        var connectionState: ConnectionState = .connecting
        var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)?
        var sequence = 0
        var shellTasks: [Task<Void, Never>] = []
        var detailTasks: [String: Task<Void, Never>] = [:]
        var detailContinuations: [String: AsyncStream<ThreadDetailSnapshot>.Continuation] = [:]
        var stopped = false
    }

    private let children: [Child]
    private let shellContinuation: AsyncStream<ShellSnapshot>.Continuation
    public let shell: AsyncStream<ShellSnapshot>
    private let state: OSAllocatedUnfairLock<State>

    public var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)? {
        get { state.withLock(\.onConnectionStateChange) }
        set { state.withLock { $0.onConnectionStateChange = newValue } }
    }

    public var connectionState: ConnectionState {
        state.withLock(\.connectionState)
    }

    public init(children: [Child]) {
        self.children = children
        let (stream, continuation) = AsyncStream<ShellSnapshot>.makeStream()
        self.shell = stream
        self.shellContinuation = continuation
        self.state = OSAllocatedUnfairLock(
            initialState: State(
                snapshots: Array(repeating: nil, count: children.count),
                childStates: children.map { $0.transport.connectionState }
            )
        )
        state.withLock { $0.connectionState = Self.combine(children: children, states: $0.childStates) }
        observeChildren()
    }

    deinit {
        stop()
    }

    /// Per-source state for the settings rows; `nil` asks for the default child.
    public func connectionState(forNamespace namespace: String?) -> ConnectionState {
        guard let index = children.firstIndex(where: { $0.namespace == namespace }) else {
            return .disconnected
        }
        return state.withLock { $0.childStates[index] }
    }

    public func threadDetail(_ id: String) -> AsyncStream<ThreadDetailSnapshot> {
        let (stream, continuation) = AsyncStream<ThreadDetailSnapshot>.makeStream()
        guard let route = route(for: id) else {
            continuation.finish()
            return stream
        }

        let childStream = children[route.index].transport.threadDetail(route.strippedId)
        let namespace = children[route.index].namespace
        let previous: Task<Void, Never>? = state.withLock { state in
            let old = state.detailTasks[id]
            state.detailContinuations[id]?.finish()
            state.detailContinuations[id] = continuation
            let task = Task {
                for await snapshot in childStream {
                    var snapshot = snapshot
                    snapshot.thread.id = Self.prefixed(snapshot.thread.id, namespace)
                    snapshot.thread.projectId = Self.prefixed(snapshot.thread.projectId, namespace)
                    if let threadId = snapshot.thread.session?.threadId {
                        snapshot.thread.session?.threadId = Self.prefixed(threadId, namespace)
                    }
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }
            state.detailTasks[id] = task
            return old
        }
        previous?.cancel()

        return stream
    }

    public func dispatch(_ command: DispatchCommand) async throws {
        guard let route = route(for: command.threadId) else {
            throw AgentTransportError.threadNotFound(command.threadId)
        }
        try await children[route.index].transport
            .dispatch(command.replacingThreadId(route.strippedId))
    }

    public func requestImmediatePoll() {
        for child in children { child.transport.requestImmediatePoll() }
    }

    /// Only the owning child keeps a focused thread; the others are told nothing
    /// is focused. Like `PollingTransport`, this never opens a detail stream, so
    /// re-asserting focus cannot end the one the UI is iterating.
    public func setFocusedThread(_ id: String?) {
        let route = id.flatMap { self.route(for: $0) }
        for (index, child) in children.enumerated() {
            child.transport.setFocusedThread(index == route?.index ? route?.strippedId : nil)
        }
    }

    public func setExpanded(_ expanded: Bool) {
        for child in children { child.transport.setExpanded(expanded) }
    }

    public func stop() {
        let tasks: [Task<Void, Never>]? = state.withLock { state in
            guard !state.stopped else { return nil }
            state.stopped = true
            var tasks = state.shellTasks
            state.shellTasks.removeAll()
            tasks.append(contentsOf: state.detailTasks.values)
            state.detailTasks.removeAll()
            for continuation in state.detailContinuations.values {
                continuation.finish()
            }
            state.detailContinuations.removeAll()
            return tasks
        }
        guard let tasks else { return }
        for task in tasks { task.cancel() }
        for child in children { child.transport.stop() }
        shellContinuation.finish()
    }

    private struct Route {
        let index: Int
        let strippedId: String
    }

    private func route(for id: String) -> Route? {
        for (index, child) in children.enumerated() {
            guard let namespace = child.namespace, id.hasPrefix(namespace + ":") else { continue }
            return Route(index: index, strippedId: String(id.dropFirst(namespace.count + 1)))
        }
        guard let defaultIndex = children.firstIndex(where: { $0.namespace == nil }) else {
            return nil
        }
        return Route(index: defaultIndex, strippedId: id)
    }

    private func observeChildren() {
        var tasks: [Task<Void, Never>] = []
        for (index, child) in children.enumerated() {
            child.transport.onConnectionStateChange = { [weak self] childState in
                self?.applyConnectionState(childState, at: index)
            }
            let shell = child.transport.shell
            tasks.append(
                Task { [weak self] in
                    for await snapshot in shell {
                        self?.applyShell(snapshot, at: index)
                    }
                }
            )
        }
        let started = tasks
        state.withLock { $0.shellTasks = started }
    }

    /// One task per child runs this concurrently. The yield stays inside the
    /// lock so it cannot be reordered against the sequence it was stamped with:
    /// consumers keep the value they saw last, so an older merge arriving after
    /// a newer one would drop the other child's freshest state permanently.
    private func applyShell(_ snapshot: ShellSnapshot, at index: Int) {
        state.withLock { state in
            guard !state.stopped else { return }
            state.snapshots[index] = snapshot
            state.sequence += 1
            let merged = self.merge(snapshots: state.snapshots, sequence: state.sequence)
            Logger(subsystem: "gg.t3tools.t3notch", category: "trace")
                .debug("aggregate: child \(index) yielded \(snapshot.threads.count) threads; merged \(merged.threads.count)")
            shellContinuation.yield(merged)
        }
    }

    private func merge(snapshots: [ShellSnapshot?], sequence: Int) -> ShellSnapshot {
        var projects: [ProjectShell] = []
        var threads: [ThreadShell] = []
        var updatedAt: String?
        for (index, snapshot) in snapshots.enumerated() {
            guard let snapshot else { continue }
            let namespace = children[index].namespace
            for var project in snapshot.projects {
                project.id = Self.prefixed(project.id, namespace)
                projects.append(project)
            }
            for var thread in snapshot.threads {
                thread.id = Self.prefixed(thread.id, namespace)
                thread.projectId = Self.prefixed(thread.projectId, namespace)
                if let threadId = thread.session?.threadId {
                    thread.session?.threadId = Self.prefixed(threadId, namespace)
                }
                threads.append(thread)
            }
            updatedAt = max(updatedAt ?? snapshot.updatedAt, snapshot.updatedAt)
        }
        return ShellSnapshot(
            snapshotSequence: sequence,
            projects: projects,
            threads: threads,
            updatedAt: updatedAt ?? ISO8601DateFormatter().string(from: Date())
        )
    }

    private func applyConnectionState(_ childState: ConnectionState, at index: Int) {
        let (changed, merged, callback) = state.withLock { state
            -> (Bool, ConnectionState, (@Sendable (ConnectionState) -> Void)?) in
            state.childStates[index] = childState
            let merged = Self.combine(children: self.children, states: state.childStates)
            let changed = state.connectionState != merged
            state.connectionState = merged
            return (changed, merged, state.onConnectionStateChange)
        }
        if changed { callback?(merged) }
    }

    /// Local transports report `.unauthorized` for nothing, and a broken T3
    /// token must not paint the whole app as signed out, so that state only
    /// survives when it comes from the default child alone.
    private static func combine(children: [Child], states: [ConnectionState]) -> ConnectionState {
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) { return .connecting }
        let defaultIndex = children.firstIndex { $0.namespace == nil }
        if let defaultIndex, states[defaultIndex] == .unauthorized { return .unauthorized }
        return .disconnected
    }

    private static func prefixed(_ id: String, _ namespace: String?) -> String {
        guard let namespace else { return id }
        return "\(namespace):\(id)"
    }
}
