import Foundation
import Testing
import os
@testable import T3NotchCore

private final class FakeTransport: AgentTransport, @unchecked Sendable {
    private struct State {
        var connectionState: ConnectionState
        var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)?
        var detailContinuations: [String: AsyncStream<ThreadDetailSnapshot>.Continuation] = [:]
        var requestedDetailIds: [String] = []
        var focusCalls: [String?] = []
        var dispatched: [DispatchCommand] = []
        var expandedCalls: [Bool] = []
        var pollCount = 0
        var stopCount = 0
    }

    let shell: AsyncStream<ShellSnapshot>
    private let shellContinuation: AsyncStream<ShellSnapshot>.Continuation
    private let state: OSAllocatedUnfairLock<State>

    init(connectionState: ConnectionState = .disconnected) {
        let (stream, continuation) = AsyncStream<ShellSnapshot>.makeStream()
        self.shell = stream
        self.shellContinuation = continuation
        self.state = OSAllocatedUnfairLock(
            initialState: State(connectionState: connectionState)
        )
    }

    var connectionState: ConnectionState { state.withLock(\.connectionState) }

    var onConnectionStateChange: (@Sendable (ConnectionState) -> Void)? {
        get { state.withLock(\.onConnectionStateChange) }
        set { state.withLock { $0.onConnectionStateChange = newValue } }
    }

    var requestedDetailIds: [String] { state.withLock(\.requestedDetailIds) }
    var focusCalls: [String?] { state.withLock(\.focusCalls) }
    var dispatched: [DispatchCommand] { state.withLock(\.dispatched) }
    var expandedCalls: [Bool] { state.withLock(\.expandedCalls) }
    var pollCount: Int { state.withLock(\.pollCount) }
    var stopCount: Int { state.withLock(\.stopCount) }

    func push(_ snapshot: ShellSnapshot) {
        shellContinuation.yield(snapshot)
    }

    func pushDetail(_ snapshot: ThreadDetailSnapshot, for id: String) {
        state.withLock { $0.detailContinuations[id] }?.yield(snapshot)
    }

    func setConnectionState(_ newState: ConnectionState) {
        let callback = state.withLock { state -> (@Sendable (ConnectionState) -> Void)? in
            state.connectionState = newState
            return state.onConnectionStateChange
        }
        callback?(newState)
    }

    func threadDetail(_ id: String) -> AsyncStream<ThreadDetailSnapshot> {
        let (stream, continuation) = AsyncStream<ThreadDetailSnapshot>.makeStream()
        state.withLock { state in
            state.requestedDetailIds.append(id)
            state.detailContinuations[id]?.finish()
            state.detailContinuations[id] = continuation
        }
        return stream
    }

    func dispatch(_ command: DispatchCommand) async throws {
        state.withLock { $0.dispatched.append(command) }
    }

    func requestImmediatePoll() {
        state.withLock { $0.pollCount += 1 }
    }

    func setFocusedThread(_ id: String?) {
        state.withLock { $0.focusCalls.append(id) }
    }

    func setExpanded(_ expanded: Bool) {
        state.withLock { $0.expandedCalls.append(expanded) }
    }

    func stop() {
        let continuations: [AsyncStream<ThreadDetailSnapshot>.Continuation] = state.withLock { state in
            state.stopCount += 1
            let values = Array(state.detailContinuations.values)
            state.detailContinuations.removeAll()
            return values
        }
        for continuation in continuations { continuation.finish() }
        shellContinuation.finish()
    }
}

private func makeThread(
    id: String,
    projectId: String,
    sessionThreadId: String? = nil
) -> ThreadShell {
    ThreadShell(
        id: id,
        projectId: projectId,
        title: id,
        modelSelection: ModelSelection(model: "test"),
        updatedAt: "2026-01-01T00:00:00.000Z",
        session: sessionThreadId.map { Session(threadId: $0, status: "idle") }
    )
}

private func makeShell(
    sequence: Int,
    threads: [ThreadShell],
    projects: [ProjectShell] = [],
    updatedAt: String = "2026-01-01T00:00:00.000Z"
) -> ShellSnapshot {
    ShellSnapshot(
        snapshotSequence: sequence,
        projects: projects,
        threads: threads,
        updatedAt: updatedAt
    )
}

private func makeDetail(sequence: Int, id: String, projectId: String) -> ThreadDetailSnapshot {
    ThreadDetailSnapshot(
        snapshotSequence: sequence,
        thread: ThreadDetail(
            id: id,
            projectId: projectId,
            title: id,
            modelSelection: ModelSelection(model: "test"),
            updatedAt: "2026-01-01T00:00:00.000Z",
            session: Session(threadId: id, status: "idle")
        )
    )
}

private actor StreamWatcher {
    private(set) var ended = false
    func markEnded() { ended = true }
}

@Suite("Aggregator")
struct AggregatorTests {
    private func makeAggregate(
        t3: FakeTransport,
        claude: FakeTransport
    ) -> AggregatingTransport {
        AggregatingTransport(children: [
            .init(transport: t3, namespace: nil),
            .init(transport: claude, namespace: "claude"),
        ])
    }

    @Test func defaultChildIdsPassThroughAndNamespacedOnesArePrefixed() async throws {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }
        var shell = aggregate.shell.makeAsyncIterator()

        t3.push(
            makeShell(
                sequence: 7,
                threads: [makeThread(id: "t3-1", projectId: "p3", sessionThreadId: "t3-1")],
                projects: [ProjectShell(id: "p3", title: "T3")]
            )
        )
        _ = await shell.next()

        claude.push(
            makeShell(
                sequence: 1,
                threads: [makeThread(id: "sess-1", projectId: "/repo", sessionThreadId: "sess-1")],
                projects: [ProjectShell(id: "/repo", title: "repo")]
            )
        )
        let merged = try #require(await shell.next())

        #expect(merged.threads.map(\.id) == ["t3-1", "claude:sess-1"])
        #expect(merged.threads.map(\.projectId) == ["p3", "claude:/repo"])
        #expect(merged.threads.compactMap { $0.session?.threadId } == ["t3-1", "claude:sess-1"])
        #expect(merged.projects.map(\.id) == ["p3", "claude:/repo"])
    }

    @Test func mergedSequenceStrictlyIncreasesAcrossInterleavedChildYields() async throws {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }
        var shell = aggregate.shell.makeAsyncIterator()

        var sequences: [Int] = []
        for round in 0..<3 {
            // Children keep their own counters, and both restart at 1 here.
            t3.push(makeShell(sequence: 100 - round, threads: []))
            sequences.append(try #require(await shell.next()).snapshotSequence)
            claude.push(makeShell(sequence: 1, threads: []))
            sequences.append(try #require(await shell.next()).snapshotSequence)
        }

        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == sequences.count)
    }

    /// Each child is drained by its own task. A merge yielded after the lock was
    /// released could overtake a newer one, and consumers keep whatever arrived
    /// last — so the other child's freshest state would be lost for good.
    @Test func concurrentChildYieldsArriveInSequenceOrder() async throws {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }

        let rounds = 200
        let collector = Task { () -> [ShellSnapshot] in
            var received: [ShellSnapshot] = []
            for await snapshot in aggregate.shell {
                received.append(snapshot)
                if received.count == rounds * 2 { break }
            }
            return received
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for round in 1...rounds {
                    t3.push(
                        makeShell(
                            sequence: round,
                            threads: [makeThread(id: "t3-\(round)", projectId: "p3")]
                        )
                    )
                }
            }
            group.addTask {
                for round in 1...rounds {
                    claude.push(
                        makeShell(
                            sequence: round,
                            threads: [makeThread(id: "sess-\(round)", projectId: "/repo")]
                        )
                    )
                }
            }
        }

        let received = await collector.value
        let sequences = received.map(\.snapshotSequence)
        #expect(sequences == sequences.sorted())
        let last = try #require(received.last)
        #expect(last.threads.map(\.id) == ["t3-\(rounds)", "claude:sess-\(rounds)"])
    }

    @Test func threadDetailRoutesToTheOwningChildAndRePrefixes() async throws {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }

        var detail = aggregate.threadDetail("claude:sess-1").makeAsyncIterator()
        #expect(claude.requestedDetailIds == ["sess-1"])
        #expect(t3.requestedDetailIds.isEmpty)

        claude.pushDetail(makeDetail(sequence: 2, id: "sess-1", projectId: "/repo"), for: "sess-1")
        let snapshot = try #require(await detail.next())
        #expect(snapshot.thread.id == "claude:sess-1")
        #expect(snapshot.thread.projectId == "claude:/repo")
        #expect(snapshot.thread.session?.threadId == "claude:sess-1")
        #expect(snapshot.snapshotSequence == 2)

        var defaultDetail = aggregate.threadDetail("t3-1").makeAsyncIterator()
        #expect(t3.requestedDetailIds == ["t3-1"])
        t3.pushDetail(makeDetail(sequence: 5, id: "t3-1", projectId: "p3"), for: "t3-1")
        let defaultSnapshot = try #require(await defaultDetail.next())
        #expect(defaultSnapshot.thread.id == "t3-1")
        #expect(defaultSnapshot.thread.projectId == "p3")
    }

    @Test func focusRoutesToTheOwnerAndClearsTheOtherChildren() {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }

        aggregate.setFocusedThread("claude:sess-1")
        aggregate.setFocusedThread("t3-1")
        aggregate.setFocusedThread(nil)

        #expect(t3.focusCalls == [nil, "t3-1", nil])
        #expect(claude.focusCalls == ["sess-1", nil, nil])
    }

    @Test func dispatchStripsThePrefixBeforeRouting() async throws {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }

        try await aggregate.dispatch(
            .approvalRespond(
                commandId: "c1",
                threadId: "claude:sess-1",
                requestId: "r1",
                decision: .accept,
                createdAt: "2026-01-01T00:00:00.000Z"
            )
        )
        try await aggregate.dispatch(
            .turnInterrupt(
                commandId: "c2",
                threadId: "t3-1",
                turnId: nil,
                createdAt: "2026-01-01T00:00:00.000Z"
            )
        )

        #expect(claude.dispatched.map(\.threadId) == ["sess-1"])
        #expect(t3.dispatched.map(\.threadId) == ["t3-1"])
    }

    @Test func dispatchWithoutADefaultChildFailsInsteadOfMisrouting() async {
        let claude = FakeTransport()
        let aggregate = AggregatingTransport(children: [
            .init(transport: claude, namespace: "claude")
        ])
        defer { aggregate.stop() }

        await #expect(throws: AgentTransportError.self) {
            try await aggregate.dispatch(
                .turnInterrupt(
                    commandId: "c1",
                    threadId: "unknown",
                    turnId: nil,
                    createdAt: "2026-01-01T00:00:00.000Z"
                )
            )
        }
    }

    @Test(arguments: [
        (ConnectionState.disconnected, ConnectionState.connected, ConnectionState.connected),
        (.connected, .disconnected, .connected),
        (.connecting, .disconnected, .connecting),
        (.unauthorized, .connecting, .connecting),
        (.unauthorized, .disconnected, .unauthorized),
        (.disconnected, .unauthorized, .disconnected),
        (.disconnected, .disconnected, .disconnected),
    ])
    func connectionCombineTruthTable(
        t3State: ConnectionState,
        claudeState: ConnectionState,
        expected: ConnectionState
    ) {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }

        t3.setConnectionState(t3State)
        claude.setConnectionState(claudeState)

        #expect(aggregate.connectionState == expected)
        #expect(aggregate.connectionState(forNamespace: nil) == t3State)
        #expect(aggregate.connectionState(forNamespace: "claude") == claudeState)
        #expect(aggregate.connectionState(forNamespace: "codex") == .disconnected)
    }

    @Test func connectionCallbackFiresOnlyOnChange() {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }

        let observed = OSAllocatedUnfairLock(initialState: [ConnectionState]())
        aggregate.onConnectionStateChange = { state in
            observed.withLock { $0.append(state) }
        }

        t3.setConnectionState(.connected)
        claude.setConnectionState(.connected)
        claude.setConnectionState(.disconnected)
        t3.setConnectionState(.disconnected)

        #expect(observed.withLock { $0 } == [.connected, .disconnected])
    }

    @Test func broadcastsPollAndExpansionAndStopsChildren() {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)

        aggregate.requestImmediatePoll()
        aggregate.setExpanded(true)
        aggregate.stop()
        aggregate.stop()

        #expect(t3.pollCount == 1)
        #expect(claude.pollCount == 1)
        #expect(t3.expandedCalls == [true])
        #expect(claude.expandedCalls == [true])
        #expect(t3.stopCount == 1)
        #expect(claude.stopCount == 1)
    }

    /// Same invariant `PollingTransport` carries: focus is re-asserted on every
    /// shell snapshot and must not end the detail stream the UI is iterating.
    @Test func focusChangeDoesNotEndAnOpenDetailStream() async throws {
        let t3 = FakeTransport()
        let claude = FakeTransport()
        let aggregate = makeAggregate(t3: t3, claude: claude)
        defer { aggregate.stop() }

        let watcher = StreamWatcher()
        let stream = aggregate.threadDetail("claude:sess-1")
        let consumer = Task {
            for await _ in stream {}
            await watcher.markEnded()
        }

        for _ in 0..<5 {
            aggregate.setFocusedThread("claude:sess-1")
            aggregate.setFocusedThread("t3-1")
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await watcher.ended == false)
        #expect(claude.requestedDetailIds == ["sess-1"])
        consumer.cancel()
    }

    /// Claude and Codex are left off here on purpose: their transports read the
    /// real `~/.claude` and `~/.codex`, which tests must never touch.
    @Test func factoryGivesT3ThePassThroughNamespace() async {
        let t3 = FakeTransport(connectionState: .connected)
        let aggregate = TransportFactory.makeAggregate(
            t3: t3,
            enableClaude: false,
            enableCodex: false
        )
        defer { aggregate.stop() }

        #expect(TransportFactory.namespace(for: .t3) == nil)
        #expect(TransportFactory.namespace(for: .claude) == "claude")
        #expect(TransportFactory.namespace(for: .codex) == "codex")
        #expect(aggregate.connectionState(forNamespace: nil) == .connected)
        #expect(aggregate.connectionState(forNamespace: "claude") == .disconnected)

        try? await aggregate.dispatch(
            .approvalRespond(
                commandId: "c1",
                threadId: "thread_1",
                requestId: "r1",
                decision: .accept,
                createdAt: "2026-01-01T00:00:00.000Z"
            )
        )
        #expect(t3.dispatched.map(\.threadId) == ["thread_1"])
    }

    @Test func agentSourceParsesThePrefix() {
        #expect(AgentSource(threadId: "claude:sess-1") == .claude)
        #expect(AgentSource(threadId: "codex:0199") == .codex)
        #expect(AgentSource(threadId: "thread_01ABC") == .t3)
        #expect(AgentSource(threadId: "t3:weird") == .t3)
        #expect(AgentSource(threadId: "other:thing") == .t3)
    }
}
