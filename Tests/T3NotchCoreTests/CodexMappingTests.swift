import Foundation
import Testing
@testable import T3NotchCore

private actor StreamWatcher {
    private(set) var ended = false
    func markEnded() { ended = true }
}

@Suite("CodexMapping")
struct CodexMappingTests {
    private static func fixtureLines() throws -> [Data] {
        let url = try #require(
            Bundle.module.url(forResource: "codex_rollout", withExtension: "jsonl", subdirectory: "Fixtures")
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map { Data($0.utf8) }
    }

    private static func mappedFixture() throws -> CodexRolloutMapper {
        var mapper = CodexRolloutMapper(sessionId: "unknown")
        for line in try fixtureLines() { mapper.ingest(line: line) }
        return mapper
    }

    @Test func sessionMetaAndTurnContextDescribeTheThread() throws {
        let state = try Self.mappedFixture().state
        #expect(state.sessionId == "019f9b5d-3efc-70d0-9f39-f17142161ead")
        #expect(state.cwd == "/tmp/demo")
        #expect(state.branch == "feature/notch")
        #expect(state.model == "gpt-5.6-codex")
        #expect(state.title == "Find the needle and patch the notch")
    }

    @Test func execCallSurvivesEscapedQuotes() throws {
        let started = try #require(
            Self.mappedFixture().state.activities.first { $0.kind == "tool.started" }
        )
        #expect(started.summary == "Ran command")
        #expect(started.tone == "tool")
        #expect(started.payload?["itemType"]?.stringValue == "command_execution")
        #expect(started.payload?["detail"]?.stringValue == #"rg -n "needle" src"#)
        #expect(started.turnId == "turn-1")
    }

    @Test func olderShellCallsFallBackToArgv() throws {
        let activities = try Self.mappedFixture().state.activities
        let shellCall = try #require(
            activities.first {
                $0.kind == "tool.started" && $0.payload?["detail"]?.stringValue == "git status --short"
            }
        )
        #expect(shellCall.payload?["itemType"]?.stringValue == "command_execution")
    }

    /// Both halves carry the same detail, which is what lets the notch fold a
    /// running command and its completion into a single row.
    @Test func outputsPairWithTheirCallByRepeatingTheDetail() throws {
        let activities = try Self.mappedFixture().state.activities
        let completions = activities.filter {
            $0.kind == "tool.completed" && $0.payload?["itemType"]?.stringValue == "command_execution"
        }
        #expect(completions.count == 2)
        #expect(completions.map { $0.payload?["detail"]?.stringValue } == [
            #"rg -n "needle" src"#,
            "git status --short",
        ])

        let rows = deriveRecentActivity(from: activities, limit: 10, relativeTo: "/tmp/demo")
        let commands = rows.filter { $0.kind == .command }
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { !$0.isRunning })
    }

    @Test func anOutputForAnUnknownCallIsIgnored() throws {
        let activities = try Self.mappedFixture().state.activities
        #expect(!activities.contains { $0.payload?["detail"]?.stringValue == "orphan" })
    }

    @Test func planStatusesAreRenamedForTheNotch() throws {
        let state = try Self.mappedFixture().state
        let plan = try #require(
            deriveActivePlanState(from: state.activities, latestTurnId: "turn-1")
        )
        #expect(plan.steps.map(\.status) == [.inProgress, .pending, .completed])
        #expect(plan.steps.first?.step == "Search for the needle")
    }

    @Test func tokenCountsBecomeTheContextWindow() throws {
        let state = try Self.mappedFixture().state
        let context = try #require(deriveLatestContextWindowSnapshot(from: state.activities))
        #expect(context.usedTokens == 23646)
        #expect(context.maxTokens == 258400)
        #expect(state.activities.filter { $0.kind == "context-window.updated" }.count == 1)
    }

    @Test func patchApplyEndAppendsALoneCompletion() throws {
        let activities = try Self.mappedFixture().state.activities
        let patch = try #require(
            activities.first {
                $0.kind == "tool.completed" && $0.summary == "Changed file"
            }
        )
        #expect(patch.payload?["itemType"]?.stringValue == "file_change")
        let paths = patch.payload?["data"]?["item"]?["changes"]?.arrayValue?
            .compactMap { $0["path"]?.stringValue }
        #expect(paths == ["/tmp/demo/src/notch.swift"])
        #expect(!activities.contains { $0.kind == "tool.started" && $0.summary == "Changed file" })
    }

    @Test func unknownLineTypesAreSkippedNotFatal() throws {
        var mapper = CodexRolloutMapper(sessionId: "s")
        let unknown = Data(#"{"timestamp":"2026-07-27T19:00:00.000Z","type":"turn_diff","payload":{"unified_diff":"@@"}}"#.utf8)
        #expect(mapper.ingest(line: unknown) == false)
        #expect(mapper.ingest(line: Data("not json at all".utf8)) == false)
        #expect(mapper.state.activities.isEmpty)
    }

    @Test func turnLifecycleDrivesStatusAndPhase() throws {
        var mapper = CodexRolloutMapper(sessionId: "s")
        let lines = try Self.fixtureLines()

        for line in lines.prefix(3) { mapper.ingest(line: line) }
        #expect(mapper.state.status == "running")
        #expect(mapper.state.latestTurn?.state == "running")
        #expect(mapper.state.settledAt == nil)

        for line in lines.dropFirst(3).prefix(11) { mapper.ingest(line: line) }
        #expect(mapper.state.status == "idle")
        #expect(mapper.state.latestTurn?.state == "completed")
        #expect(mapper.state.latestTurn?.completedAt == "2026-07-27T19:23:30.000Z")
        #expect(mapper.state.settledAt == "2026-07-27T19:23:30.000Z")

        for line in lines.dropFirst(14) { mapper.ingest(line: line) }
        let turn = try #require(mapper.state.latestTurn)
        #expect(turn.turnId == "turn-2")
        #expect(turn.state == "interrupted")
        // An interrupted turn only reads as finished when completedAt is set.
        #expect(turn.completedAt == "2026-07-27T19:23:45.000Z")
    }

    @Test func anInterruptedSessionReadsAsCompleted() throws {
        let state = try Self.mappedFixture().state
        let thread = ThreadShell(
            id: state.sessionId,
            projectId: state.cwd ?? "",
            title: state.title ?? "",
            modelSelection: ModelSelection(model: state.model ?? "codex"),
            latestTurn: state.latestTurn,
            updatedAt: state.updatedAt ?? "",
            session: Session(status: state.status)
        )
        #expect(resolveThreadAwarenessPhase(thread) == .completed)
    }
}

@Suite("CodexTransport")
struct CodexTransportTests {
    /// Builds a `~/.codex`-shaped temp directory holding today's rollout.
    private static func makeCodexHome() throws -> (URL, String) {
        let sessionId = "019f9b5d-3efc-70d0-9f39-f17142161ead"
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)")
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: Date())
        let day = home
            .appendingPathComponent("sessions")
            .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
            .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
            .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let fixture = try #require(
            Bundle.module.url(forResource: "codex_rollout", withExtension: "jsonl", subdirectory: "Fixtures")
        )
        let rollout = day.appendingPathComponent("rollout-2026-07-27T16-23-38-\(sessionId).jsonl")
        try FileManager.default.copyItem(at: fixture, to: rollout)
        // Liveness is an mtime window, and a copy inherits the fixture's date.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rollout.path)
        return (home, sessionId)
    }

    /// Fails the test rather than hanging when no matching snapshot arrives. The
    /// roster is emitted as soon as a rollout is discovered, so tests wait for
    /// the one that carries the tailed content.
    private static func firstSnapshot(
        _ transport: CodexTransport,
        matching predicate: @escaping @Sendable (ShellSnapshot) -> Bool
    ) async -> ShellSnapshot? {
        let shell = transport.shell
        return await withTaskGroup(of: ShellSnapshot?.self) { group in
            group.addTask {
                for await snapshot in shell where predicate(snapshot) { return snapshot }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func tailsTodaysRolloutsIntoTheShell() async throws {
        let (home, sessionId) = try Self.makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = CodexTransport(codexHome: home)
        defer { transport.stop() }

        let snapshot = try #require(
            await Self.firstSnapshot(transport) { $0.threads.first?.branch != nil }
        )
        let thread = try #require(snapshot.threads.first)
        #expect(thread.id == sessionId)
        #expect(thread.projectId == "/tmp/demo")
        #expect(thread.title == "Find the needle and patch the notch")
        #expect(thread.branch == "feature/notch")
        #expect(thread.modelSelection.provider == "codex")
        #expect(thread.hasPendingApprovals == false)
        #expect(thread.hasPendingUserInput == false)
    }

    /// Resuming appends to the rollout in its original date directory, so a
    /// months-old folder with a freshly touched file must still go live.
    @Test func findsAResumedRolloutInAnOldDateDirectory() async throws {
        let sessionId = "019f9b5d-3efc-70d0-9f39-f17142161ead"
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2025/03/05")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let fixture = try #require(
            Bundle.module.url(forResource: "codex_rollout", withExtension: "jsonl", subdirectory: "Fixtures")
        )
        let rollout = day.appendingPathComponent("rollout-2025-03-05T09-00-00-\(sessionId).jsonl")
        try FileManager.default.copyItem(at: fixture, to: rollout)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: rollout.path)

        let transport = CodexTransport(codexHome: home)
        defer { transport.stop() }
        let snapshot = try #require(
            await Self.firstSnapshot(transport) { $0.threads.first?.branch != nil }
        )
        #expect(snapshot.threads.first?.id == sessionId)
    }

    @Test func dispatchIsUnsupported() async throws {
        let (home, sessionId) = try Self.makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = CodexTransport(codexHome: home)
        defer { transport.stop() }

        await #expect(throws: AgentTransportError.self) {
            try await transport.dispatch(
                .turnInterrupt(
                    commandId: "c",
                    threadId: sessionId,
                    turnId: nil,
                    createdAt: "2026-07-27T19:23:45.000Z"
                )
            )
        }
    }

    /// Mirrors the PollingTransport invariant: focus is re-asserted on every
    /// snapshot, and must never end the detail stream the UI is iterating.
    @Test func focusChangeDoesNotEndAnOpenDetailStream() async throws {
        let (home, sessionId) = try Self.makeCodexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = CodexTransport(codexHome: home)
        defer { transport.stop() }

        let watcher = StreamWatcher()
        let stream = transport.threadDetail(sessionId)
        let consumer = Task {
            for await _ in stream {}
            await watcher.markEnded()
        }

        for _ in 0..<5 {
            transport.setFocusedThread(sessionId)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(await watcher.ended == false)
        consumer.cancel()
    }
}
